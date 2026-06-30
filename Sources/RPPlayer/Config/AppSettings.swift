import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var volumeMode: VolumeMode
    public var notificationsEnabled: Bool
    public var appearance: AppearanceMode
    public var menuBarIconStyle: MenuBarIconStyle
    public var ambientBackgroundEnabled: Bool
    public var popoverStyle: PopoverStyle
    public var frostedUpcomingEnabled: Bool
    public var skipLowRatedEnabled: Bool
    public var skipRatingThreshold: Int
    /// Radio Paradise bitrate code passed to `api/gapless`.
    /// 0 = 32k aac, 1 = 64k aac, 2 = 128k aac, 3 = 320k aac, 4 = flac, 5 = 128k mp3, 6 = 320k mp3.
    /// Default 4 (FLAC) to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level
    public var verboseLoggingEnabled: Bool
    /// Stable per-install `rp3_<uuid>` identifier sent as `player_id` URL param to `api/gapless` (and telemetry endpoints). Generated lazily by AppContainer on first launch when nil.
    public var playerId: String?
    public var upcomingRowCount: Int
    // Chan 42 and 99 are always excluded from the Upcoming Program view regardless of this list.
    public var upcomingHiddenChannelIds: [Int]
    // When true, the popover is shown as a movable always-visible floating
    // panel (no outside-click dismissal, draggable). Toggled from the menu.
    public var popoverFloating: Bool
    public var audioProfiles: [String: AudioProfile]
    public var updateCheckEnabled: Bool
    public var lastUpdateCheckAt: Date?
    public var dismissedUpdateVersion: String?
    public var cachedLatestRelease: ReleaseInfo?

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        releaseHogOnPauseEnabled: Bool = true,
        volumeMode: VolumeMode = .none,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        menuBarIconStyle: MenuBarIconStyle = .template,
        ambientBackgroundEnabled: Bool = true,
        popoverStyle: PopoverStyle = .ambient,
        frostedUpcomingEnabled: Bool = false,
        skipLowRatedEnabled: Bool = false,
        skipRatingThreshold: Int = 5,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false,
        playerId: String? = nil,
        upcomingRowCount: Int = 5,
        upcomingHiddenChannelIds: [Int] = [],
        popoverFloating: Bool = false,
        audioProfiles: [String: AudioProfile] = [:],
        updateCheckEnabled: Bool = true,
        lastUpdateCheckAt: Date? = nil,
        dismissedUpdateVersion: String? = nil,
        cachedLatestRelease: ReleaseInfo? = nil
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.volumeMode = volumeMode
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.menuBarIconStyle = menuBarIconStyle
        self.ambientBackgroundEnabled = ambientBackgroundEnabled
        self.popoverStyle = popoverStyle
        self.frostedUpcomingEnabled = frostedUpcomingEnabled
        self.skipLowRatedEnabled = skipLowRatedEnabled
        self.skipRatingThreshold = skipRatingThreshold
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
        self.playerId = playerId
        self.upcomingRowCount = upcomingRowCount
        self.upcomingHiddenChannelIds = upcomingHiddenChannelIds
        self.popoverFloating = popoverFloating
        self.audioProfiles = audioProfiles
        self.updateCheckEnabled = updateCheckEnabled
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.dismissedUpdateVersion = dismissedUpdateVersion
        self.cachedLatestRelease = cachedLatestRelease
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedChannelId = try c.decodeIfPresent(Int.self, forKey: .selectedChannelId) ?? 0
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? true
        self.releaseHogOnPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .releaseHogOnPauseEnabled) ?? true
        if let mode = try c.decodeIfPresent(VolumeMode.self, forKey: .volumeMode) {
            self.volumeMode = mode
        } else {
            let forceMax = try c.decodeIfPresent(Bool.self, forKey: .forceMaxVolumeEnabled) ?? false
            let rg = try c.decodeIfPresent(Bool.self, forKey: .applyReplayGainEnabled) ?? false
            self.volumeMode = forceMax ? .forceMax : (rg ? .replayGain : .none)
        }
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .template
        self.ambientBackgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? true
        self.popoverStyle = try c.decodeIfPresent(PopoverStyle.self, forKey: .popoverStyle) ?? .ambient
        self.frostedUpcomingEnabled = try c.decodeIfPresent(Bool.self, forKey: .frostedUpcomingEnabled) ?? false
        self.skipLowRatedEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipLowRatedEnabled) ?? false
        self.skipRatingThreshold = try c.decodeIfPresent(Int.self, forKey: .skipRatingThreshold) ?? 5
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 4
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.logLevel = try c.decodeIfPresent(AppLogger.Level.self, forKey: .logLevel) ?? .info
        self.verboseLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .verboseLoggingEnabled) ?? false
        self.playerId = try c.decodeIfPresent(String.self, forKey: .playerId)
        self.upcomingRowCount = try c.decodeIfPresent(Int.self, forKey: .upcomingRowCount) ?? 5
        self.upcomingHiddenChannelIds = try c.decodeIfPresent([Int].self, forKey: .upcomingHiddenChannelIds) ?? []
        self.popoverFloating = try c.decodeIfPresent(Bool.self, forKey: .popoverFloating) ?? false
        self.audioProfiles = try c.decodeIfPresent([String: AudioProfile].self, forKey: .audioProfiles) ?? [:]
        self.updateCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .updateCheckEnabled) ?? true
        self.lastUpdateCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheckAt)
        self.dismissedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .dismissedUpdateVersion)
        self.cachedLatestRelease = try c.decodeIfPresent(ReleaseInfo.self, forKey: .cachedLatestRelease)
    }

    public static let `default` = AppSettings()

    private enum CodingKeys: String, CodingKey {
        case selectedChannelId, hogModeEnabled, releaseHogOnPauseEnabled
        case volumeMode
        case notificationsEnabled, appearance, menuBarIconStyle
        case ambientBackgroundEnabled, popoverStyle, frostedUpcomingEnabled
        case skipLowRatedEnabled, skipRatingThreshold
        case bitrate, outputDeviceUID, logLevel, verboseLoggingEnabled
        case playerId, upcomingRowCount, upcomingHiddenChannelIds
        case popoverFloating, audioProfiles, updateCheckEnabled
        case lastUpdateCheckAt, dismissedUpdateVersion, cachedLatestRelease
        // Legacy migration only — never encoded.
        case forceMaxVolumeEnabled
        case applyReplayGainEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedChannelId, forKey: .selectedChannelId)
        try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
        try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
        try c.encode(volumeMode, forKey: .volumeMode)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(menuBarIconStyle, forKey: .menuBarIconStyle)
        try c.encode(ambientBackgroundEnabled, forKey: .ambientBackgroundEnabled)
        try c.encode(popoverStyle, forKey: .popoverStyle)
        try c.encode(frostedUpcomingEnabled, forKey: .frostedUpcomingEnabled)
        try c.encode(skipLowRatedEnabled, forKey: .skipLowRatedEnabled)
        try c.encode(skipRatingThreshold, forKey: .skipRatingThreshold)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try c.encode(logLevel, forKey: .logLevel)
        try c.encode(verboseLoggingEnabled, forKey: .verboseLoggingEnabled)
        try c.encodeIfPresent(playerId, forKey: .playerId)
        try c.encode(upcomingRowCount, forKey: .upcomingRowCount)
        try c.encode(upcomingHiddenChannelIds, forKey: .upcomingHiddenChannelIds)
        try c.encode(popoverFloating, forKey: .popoverFloating)
        try c.encode(audioProfiles, forKey: .audioProfiles)
        try c.encode(updateCheckEnabled, forKey: .updateCheckEnabled)
        try c.encodeIfPresent(lastUpdateCheckAt, forKey: .lastUpdateCheckAt)
        try c.encodeIfPresent(dismissedUpdateVersion, forKey: .dismissedUpdateVersion)
        try c.encodeIfPresent(cachedLatestRelease, forKey: .cachedLatestRelease)
    }
}
