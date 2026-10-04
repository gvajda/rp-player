import XCTest
@testable import RPPlayer

final class PlaybackCoordinatorUpcomingProgramTests: XCTestCase {
    private func silentLogger() -> AppLogger { AppLogger(category: "PlaybackCoordinatorUpcomingProgramTests") }

    // A system pause arriving while already paused must not reset the pause clock, or long-idle catch-up is skipped.
    func testRepeatedPauseKeepsFirstPauseTimeForLongIdleResume() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: (1001...1005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        let refetch = makeGaplessResponse(songs: (2001...2012).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        await api.setGaplessResponses([initial, refetch])
        let cache = MockSongFileCache()
        cache.cachedFileOverride = { song in URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 30 * 60)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 65 * 60)
        try await coord.resume()

        let pauseCalls = await waitForUpdatePauseCalls(api)
        XCTAssertEqual(pauseCalls, 1, "second pause while paused must not resend update_pause")
        let merged = try await waitUntil({ await coord.snapshotQueueIds().contains(2001) }, timeout: 2)
        let ids = await coord.snapshotQueueIds()
        XCTAssertTrue(merged, "65-min pause must trigger long-idle catch-up; queue=\(ids)")
        XCTAssertEqual(Array(ids.prefix(3)), [1001, 1002, 2001])
    }

    func testUpcomingProgramIsQueueWithSkippedSongsInterleaved() async throws {
        let api = MockRpApiClient()
        await api.setGaplessResponse(makeGaplessResponse(songs: [
            makeGaplessSong(songId: "a", eventId: 100, gaplessUrl: "https://example.com/a.flac", userRating: 8),
            makeGaplessSong(songId: "bad", eventId: 101, gaplessUrl: "https://example.com/bad.flac", userRating: 2),
            makeGaplessSong(songId: "b", eventId: 102, gaplessUrl: "https://example.com/b.flac", userRating: 0),
            makeGaplessSong(songId: "c", eventId: 103, gaplessUrl: "https://example.com/c.flac", userRating: 0),
        ]))
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), songFileCache: MockSongFileCache(), logger: silentLogger(),
            bitrateProvider: { 4 }
        )
        let before = await coord.upcomingProgram
        XCTAssertNil(before)
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))
        try await coord.play(channelId: 7)

        let program = await coord.upcomingProgram
        XCTAssertEqual(program?.channelId, 7)
        XCTAssertEqual(program?.songs.map(\.songId), ["a", "bad", "b", "c"])
        let ids = await coord.snapshotQueueIds()
        XCTAssertEqual(ids, [100, 102, 103], "skipped song stays out of the play queue")

        try await coord.stop()
        let afterStop = await coord.upcomingProgram
        XCTAssertNil(afterStop)
    }

    private func waitForUpdatePauseCalls(_ api: MockRpApiClient) async -> Int {
        // update_pause is fired from a detached task.
        try? await Task.sleep(nanoseconds: 100_000_000)
        return await api.updatePauseCalls.count
    }
}
