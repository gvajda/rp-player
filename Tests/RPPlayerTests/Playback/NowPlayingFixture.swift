import Foundation
@testable import RPPlayer

extension NowPlaying {
    static func fixture(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        cover: String? = nil,
        userRating: String? = nil,
        songId: String = "1",
        eventId: Int = 100,
        channelId: Int = 0,
        songDurationSeconds: Double = 180
    ) -> NowPlaying {
        NowPlaying(
            channelId: channelId,
            song: makeGaplessSong(
                songId: songId,
                eventId: eventId,
                artist: artist,
                title: title,
                album: album,
                userRating: userRating.flatMap(Int.init) ?? 0,
                coverLarge: cover
            ),
            songDurationSeconds: songDurationSeconds
        )
    }
}
