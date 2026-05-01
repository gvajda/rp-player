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
        songStartSeconds: Double = 0,
        songEndSeconds: Double = 180
    ) -> NowPlaying {
        NowPlaying(
            channelId: 0,
            song: PlayListSong(
                songId: songId,
                artist: artist,
                title: title,
                album: album,
                duration: 180_000,
                event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
                rating: nil, userRating: userRating, cover: cover, elapsed: nil, slideshow: nil
            ),
            songIndexInBlock: 0,
            blockDurationSeconds: 720,
            songStartSeconds: songStartSeconds,
            songEndSeconds: songEndSeconds
        )
    }
}
