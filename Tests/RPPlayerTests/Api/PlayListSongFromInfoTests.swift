import XCTest
@testable import RPPlayer

final class PlayListSongFromInfoTests: XCTestCase {
    func testInitFromSongInfoMapsCommonFieldsAndPrefersLargeCover() {
        let info = SongInfo(
            songId: 4242,
            artist: "Bowie",
            title: "Heroes",
            album: "\"Heroes\"",
            asin: nil,
            avgRating: 9.1,
            numRatings: nil,
            userRating: 9,
            webLink: nil,
            wikiLink: nil,
            lyricsAvail: nil,
            lyrics: nil,
            medCover: "covers/m/abc.jpg",
            largeCover: "covers/l/abc.jpg",
            releaseDate: nil,
            length: "367",
            plays30: nil,
            slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertEqual(song.songId, "4242")
        XCTAssertEqual(song.artist, "Bowie")
        XCTAssertEqual(song.title, "Heroes")
        XCTAssertEqual(song.album, "\"Heroes\"")
        XCTAssertEqual(song.cover, "covers/l/abc.jpg")
        XCTAssertEqual(song.userRating, "9")
        XCTAssertEqual(song.duration, 367_000)
    }

    func testInitFallsBackToMedCoverWhenLargeMissing() {
        let info = SongInfo(
            songId: 1, artist: "A", title: "T", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: "m.jpg", largeCover: nil,
            releaseDate: nil, length: nil, plays30: nil, slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertEqual(song.cover, "m.jpg")
        XCTAssertNil(song.userRating)
        XCTAssertEqual(song.duration, 0)
    }

    func testInitHandlesAllNilCovers() {
        let info = SongInfo(
            songId: 1, artist: "A", title: "T", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: nil, largeCover: nil,
            releaseDate: nil, length: nil, plays30: nil, slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertNil(song.cover)
    }
}
