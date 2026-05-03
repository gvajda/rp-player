import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var api: MockRpApiClient!
    private var auth: StubKeychainAuth!
    private var openSettingsCalls = 0
    private var sut: MiniPlayerViewModel!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        auth = StubKeychainAuth()
        openSettingsCalls = 0
        sut = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: auth,
            openSettings: { [unowned self] in self.openSettingsCalls += 1 }
        )
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
        await sut.togglePlayPause()
        await sut.togglePlayPause()
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls, [.play(channelId: 0), .pause])
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
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            openSettings: { },
            persistChannelId: { id in await capture.record(id) }
        )
        await model.selectChannel(2)
        let calls = await capture.calls
        XCTAssertEqual(calls, [2])
    }

    func testSuccessfulOperationClearsPriorErrorMessage() async throws {
        await coordinator.setNextError(NSError(domain: "test", code: 1))
        await sut.skipForward()
        XCTAssertNotNil(sut.errorMessage)

        await sut.skipForward()
        XCTAssertNil(sut.errorMessage)
    }

    func testSelectChannelSecondCallSupersedesFirst() async throws {
        let model = sut!
        async let first: Void = model.selectChannel(2)
        async let second: Void = model.selectChannel(5)
        _ = await (first, second)
        XCTAssertEqual(sut.selectedChannelId, 5)
        let calls = await coordinator.recordedCalls()
        XCTAssertEqual(calls.count, 2)
    }

    func testCurrentArtLoadsFromCacheOnNowPlayingUpdate() async throws {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/1.jpg"] = NSImage(size: NSSize(width: 1, height: 1))
        let model = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            openSettings: { }
        )
        await model.start()
        let np = NowPlaying.fixture(cover: "covers/l/1.jpg")
        await coordinator.setNowPlaying(np)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(model.currentArt)
        XCTAssertEqual(cache.requestedPaths, ["covers/l/1.jpg"])
    }

    func testCurrentArtClearsWhenNowPlayingHasNoCover() async throws {
        let cache = StubAlbumArtCache()
        let model = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            openSettings: { }
        )
        await model.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.currentArt)
        XCTAssertTrue(cache.requestedPaths.isEmpty)
    }

    func testIsSignedInTracksKeychainOnNowPlaying() async throws {
        auth.loggedIn = true
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(userRating: "7"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sut.isSignedIn)
        XCTAssertEqual(sut.currentRating, 7)
    }

    func testRateNoOpsWhenSignedOut() async throws {
        auth.loggedIn = false
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(8)
        let calls = await api.calls
        XCTAssertFalse(calls.contains(where: { if case .rate = $0 { return true } else { return false } }))
    }

    func testRateCallsApiAndUpdatesCurrentRatingWhenSignedIn() async throws {
        auth.loggedIn = true
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(songId: "61209"))
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(9)

        let calls = await api.calls
        XCTAssertTrue(calls.contains(.rate(songId: 61209, rating: 9)))
        XCTAssertEqual(sut.currentRating, 9)
    }

    func testRateSurfacesErrorAndDoesNotUpdateRating() async throws {
        auth.loggedIn = true
        await api.setRateError(RpApiError.network(URLError(.notConnectedToInternet)))
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(songId: "1"))
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(5)

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertNil(sut.currentRating)
    }

    func testRateClearsCookieAndUpdatesSignedInOnAuthFailure() async throws {
        auth.loggedIn = true
        try await auth.storeCookie("C_username=test; C_passwd=hash; C_validated=tok")
        await api.setRateError(RpApiError.invalidResponse(statusCode: 401, body: Data("auth failure".utf8)))
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(songId: "1"))
        try await Task.sleep(nanoseconds: 50_000_000)

        await sut.rate(5)

        XCTAssertFalse(auth.loggedIn, "auth cookie should be cleared on 401")
        XCTAssertFalse(sut.isSignedIn, "view model should reflect cleared auth")
        XCTAssertNotNil(sut.errorMessage)
        XCTAssertTrue(
            sut.errorMessage!.lowercased().contains("sign in"),
            "error message should prompt re-login, got: \(sut.errorMessage ?? "nil")"
        )
        XCTAssertNil(sut.currentRating)
    }

    func testCurrentArtClearsImmediatelyOnNowPlayingChange() async throws {
        let cache = StubAlbumArtCache()
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 1, height: 1))
        sut = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(sut.currentArt)

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil))
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNil(sut.currentArt)
    }

    func testOpenSettingsInvokesInjectedClosure() {
        sut.openSettings()
        XCTAssertEqual(openSettingsCalls, 1)
    }

    func testCurrentBitrateLabelReflectsBlockBitrate() async throws {
        auth.loggedIn = false
        await sut.start()
        var np = NowPlaying.fixture(songId: "1")
        np.blockBitrate = "32k aac"
        await coordinator.setNowPlaying(np)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sut.currentBitrateLabel, "32K AAC")
    }

    func testCurrentArtPersistsWhenOnlyBitrateChanges() async throws {
        let cache = StubAlbumArtCache()
        let stableImage = NSImage(size: NSSize(width: 1, height: 1))
        cache.imageByPath["covers/l/stable.jpg"] = stableImage
        sut = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        auth.loggedIn = false
        await sut.start()

        var np = NowPlaying.fixture(cover: "covers/l/stable.jpg", songId: "1")
        np.blockBitrate = "flac"
        await coordinator.setNowPlaying(np)
        try await Task.sleep(nanoseconds: 80_000_000)
        let firstArt = sut.currentArt
        XCTAssertNotNil(firstArt, "art should load on first emission")

        np.blockBitrate = "320"
        await coordinator.setNowPlaying(np)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNotNil(sut.currentArt, "art must persist across bitrate-only updates")
        XCTAssertTrue(sut.currentArt === firstArt,
                      "should be the same NSImage instance — no nil-then-reload flicker")
        XCTAssertEqual(cache.requestedPaths.count, 1,
                       "cache should be queried once, not re-queried on bitrate change")
    }

    func testCurrentArtReloadsWhenCoverPathChanges() async throws {
        let cache = StubAlbumArtCache()
        let imageA = NSImage(size: NSSize(width: 1, height: 1))
        let imageB = NSImage(size: NSSize(width: 2, height: 2))
        cache.imageByPath["covers/l/a.jpg"] = imageA
        cache.imageByPath["covers/l/b.jpg"] = imageB
        sut = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        auth.loggedIn = false
        await sut.start()

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(sut.currentArt === imageA)

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/b.jpg", songId: "2"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(sut.currentArt === imageB,
                      "cover-path change must reload art")
        XCTAssertEqual(cache.requestedPaths, ["covers/l/a.jpg", "covers/l/b.jpg"])
    }

    func testPositionUpdateDerivesElapsedAndDuration() async throws {
        let np = NowPlaying.fixture(songStartSeconds: 100, songEndSeconds: 280)
        await coordinator.setNowPlaying(np)
        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.firePosition(145)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 45, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 180, accuracy: 0.001)
    }

    func testSongChangeResetsElapsed() async throws {
        let np1 = NowPlaying.fixture(songId: "1", songStartSeconds: 100, songEndSeconds: 280)
        await coordinator.setNowPlaying(np1)
        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.firePosition(200)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(sut.songElapsedSeconds, 0)

        let np2 = NowPlaying.fixture(songId: "2", songStartSeconds: 280, songEndSeconds: 520)
        await coordinator.setNowPlaying(np2)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 240, accuracy: 0.001)
    }

    func testElapsedClampedToDuration() async throws {
        let np = NowPlaying.fixture(songStartSeconds: 100, songEndSeconds: 280)
        await coordinator.setNowPlaying(np)
        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.firePosition(310)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 180, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 180, accuracy: 0.001)
    }

    func testCoordinatorErrorSetsErrorMessageAndCallsShowPopover() async throws {
        var popoverCallCount = 0
        sut.showPopoverIfNeeded = { popoverCallCount += 1 }
        await sut.start()

        await coordinator.errorsContinuation.yield("Audio device lost")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.errorMessage, "Audio device lost")
        XCTAssertEqual(popoverCallCount, 1)
    }

    func testUserActionClearsErrorMessageFromCoordinatorStream() async throws {
        await coordinator.setNextError(NSError(domain: "test", code: 1))
        await sut.start()
        await sut.skipForward()
        XCTAssertNotNil(sut.errorMessage)

        await sut.togglePlayPause()
        XCTAssertNil(sut.errorMessage)
    }
}
