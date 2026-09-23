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

    public init(store: PluginStore, setUnit: @escaping @Sendable (AudioUnit?) -> Void, logger: (any Logging)? = nil) {
        self.store = store
        self.setUnit = setUnit
        self.logger = logger
    }

    public func select(_ id: String?) async {
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
        guard let current, let state = audioUnit?.auAudioUnit.fullState else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            try await store.saveState(id: current.id, data)
        } catch {
            logger?.error("plugin host: saving state for \(current.id) failed: \(error)")
        }
    }

    private func load(id: String) async throws -> (ImportedPlugin, AVAudioUnit) {
        guard let plugin = await store.plugin(id: id) else { throw PluginHostError.notFound }
        var desc = plugin.component.componentDescription
        if AudioComponentFindNext(nil, &desc) == nil {
            try register(plugin)
        }
        let unit = try await Self.instantiate(with: desc)
        if let data = await store.loadState(id: id),
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        return (plugin, unit)
    }

    private static func instantiate(with description: AudioComponentDescription) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: []) { unit, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let unit {
                    let box = UnitBox(unit: unit)
                    continuation.resume(returning: box.unit)
                } else {
                    continuation.resume(throwing: PluginHostError.registrationFailed)
                }
            }
        }
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
        guard AudioComponentRegister(&desc, name, plugin.component.version, factory) != nil else {
            throw PluginHostError.registrationFailed
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case PluginHostError.notFound:
            return "The selected plugin is no longer installed."
        case PluginHostError.bundleLoadFailed(let reason):
            return "The plugin could not be loaded (\(reason)). Open the plugin once in Finder, or check that it is signed."
        case PluginHostError.factoryMissing, PluginHostError.registrationFailed:
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
    case registrationFailed
}

private struct UnitHandoff: @unchecked Sendable {
    let unit: AudioUnit?
}

private struct UnitBox: @unchecked Sendable {
    let unit: AVAudioUnit
}
