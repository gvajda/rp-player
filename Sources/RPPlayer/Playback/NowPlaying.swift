import Foundation

public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: PlayListSong
    public let songIndexInBlock: Int
    public let blockDurationSeconds: Double
    public let songStartSeconds: Double
    public let songEndSeconds: Double
    public var streamFormat: StreamFormat?

    public init(
        channelId: Int,
        song: PlayListSong,
        songIndexInBlock: Int,
        blockDurationSeconds: Double,
        songStartSeconds: Double,
        songEndSeconds: Double,
        streamFormat: StreamFormat? = nil
    ) {
        self.channelId = channelId
        self.song = song
        self.songIndexInBlock = songIndexInBlock
        self.blockDurationSeconds = blockDurationSeconds
        self.songStartSeconds = songStartSeconds
        self.songEndSeconds = songEndSeconds
        self.streamFormat = streamFormat
    }
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case notPlaying
    case channelNotFound(channelId: Int)
    case blockHasNoSongs
    case engineError(message: String)
    case underlying(message: String)
}
