import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var selectedChannelId: Int
    @Published private(set) var bitrate: Int
    @Published private(set) var hogModeEnabled: Bool
    @Published private(set) var releaseHogOnPauseEnabled: Bool
    @Published private(set) var volumeMode: VolumeMode
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var verboseLoggingEnabled: Bool
    @Published private(set) var appearance: AppearanceMode
    @Published private(set) var menuBarIconStyle: MenuBarIconStyle
    @Published private(set) var ambientBackgroundEnabled: Bool
    @Published private(set) var popoverStyle: PopoverStyle
    @Published private(set) var frostedUpcomingEnabled: Bool
    @Published private(set) var upcomingRowCount: Int
    @Published private(set) var upcomingHiddenChannelIds: [Int]
    @Published private(set) var upcomingChannels: [Channel] = []
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var currentUsername: String?
    @Published private(set) var currentDeviceName: String?
    @Published private(set) var updateCheckEnabled: Bool = true
    @Published private(set) var lastCheckedRelative: String = "never"
    @Published private(set) var currentVersionLine: String = ""
    @Published private(set) var updateAvailable: Bool = false

    var openUpdatePanel: @MainActor (ReleaseInfo) -> Void = { _ in }

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openApplicationDataAction: @MainActor () -> Void
    private let listChannels: @Sendable () async throws -> [Channel]
    private let updateChecker: any UpdateChecking
    private let currentVersionString: String

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var updateStateTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openApplicationData: @escaping @MainActor () -> Void,
        listChannels: @Sendable @escaping () async throws -> [Channel] = { [] },
        updateChecker: any UpdateChecking = NoopUpdateChecker(),
        currentVersionString: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openApplicationDataAction = openApplicationData
        self.listChannels = listChannels
        self.updateChecker = updateChecker
        self.currentVersionString = currentVersionString

        let snapshot = AppSettings.default
        self.selectedChannelId = snapshot.selectedChannelId
        self.bitrate = snapshot.bitrate
        self.hogModeEnabled = snapshot.hogModeEnabled
        self.releaseHogOnPauseEnabled = snapshot.releaseHogOnPauseEnabled
        self.volumeMode = snapshot.volumeMode
        self.notificationsEnabled = snapshot.notificationsEnabled
        self.outputDeviceUID = snapshot.outputDeviceUID
        self.verboseLoggingEnabled = snapshot.verboseLoggingEnabled
        self.appearance = snapshot.appearance
        self.menuBarIconStyle = snapshot.menuBarIconStyle
        self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
        self.popoverStyle = snapshot.popoverStyle
        self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled
        self.upcomingRowCount = snapshot.upcomingRowCount
        self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds

        let versionPrefix = currentVersionString.hasPrefix("v") ? currentVersionString : "v" + currentVersionString
        self.currentVersionLine = "\(versionPrefix) (status unknown)"
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
                    self.volumeMode = snapshot.volumeMode
                    self.notificationsEnabled = snapshot.notificationsEnabled
                    self.outputDeviceUID = snapshot.outputDeviceUID
                    self.verboseLoggingEnabled = snapshot.verboseLoggingEnabled
                    self.appearance = snapshot.appearance
                    self.menuBarIconStyle = snapshot.menuBarIconStyle
                    self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
                    self.popoverStyle = snapshot.popoverStyle

                    self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled
                    self.upcomingRowCount = snapshot.upcomingRowCount
                    self.upcomingHiddenChannelIds = snapshot.upcomingHiddenChannelIds
                    self.currentDeviceName = self.devices.first(where: { $0.uid == snapshot.outputDeviceUID })?.name
                    self.updateCheckEnabled = snapshot.updateCheckEnabled
                    self.applyLastChecked(snapshot.lastUpdateCheckAt)
                }
            }
        }
        let deviceStream = await deviceCatalog.changes
        deviceTask = Task { [weak self] in
            for await devices in deviceStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.devices = devices
                    self.currentDeviceName = devices.first(where: { $0.uid == self.outputDeviceUID })?.name
                }
            }
        }
        let updateStream = await updateChecker.stateUpdates
        updateStateTask = Task { [weak self] in
            for await state in updateStream {
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run { self.applyUpdateState(state) }
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
        updateStateTask?.cancel()
        updateStateTask = nil
    }

    func setBitrate(_ value: Int) async {
        await update { s in
            s.bitrate = value
            if let uid = s.outputDeviceUID { s.audioProfiles[uid, default: .safeDefault].bitrate = value }
        }
    }

    func setHogModeEnabled(_ value: Bool) async {
        await update { s in
            s.hogModeEnabled = value
            if let uid = s.outputDeviceUID { s.audioProfiles[uid, default: .safeDefault].hogModeEnabled = value }
        }
    }

    func setReleaseHogOnPauseEnabled(_ value: Bool) async {
        await update { s in
            s.releaseHogOnPauseEnabled = value
            if let uid = s.outputDeviceUID { s.audioProfiles[uid, default: .safeDefault].releaseHogOnPauseEnabled = value }
        }
    }

    // Transitional — removed in Task 6 once SettingsView lands.
    var forceMaxVolumeEnabled: Bool { volumeMode == .forceMax }
    var applyReplayGainEnabled: Bool { volumeMode == .replayGain }
    func setForceMaxVolumeEnabled(_ value: Bool) async {
        await setVolumeMode(value ? .forceMax : .none)
    }
    func setApplyReplayGainEnabled(_ value: Bool) async {
        await setVolumeMode(value ? .replayGain : .none)
    }

    func setVolumeMode(_ value: VolumeMode) async {
        await update { s in
            s.volumeMode = value
            if let uid = s.outputDeviceUID {
                s.audioProfiles[uid, default: .safeDefault].volumeMode = value
            }
        }
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

    func setPopoverStyle(_ value: PopoverStyle) async {
        // Keep ambientBackgroundEnabled in sync so existing palette-extraction
        // logic in MiniPlayer/PastSong VMs (which still keys off the bool)
        // doesn't need restructuring.
        await update { settings in
            settings.popoverStyle = value
            settings.ambientBackgroundEnabled = (value == .ambient)
        }
    }

    func setFrostedUpcomingEnabled(_ value: Bool) async {
        await update { $0.frostedUpcomingEnabled = value }
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

    func setUpdateCheckEnabled(_ value: Bool) async {
        await update { $0.updateCheckEnabled = value }
    }

    func checkNow() async {
        await updateChecker.checkNow()
    }

    func openUpdate() async {
        await updateChecker.checkNow()
        let state = await updateChecker.currentState
        if case .available(let info, _) = state {
            openUpdatePanel(info)
            await updateChecker.dismissCurrentForButton()
        }
    }

    func applyUpdateState(_ state: UpdateState) {
        switch state {
        case .unknown:
            currentVersionLine = "\(displayVersion) (status unknown)"
            updateAvailable = false
        case .upToDate:
            currentVersionLine = "\(displayVersion) (up to date)"
            updateAvailable = false
        case .available(let info, _):
            currentVersionLine = "\(info.tagName) available"
            updateAvailable = true
        }
    }

    func applyLastChecked(_ date: Date?) {
        guard let date else { lastCheckedRelative = "never"; return }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        lastCheckedRelative = f.localizedString(for: date, relativeTo: Date())
    }

    private var displayVersion: String {
        currentVersionString.hasPrefix("v") ? currentVersionString : "v" + currentVersionString
    }

    private func update(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        try? await configStore.update(mutate)
    }
}
