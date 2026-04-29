import XCTest
@testable import RPPlayer

final class NowPlayingTests: XCTestCase {
    private func makeSong(id: String = "1", duration: Int = 180000) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "A", title: "T", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    func testEqualityRequiresAllFieldsMatch() {
        let song = makeSong()
        let np1 = NowPlaying(channelId: 0, song: song, songIndexInBlock: 1,
                             blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        let np2 = NowPlaying(channelId: 0, song: song, songIndexInBlock: 1,
                             blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        XCTAssertEqual(np1, np2)

        let differentChannel = NowPlaying(channelId: 1, song: song, songIndexInBlock: 1,
                                           blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        XCTAssertNotEqual(np1, differentChannel)
    }

    func testCoordinatorErrorEquality() {
        XCTAssertEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 5)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 6)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.notPlaying,
            PlaybackCoordinatorError.blockHasNoSongs
        )
    }
}
