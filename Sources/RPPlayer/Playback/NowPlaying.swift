import Foundation

public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: PlayListSong
    public let songIndexInBlock: Int
    public let blockDurationSeconds: Double
    public let songStartSeconds: Double
    public let songEndSeconds: Double
    /// Raw `bitrate` field from the live API's get_block response (server-defined
    /// label, e.g. "flac", "flacm", "320", "32k aac"). Reflects what the app
    /// requested + the server served — single source of truth for the popover label.
    public var blockBitrate: String?

    public init(
        channelId: Int,
        song: PlayListSong,
        songIndexInBlock: Int,
        blockDurationSeconds: Double,
        songStartSeconds: Double,
        songEndSeconds: Double,
        blockBitrate: String? = nil
    ) {
        self.channelId = channelId
        self.song = song
        self.songIndexInBlock = songIndexInBlock
        self.blockDurationSeconds = blockDurationSeconds
        self.songStartSeconds = songStartSeconds
        self.songEndSeconds = songEndSeconds
        self.blockBitrate = blockBitrate
    }
}

public enum BlockBitrateLabel {
    /// Surfaces the raw `block.bitrate` string from the live API verbatim, only
    /// trimming whitespace and uppercasing for legibility. Real-world values
    /// observed include "flac", "flacm", "320", "32k aac", etc. — the set isn't
    /// formally documented, so the safest display is the server's own label.
    public static func display(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case notPlaying
    case channelNotFound(channelId: Int)
    case blockHasNoSongs
    case engineError(message: String)
    case underlying(message: String)
}
