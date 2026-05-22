import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelStopAndNextReadyTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var sut: MiniPlayerViewModel!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        sut = MiniPlayerViewModel(
            coordinator: coordinator,
            api: MockRpApiClient(),
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: {}
        )
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testNextReadyMirrorsCoordinatorStream() async {
        await sut.start()
        XCTAssertFalse(sut.nextReady)
        await coordinator.fireNextReady(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sut.nextReady)
        await coordinator.fireNextReady(false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(sut.nextReady)
    }

    func testStopPlaybackCallsCoordinatorStopAndClearsArtAndNowPlaying() async throws {
        await sut.start()

        await coordinator.setNowPlaying(.fixture(songId: "s1"))
        await coordinator.fireState(.playing)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(sut.nowPlaying)

        let channelBefore = sut.selectedChannelId

        await sut.stopPlayback()
        await coordinator.fireState(.stopped)
        try? await Task.sleep(nanoseconds: 80_000_000)

        let calls = await coordinator.recordedCalls()
        XCTAssertTrue(calls.contains(.stop), "stopPlayback should invoke coordinator.stop()")
        XCTAssertNil(sut.nowPlaying)
        XCTAssertNil(sut.currentArt)
        XCTAssertNil(sut.ambientTopColor)
        XCTAssertNil(sut.currentRating)
        XCTAssertNil(sut.currentBitrateLabel)
        XCTAssertEqual(sut.songElapsedSeconds, 0)
        XCTAssertEqual(sut.songDurationSeconds, 0)
        XCTAssertEqual(sut.selectedChannelId, channelBefore, "channel selection must persist across stop")
    }
}
