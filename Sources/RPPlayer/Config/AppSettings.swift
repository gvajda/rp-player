import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
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
