import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelAmbientTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var api: MockRpApiClient!
    private var auth: StubKeychainAuth!
    private var cache: StubAlbumArtCache!
    private var extractor: StubAmbientPaletteExtractor!
    private var store: StubConfigStore!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        auth = StubKeychainAuth()
        cache = StubAlbumArtCache()
        extractor = StubAmbientPaletteExtractor()
    }

    private func makeSUT(ambientEnabled: Bool = true) -> MiniPlayerViewModel {
        var initial = AppSettings.default
        initial.ambientBackgroundEnabled = ambientEnabled
        store = StubConfigStore(initial: initial)
        return MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: auth,
            configStore: store,
            paletteExtractor: extractor,
            openSettings: { }
        )
    }

    func testAmbientTopColorRemainsNilWhenAmbientDisabled() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT(ambientEnabled: false)
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(sut.ambientTopColor)
        await sut.stop()
    }

    func testAmbientTopColorPublishedAfterArtLoadsWhenEnabled() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)
        await sut.stop()
    }

    func testAmbientTopColorClearedOnPromoBlock() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil, songId: "0"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "promo block (songId == 0) must clear ambient color")
        await sut.stop()
    }

    func testAmbientTopColorStickyDuringTrackChangeArtLoad() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        cache.imageByPath["covers/l/b.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        let firstColor = sut.ambientTopColor
        XCTAssertNotNil(firstColor)

        extractor.delayNanoseconds = 200_000_000
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/b.jpg", songId: "2"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sut.ambientTopColor, firstColor, "ambient color must remain sticky during track-art-load")

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(sut.ambientTopColor, "ambient color should be set once new art loads")
        await sut.stop()
    }

    func testAmbientTopColorClearedOnEngineError() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        await coordinator.errorsContinuation.yield("Audio device lost")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "engine error must clear ambient color")
        await sut.stop()
    }

    func testAmbientTopColorClearedWhenAmbientDisabledMidPlayback() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        try await store.update { $0.ambientBackgroundEnabled = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "disabling ambient must clear current color")
        await sut.stop()
    }

    func testAmbientTopColorAppearsWhenToggledOnMidPlayback() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT(ambientEnabled: false)
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(sut.ambientTopColor, "ambient OFF — should be nil even though art is loaded")

        try await store.update { $0.ambientBackgroundEnabled = true }
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor, "toggling ambient ON mid-playback should produce a color from the already-loaded art")
        await sut.stop()
    }

    func testLiquidGlassEnabledReflectsConfigStoreChange() async throws {
        var initial = AppSettings.default
        initial.liquidGlassEnabled = false
        store = StubConfigStore(initial: initial)
        let sut = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: auth,
            configStore: store,
            paletteExtractor: extractor,
            openSettings: { }
        )
        await sut.start()
        XCTAssertFalse(sut.liquidGlassEnabled)
        try await store.update { $0.liquidGlassEnabled = true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sut.liquidGlassEnabled)
        await sut.stop()
    }
}
