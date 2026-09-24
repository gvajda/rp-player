import Foundation

@MainActor
final class AudioUnitSettingsModel: ObservableObject {
    @Published private(set) var plugins: [ImportedPlugin] = []
    @Published private(set) var pluginEnabled = false
    @Published private(set) var pluginId: String?
    @Published private(set) var hasOutputDevice = false

    let isBridgeAvailable: Bool
    let host: PluginHost

    private let configStore: any ConfigStore
    private let store: PluginStore
    private let logger: (any Logging)?
    private var configTask: Task<Void, Never>?

    init(configStore: any ConfigStore, store: PluginStore, host: PluginHost, isBridgeAvailable: Bool,
         logger: (any Logging)? = nil) {
        self.configStore = configStore
        self.store = store
        self.host = host
        self.isBridgeAvailable = isBridgeAvailable
        self.logger = logger
    }

    func start() async {
        stop()
        apply(await configStore.settings)
        let stream = await configStore.changes
        configTask = Task { [weak self] in
            for await settings in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(settings)
            }
        }
        await refreshPlugins()
    }

    func stop() {
        configTask?.cancel()
        configTask = nil
    }

    func refreshPlugins() async {
        plugins = await store.list()
    }

    func setEnabled(_ value: Bool) async {
        await updateCurrentProfile { $0.pluginEnabled = value }
    }

    func setPluginId(_ id: String?) async {
        await updateCurrentProfile { $0.pluginId = id }
    }

    func importComponent(from url: URL) async throws {
        let imported = try await store.importComponent(from: url)
        await refreshPlugins()
        await updateCurrentProfile {
            $0.pluginId = imported.id
            $0.pluginEnabled = true
        }
    }

    // Config first: the binder deselects before the folder disappears, so nothing points at a deleted bundle.
    func deletePlugin(id: String) async throws {
        try await configStore.update { settings in
            for (uid, var profile) in settings.audioProfiles where profile.pluginId == id {
                profile.pluginId = nil
                settings.audioProfiles[uid] = profile
            }
        }
        try await store.delete(id: id)
        await refreshPlugins()
    }

    static func message(for error: Error) -> String {
        switch error {
        case PluginStoreError.notAComponent: return "This isn't an Audio Unit plugin (.component)."
        case PluginStoreError.notAnEffect: return "This plugin is an instrument or generator. Only effect plugins can be used."
        case PluginStoreError.wrongArchitecture: return "This plugin doesn't support this Mac's processor (it may be Intel-only)."
        case PluginStoreError.duplicate(let name): return "\u{201C}\(name)\u{201D} is already imported. Delete it first to import another copy."
        case PluginStoreError.notFound: return "The plugin is no longer installed."
        case PluginStoreError.ioFailure(let reason): return "The plugin couldn't be copied (\(reason))."
        default: return error.localizedDescription
        }
    }

    private func apply(_ settings: AppSettings) {
        let profile = settings.outputDeviceUID.flatMap { settings.audioProfiles[$0] }
        hasOutputDevice = settings.outputDeviceUID != nil
        pluginEnabled = profile?.pluginEnabled ?? false
        pluginId = profile?.pluginId
    }

    private func updateCurrentProfile(_ mutate: @escaping @Sendable (inout AudioProfile) -> Void) async {
        do {
            try await configStore.update { s in
                guard let uid = s.outputDeviceUID else { return }
                var p = s.audioProfiles[uid] ?? .safeDefault
                mutate(&p)
                s.audioProfiles[uid] = p
            }
        } catch {
            logger?.error("AudioUnitSettingsModel: config update failed: \(error)")
        }
    }
}
