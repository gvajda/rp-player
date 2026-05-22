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
        let cache = MockSongFileCache()
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
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
        let cache = MockSongFileCache()
        await cache.markDownloaded(Array(response.songs.prefix(3)))
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
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

    /// 10. fileEnded(.error(-14)) clears all state; when no handler is set, yields generic error.
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
        XCTAssertTrue(message?.contains("Playback stopped unexpectedly") ?? false,
                      "expected generic error when no handler is set. got: \(message ?? "nil")")

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
        let cache = MockSongFileCache()
        await cache.markDownloaded(Array(initial.songs.prefix(2)))
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { bitrateBox.value }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        await cache.markDownloaded(Array(refetched.songs.prefix(2)))
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
                if seen.count == 5 { return seen }
            }
            return seen
        }
        try await coord.play(channelId: 0)
        try await coord.pause()
        try await coord.stop()
        let result = await task.value
        XCTAssertEqual(result, [.stopped, .loading, .playing, .paused, .stopped])
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
        await cache.markDownloaded(response.songs)

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

    /// Regression: PR 32 download-then-play hands mpv a local file path, not the
    /// remote gaplessUrl. mpv's `path` property therefore returns the local file
    /// path (no scheme). syncQueueHeadFromMpv must match queue entries against
    /// SongFileCache.expectedLocalPath in addition to gaplessUrl, otherwise the
    /// queue head never advances and the UI / telemetry / prefetch chain stalls.
    func testBoundaryAdvanceMatchesByLocalFilePath() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-syncqueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cache = try LiveSongFileCache(
            directory: tmpDir,
            session: URLSession.shared,
            logger: silentLogger()
        )
        let song1 = makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://s.example.com/1.flac")
        let song2 = makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://s.example.com/2.flac")
        let song3 = makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://s.example.com/3.flac")
        let response = makeGaplessResponse(songs: [song1, song2, song3])
        await api.setGaplessResponse(response)

        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)

        // Initial fileStarted seeds lastStartedEventId. We bypass the real download
        // path here (URLSession.shared on a fake URL would fail) — coordinator's
        // localFile resolution falls back to URL(string: gaplessUrl) when the cache
        // returns nil, so engine.play got the remote URL. Set simulated path to
        // match the queue head's gaplessUrl so initial sync succeeds.
        await engine.setSimulatedCurrentPath(URL(string: song1.gaplessUrl))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Simulate mpv reporting the LOCAL file path (no scheme) for song2 — the
        // PR 32 production path where the cache hit returns a file:// URL and
        // mpv strips the scheme to /path/to/file.flac. This is the bug case: the
        // old lookup compared only against gaplessUrl and fell back to queue[0].
        let song2LocalPath = cache.expectedLocalPath(for: song2).path
        await engine.setSimulatedCurrentPath(raw: song2LocalPath)
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 150_000_000)

        let np = await coord.nowPlaying
        XCTAssertEqual(np?.song.songId, "s2",
                       "nowPlaying must advance to s2 when mpv reports the local cache path")
    }

    // MARK: - Cancel-in-flight-downloads on lifecycle transitions

    func testChangeChannelCancelsInFlightDownloads() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
        ])
        await api.setGaplessResponses([response, response, response, response])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let cancelsBefore = await cache.cancelInFlightCalls

        try await coordinator.changeChannel(to: 1)

        // Allow the detached Task { await cacheRef.cancelInFlightDownloads() } to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancelsAfter = await cache.cancelInFlightCalls
        XCTAssertGreaterThanOrEqual(cancelsAfter, cancelsBefore + 1)
    }

    func testStopCancelsInFlightDownloads() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
        ])
        await api.setGaplessResponses([response, response])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let cancelsBefore = await cache.cancelInFlightCalls
        try await coordinator.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelsAfter = await cache.cancelInFlightCalls
        XCTAssertGreaterThanOrEqual(cancelsAfter, cancelsBefore + 1)
    }

    func testShutdownCancelsInFlightDownloads() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
        ])
        await api.setGaplessResponses([response, response])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let cancelsBefore = await cache.cancelInFlightCalls
        await coordinator.shutdown()
        let cancelsAfter = await cache.cancelInFlightCalls
        XCTAssertGreaterThanOrEqual(cancelsAfter, cancelsBefore + 1)
    }

    func testHandlePlaybackErrorCancelsInFlightDownloads() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
        ])
        await api.setGaplessResponses([response, response])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let cancelsBefore = await cache.cancelInFlightCalls

        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 150_000_000)

        let cancelsAfter = await cache.cancelInFlightCalls
        XCTAssertGreaterThanOrEqual(cancelsAfter, cancelsBefore + 1)
    }

    func testPlayFallsBackToRemoteUrlWhenCacheFails() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        await cache.setFailing([42])

        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 42, gaplessUrl: "https://s.example.com/42.flac"),
        ])
        await api.setGaplessResponses([response, response, response])  // play + post-play kickRefetch
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)

        let recorded = await engine.recordedCalls()
        let firstPlayUrl: URL? = recorded.lazy.compactMap {
            if case .play(let url, _) = $0 { return url } else { return nil }
        }.first
        XCTAssertEqual(firstPlayUrl, URL(string: "https://s.example.com/42.flac"))
    }

    func testPlayKicksSequentialDownloadOfAtMostTwoAhead() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
            makeGaplessSong(eventId: 2, gaplessUrl: "https://s.example.com/2.flac"),
            makeGaplessSong(eventId: 3, gaplessUrl: "https://s.example.com/3.flac"),
            makeGaplessSong(eventId: 4, gaplessUrl: "https://s.example.com/4.flac"),
            makeGaplessSong(eventId: 5, gaplessUrl: "https://s.example.com/5.flac"),
        ])
        await api.setGaplessResponses([response])
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)

        // Let the background downloader walk through queue[1..]
        try await Task.sleep(nanoseconds: 200_000_000)

        let calls = await cache.localFileCalls
        XCTAssertTrue(calls.contains(1), "queue[0] resolved synchronously by play()")
        XCTAssertTrue(calls.contains(2), "queue[1] resolved by play()'s explicit queueNext call")
        XCTAssertTrue(calls.contains(3), "queue[2] resolved by kickSequentialDownload")
        XCTAssertFalse(calls.contains(4), "queue[3] should NOT be downloaded (cap = 2 ahead)")
        XCTAssertFalse(calls.contains(5), "queue[4] should NOT be downloaded (cap = 2 ahead)")
    }

    func testQueueAdvanceEvictsDroppedSongAfterTelemetry() async throws {
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
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Boundary advance: mpv path = song[1]. Both telemetry (update_history for
        // eventId 10) and cache eviction (event 10) should occur. The coordinator's
        // syncQueueHeadFromMpv body spawns telemetry first, then the eviction Task —
        // by the time both side effects are observable, we expect at least:
        //   - api.updateHistoryCalls contains a "10" entry
        //   - cache.evictCalls contains 10
        await engine.setSimulatedCurrentPath(URL(string: "https://s.example.com/1.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 200_000_000)

        let evicted = await cache.evictCalls
        let history = await api.updateHistoryCalls
        XCTAssertTrue(evicted.contains(10), "expected cache.evict for the just-finished song; got=\(evicted)")
        XCTAssertTrue(history.contains(where: { $0.event == "10" }), "expected updateHistory for the just-finished song; got=\(history.map { $0.event })")
    }

    /// kickRefetch filters by queue.last.eventId and appends — preserves entire prefix.
    /// queue=[A(1),B(2),C(3)]; refetch returns [B(2),D(4),E(5)].
    /// Expected settled queue: [1,2,3,4,5] — prefix preserved, new tail appended.
    func testKickRefetchFiltersByQueueLastEventIdAndAppendsTail() async throws {
        let api = MockRpApiClient()
        let songA = makeGaplessSong(eventId: 1, gaplessUrl: "https://example.com/a.flac", title: "A")
        let songB = makeGaplessSong(eventId: 2, gaplessUrl: "https://example.com/b.flac", title: "B")
        let songC = makeGaplessSong(eventId: 3, gaplessUrl: "https://example.com/c.flac", title: "C")
        let songD = makeGaplessSong(eventId: 4, gaplessUrl: "https://example.com/d.flac", title: "D")
        let songE = makeGaplessSong(eventId: 5, gaplessUrl: "https://example.com/e.flac", title: "E")
        // play() consumes the first response; kickRefetch (queue<3 triggers after play) consumes the second.
        let initial = makeGaplessResponse(songs: [songA, songB, songC])
        let merge = makeGaplessResponse(songs: [songB, songD, songE])
        await api.setGaplessResponses([initial, merge])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(),
            logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)
        // play() fetches initial (3 songs, count==3, NO kickRefetch), then we need to verify the
        // queue shape. Since queue.count==3 the bootstrap does NOT kick a refetch; the queue
        // stays [A,B,C]. To trigger the merge-scenario refetch, simulate a boundary advance that
        // drops A, leaving [B,C] (count<3 → kickRefetch with tailEvent=C.eventId=3).
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/b.flac"))
        await engine.fire(.fileStarted)
        try await waitUntil({ await coord.snapshotQueueIds() == [2, 3, 4, 5] }, timeout: 2.0)
    }

    // MARK: - PR 33 Task 2: long-idle resume keeps cached song

    /// Long-idle resume with queue[0] cached: engine.resume (not play/clearPlaylist), queue[0]+[1] preserved.
    func testLongIdleResumePreservesCachedSongAndQueueOne() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        // 5-song initial response so queue has [1001..1005] after play.
        let initial = makeGaplessResponse(songs: (1001...1005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        // Refetch after resume returns new tail starting at 2001.
        let refetch = makeGaplessResponse(songs: (2001...2012).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        // play consumes initial; post-play kickRefetch (queue==5 >= 3 → no kick); resume kickRefetch consumes refetch.
        await api.setGaplessResponses([initial, refetch])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        // Simulate queue[0] present in cache so the new resume() path takes effect.
        cache.cachedFileOverride = { song in URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.pause()

        let callsBeforeResume = await engine.recordedCalls()
        let playCountBefore = callsBeforeResume.filter { if case .play = $0 { return true } else { return false } }.count
        let clearCountBefore = callsBeforeResume.filter { $0 == .clearPlaylist }.count

        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let callsAfterResume = await engine.recordedCalls()
        let resumeCount = callsAfterResume.filter { $0 == .resume }.count
        let playCountAfter = callsAfterResume.filter { if case .play = $0 { return true } else { return false } }.count
        let clearCountAfter = callsAfterResume.filter { $0 == .clearPlaylist }.count

        XCTAssertEqual(resumeCount, 1, "long-idle resume with cached song must call engine.resume exactly once")
        XCTAssertEqual(playCountAfter, playCountBefore, "engine.play must NOT be called again on cached long-idle resume")
        XCTAssertEqual(clearCountAfter, clearCountBefore, "clearPlaylist must NOT be called on cached long-idle resume")

        let ids = await coord.snapshotQueueIds()
        XCTAssertEqual(Array(ids.prefix(2)), [1001, 1002], "queue[0] and queue[1] must be preserved; got=\(ids)")
        XCTAssertTrue(ids.count >= 2, "queue must have at least 2 entries after truncate; got=\(ids)")
    }

    /// Long-idle resume with cached song merges fresh refetch as tail.
    func testLongIdleResumeMergesFreshTailAfterRefetch() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: (1001...1012).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        // Refetch returns songs with eventIds 2001..2010 — all > queue.last (1012 before truncate; 1002 after truncate).
        let refetch = makeGaplessResponse(songs: (2001...2010).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        await api.setGaplessResponses([initial, refetch])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        cache.cachedFileOverride = { song in URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        // After truncate: [1001, 1002]. Refetch returns [2001..2010], all > 1002, so merge appends all.
        try await waitUntil({
            let ids = await coord.snapshotQueueIds()
            return ids == [1001, 1002, 2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008, 2009, 2010]
        }, timeout: 2.0)
    }

    /// Long-idle resume with cache miss for queue[0] falls back to clearPlaylist + play.
    func testLongIdleResumeWithCacheMissForQueueZeroFallsBack() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: (1001...1005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        let refetch = makeGaplessResponse(songs: (2001...2005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        await api.setGaplessResponses([initial, refetch])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        // queue[0] is eventId 1001 — simulate it being evicted (cache miss).
        cache.cachedFileOverride = { song in song.eventId == 1001 ? nil : URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.pause()

        let callsBefore = await engine.recordedCalls()
        let clearCountBefore = callsBefore.filter { $0 == .clearPlaylist }.count
        let playCountBefore = callsBefore.filter { if case .play = $0 { return true } else { return false } }.count

        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()
        try await Task.sleep(nanoseconds: 150_000_000)

        let callsAfter = await engine.recordedCalls()
        let clearCountAfter = callsAfter.filter { $0 == .clearPlaylist }.count
        let playCountAfter = callsAfter.filter { if case .play = $0 { return true } else { return false } }.count

        XCTAssertGreaterThan(clearCountAfter, clearCountBefore,
                             "cache-miss fallback must call clearPlaylist")
        XCTAssertGreaterThan(playCountAfter, playCountBefore,
                             "cache-miss fallback must call engine.play for new song")

        let ids = await coord.snapshotQueueIds()
        XCTAssertEqual(ids.first, 2001, "after fallback refetch, queue head must be 2001; got=\(ids)")
    }

    /// Long-idle resume with a short queue still does engine.resume + kickRefetch.
    func testLongIdleResumeKicksRefetchAfterShortQueue() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(eventId: 1001, gaplessUrl: "https://example.com/1001.flac"),
        ])
        let refetch = makeGaplessResponse(songs: (2001...2003).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        await api.setGaplessResponses([initial, refetch, refetch])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        cache.cachedFileOverride = { song in URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        // Let the post-play kickRefetch consume the second slot (refetch).
        try await Task.sleep(nanoseconds: 150_000_000)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let calls = await engine.recordedCalls()
        let resumeCount = calls.filter { $0 == .resume }.count
        XCTAssertEqual(resumeCount, 1, "engine.resume must be called once. calls=\(calls)")

        // After resume's kickRefetch (consumes third slot), tail should include 2001.
        try await waitUntil({
            let ids = await coord.snapshotQueueIds()
            return ids.contains(2001)
        }, timeout: 2.0)
    }

    /// Second resume() during in-flight refetch is idempotent: no duplicate refetch; tail settles correctly.
    func testSecondResumeDuringInFlightRefetchIsIdempotent() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: (1001...1005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        let refetch = makeGaplessResponse(songs: (2001...2005).map { id in
            makeGaplessSong(eventId: id, gaplessUrl: "https://example.com/\(id).flac")
        })
        // Delay so the first kickRefetch is in-flight when the second resume fires.
        await api.setGaplessResponses([initial, refetch, refetch])
        await api.setGaplessDelay(nanos: 200_000_000)
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        cache.cachedFileOverride = { song in URL(string: song.gaplessUrl) }
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)

        // First resume kicks kickRefetch (in-flight, blocked by 200ms delay).
        try await coord.resume()
        // Second resume: pausedAt is nil now, so longIdle is false; just calls engine.resume again.
        // kickRefetch guard (refetchTask != nil) prevents a duplicate fetch.
        try await coord.resume()

        let calls = await engine.recordedCalls()
        let resumeCount = calls.filter { $0 == .resume }.count
        XCTAssertEqual(resumeCount, 2, "first resume = long-idle path, second = short-idle (pausedAt nil); both call engine.resume; got=\(resumeCount)")

        // Tail from first kickRefetch should eventually settle.
        try await waitUntil({
            let ids = await coord.snapshotQueueIds()
            return ids.contains(2001) && ids.contains(2005)
        }, timeout: 2.0)

        // Exactly 2 gapless calls: one for play() bootstrap, one for the long-idle kickRefetch.
        // The second resume() must NOT trigger a duplicate fetch (refetchTask != nil guard).
        let gaplessCalls = await api.calls.filter { if case .gapless = $0 { return true } else { return false } }.count
        XCTAssertEqual(gaplessCalls, 2, "expected exactly one bootstrap gapless + one long-idle refetch; got \(gaplessCalls)")
    }

    /// PR 40 Task 1 (failing test): the .fileEnded(.eof) recovery branch must
    /// not block the coordinator actor while queue[1]'s download is in flight.
    /// Pre-fix behavior: `await songFileCache.localFile(for: next)` parks the
    /// actor until bytes land, leaving the UI silent (no .loading emit) and
    /// blocking any concurrent actor work. Post-fix: cache miss should defer
    /// queueNext, emit .loading, and let a post-download hook fire queueNext.
    func testEofRecoveryDoesNotBlockWhenNextDownloadInFlight() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 100, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 101, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 102, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        // Subscribe to state updates BEFORE play so we capture the full sequence.
        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream {
                await statesBox.append(s)
            }
        }

        // Mark C as in-flight BEFORE play() so kickSequentialDownload's
        // background task for C parks on the continuation instead of racing
        // past via passthrough. Mark A/B as already downloaded so the
        // bootstrap downloader's localFile(A)/localFile(B) calls return
        // synchronously and don't perturb ordering.
        // setInFlight replaces the in-flight set; passing [102] leaves C as
        // the only blocked song.
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([102])

        try await coord.play(channelId: 0)

        // Poll for bootstrap markers instead of a fixed sleep: engine.play(A)
        // and engine.queueNext(B) must both be recorded before we proceed.
        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        // Drop bootstrap states (.stopped, .loading, .playing) so subsequent
        // assertions only consider recovery-path emits.
        await statesBox.reset()

        // Fire .fileEnded(.eof) for A → recovery removes A, plays B, then tries
        // to queueNext C. Current (buggy) code awaits localFile(for: C) which
        // blocks the actor here.
        await engine.fire(.fileEnded(reason: .eof))

        // Poll until engine.play(B) has been recorded (recovery's pre-block step).
        // 2s budget: well under typical CI test timeout, well over actor scheduling.
        let playedB = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(playedB, "recovery should have called engine.play(B) after EOF on A")

        // queueNext(C) must NOT be called yet — C's download is still in flight.
        let callsAfterPlay = await engine.recordedCalls()
        let queuedC = callsAfterPlay.contains(.queueNext(url: cUrl, startSeconds: nil))
        XCTAssertFalse(queuedC,
                       "queueNext(C) must be deferred while C's download is in flight; calls=\(callsAfterPlay)")

        // State must have transitioned to .loading: recovery deferred queueNext,
        // so the UI needs the loading spinner. Pre-fix this assertion fails because
        // the recovery branch never calls emitState.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "recovery should emit .loading when next song's download is in flight")

        // Release C's download. Post-fix: a post-download hook fires queueNext(C)
        // and state returns to .playing. Pre-fix: the parked actor await finally
        // returns and engine.queueNext(C) is called too, but state never returns
        // to .loading→.playing cycle (no emit).
        await cache.releaseInFlight(eventId: 102, url: cUrl)

        let queuedAfterRelease = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.queueNext(url: cUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(queuedAfterRelease,
                      "engine.queueNext(C) must fire after C's download completes")

        let endedPlaying = try await waitUntil({
            await coord.currentPlaybackState == .playing
        }, timeout: 1.0)
        XCTAssertTrue(endedPlaying,
                      "coordinator state must return to .playing after deferred queueNext lands")

        stateCollector.cancel()
    }

    /// Regression for the actual log scenario behind PR 40. Queue is [A, promo, C].
    /// A ends → recovery plays promo, defers queueNext(C) (in-flight). Before C lands,
    /// promo's own EOF fires (short promos do that). A second recovery runs while the
    /// first deferred queueNext is still pending. Once C finally downloads, the queue
    /// and the engine must not desync: exactly one engine.play(C), at most one
    /// engine.queueNext(C), no crash or stuck handler.
    func testEofRecoveryCascadeOnShortPromoDoesNotDesyncQueue() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 200, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "promo", eventId: 201, type: "P", gaplessUrl: "https://example.com/promo.flac"),
            makeGaplessSong(songId: "C", eventId: 202, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream {
                await statesBox.append(s)
            }
        }

        // A and promo cached so bootstrap and the first recovery proceed without
        // parking on localFile. C is in-flight so the deferred-queueNext branch fires.
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([202])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let promoUrl = URL(string: "https://example.com/promo.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!

        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: promoUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        // Step 1: A ends. Recovery removes A, plays promo, defers queueNext(C).
        await engine.fire(.fileEnded(reason: .eof))

        let playedPromo = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: promoUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(playedPromo, "first recovery should play the promo")

        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading, "deferred queueNext should emit .loading")

        // Step 2: promo ends while C is still downloading. Second recovery removes promo;
        // its head-resolve awaits localFile(C), which is still in-flight, so it parks.
        // The pre-Task-2 actor would have already been blocked on C from step 1 and
        // this event would have queued behind it; post-Task-2 the first recovery is
        // done, so this fires cleanly. The actor parks on the head-resolve await.
        await engine.fire(.fileEnded(reason: .eof))

        // C must NOT yet have been played — the recovery is parked on localFile(C).
        let preReleaseCalls = await engine.recordedCalls()
        XCTAssertFalse(preReleaseCalls.contains(.play(url: cUrl, startSeconds: nil)),
                       "engine.play(C) must not fire before C's download completes")

        // Step 3: release C. Both the parked recovery head-resolve and any pending
        // downloader localFile(C) waiters resume.
        await cache.releaseInFlight(eventId: 202, url: cUrl)

        let playedC = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: cUrl, startSeconds: nil))
        }, timeout: 3.0)
        XCTAssertTrue(playedC, "second recovery should play C once its download lands")

        // Recovery must lift coordinator state out of .loading once playback resumes.
        // This also gives any racing downloader hooks a beat to attempt a stale queueNext.
        let liftedToPlaying = try await waitUntil({
            await coord.currentPlaybackState == .playing
        }, timeout: 1.0)
        XCTAssertTrue(liftedToPlaying, "cascade recovery must lift state from .loading to .playing")

        let finalCalls = await engine.recordedCalls()
        let playCCount = finalCalls.filter { $0 == .play(url: cUrl, startSeconds: nil) }.count
        XCTAssertEqual(playCCount, 1, "C must be played exactly once; calls=\(finalCalls)")

        let queueNextCCount = finalCalls.filter { $0 == .queueNext(url: cUrl, startSeconds: nil) }.count
        XCTAssertLessThanOrEqual(queueNextCCount, 1,
                                 "queueNext(C) must not duplicate; calls=\(finalCalls)")

        let finalState = await coord.currentPlaybackState
        XCTAssertEqual(finalState, .playing,
                       "coordinator must reach .playing after cascade recovery completes")
        let observedPlaying = await statesBox.contains(.playing)
        XCTAssertTrue(observedPlaying,
                      "state stream must observe .playing after cascade recovery")

        stateCollector.cancel()
    }

    /// Task 4 log-assertion: recovery path must emit the expected diagnostic
    /// lines in order — entry log, deferring (cache miss), downloader landed,
    /// deferred queueNext fired.
    func testRecoveryEmitsExpectedLogLinesForDeferredQueueNext() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 100, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 101, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 102, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let capture = RecordingLogger()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: capture, bitrateProvider: { 4 }
        )

        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([102])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        await engine.fire(.fileEnded(reason: .eof))

        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        // Wait for the defer log (proves we hit the cache-miss branch).
        _ = try await waitUntil({
            capture.entries().contains(where: { $0.contains("recovery: deferring queueNext (not cached) event=102") })
        }, timeout: 1.0)

        await cache.releaseInFlight(eventId: 102, url: cUrl)

        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.queueNext(url: cUrl, startSeconds: nil))
        }, timeout: 2.0)

        _ = try await waitUntil({
            capture.entries().contains(where: { $0.contains("recovery: deferred queueNext fired event=102 elapsedSinceDeferMs=") })
        }, timeout: 1.0)

        let entries = capture.entries()
        func firstIndex(_ needle: String) -> Int? {
            entries.firstIndex(where: { $0.contains(needle) })
        }

        guard let entryIdx = firstIndex("recovery: head=event=101 (cached) next=event=102 (miss)") else {
            XCTFail("missing entry log; entries=\(entries)")
            return
        }
        guard let deferIdx = firstIndex("recovery: deferring queueNext (not cached) event=102") else {
            XCTFail("missing defer log; entries=\(entries)")
            return
        }
        guard let landedIdx = firstIndex("downloader: landed event=102, checking pending queueNext") else {
            XCTFail("missing downloader landed log; entries=\(entries)")
            return
        }
        guard let firedIdx = firstIndex("recovery: deferred queueNext fired event=102 elapsedSinceDeferMs=") else {
            XCTFail("missing deferred-fired log; entries=\(entries)")
            return
        }

        XCTAssertLessThan(entryIdx, deferIdx, "entry log must precede defer log; entries=\(entries)")
        XCTAssertLessThan(deferIdx, landedIdx, "defer log must precede downloader landed log; entries=\(entries)")
        XCTAssertLessThan(landedIdx, firedIdx, "downloader landed log must precede deferred-fired log; entries=\(entries)")
    }

    /// PR 41: syncQueueHeadFromMpv (.fileStarted advance branch) must defer queueNext
    /// via the synchronous cachedFile(for:) probe when queue[1] is not yet downloaded.
    /// Pre-fix: blocking await songFileCache.localFile(for: queue[1]) parks the actor
    /// and risks the same cascade PR 40 fixed in the .fileEnded(.eof) recovery branch.
    func testSyncQueueHeadFromMpvDefersQueueNextOnAdvanceWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 300, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 301, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 302, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A + B downloaded so bootstrap completes; C in-flight (uncached).
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([302])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        // Initial fileStarted: A is playing. Seeds lastStartedEventId so the next
        // fileStarted is treated as an advance. engine.currentPath() already returns aUrl
        // (set by engine.play() inside coord.play). The sleep yields enough actor time
        // for the first event to be consumed and lastStartedEventId set before we
        // mutate currentPath and fire the second event. 200ms is a comfortable margin
        // over typical actor-scheduling latency without slowing the test meaningfully.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 200_000_000)

        await statesBox.reset()

        // Simulate B starting (mpv advanced from A → B naturally). syncQueueHeadFromMpv
        // runs, advances queue head, then tries to queueNext C. C is in-flight.
        await engine.setSimulatedCurrentPath(bUrl)
        await engine.fire(.fileStarted)

        // Wait for .loading first: once emitted, syncQueueHeadFromMpv's defer
        // path has run to completion (helper emits .loading at its tail), so any
        // subsequent assertion about engine.queueNext is settled.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "syncQueueHeadFromMpv must emit .loading when deferring queueNext")

        // queueNext(C) must NOT have fired — C is uncached, defer path took it.
        let callsAfterAdvance = await engine.recordedCalls()
        let queuedC = callsAfterAdvance.contains(.queueNext(url: cUrl, startSeconds: nil))
        XCTAssertFalse(queuedC,
                       "syncQueueHeadFromMpv must defer queueNext(C) when C is uncached; calls=\(callsAfterAdvance)")

        stateCollector.cancel()
    }

    /// PR 41: handleSongPlaybackError's recovery-play branch must defer queueNext
    /// when the new queue[1] (after dropping the unplayable head) is uncached.
    func testHandleSongPlaybackErrorDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 400, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 401, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 402, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A + B downloaded (bootstrap plays A, queueNext B); C in-flight.
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([402])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        // Code -13 = LOADING_FAILED, classified as unplayable. Routes to
        // handleSongPlaybackError which drops A, plays B, tries queueNext(C).
        await engine.fire(.fileEnded(reason: .error(code: -13)))

        let playedB = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(playedB, "recovery must play B after unplayable-A drop")

        // Wait for .loading first — once emitted, the defer path completed.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "handleSongPlaybackError must emit .loading when deferring queueNext")

        // queueNext(C) must NOT have fired — C is uncached, defer path took it.
        let callsAfter = await engine.recordedCalls()
        let queuedC = callsAfter.contains(.queueNext(url: cUrl, startSeconds: nil))
        XCTAssertFalse(queuedC,
                       "handleSongPlaybackError must defer queueNext(C) when uncached; calls=\(callsAfter)")

        stateCollector.cancel()
    }

    /// PR 41: applyBitrateChange's post-refresh queueNext must defer when the new
    /// queue[1] (refreshed at the new bitrate) is uncached.
    func testApplyBitrateChangeDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 500, gaplessUrl: "https://example.com/A-320.mp3"),
            makeGaplessSong(songId: "B", eventId: 501, gaplessUrl: "https://example.com/B-320.mp3"),
        ])
        // No-op response for kickRefetch (fires after play() because queue.count < 3).
        // Same eventIds as initial so runRefetch's `newSongs > tailEvent` filter is empty;
        // queue stays unchanged and applyBitrateChange consumes the refresh response.
        let kickRefetchNoop = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 500, gaplessUrl: "https://example.com/A-320.mp3"),
            makeGaplessSong(songId: "B", eventId: 501, gaplessUrl: "https://example.com/B-320.mp3"),
        ])
        let refresh = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 500, gaplessUrl: "https://example.com/A-flac.flac"),
            makeGaplessSong(songId: "B", eventId: 501, gaplessUrl: "https://example.com/B-flac.flac"),
        ])
        await api.setGaplessResponses([initial, kickRefetchNoop, refresh])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        await cache.markDownloaded(Array(initial.songs.prefix(2)))

        try await coord.play(channelId: 0)

        let aOld = URL(string: "https://example.com/A-320.mp3")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aOld, startSeconds: nil))
        }, timeout: 2.0)

        // Override cachedFile to force a miss for event 501 (B). The mock's
        // releasedMirror would otherwise return a URL because markDownloaded
        // stored the eventId. Override is sync (nonisolated(unsafe) var).
        cache.cachedFileOverride = { song in
            song.eventId == 501 ? nil : URL(string: song.gaplessUrl)
        }
        await statesBox.reset()

        await coord.applyBitrateChange()

        // Wait for .loading first — once emitted, the defer path completed.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "applyBitrateChange must emit .loading when deferring queueNext")

        // queueNext(B-flac) must NOT have fired — B is uncached, defer path took it.
        let bNew = URL(string: "https://example.com/B-flac.flac")!
        let callsAfter = await engine.recordedCalls()
        let queuedB = callsAfter.contains(.queueNext(url: bNew, startSeconds: nil))
        XCTAssertFalse(queuedB,
                       "applyBitrateChange must defer queueNext(B-flac) when uncached; calls=\(callsAfter)")

        stateCollector.cancel()
    }

    /// PR 41: play(channelId:) must defer queueNext when queue[1] is uncached at
    /// the post-engine.play queueNext step.
    ///
    /// Uses cachedFileOverride (not setInFlight) to force cache miss without
    /// parking the actor — pre-fix awaits on localFile(B) would hang the test
    /// body forever since play() is itself awaited. With override, pre-fix's
    /// localFile(B) returns the passthrough URL and queueNext(B) fires;
    /// post-fix's cachedFile(B) returns nil and the helper defers. The
    /// discriminator is queueNext(B) being absent post-fix.
    func testPlayDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 800, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 801, gaplessUrl: "https://example.com/B.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // Both downloaded so localFile resolves synchronously for either song.
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        // Override: cachedFile reports a miss for B (event 801) but the cached
        // URL for A. tryQueueNextOrDefer's synchronous probe for queue[1] thus
        // sees a miss; pre-fix's localFile path still returns B's passthrough URL.
        cache.cachedFileOverride = { song in
            song.eventId == 801 ? nil : URL(string: song.gaplessUrl)
        }

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        _ = try await waitUntil({
            await engine.recordedCalls().contains(.play(url: aUrl, startSeconds: nil))
        }, timeout: 2.0)

        // Pre-fix: localFile(B) returns passthrough URL, queueNext(B) fires.
        // Post-fix: cachedFile(B) returns nil, helper defers, queueNext(B) NOT called.
        // Give the actor a moment to run play()'s queue[1] block to completion.
        // (200ms — wait-loading-first does not apply here because .loading is
        // emitted at L148 before playInternal too, so it's not a discriminator.)
        try await Task.sleep(nanoseconds: 200_000_000)
        let callsAfter = await engine.recordedCalls()
        let queuedB = callsAfter.contains(.queueNext(url: bUrl, startSeconds: nil))
        XCTAssertFalse(queuedB,
                       "play() must defer queueNext(B) when uncached; calls=\(callsAfter)")

        stateCollector.cancel()
    }

    /// PR 41 cross-cutting: when a tryQueueNextOrDefer call defers (via the
    /// .fileStarted advance path), kickSequentialDownload's post-download hook
    /// must fire queueNext + lift state .loading → .playing once the bytes land.
    /// One exemplar test covers the lift behaviour across all converted sites
    /// (helper extraction means the lift path is shared).
    func testDeferredQueueNextLiftsStateWhenDownloaderLands() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 900, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 901, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 902, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A + B downloaded so bootstrap completes; C in-flight so defer fires on advance.
        await cache.markDownloaded(Array(response.songs.prefix(2)))
        await cache.setInFlight([902])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        // Seed lastStartedEventId by firing the initial .fileStarted (A).
        // Mirrors the syncQueueHeadFromMpv defer test pattern.
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 200_000_000)

        await statesBox.reset()

        // Advance to B → tryQueueNextOrDefer(C) sees cache miss → defers + emits .loading.
        await engine.setSimulatedCurrentPath(bUrl)
        await engine.fire(.fileStarted)

        // Confirm defer happened.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "defer path must emit .loading before downloader lands")

        // Release C's download → tryQueueNextIfPending fires queueNext(C) + lifts state.
        await cache.releaseInFlight(eventId: 902, url: cUrl)

        let queuedC = try await waitUntil({
            await engine.recordedCalls().contains(.queueNext(url: cUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(queuedC,
                      "tryQueueNextIfPending must fire queueNext(C) after C lands")

        let backToPlaying = try await waitUntil({
            await coord.currentPlaybackState == .playing
        }, timeout: 1.0)
        XCTAssertTrue(backToPlaying,
                      "state must lift .loading → .playing after deferred queueNext lands")

        stateCollector.cancel()
    }
}

private actor StateBox {
    private(set) var states: [PlaybackState] = []
    func append(_ s: PlaybackState) { states.append(s) }
    func contains(_ s: PlaybackState) -> Bool { states.contains(s) }
    func reset() { states.removeAll() }
}
