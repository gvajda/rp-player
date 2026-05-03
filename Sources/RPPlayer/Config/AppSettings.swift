import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
    public var appearance: AppearanceMode
    public var ambientBackgroundEnabled: Bool
    /// Radio Paradise bitrate code passed to `api/play`.
    /// 0 = 32k aac, 1 = 64k aac, 2 = 128k aac, 3 = 320k aac, 4 = flac, 5 = 128k mp3, 6 = 320k mp3.
    /// Default 4 (FLAC) to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level
    public var verboseLoggingEnabled: Bool
    /// Stable per-install `rp3_<uuid>` identifier sent as `player_id` URL param to `api/play` (and future telemetry endpoints). Generated lazily by AppContainer on first launch when nil.
    public var playerId: String?

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        ambientBackgroundEnabled: Bool = false,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false,
        playerId: String? = nil
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.ambientBackgroundEnabled = ambientBackgroundEnabled
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
        self.playerId = playerId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedChannelId = try c.decodeIfPresent(Int.self, forKey: .selectedChannelId) ?? 0
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? true
        self.softwareVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .softwareVolumeEnabled) ?? false
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.ambientBackgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? false
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 4
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.logLevel = try c.decodeIfPresent(AppLogger.Level.self, forKey: .logLevel) ?? .info
        self.verboseLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .verboseLoggingEnabled) ?? false
        self.playerId = try c.decodeIfPresent(String.self, forKey: .playerId)
    }

    public static let `default` = AppSettings()
}
