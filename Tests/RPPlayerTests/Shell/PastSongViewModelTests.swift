import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongViewModelTests: XCTestCase {
    private func makeSong(rating: String? = nil, cover: String? = nil) -> PlayListSong {
        PlayListSong(
            songId: "100", artist: "Artist", title: "Title", album: "Album",
            duration: 0, event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: rating, cover: cover, elapsed: nil, slideshow: nil,
            type: nil, sliceNum: nil
        )
    }

    func testStartHydratesRatingFromUserRating() async {
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let auth = StubKeychainAuth()
        auth.loggedIn = true
        let sut = PastSongViewModel(song: makeSong(rating: "8"), albumArtCache: cache, auth: auth, api: api)
        await sut.start()
        XCTAssertEqual(sut.currentRating, 8)
        XCTAssertTrue(sut.isSignedIn)
    }

    func testStartHydratesNilRatingWhenAbsent() async {
        let sut = PastSongViewModel(
            song: makeSong(rating: nil),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        await sut.start()
        XCTAssertNil(sut.currentRating)
    }

    func testStartLoadsArtFromCacheWhenCoverPresent() async {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
        let sut = PastSongViewModel(
            song: makeSong(cover: "covers/l/x.jpg"),
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        await sut.start()
        XCTAssertNotNil(sut.currentArt)
    }

    func testRateCallsApiAndUpdatesCurrentRating() async {
        let api = MockRpApiClient()
        let sut = PastSongViewModel(
            song: makeSong(rating: "5"),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: api
        )
        await sut.start()
        await sut.rate(9)
        let calls = await api.calls
        XCTAssertTrue(calls.contains(.rate(songId: 100, rating: 9)),
                      "expected rate(100, 9) in calls, got: \(calls)")
        XCTAssertEqual(sut.currentRating, 9)
    }

    func testRateLeavesRatingUnchangedOnError() async {
        let api = MockRpApiClient()
        await api.setRateError(RpApiError.network(URLError(.unknown)))
        let sut = PastSongViewModel(
            song: makeSong(rating: "5"),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: api
        )
        await sut.start()
        await sut.rate(9)
        XCTAssertEqual(sut.currentRating, 5)
    }
}
