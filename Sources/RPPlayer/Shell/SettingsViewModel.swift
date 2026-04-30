import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var bitrate: Int
    @Published private(set) var hogModeEnabled: Bool
    @Published private(set) var softwareVolumeEnabled: Bool
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var isSignedIn: Bool = false

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openDataFolderAction: @MainActor () -> Void
    private let openLogsFolderAction: @MainActor () -> Void

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openDataFolder: @escaping @MainActor () -> Void,
        openLogsFolder: @escaping @MainActor () -> Void
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openDataFolderAction = openDataFolder
        self.openLogsFolderAction = openLogsFolder

        let snapshot = AppSettings.default
        self.selectedChannelId = snapshot.selectedChannelId
        self.bitrate = snapshot.bitrate
        self.hogModeEnabled = snapshot.hogModeEnabled
        self.softwareVolumeEnabled = snapshot.softwareVolumeEnabled
        self.notificationsEnabled = snapshot.notificationsEnabled
        self.outputDeviceUID = snapshot.outputDeviceUID
    }

    func start() async {
        await stop()
        let configStream = await configStore.changes
        configTask = Task { [weak self] in
            for await snapshot in configStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.selectedChannelId = snapshot.selectedChannelId
                    self.bitrate = snapshot.bitrate
                    self.hogModeEnabled = snapshot.hogModeEnabled
                    self.softwareVolumeEnabled = snapshot.softwareVolumeEnabled
                    self.notificationsEnabled = snapshot.notificationsEnabled
                    self.outputDeviceUID = snapshot.outputDeviceUID
                }
            }
        }
        let deviceStream = await deviceCatalog.changes
        deviceTask = Task { [weak self] in
            for await devices in deviceStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run { self.devices = devices }
            }
        }
        isSignedIn = auth.isLoggedIn
    }

    func stop() async {
        configTask?.cancel()
        configTask = nil
        deviceTask?.cancel()
        deviceTask = nil
    }

    func setBitrate(_ value: Int) async {
        await update { $0.bitrate = value }
    }

    func setHogModeEnabled(_ value: Bool) async {
        await update { $0.hogModeEnabled = value }
    }

    func setSoftwareVolumeEnabled(_ value: Bool) async {
        await update { $0.softwareVolumeEnabled = value }
    }

    func setNotificationsEnabled(_ value: Bool) async {
        await update { $0.notificationsEnabled = value }
    }

    func setOutputDeviceUID(_ value: String?) async {
        await update { $0.outputDeviceUID = value }
    }

    func signOut() async {
        await auth.clearCookie()
        isSignedIn = auth.isLoggedIn
    }

    func openLoginWindow() { openLoginWindowAction() }
    func openDataFolder() { openDataFolderAction() }
    func openLogsFolder() { openLogsFolderAction() }

    func refreshAuthState() {
        isSignedIn = auth.isLoggedIn
    }

    private func update(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        try? await configStore.update(mutate)
    }
}
