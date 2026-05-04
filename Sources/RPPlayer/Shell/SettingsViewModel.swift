import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var bitrate: Int
    @Published private(set) var hogModeEnabled: Bool
    @Published private(set) var releaseHogOnPauseEnabled: Bool
    @Published private(set) var forceMaxVolumeEnabled: Bool
    @Published private(set) var applyReplayGainEnabled: Bool
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var verboseLoggingEnabled: Bool
    @Published private(set) var appearance: AppearanceMode
    @Published private(set) var menuBarIconStyle: MenuBarIconStyle
    @Published private(set) var ambientBackgroundEnabled: Bool
    @Published private(set) var upcomingRowCount: Int
    @Published private(set) var upcomingHiddenChannelIds: [Int]
    @Published private(set) var upcomingChannels: [Channel] = []
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var currentUsername: String?

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openApplicationDataAction: @MainActor () -> Void
    private let listChannels: @Sendable () async throws -> [Channel]

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openApplicationData: @escaping @MainActor () -> Void,
        listChannels: @Sendable @escaping () async throws -> [Channel] = { [] }
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openApplicationDataAction = openApplicationData
        self.listChannels = listChannels

        let snapshot = AppSettings.default
        self.selectedChannelId = snapshot.selectedChannelId
        self.bitrate = snapshot.bitrate
        self.hogModeEnabled = snapshot.hogModeEnabled
        self.releaseHogOnPauseEnabled = snapshot.releaseHogOnPauseEnabled
        self.forceMaxVolumeEnabled = snapshot.forceMaxVolumeEnabled
        self.applyReplayGainEnabled = snapshot.applyReplayGainEnabled
        self.notificationsEnabled = snapshot.notificationsEnabled
        self.outputDeviceUID = snapshot.outputDeviceUID
        self.verboseLoggingEnabled = snapshot.verboseLoggingEnabled
        self.appearance = snapshot.appearance
        self.menuBarIconStyle = snapshot.menuBarIconStyle
        self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
        self.upcomingRowCount = snapshot.upcomingRowCount
        self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds
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
                    self.releaseHogOnPauseEnabled = snapshot.releaseHogOnPauseEnabled
                    self.forceMaxVolumeEnabled = snapshot.forceMaxVolumeEnabled
                    self.applyReplayGainEnabled = snapshot.applyReplayGainEnabled
                    self.notificationsEnabled = snapshot.notificationsEnabled
                    self.outputDeviceUID = snapshot.outputDeviceUID
                    self.verboseLoggingEnabled = snapshot.verboseLoggingEnabled
                    self.appearance = snapshot.appearance
                    self.menuBarIconStyle = snapshot.menuBarIconStyle
                    self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
                    self.upcomingRowCount = snapshot.upcomingRowCount
                    self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds
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
        Task { [weak self] in
            guard let self else { return }
            let channels = (try? await listChannels()) ?? []
            let filtered = channels.filter {
                guard let id = Int($0.chan) else { return false }
                return id != 42 && id != 99
            }
            await MainActor.run { self.upcomingChannels = filtered }
        }
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

    func setReleaseHogOnPauseEnabled(_ value: Bool) async {
        await update { $0.releaseHogOnPauseEnabled = value }
    }

    func setForceMaxVolumeEnabled(_ value: Bool) async {
        await update { $0.forceMaxVolumeEnabled = value }
    }

    func setApplyReplayGainEnabled(_ value: Bool) async {
        await update { $0.applyReplayGainEnabled = value }
    }

    func setNotificationsEnabled(_ value: Bool) async {
        await update { $0.notificationsEnabled = value }
    }

    func setOutputDeviceUID(_ value: String?) async {
        await update { $0.outputDeviceUID = value }
    }

    func refreshDevices() async {
        await deviceCatalog.reload()
    }

    func setVerboseLoggingEnabled(_ value: Bool) async {
        await update { $0.verboseLoggingEnabled = value }
    }

    func setAppearance(_ value: AppearanceMode) async {
        await update { $0.appearance = value }
    }

    func setMenuBarIconStyle(_ value: MenuBarIconStyle) async {
        await update { $0.menuBarIconStyle = value }
    }

    func setAmbientBackgroundEnabled(_ value: Bool) async {
        await update { $0.ambientBackgroundEnabled = value }
    }

    func setUpcomingRowCount(_ value: Int) async {
        await update { $0.upcomingRowCount = value }
    }

    func setChannelHidden(_ channelId: Int, _ hidden: Bool) async {
        await update { settings in
            if hidden {
                if !settings.upcomingHiddenChannelIds.contains(channelId) {
                    settings.upcomingHiddenChannelIds.append(channelId)
                }
            } else {
                settings.upcomingHiddenChannelIds.removeAll { $0 == channelId }
            }
        }
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
