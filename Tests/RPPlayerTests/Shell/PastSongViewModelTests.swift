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
        let sut = PastSongViewModel(
            song: makeSong(rating: "8"),
            albumArtCache: cache,
            auth: auth,
            api: api,
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor()
        )
        await sut.start()
        XCTAssertEqual(sut.currentRating, 8)
        XCTAssertTrue(sut.isSignedIn)
    }

    func testStartHydratesNilRatingWhenAbsent() async {
        let sut = PastSongViewModel(
            song: makeSong(rating: nil),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor()
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
            api: MockRpApiClient(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor()
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
            api: api,
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor()
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
            api: api,
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor()
        )
        await sut.start()
        await sut.rate(9)
        XCTAssertEqual(sut.currentRating, 5)
    }

    func testStartExtractsAmbientColorWhenEnabledAndCoverPresent() async {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
        var settings = AppSettings.default
        settings.ambientBackgroundEnabled = true
        let store = StubConfigStore(initial: settings)
        let extractor = StubAmbientPaletteExtractor(
            nextResult: ExtractedColor(red: 0.5, green: 0.25, blue: 0.75)
        )
        let sut = PastSongViewModel(
            song: makeSong(cover: "covers/l/x.jpg"),
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            api: MockRpApiClient(),
            configStore: store,
            paletteExtractor: extractor
        )
        await sut.start()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNotNil(sut.ambientTopColor)
    }

    func testStartSkipsAmbientExtractionWhenDisabled() async {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
        let store = StubConfigStore(initial: .default)
        let extractor = StubAmbientPaletteExtractor(
            nextResult: ExtractedColor(red: 0.5, green: 0.25, blue: 0.75)
        )
        let sut = PastSongViewModel(
            song: makeSong(cover: "covers/l/x.jpg"),
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            api: MockRpApiClient(),
            configStore: store,
            paletteExtractor: extractor
        )
        await sut.start()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(sut.ambientTopColor)
        XCTAssertTrue(extractor.calls.isEmpty)
    }

    func testStartClearsAmbientColorForPromoSong() async {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/promo.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
        var settings = AppSettings.default
        settings.ambientBackgroundEnabled = true
        let store = StubConfigStore(initial: settings)
        let extractor = StubAmbientPaletteExtractor(
            nextResult: ExtractedColor(red: 1, green: 1, blue: 1)
        )
        var promo = makeSong(cover: "covers/l/promo.jpg")
        promo = PlayListSong(
            songId: "0", artist: promo.artist, title: promo.title, album: promo.album,
            duration: promo.duration, event: promo.event, schedTime: promo.schedTime,
            chan: promo.chan, year: promo.year, asin: promo.asin, rating: promo.rating,
            userRating: promo.userRating, cover: promo.cover, elapsed: promo.elapsed,
            slideshow: promo.slideshow, type: "P", sliceNum: promo.sliceNum
        )
        let sut = PastSongViewModel(
            song: promo,
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            api: MockRpApiClient(),
            configStore: store,
            paletteExtractor: extractor
        )
        await sut.start()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(sut.ambientTopColor)
    }

    func testStopCancelsTasks() async {
        let store = StubConfigStore(initial: .default)
        let extractor = StubAmbientPaletteExtractor()
        let sut = PastSongViewModel(
            song: makeSong(),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient(),
            configStore: store,
            paletteExtractor: extractor
        )
        await sut.start()
        sut.stop()
        try? await store.update { $0.ambientBackgroundEnabled = true }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(sut.ambientTopColor)
    }

    func testLiquidGlassEnabledReflectsConfigStoreChange() async throws {
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let auth = StubKeychainAuth()
        let store = StubConfigStore(initial: .default)
        let sut = PastSongViewModel(
            song: makeSong(),
            albumArtCache: cache,
            auth: auth,
            api: api,
            configStore: store,
            paletteExtractor: StubAmbientPaletteExtractor()
        )
        await sut.start()
        XCTAssertFalse(sut.liquidGlassEnabled)
        try await store.update { $0.liquidGlassEnabled = true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sut.liquidGlassEnabled)
    }
}
