import Foundation

public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: GaplessSong
    public let songDurationSeconds: Double
    public var bitrateLabel: String?

    public init(
        channelId: Int,
        song: GaplessSong,
        songDurationSeconds: Double,
        bitrateLabel: String? = nil
    ) {
        self.channelId = channelId
        self.song = song
        self.songDurationSeconds = songDurationSeconds
        self.bitrateLabel = bitrateLabel
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
