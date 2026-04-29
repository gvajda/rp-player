import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
    /// Radio Paradise bitrate code passed to `api/get_block`.
    /// 0 = AAC 64 kbps, 1 = AAC 128 kbps, 2 = MP3 320 kbps, 3 = FLAC (compressed), 4 = FLAC (highest).
    /// Default 4 to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
    }

    public static let `default` = AppSettings()
}
