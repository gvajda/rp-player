import XCTest
@testable import RPPlayer

final class LivePlaybackCoordinatorTests: XCTestCase {

    fileprivate func silentLogger() -> AppLogger {
        AppLogger(category: "PlaybackCoordinatorTests")
    }

    /// 1. Bootstrap: gapless fetch, engine.play first, queueNext second.
    func testPlayFetchesGaplessAndStartsFirstSong() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
            makeGaplessSong(songId: "s4", eventId: 103, gaplessUrl: "https://example.com/s4.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)

        let apiCalls = await api.calls
        XCTAssertTrue(apiCalls.contains(.gapless(channel: 0, bitrate: 4, numSongs: 20)))

        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.first, .play(url: URL(string: "https://example.com/s1.flac")!, startSeconds: nil))
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/s2.flac")!, startSeconds: nil)),
                      "queueNext should pre-load the second song. calls=\(engineCalls)")
    }

    /// 2. Single-song response — no queueNext should be issued.
    func testPlayWithSingleSongResponseDoesNotQueueNext() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "only", eventId: 100, gaplessUrl: "https://example.com/only.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)

        let engineCalls = await engine.recordedCalls()
        let queueNextCount = engineCalls.filter { if case .queueNext = $0 { return true } else { return false } }.count
        XCTAssertEqual(queueNextCount, 0, "single-song response must not queueNext. calls=\(engineCalls)")
    }

    /// 3. fileStarted → queue.removeFirst, emitNowPlaying for new head, queueNext for new index 1, telemetry for finished.
    func testFileStartedAdvancesQueueAndQueuesNext() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
            makeGaplessSong(songId: "s4", eventId: 103, gaplessUrl: "https://example.com/s4.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // First fileStarted: mpv path = s1 (set by engine.play). Sets lastStartedEventId; no advance.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.fire(.positionUpdate(seconds: 60.0))
        // Simulate mpv auto-advance: path now points at queue[1] = s2.
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/s2.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 100_000_000)

        let np = await coord.nowPlaying
        XCTAssertEqual(np?.song.songId, "s2", "nowPlaying must reflect new head after fileStarted")

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/s3.flac")!, startSeconds: nil)),
                      "queueNext should be issued for new queue[1]. calls=\(engineCalls)")

        // Telemetry for finished song s1
        let history = await api.updateHistoryCalls
        XCTAssertTrue(history.contains { $0.songId == "s1" && $0.pauseFlag == false },
                      "expected update_history for finished s1. calls=\(history)")
    }

    /// 4. fileStarted with shallow queue triggers refetch.
    func testFileStartedRefetchesWhenQueueShallow() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        // Refetch returns the same head + 2 new songs.
        let refetch = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
            makeGaplessSong(songId: "s4", eventId: 103, gaplessUrl: "https://example.com/s4.flac"),
        ])
        await api.setGaplessResponses([initial, refetch, refetch])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // Initial play kicks an immediate refetch (queue.count<3). Wait for it.
        try await Task.sleep(nanoseconds: 150_000_000)

        // First fileStarted: mpv path = s1 (initial). lastStartedEventId set, no advance.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Advance to s2: queue 4 → 3, kickRefetch fires (queue.count<3 false → no refetch yet).
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/s2.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Advance to s3: queue 3 → 2, kickRefetch fires.
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/s3.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 150_000_000)

        let calls = await api.calls
        let gaplessCount = calls.filter { if case .gapless = $0 { return true } else { return false } }.count
        XCTAssertGreaterThanOrEqual(gaplessCount, 3,
                                    "expected initial gapless + post-play refetch + boundary refetch. calls=\(calls)")
    }

    /// 5. skipForward with deep queue → engine.advanceToQueued, telemetry for skipped song.
    func testSkipForwardWithDeepQueueCallsAdvanceToQueued() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await coord.skipForward()

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.advanceToQueued),
                      "skipForward must call advanceToQueued when queue.count >= 2. calls=\(engineCalls)")

        // Telemetry for skipped s1
        try await Task.sleep(nanoseconds: 100_000_000)
        let history = await api.updateHistoryCalls
        XCTAssertTrue(history.contains { $0.songId == "s1" },
                      "expected update_history for skipped s1. calls=\(history)")
    }

    /// 6. skipForward with single song — synchronous gapless refetch + engine.play.
    /// Setup: initial single-song. The post-play kickRefetch returns the same
    /// head (no new songs filter past the head event), so queue.count stays at 1.
    /// skipForward then triggers the synchronous refetch path which returns
    /// distinct new songs.
    func testSkipForwardWithSingleSongRefetches() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "only", eventId: 100, gaplessUrl: "https://example.com/only.flac"),
        ])
        // The post-play kickRefetch returns just the same head — no new songs to append,
        // so queue stays at size 1.
        let sameHead = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "only", eventId: 100, gaplessUrl: "https://example.com/only.flac"),
        ])
        let nextFresh = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "next1", eventId: 200, gaplessUrl: "https://example.com/next1.flac"),
            makeGaplessSong(songId: "next2", eventId: 201, gaplessUrl: "https://example.com/next2.flac"),
        ])
        await api.setGaplessResponses([initial, sameHead, nextFresh, nextFresh])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // Drain the post-play kickRefetch (returns sameHead → no append).
        try await Task.sleep(nanoseconds: 150_000_000)

        try await coord.skipForward()
        let engineCalls = await engine.recordedCalls()
        let playsToNext = engineCalls.filter { call in
            if case let .play(url, _) = call,
               url.absoluteString.contains("next1") { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(playsToNext.count, 1,
                                    "expected engine.play for refetched song. calls=\(engineCalls)")
    }

    /// 7. changeChannel clears queue + clearPlaylist + new gapless call.
    func testChangeChannelClearsQueueAndRefetches() async throws {
        let api = MockRpApiClient()
        let chan0 = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "a1", eventId: 100, gaplessUrl: "https://example.com/a1.flac"),
        ], chan: "0")
        let chan1 = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "b1", eventId: 200, gaplessUrl: "https://example.com/b1.flac"),
        ], chan: "1")
        await api.setGaplessResponses([chan0, chan0, chan1, chan1])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await coord.changeChannel(to: 1)

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.clearPlaylist),
                      "changeChannel must clear playlist. calls=\(engineCalls)")

        let calls = await api.calls
        let chan1Gapless = calls.contains { call in
            if case .gapless(let channel, _, _) = call, channel == 1 { return true }
            return false
        }
        XCTAssertTrue(chan1Gapless, "expected gapless call on chan 1. calls=\(calls)")
    }

    /// 8. Long-idle resume refetches via gapless.
    func testLongIdleResumeRefetchesViaGapless() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        // FIFO response queue: bootstrap sees `initial`, after long-idle resume
        // the second play(0) sees `refetched`. Drain post-play kickRefetch by
        // sleeping briefly so it consumes its own slot before resume runs.
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        let refetched = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s3", eventId: 200, gaplessUrl: "https://example.com/s3.flac"),
            makeGaplessSong(songId: "s4", eventId: 201, gaplessUrl: "https://example.com/s4.flac"),
        ])
        await api.setGaplessResponses([initial, initial, refetched, refetched])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        // Drain the post-play kickRefetch so it consumes the second `initial` slot.
        try await Task.sleep(nanoseconds: 100_000_000)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()
        try await Task.sleep(nanoseconds: 100_000_000)

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.clearPlaylist),
                      "long-idle resume must clear playlist. calls=\(engineCalls)")

        let plays = engineCalls.compactMap { call -> URL? in
            if case let .play(url, _) = call { return url } else { return nil }
        }
        XCTAssertTrue(plays.contains(URL(string: "https://example.com/s3.flac")!),
                      "long-idle resume must engine.play the refetched head. plays=\(plays)")
    }

    /// 9. fileEnded(.error(-16)) drops song head and continues.
    func testEngineErrorCode16DropsSongAndAdvances() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.fire(.fileEnded(reason: .error(code: -16)))
        try await Task.sleep(nanoseconds: 150_000_000)

        let np = await coord.nowPlaying
        XCTAssertEqual(np?.song.songId, "s2",
                       "after dropping unplayable s1, head must be s2")

        let engineCalls = await engine.recordedCalls()
        let plays = engineCalls.compactMap { call -> URL? in
            if case let .play(url, _) = call { return url } else { return nil }
        }
        XCTAssertTrue(plays.contains(URL(string: "https://example.com/s2.flac")!),
                      "expected engine.play for s2 after dropping s1. plays=\(plays)")
    }

    /// 10. fileEnded(.error(-14)) clears all state + yields device-unavailable error.
    func testEngineErrorCode14ClearsAllStateAndYieldsDeviceMessage() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        let errors = await coord.errors
        let errorTask = Task<String?, Never> {
            var iter = errors.makeAsyncIterator()
            return await iter.next()
        }

        try await coord.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .error(code: -14)))

        let message = await errorTask.value
        XCTAssertTrue(message?.contains("Audio device unavailable") ?? false,
                      "expected device-unavailable error. got: \(message ?? "nil")")

        try await Task.sleep(nanoseconds: 50_000_000)
        let np = await coord.nowPlaying
        XCTAssertNil(np, "state must be cleared on -14")
    }

    /// 11. kickRefetch appends new songs above the head event.
    func testKickRefetchAppendsNewSongs() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "head", eventId: 100, gaplessUrl: "https://example.com/head.flac"),
        ])
        let refetch = makeGaplessResponse(songs: [
            // Refetch returns the old head + new ones.
            makeGaplessSong(songId: "head", eventId: 100, gaplessUrl: "https://example.com/head.flac"),
            makeGaplessSong(songId: "new1", eventId: 101, gaplessUrl: "https://example.com/new1.flac"),
            makeGaplessSong(songId: "new2", eventId: 102, gaplessUrl: "https://example.com/new2.flac"),
        ])
        await api.setGaplessResponses([initial, refetch, refetch])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // initial play kicks immediate refetch (queue.count<3); wait for it.
        try await Task.sleep(nanoseconds: 200_000_000)

        let engineCalls = await engine.recordedCalls()
        // After refetch, queue[1] should be new1 — verify queueNext was issued.
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/new1.flac")!, startSeconds: nil)),
                      "expected queueNext for first new song. calls=\(engineCalls)")
    }

    /// 11b. applyBitrateChange refetches, keeps head URL, swaps queued next.
    func testApplyBitrateChangeSwapsQueuedNextUrl() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1_aac.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2_aac.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3_aac.flac"),
        ], bitrateTitle: "320k aac")
        // After bitrate change: server returns same cursor but FLAC URLs + flac title.
        let refetched = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac"),
        ], bitrateTitle: "flac")
        await api.setGaplessResponses([initial, refetched, refetched])
        let engine = MockPlayerEngine()
        final class IntBox: @unchecked Sendable { var value: Int; init(_ v: Int) { value = v } }
        let bitrateBox = IntBox(3)
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(),
            bitrateProvider: { bitrateBox.value }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        bitrateBox.value = 4
        await coord.applyBitrateChange()

        let engineCalls = await engine.recordedCalls()
        // The currently-playing URL must NOT be re-played — engine.play stays at AAC.
        let playCount = engineCalls.filter { if case .play = $0 { return true } else { return false } }.count
        XCTAssertEqual(playCount, 1, "applyBitrateChange must not restart current song. calls=\(engineCalls)")

        // engine.clearPlaylist + queueNext for new bitrate s2 URL.
        XCTAssertTrue(engineCalls.contains(.clearPlaylist),
                      "expected clearPlaylist. calls=\(engineCalls)")
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/s2.flac")!, startSeconds: nil)),
                      "expected queueNext for new-bitrate s2. calls=\(engineCalls)")

        // bitrateLabel surfaced via nowPlaying must be the new value.
        let np = await coord.nowPlaying
        XCTAssertEqual(np?.bitrateLabel, "flac")
        XCTAssertEqual(np?.song.songId, "s1", "head must stay on s1")
    }

    /// 11c. applyBitrateChange no-ops when nothing is playing.
    func testApplyBitrateChangeNoOpWhenIdle() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.applyBitrateChange()

        let apiCalls = await api.calls
        XCTAssertTrue(apiCalls.isEmpty, "must not hit api when idle. calls=\(apiCalls)")
        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.isEmpty, "must not touch engine when idle. calls=\(engineCalls)")
    }

    /// 12. kickRefetch result is discarded if channel changed mid-fetch.
    /// Setup: gapless responds based on channel, with a 200ms delay on each call.
    /// While the post-play kickRefetch on chan 0 is in flight, changeChannel(1)
    /// runs — cancels refetchTask and switches to chan 1. After settling, the
    /// head must be from chan 1, never polluted by a stale chan-0 refetch.
    func testKickRefetchRaceGuardDiscardsResultOnChannelChange() async throws {
        let api = MockRpApiClient()
        let chan0 = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "a1", eventId: 100, gaplessUrl: "https://example.com/a1.flac"),
        ], chan: "0")
        let chan1 = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "b1", eventId: 200, gaplessUrl: "https://example.com/b1.flac"),
        ], chan: "1")
        await api.setGaplessByChannel([0: chan0, 1: chan1])
        await api.setGaplessDelay(nanos: 200_000_000) // 200ms — every gapless call is slow
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // play(0) is done; post-play kickRefetch is in-flight. Switch channels.
        try await coord.changeChannel(to: 1)
        // Now wait long enough for the cancelled refetch + new chan-1 refetch to settle.
        try await Task.sleep(nanoseconds: 500_000_000)

        // After the dust settles, the head must be from chan 1 — not from a stale chan-0 refetch.
        let np = await coord.nowPlaying
        XCTAssertEqual(np?.song.songId, "b1", "race-guard must discard stale chan-0 refetch")
    }

    /// 13. PR 30 stall watchdog interplay: long-idle resume still arms watchdog.
    func testStallWatchdogStillArmsAfterLongIdleResume() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        let refetched = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s3", eventId: 200, gaplessUrl: "https://example.com/s3.flac"),
            makeGaplessSong(songId: "s4", eventId: 201, gaplessUrl: "https://example.com/s4.flac"),
        ])
        await api.setGaplessResponses([initial, initial, refetched, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }, sleep: sleeper.sleep
        )
        try await coord.play(channelId: 0)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let armed = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed, "watchdog must arm after long-idle gapless resume")
    }

    /// 14. Promo song at queue head: updateHistory == false → no telemetry.
    func testPromoSongAtQueueZeroSkipsTelemetry() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "promo", eventId: 100, type: "P",
                            gaplessUrl: "https://example.com/promo.flac",
                            updateHistory: false),
            makeGaplessSong(songId: "real", eventId: 101,
                            gaplessUrl: "https://example.com/real.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)

        let history = await api.updateHistoryCalls
        XCTAssertFalse(history.contains { $0.songId == "promo" },
                       "promo song must not trigger update_history. calls=\(history)")
    }

    /// 15. Empty gapless response throws blockHasNoSongs.
    func testEmptyGaplessResponseThrowsBlockHasNoSongs() async throws {
        let api = MockRpApiClient()
        let empty = makeGaplessResponse(songs: [])
        await api.setGaplessResponse(empty)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        do {
            try await coord.play(channelId: 0)
            XCTFail("expected blockHasNoSongs")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .blockHasNoSongs)
        }
    }

    // MARK: - Additional regression coverage (preserved from earlier model)

    func testNowPlayingIsNilBeforePlay() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        let np = await coord.nowPlaying
        XCTAssertNil(np)
    }

    func testPlayPropagatesBitrateLabelIntoNowPlaying() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ], bitrateTitle: "320k aac")
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        let np = await coord.nowPlaying
        XCTAssertEqual(np?.bitrateLabel, "320k aac")
    }

    func testSkipForwardWithoutCurrentChannelThrows() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        do {
            try await coord.skipForward()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }

    func testPauseBeforePlayThrowsNotPlaying() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        do {
            try await coord.pause()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }

    func testPauseAndResumeForwardToEngineWhenPlaying() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await coord.pause()
        try await coord.resume()
        let calls = await engine.recordedCalls()
        XCTAssertTrue(calls.contains(.pause))
        XCTAssertTrue(calls.contains(.resume))
    }

    func testStopClearsPlaylist() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        try await coord.stop()
        let calls = await engine.recordedCalls()
        XCTAssertTrue(calls.contains(.clearPlaylist))
    }

    func testPositionUpdatesYieldsToSubscribers() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        let positions = await coord.positionUpdates
        let task = Task<[Double], Never> {
            var seen: [Double] = []
            for await p in positions {
                seen.append(p)
                if seen.count == 3 { return seen }
            }
            return seen
        }
        try await coord.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 5.0))
        await engine.fire(.positionUpdate(seconds: 10.0))
        let result = await task.value
        XCTAssertEqual(result, [0.0, 5.0, 10.0])
    }

    func testStateStreamEmitsTransitions() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        let states = await coord.stateUpdates
        let task = Task<[PlaybackState], Never> {
            var seen: [PlaybackState] = []
            for await s in states {
                seen.append(s)
                if seen.count == 4 { return seen }
            }
            return seen
        }
        try await coord.play(channelId: 0)
        try await coord.pause()
        try await coord.stop()
        let result = await task.value
        XCTAssertEqual(result, [.stopped, .playing, .paused, .stopped])
    }

    func testPlayPrefetchesNextSongCover() async throws {
        let api = MockRpApiClient()
        var json: [String: Any] = [
            "song_id": "s1",
            "artist": "A", "title": "T", "album": "Al",
            "duration": 180_000, "cue": 0, "event_id": 100,
            "gapless_url": "https://example.com/s1.flac",
            "type": "M", "update_history": true,
            "is_rateable": true, "is_playable_after_skip": true, "is_playable_on_start": true,
            "slice_num": 0, "rating": 0, "user_rating": 0, "ratings_num": 0,
            "episode_id": 0, "sched_time_millis": 0, "skip_allowed_millis": 0,
            "slideshow": [],
            "cover_large": "covers/s1-large.jpg"
        ]
        let s1 = try! JSONDecoder.rpDecoder.decode(GaplessSong.self,
            from: try! JSONSerialization.data(withJSONObject: json))
        json["song_id"] = "s2"
        json["event_id"] = 101
        json["gapless_url"] = "https://example.com/s2.flac"
        json["cover_large"] = "covers/s2-large.jpg"
        let s2 = try! JSONDecoder.rpDecoder.decode(GaplessSong.self,
            from: try! JSONSerialization.data(withJSONObject: json))

        let response = makeGaplessResponse(songs: [s1, s2])
        await api.setGaplessResponse(response)

        let engine = MockPlayerEngine()
        actor PrefetchSpy {
            var paths: [String] = []
            func record(_ path: String) { paths.append(path) }
            func snapshot() -> [String] { paths }
        }
        let spy = PrefetchSpy()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(),
            bitrateProvider: { 4 },
            prefetchArt: { path in Task { await spy.record(path) } }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        let snap = await spy.snapshot()
        XCTAssertTrue(snap.contains("covers/s2-large.jpg"),
                      "expected next-song cover prefetched. saw=\(snap)")
    }

    func testPrePlayHookFiresBeforeEnginePlay() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        actor HookSpy {
            var firedAt: Int = -1
            var step: Int = 0
            func recordHook() { firedAt = step; step += 1 }
            func recordPlay() { step += 1 }
            func get() -> (Int, Int) { (firedAt, step) }
        }
        let spy = HookSpy()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 },
            prePlayHook: { await spy.recordHook() }
        )
        try await coord.play(channelId: 0)
        let (firedAt, _) = await spy.get()
        XCTAssertEqual(firedAt, 0, "prePlayHook must fire before any engine.play")
    }

    func testFavoritesLikeChannelStillCallsGapless() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "fav1", eventId: 100, gaplessUrl: "https://example.com/fav1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 99)
        let calls = await api.calls
        XCTAssertTrue(calls.contains(.gapless(channel: 99, bitrate: 4, numSongs: 20)))
    }

    func testFileLoadedResetsUnplayableFailureCounter() async throws {
        // After a successful load, consecutive failure counter should reset so
        // the next unplayable error gets a fresh attempt budget.
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        await engine.fire(.fileLoaded) // successful load
        try await Task.sleep(nanoseconds: 50_000_000)
        // No assert; absence of crash + state preserved is the contract.
        let np = await coord.nowPlaying
        XCTAssertEqual(np?.song.songId, "s1")
    }

    /// PR 32 Task 6: play(channelId:) must resolve the head URL through SongFileCache
    /// before calling engine.play, so downloaded local files are used in preference
    /// to the remote gapless URL.
    func testPlayChannelIdResolvesUrlViaSongFileCacheBeforeEnginePlay() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let local = URL(string: "file:///tmp/song-1.flac")!
        await cache.setMode(.downloaded(local))

        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
            makeGaplessSong(eventId: 2, gaplessUrl: "https://s.example.com/2.flac"),
        ])
        await api.setGaplessResponses([response])

        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coord.play(channelId: 0)

        let calls = await cache.localFileCalls
        XCTAssertTrue(calls.contains(1), "expected localFile(for: song 1) to be called before engine.play; got=\(calls)")
        let engineCalls = await engine.recordedCalls()
        let firstPlayUrl: URL? = engineCalls.lazy.compactMap { call -> URL? in
            if case .play(let url, _) = call { return url }
            return nil
        }.first
        XCTAssertEqual(firstPlayUrl, local, "engine.play should be invoked with the cache-resolved local file URL")
    }

    /// Boundary advance must evict the just-finished song's cached file (after telemetry).
    func testQueueAdvanceEvictsDroppedSongFromCache() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()

        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 10, gaplessUrl: "https://s.example.com/0.flac"),
            makeGaplessSong(eventId: 20, gaplessUrl: "https://s.example.com/1.flac"),
        ])
        await api.setGaplessResponses([response])

        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // Initial fileStarted: mpv path = song[0]. lastStartedEventId is set; no advance, no eviction.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Boundary advance: mpv path = song[1].
        await engine.setSimulatedCurrentPath(URL(string: "https://s.example.com/1.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 150_000_000)

        let evicted = await cache.evictCalls
        XCTAssertTrue(evicted.contains(10), "expected song 10 (just-finished) to be evicted; got=\(evicted)")
        XCTAssertFalse(evicted.contains(20), "expected song 20 (now-current) NOT to be evicted; got=\(evicted)")
    }

    /// Boundary advance must resolve queue[1]'s URL via the cache and call engine.queueNext exactly once.
    func testQueueAdvanceQueuesNextSongFromCache() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()

        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 10, gaplessUrl: "https://s.example.com/0.flac"),
            makeGaplessSong(eventId: 20, gaplessUrl: "https://s.example.com/1.flac"),
            makeGaplessSong(eventId: 30, gaplessUrl: "https://s.example.com/2.flac"),
        ])
        await api.setGaplessResponses([response])

        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // Initial fileStarted: mpv path = song[0]. lastStartedEventId is set; no advance, no extra queueNext.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)

        let queueNextsBefore = await engine.recordedCalls().filter {
            if case .queueNext = $0 { return true } else { return false }
        }.count

        await engine.setSimulatedCurrentPath(URL(string: "https://s.example.com/1.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 150_000_000)

        let queueNextsAfter = await engine.recordedCalls().filter {
            if case .queueNext = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(queueNextsAfter, queueNextsBefore + 1,
                       "advance must queue exactly one new song; before=\(queueNextsBefore) after=\(queueNextsAfter)")

        let cacheCalls = await cache.localFileCalls
        XCTAssertTrue(cacheCalls.contains(30),
                      "queueNext path must resolve song 30 via cache; calls=\(cacheCalls)")
    }

    /// PR 32 Task 10: skipForward's sync-refetch fallback must resolve the new
    /// head's URL through SongFileCache before calling engine.play.
    func testSkipForwardSyncRefetchPlaysViaCachedFile() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let local = URL(string: "file:///tmp/refetched.flac")!
        await cache.setMode(.downloaded(local))

        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 100, gaplessUrl: "https://s.example.com/100.flac"),
        ])
        // Post-play kickRefetch will see the same head (no new songs) so queue stays at 1.
        let sameHead = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 100, gaplessUrl: "https://s.example.com/100.flac"),
        ])
        let after = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 200, gaplessUrl: "https://s.example.com/200.flac"),
        ])
        await api.setGaplessResponses([initial, sameHead, after])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        // Drain the post-play kickRefetch (returns sameHead → no append).
        try await Task.sleep(nanoseconds: 150_000_000)

        try await coordinator.skipForward() // queue is 1-deep → sync refetch path

        let recorded = await engine.recordedCalls()
        let lastPlayUrl: URL? = recorded.reversed().lazy.compactMap { call -> URL? in
            if case .play(let url, _) = call { return url } else { return nil }
        }.first
        XCTAssertEqual(lastPlayUrl, local,
                       "skipForward sync-refetch must engine.play the cache-resolved local URL. recorded=\(recorded)")
    }
}
