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
}
