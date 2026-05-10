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
        songDurationSeconds: Double = 180
    ) -> NowPlaying {
        NowPlaying(
            channelId: 0,
            song: makeGaplessSong(
                songId: songId,
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
