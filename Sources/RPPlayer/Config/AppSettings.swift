import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var forceMaxVolumeEnabled: Bool
    public var applyReplayGainEnabled: Bool
    public var notificationsEnabled: Bool
    public var appearance: AppearanceMode
    public var menuBarIconStyle: MenuBarIconStyle
    public var ambientBackgroundEnabled: Bool
    public var popoverStyle: PopoverStyle
    public var frostedUpcomingEnabled: Bool
    /// Radio Paradise bitrate code passed to `api/play`.
    /// 0 = 32k aac, 1 = 64k aac, 2 = 128k aac, 3 = 320k aac, 4 = flac, 5 = 128k mp3, 6 = 320k mp3.
    /// Default 4 (FLAC) to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level
    public var verboseLoggingEnabled: Bool
    /// Stable per-install `rp3_<uuid>` identifier sent as `player_id` URL param to `api/play` (and future telemetry endpoints). Generated lazily by AppContainer on first launch when nil.
    public var playerId: String?
    public var upcomingRowCount: Int
    // Chan 42 and 99 are always excluded from the Upcoming Program view regardless of this list.
    public var upcomingHiddenChannelIds: [Int]
    // When true, the popover is shown as a movable always-visible floating
    // panel (no outside-click dismissal, draggable). Toggled from the menu.
    public var popoverFloating: Bool
    public var audioProfiles: [String: AudioProfile]

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        releaseHogOnPauseEnabled: Bool = true,
        forceMaxVolumeEnabled: Bool = false,
        applyReplayGainEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        menuBarIconStyle: MenuBarIconStyle = .template,
        ambientBackgroundEnabled: Bool = true,
        popoverStyle: PopoverStyle = .ambient,
        frostedUpcomingEnabled: Bool = false,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false,
        playerId: String? = nil,
        upcomingRowCount: Int = 5,
        upcomingHiddenChannelIds: [Int] = [],
        popoverFloating: Bool = false,
        audioProfiles: [String: AudioProfile] = [:]
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.forceMaxVolumeEnabled = forceMaxVolumeEnabled
        self.applyReplayGainEnabled = applyReplayGainEnabled
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.menuBarIconStyle = menuBarIconStyle
        self.ambientBackgroundEnabled = ambientBackgroundEnabled
        self.popoverStyle = popoverStyle
        self.frostedUpcomingEnabled = frostedUpcomingEnabled
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
        self.playerId = playerId
        self.upcomingRowCount = upcomingRowCount
        self.upcomingHiddenChannelIds = upcomingHiddenChannelIds
        self.popoverFloating = popoverFloating
        self.audioProfiles = audioProfiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedChannelId = try c.decodeIfPresent(Int.self, forKey: .selectedChannelId) ?? 0
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? true
        self.releaseHogOnPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .releaseHogOnPauseEnabled) ?? true
        self.forceMaxVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .forceMaxVolumeEnabled) ?? false
        self.applyReplayGainEnabled = try c.decodeIfPresent(Bool.self, forKey: .applyReplayGainEnabled) ?? false
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .template
        self.ambientBackgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? true
        self.popoverStyle = try c.decodeIfPresent(PopoverStyle.self, forKey: .popoverStyle) ?? .ambient
        self.frostedUpcomingEnabled = try c.decodeIfPresent(Bool.self, forKey: .frostedUpcomingEnabled) ?? false
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 4
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.logLevel = try c.decodeIfPresent(AppLogger.Level.self, forKey: .logLevel) ?? .info
        self.verboseLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .verboseLoggingEnabled) ?? false
        self.playerId = try c.decodeIfPresent(String.self, forKey: .playerId)
        self.upcomingRowCount = try c.decodeIfPresent(Int.self, forKey: .upcomingRowCount) ?? 5
        self.upcomingHiddenChannelIds = try c.decodeIfPresent([Int].self, forKey: .upcomingHiddenChannelIds) ?? []
        self.popoverFloating = try c.decodeIfPresent(Bool.self, forKey: .popoverFloating) ?? false
        self.audioProfiles = try c.decodeIfPresent([String: AudioProfile].self, forKey: .audioProfiles) ?? [:]
    }

    public static let `default` = AppSettings()
}
