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
    @Published public private(set) var eqEnabled: Bool = false
    @Published public private(set) var eqPresetName: String?
    @Published public private(set) var availablePresets: [String] = []
    @Published public private(set) var parsedEqPreset: EqPreset?
    @Published public private(set) var crossfeedEnabled: Bool = false
    @Published public private(set) var crossfeedStrength: Double = 0.2
    @Published public private(set) var crossfeedRange: Double = 0.5

    public enum ImportOutcome: Equatable, Sendable {
        case imported(name: String)
        case nameCollision(name: String)
    }

    public enum EqImportError: Error, Equatable, Sendable {
        case parseFailed(reasons: [String])
        case ioFailure(String)
        case invalidExtension
    }

    var openUpdatePanel: @MainActor (ReleaseInfo) -> Void = { _ in }

    private let configStore: any ConfigStore
    private let deviceCatalog: any AudioDeviceCatalog
    private let auth: any KeychainAuth
    private let openLoginWindowAction: @MainActor () -> Void
    private let openApplicationDataAction: @MainActor () -> Void
    private let listChannels: @Sendable () async throws -> [Channel]
    private let updateChecker: any UpdateChecking
    private let currentVersionString: String
    private let eqPresetStore: any EqPresetStore
    private let logger: (any Logging)?

    private var configTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var updateStateTask: Task<Void, Never>?
    private var presetsRefreshTask: Task<Void, Never>?

    init(
        configStore: any ConfigStore,
        deviceCatalog: any AudioDeviceCatalog,
        auth: any KeychainAuth,
        openLoginWindow: @escaping @MainActor () -> Void,
        openApplicationData: @escaping @MainActor () -> Void,
        listChannels: @Sendable @escaping () async throws -> [Channel] = { [] },
        updateChecker: any UpdateChecking = NoopUpdateChecker(),
        currentVersionString: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev",
        eqPresetStore: any EqPresetStore = NoopEqPresetStore(),
        logger: (any Logging)? = nil
    ) {
        self.configStore = configStore
        self.deviceCatalog = deviceCatalog
        self.auth = auth
        self.openLoginWindowAction = openLoginWindow
        self.openApplicationDataAction = openApplicationData
        self.listChannels = listChannels
        self.updateChecker = updateChecker
        self.currentVersionString = currentVersionString
        self.eqPresetStore = eqPresetStore
        self.logger = logger

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

                    let uid = snapshot.outputDeviceUID
                    let profile = uid.flatMap { snapshot.audioProfiles[$0] }
                    self.eqEnabled = profile?.eqEnabled ?? false
                    if self.eqPresetName != profile?.eqPresetName {
                        self.eqPresetName = profile?.eqPresetName
                        Task { [weak self] in await self?.reloadParsedPreset() }
                    }
                    self.crossfeedEnabled = profile?.crossfeedEnabled ?? false
                    self.crossfeedStrength = profile?.crossfeedStrength ?? 0.2
                    self.crossfeedRange = profile?.crossfeedRange ?? 0.5
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
        presetsRefreshTask = Task { [weak self] in
            if Task.isCancelled { return }
            await self?.refreshPresets()
        }
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
        presetsRefreshTask?.cancel()
        presetsRefreshTask = nil
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

    public func setEqEnabled(_ value: Bool) async {
        logger?.debug("setEqEnabled value=\(value)")
        await update { s in
            guard let uid = s.outputDeviceUID else { return }
            var p = s.audioProfiles[uid] ?? .safeDefault
            p.eqEnabled = value
            s.audioProfiles[uid] = p
        }
    }

    public func setEqPresetName(_ name: String?) async {
        logger?.debug("setEqPresetName name=\(name ?? "<nil>")")
        await update { s in
            guard let uid = s.outputDeviceUID else { return }
            var p = s.audioProfiles[uid] ?? .safeDefault
            p.eqPresetName = name
            s.audioProfiles[uid] = p
        }
    }

    public func setCrossfeedEnabled(_ value: Bool) async {
        logger?.debug("setCrossfeedEnabled value=\(value)")
        await update { s in
            guard let uid = s.outputDeviceUID else { return }
            var p = s.audioProfiles[uid] ?? .safeDefault
            p.crossfeedEnabled = value
            s.audioProfiles[uid] = p
        }
    }

    public func setCrossfeedStrength(_ value: Double) async {
        let clamped = min(1.0, max(0.0, value))
        logger?.debug("setCrossfeedStrength value=\(clamped)")
        await update { s in
            guard let uid = s.outputDeviceUID else { return }
            var p = s.audioProfiles[uid] ?? .safeDefault
            p.crossfeedStrength = clamped
            s.audioProfiles[uid] = p
        }
    }

    public func setCrossfeedRange(_ value: Double) async {
        let clamped = min(1.0, max(0.0, value))
        logger?.debug("setCrossfeedRange value=\(clamped)")
        await update { s in
            guard let uid = s.outputDeviceUID else { return }
            var p = s.audioProfiles[uid] ?? .safeDefault
            p.crossfeedRange = clamped
            s.audioProfiles[uid] = p
        }
    }

    public func refreshPresets() async {
        let names = await eqPresetStore.list()
        await MainActor.run { self.availablePresets = names }
    }

    public func reloadParsedPreset() async {
        guard let name = self.eqPresetName else {
            await MainActor.run { self.parsedEqPreset = nil }
            return
        }
        let text: String
        do {
            text = try await eqPresetStore.loadText(name: name)
        } catch {
            await MainActor.run { self.parsedEqPreset = nil }
            return
        }
        let result = EqPresetParser.parse(text: text, filename: name)
        await MainActor.run {
            if case .success(let preset) = result {
                self.parsedEqPreset = preset
            } else {
                self.parsedEqPreset = nil
            }
        }
    }

    public func importPresetFile(url: URL, overwrite: Bool) async throws -> ImportOutcome {
        logger?.info("importPresetFile entry url=\(url.path) overwrite=\(overwrite) ext=\(url.pathExtension)")
        guard url.pathExtension.lowercased() == "txt" else {
            logger?.warn("importPresetFile rejected reason=invalidExtension ext=\(url.pathExtension)")
            throw EqImportError.invalidExtension
        }
        let raw: String
        do {
            raw = try String(contentsOf: url, encoding: .utf8)
            logger?.debug("importPresetFile read \(raw.utf8.count) bytes from \(url.lastPathComponent)")
        } catch {
            logger?.error("importPresetFile read failed: \(error)")
            throw EqImportError.ioFailure("\(error)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        switch EqPresetParser.parse(text: raw, filename: name) {
        case .failure(.warningsNotPermitted(let reasons)):
            logger?.warn("importPresetFile rejected reason=warningsNotPermitted reasons=\(reasons.joined(separator: " | "))")
            throw EqImportError.parseFailed(reasons: reasons)
        case .failure(.empty):
            logger?.warn("importPresetFile rejected reason=empty (parser found no usable filter lines)")
            throw EqImportError.parseFailed(reasons: ["No recognised filter lines"])
        case .success(let preset):
            logger?.info("importPresetFile parsed name=\(name) preamp=\(preset.preampDb) bands=\(preset.bands.count)")
            do {
                try await eqPresetStore.save(name: name, text: raw, overwrite: overwrite)
                await refreshPresets()
                if self.eqPresetName == name { await reloadParsedPreset() }
                logger?.info("importPresetFile saved name=\(name)")
                return .imported(name: name)
            } catch EqPresetStoreError.alreadyExists {
                logger?.info("importPresetFile collision name=\(name) overwrite=false")
                return .nameCollision(name: name)
            } catch {
                logger?.error("importPresetFile save failed: \(error)")
                throw EqImportError.ioFailure("\(error)")
            }
        }
    }

    public func exportPreset(to url: URL) async throws {
        guard let name = eqPresetName else { return }
        let text = try await eqPresetStore.loadText(name: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func prepareDeletePreset(name: String) async -> [String] {
        let settings = await configStore.settings
        return settings.audioProfiles
            .filter { $0.value.eqPresetName == name }
            .map(\.key)
    }

    public func deletePresetConfirmed(name: String) async throws {
        logger?.info("deletePresetConfirmed name=\(name)")
        try await configStore.update { settings in
            for (uid, var profile) in settings.audioProfiles where profile.eqPresetName == name {
                profile.eqPresetName = nil
                settings.audioProfiles[uid] = profile
            }
        }
        try await eqPresetStore.delete(name: name)
        await refreshPresets()
    }

    private func update(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        try? await configStore.update(mutate)
    }
}

private final class NoopEqPresetStore: EqPresetStore {
    func list() async -> [String] { [] }
    func exists(name: String) async -> Bool { false }
    func loadText(name: String) async throws -> String { throw EqPresetStoreError.notFound }
    func save(name: String, text: String, overwrite: Bool) async throws { throw EqPresetStoreError.ioFailure("noop") }
    func delete(name: String) async throws { throw EqPresetStoreError.notFound }
}
