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
    @Published private(set) var currentUsername: String?

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openApplicationDataAction: @MainActor () -> Void

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openApplicationData: @escaping @MainActor () -> Void
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openApplicationDataAction = openApplicationData

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
        refreshAuthState()
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
        refreshAuthState()
    }

    func openLoginWindow() { openLoginWindowAction() }
    func openApplicationData() { openApplicationDataAction() }

    func refreshAuthState() {
        isSignedIn = auth.isLoggedIn
        currentUsername = auth.currentUsername
    }

    private func update(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        try? await configStore.update(mutate)
    }
}
