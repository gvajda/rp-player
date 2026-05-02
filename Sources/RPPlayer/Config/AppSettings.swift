import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
    public var appearance: AppearanceMode
    /// Radio Paradise bitrate code passed to `api/play`.
    /// 0 = 32k aac, 1 = 64k aac, 2 = 128k aac, 3 = 320k aac, 4 = flac, 5 = 128k mp3, 6 = 320k mp3.
    /// Default 4 (FLAC) to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level
    public var verboseLoggingEnabled: Bool

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedChannelId = try c.decodeIfPresent(Int.self, forKey: .selectedChannelId) ?? 0
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? true
        self.softwareVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .softwareVolumeEnabled) ?? false
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 4
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.logLevel = try c.decodeIfPresent(AppLogger.Level.self, forKey: .logLevel) ?? .info
        self.verboseLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .verboseLoggingEnabled) ?? false
    }

    public static let `default` = AppSettings()
}
