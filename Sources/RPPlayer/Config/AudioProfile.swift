import Foundation

public struct AudioProfile: Codable, Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var forceMaxVolumeEnabled: Bool
    public var applyReplayGainEnabled: Bool
    public var bitrate: Int

    public static let safeDefault = AudioProfile(
        hogModeEnabled: false,
        releaseHogOnPauseEnabled: false,
        forceMaxVolumeEnabled: false,
        applyReplayGainEnabled: false,
        bitrate: 3  // 320k AAC
    )
}
