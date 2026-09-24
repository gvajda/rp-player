import AudioToolbox
import AVFAudio
import Foundation

@MainActor
public final class PluginHost: ObservableObject {
    @Published public private(set) var current: ImportedPlugin?
    @Published public private(set) var loadError: String?
    public private(set) var audioUnit: AVAudioUnit?

    private let store: PluginStore
    private let setUnit: @Sendable (AudioUnit?) -> Void
    private let logger: (any Logging)?
    private var tail: Task<Void, Never>?

    public init(store: PluginStore, setUnit: @escaping @Sendable (AudioUnit?) -> Void, logger: (any Logging)? = nil) {
        self.store = store
        self.setUnit = setUnit
        self.logger = logger
    }

    // Serialized so an overlapping select sees the true previous unit and the last request wins, never a torn handoff.
    public func select(_ id: String?) async {
        let prior = tail
        let task = Task { await prior?.value; await self.perform(id) }
        tail = task
        await task.value
    }

    private func perform(_ id: String?) async {
        if let current, let audioUnit {
            await save(id: current.id, unit: audioUnit)
        }
        let previous = audioUnit
        audioUnit = nil
        current = nil
        loadError = nil
        if let id {
            do {
                let (plugin, unit) = try await load(id: id)
                audioUnit = unit
                current = plugin
                logger?.info("plugin host: loaded \(plugin.component.manufacturerName): \(plugin.component.name)")
            } catch {
                loadError = Self.message(for: error)
                logger?.error("plugin host: loading \(id) failed: \(error)")
            }
        }
        let handoff = UnitHandoff(unit: audioUnit?.audioUnit)
        let setUnit = self.setUnit
        // rpbridge_set_unit can wait on a lazy AudioUnitInitialize inside run(); never block the main thread on it.
        await Task.detached { setUnit(handoff.unit) }.value
        withExtendedLifetime(previous) {}
    }

    public func saveCurrentState() async {
        guard let current, let audioUnit else { return }
        await save(id: current.id, unit: audioUnit)
    }

    // Synchronous so it can be called from applicationWillTerminate before the main thread blocks on shutdown.
    public func stateSnapshot() -> (id: String, data: Data)? {
        guard let current, let audioUnit, let data = Self.serializedState(audioUnit) else { return nil }
        return (current.id, data)
    }

    private func save(id: String, unit: AVAudioUnit) async {
        guard let data = Self.serializedState(unit) else { return }
        do {
            try await store.saveState(id: id, data)
        } catch {
            logger?.error("plugin host: saving state for \(id) failed: \(error)")
        }
    }

    private static func serializedState(_ unit: AVAudioUnit) -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func load(id: String) async throws -> (ImportedPlugin, AVAudioUnit) {
        guard let plugin = await store.plugin(id: id) else { throw PluginHostError.notFound }
        var desc = plugin.component.componentDescription
        if AudioComponentFindNext(nil, &desc) == nil {
            try register(plugin)
        }
        let unit = try await AVAudioUnit.instantiate(with: desc, options: [])
        if let data = await store.loadState(id: id),
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        return (plugin, unit)
    }

    // Process-local registration: invisible to other apps, cannot be undone, and the bundle stays loaded.
    private func register(_ plugin: ImportedPlugin) throws {
        guard let bundle = CFBundleCreate(nil, plugin.bundleURL as CFURL) else {
            throw PluginHostError.bundleLoadFailed("the bundle could not be opened")
        }
        var cfError: Unmanaged<CFError>?
        guard CFBundleLoadExecutableAndReturnError(bundle, &cfError) else {
            throw PluginHostError.bundleLoadFailed(cfError?.takeRetainedValue().localizedDescription ?? "unknown error")
        }
        guard let pointer = CFBundleGetFunctionPointerForName(bundle, plugin.component.factoryFunction as CFString) else {
            throw PluginHostError.factoryMissing(plugin.component.factoryFunction)
        }
        let factory = unsafeBitCast(pointer, to: AudioComponentFactoryFunction.self)
        var desc = plugin.component.componentDescription
        let name = "\(plugin.component.manufacturerName): \(plugin.component.name)" as CFString
        AudioComponentRegister(&desc, name, plugin.component.version, factory)
    }

    static func message(for error: Error) -> String {
        switch error {
        case PluginHostError.notFound:
            return "The selected plugin is no longer installed."
        case PluginHostError.bundleLoadFailed(let reason):
            return "The plugin could not be loaded (\(reason)). Open the plugin once in Finder, or check that it is signed."
        case PluginHostError.factoryMissing:
            return "The plugin is not a usable Audio Unit."
        default:
            return "The plugin could not be started (\(error.localizedDescription))."
        }
    }
}

enum PluginHostError: Error {
    case notFound
    case bundleLoadFailed(String)
    case factoryMissing(String)
}

private struct UnitHandoff: @unchecked Sendable {
    let unit: AudioUnit?
}
