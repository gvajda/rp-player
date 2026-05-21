import Foundation

public struct AudioProfile: Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var volumeMode: VolumeMode
    public var bitrate: Int
    public var eqEnabled: Bool
    public var eqPresetName: String?
    public var crossfeedEnabled: Bool
    public var crossfeedProfile: CrossfeedProfile
    public var crossfeedFcut: Int
    public var crossfeedFeedDb: Double

    public init(
        hogModeEnabled: Bool,
        releaseHogOnPauseEnabled: Bool,
        volumeMode: VolumeMode,
        bitrate: Int,
        eqEnabled: Bool = false,
        eqPresetName: String? = nil,
        crossfeedEnabled: Bool = false,
        crossfeedProfile: CrossfeedProfile = .cmoy,
        crossfeedFcut: Int = 700,
        crossfeedFeedDb: Double = 6.0
    ) {
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.volumeMode = volumeMode
        self.bitrate = bitrate
        self.eqEnabled = eqEnabled
        self.eqPresetName = eqPresetName
        self.crossfeedEnabled = crossfeedEnabled
        self.crossfeedProfile = crossfeedProfile
        self.crossfeedFcut = crossfeedFcut
        self.crossfeedFeedDb = crossfeedFeedDb
    }

    public static let safeDefault = AudioProfile(
        hogModeEnabled: false,
        releaseHogOnPauseEnabled: false,
        volumeMode: .none,
        bitrate: 3
    )
}

extension AudioProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case hogModeEnabled
        case releaseHogOnPauseEnabled
        case volumeMode
        case bitrate
        case eqEnabled
        case eqPresetName
        case crossfeedEnabled
        case crossfeedProfile
        case crossfeedFcut
        case crossfeedFeedDb
        // Legacy keys for migration only — never encoded.
        case forceMaxVolumeEnabled
        case applyReplayGainEnabled
        case crossfeedStrength
        case crossfeedRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? false
        self.releaseHogOnPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .releaseHogOnPauseEnabled) ?? false
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 3
        if let mode = try c.decodeIfPresent(VolumeMode.self, forKey: .volumeMode) {
            self.volumeMode = mode
        } else {
            let forceMax = try c.decodeIfPresent(Bool.self, forKey: .forceMaxVolumeEnabled) ?? false
            let rg = try c.decodeIfPresent(Bool.self, forKey: .applyReplayGainEnabled) ?? false
            self.volumeMode = forceMax ? .forceMax : (rg ? .replayGain : VolumeMode.none)
        }
        self.eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        self.eqPresetName = try c.decodeIfPresent(String.self, forKey: .eqPresetName)
        self.crossfeedEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfeedEnabled) ?? false
        self.crossfeedProfile = try c.decodeIfPresent(CrossfeedProfile.self, forKey: .crossfeedProfile) ?? .cmoy
        self.crossfeedFcut = try c.decodeIfPresent(Int.self, forKey: .crossfeedFcut) ?? 700
        self.crossfeedFeedDb = try c.decodeIfPresent(Double.self, forKey: .crossfeedFeedDb) ?? 6.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
        try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
        try c.encode(volumeMode, forKey: .volumeMode)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encode(eqEnabled, forKey: .eqEnabled)
        try c.encodeIfPresent(eqPresetName, forKey: .eqPresetName)
        try c.encode(crossfeedEnabled, forKey: .crossfeedEnabled)
        try c.encode(crossfeedProfile, forKey: .crossfeedProfile)
        try c.encode(crossfeedFcut, forKey: .crossfeedFcut)
        try c.encode(crossfeedFeedDb, forKey: .crossfeedFeedDb)
    }
}
