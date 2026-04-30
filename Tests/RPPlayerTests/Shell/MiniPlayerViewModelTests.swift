import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var api: MockRpApiClient!
    private var sut: MiniPlayerViewModel!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        sut = MiniPlayerViewModel(coordinator: coordinator, api: api, initialChannelId: 0)
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testInitialStateBeforeStart() {
        XCTAssertNil(sut.nowPlaying)
        XCTAssertFalse(sut.isPlaying)
        XCTAssertEqual(sut.selectedChannelId, 0)
        XCTAssertTrue(sut.channels.isEmpty)
        XCTAssertNil(sut.errorMessage)
    }

    func testStartLoadsChannelsAndSubscribesToNowPlaying() async throws {
        let channel0 = Channel(chan: "0", title: "Main Mix", streamName: nil, bannerUrl: nil, slug: nil, image: nil)
        await api.setListChannelsResponse([channel0])

        await sut.start()

        XCTAssertEqual(sut.channels.map(\.chan), ["0"])
        XCTAssertEqual(sut.errorMessage, nil)
    }

    func testStartSurfacesListChannelsErrorAsErrorMessage() async throws {
        await api.setListChannelsError(RpApiError.network(URLError(.notConnectedToInternet)))

        await sut.start()

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertTrue(sut.channels.isEmpty)
    }

    func testTogglePlayPauseStartsPlaybackWhenNotPlaying() async throws {
        await sut.togglePlayPause()
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.play(channelId: 0)])
        XCTAssertTrue(sut.isPlaying)
    }

    func testTogglePlayPausePausesWhenPlaying() async throws {
        sut.setIsPlayingForTesting(true)

        await sut.togglePlayPause()

        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.pause])
        XCTAssertFalse(sut.isPlaying)
    }

    func testSkipForwardCallsCoordinator() async throws {
        await sut.skipForward()
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.skipForward])
    }

    func testSelectChannelChangesChannelOnCoordinator() async throws {
        await sut.selectChannel(2)
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.changeChannel(to: 2)])
        XCTAssertEqual(sut.selectedChannelId, 2)
    }

    func testSelectChannelDoesNothingWhenIdUnchanged() async throws {
        await sut.selectChannel(0)
        let calls = await coordinator.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSelectChannelInvokesPersistenceClosureOnSuccess() async throws {
        actor PersistenceCapture {
            var calls: [Int] = []
            func record(_ id: Int) { calls.append(id) }
        }
        let capture = PersistenceCapture()
        let coord = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let model = MiniPlayerViewModel(
            coordinator: coord,
            api: api,
            initialChannelId: 0,
            persistChannelId: { id in await capture.record(id) }
        )
        await model.selectChannel(2)
        let calls = await capture.calls
        XCTAssertEqual(calls, [2])
    }
}
