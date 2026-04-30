import Foundation
@testable import RPPlayer

extension NowPlaying {
    static func fixture(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        cover: String? = nil
    ) -> NowPlaying {
        NowPlaying(
            channelId: 0,
            song: PlayListSong(
                songId: "1",
                artist: artist,
                title: title,
                album: album,
                duration: 180_000,
                event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
                rating: nil, userRating: nil, cover: cover, elapsed: nil, slideshow: nil
            ),
            songIndexInBlock: 0,
            blockDurationSeconds: 720,
            songStartSeconds: 0,
            songEndSeconds: 180
        )
    }
}
