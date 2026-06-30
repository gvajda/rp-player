import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelSkipTests: XCTestCase {
    private func makeVM(settings: AppSettings)
        async -> (MiniPlayerViewModel, MockPlaybackCoordinator, StubKeychainAuth) {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let auth = StubKeychainAuth()
        auth.loggedIn = true
        let store = StubConfigStore(initial: settings)
        let vm = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: auth,
            configStore: store,
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: {}
        )
        await vm.start()
        let song = makeGaplessSong(songId: "42", eventId: 100, userRating: 0)
        let np = NowPlaying(channelId: 0, song: song, songDurationSeconds: 180, bitrateLabel: "flac")
        await coordinator.setNowPlaying(np)
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.refreshAuthState()
        return (vm, coordinator, auth)
    }

    func testRateBelowThresholdSkips() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s)
        await vm.rate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertTrue(calls.contains(.skipForward), "rating 2 below threshold 5 should skip. calls=\(calls)")
        await vm.stop()
    }

    func testRateAtThresholdDoesNotSkip() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s)
        await vm.rate(5)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertFalse(calls.contains(.skipForward), "rating 5 (== threshold) must not skip. calls=\(calls)")
        await vm.stop()
    }

    func testRateBelowThresholdDisabledDoesNotSkip() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = false
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s)
        await vm.rate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertFalse(calls.contains(.skipForward), "feature disabled must not skip. calls=\(calls)")
        await vm.stop()
    }
}
