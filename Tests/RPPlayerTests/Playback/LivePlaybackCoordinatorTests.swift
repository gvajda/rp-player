import XCTest
@testable import RPPlayer

final class LivePlaybackCoordinatorTests: XCTestCase {
    fileprivate func makeSong(id: String, duration: Int, elapsed: Int, event: String? = nil) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: event, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: elapsed, slideshow: nil,
            type: nil, sliceNum: nil
        )
    }

    fileprivate func makeBlock(channel: String = "0", url: String = "https://example.com/0-0.flac",
                                cue: Int = 0,
                                expiration: Int = 0,
                                bitrate: String? = nil,
                                endEvent: String? = nil,
                                songs: [(String, Int)]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        var elapsed = 0
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = makeSong(id: pair.0, duration: pair.1, elapsed: elapsed)
            elapsed += pair.1
        }
        return GetBlock(
            url: url, chan: channel, bitrate: bitrate, cue: cue, expiration: expiration,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: endEvent, type: nil, ext: nil
        )
    }

    fileprivate func makeBlock(channel: String = "0", url: String = "https://example.com/0-0.flac",
                                cue: Int = 0,
                                expiration: Int = 0,
                                bitrate: String? = nil,
                                endEvent: String? = nil,
                                prebuiltSongs: [PlayListSong]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        for (idx, song) in prebuiltSongs.enumerated() {
            dict[String(idx)] = song
        }
        return GetBlock(
            url: url, chan: channel, bitrate: bitrate, cue: cue, expiration: expiration,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: endEvent, type: nil, ext: nil
        )
    }

    fileprivate func silentLogger() -> AppLogger {
        AppLogger(category: "PlaybackCoordinatorTests")
    }

    func testPlayCallsGetBlockAndEnginePlay() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(apiCalls.contains(.play(channel: 0, bitrate: 4, event: 0, action: .start,
                                              audioType: nil, episodeId: nil, sliceNum: nil)))
        XCTAssertEqual(engineCalls, [.play(url: URL(string: "https://example.com/0-0.flac")!, startSeconds: nil)])
    }

    func testPlayPropagatesBlockBitrateIntoNowPlaying() async throws {
        // Display label comes from `block.bitrate` (what was requested + served)
        // not mpv's runtime audio-bitrate observer, which can disagree.
        let api = MockRpApiClient()
        let block = makeBlock(bitrate: "flac",
                              songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        let np = await coordinator.nowPlaying
        XCTAssertEqual(np?.blockBitrate, "flac")
    }

    func testPlayThrowsWhenBlockHasNoSongs() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        do {
            try await coordinator.play(channelId: 0)
            XCTFail("expected blockHasNoSongs")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .blockHasNoSongs)
        }
    }

    func testNowPlayingIsNilBeforePlay() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }

    func testPlayDetectsStaleBlockAndAdvancesViaActionPlay() async throws {
        // Server returned a "stale" bootstrap block: cue=0, all elapsed <= 0 with at
        // least one strictly negative. Coordinator must follow up with a single
        // action=play advance call, using the last song's event/type/sliceNum,
        // and play the resulting block.
        let staleSong = PlayListSong(
            songId: "old", artist: "A", title: "T", album: "Al", duration: 289_400,
            event: "2870247", schedTime: nil, chan: "0", year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: -289_400, slideshow: nil,
            type: "M", sliceNum: "5"
        )
        let staleBlock = makeBlock(
            url: "https://example.com/stale.flac",
            cue: 0, endEvent: "2870247", prebuiltSongs: [staleSong]
        )
        let freshBlock = makeBlock(
            url: "https://example.com/fresh.flac",
            songs: [("s1", 60_000), ("s2", 60_000)]
        )

        let api = MockRpApiClient()
        await api.setBlockResponses([staleBlock, freshBlock])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2, "expected bootstrap + 1 advance")
        XCTAssertEqual(calls[0], .play(channel: 0, bitrate: 4, event: 0, action: .start,
                                       audioType: nil, episodeId: nil, sliceNum: nil))
        guard case let .play(_, _, event2, action2, audioType2, episodeId2, sliceNum2) = calls[1] else {
            return XCTFail("expected second call to be .play")
        }
        XCTAssertEqual(action2, .play)
        XCTAssertEqual(event2, 2_870_247)
        XCTAssertEqual(audioType2, "M")
        XCTAssertEqual(episodeId2, 0)
        XCTAssertEqual(sliceNum2, "5")

        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last,
                       .play(url: URL(string: "https://example.com/fresh.flac")!, startSeconds: nil),
                       "engine should play the fresh (post-advance) block, not the stale one")
    }

    func testPlayDoesNotAdvanceTwiceIfAdvanceAlsoReturnsStale() async throws {
        // Defense-in-depth: if both the bootstrap AND the action=play advance
        // return stale, we accept the second response rather than recursing.
        let staleA = PlayListSong(
            songId: "a", artist: "A", title: "T", album: "Al", duration: 100_000,
            event: "100", schedTime: nil, chan: "0", year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: -100_000, slideshow: nil,
            type: "M", sliceNum: "1"
        )
        let staleB = PlayListSong(
            songId: "b", artist: "A", title: "T", album: "Al", duration: 100_000,
            event: "200", schedTime: nil, chan: "0", year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: -100_000, slideshow: nil,
            type: "M", sliceNum: "1"
        )
        let staleBlockA = makeBlock(url: "https://example.com/staleA.flac", cue: 0,
                                    endEvent: "100", prebuiltSongs: [staleA])
        let staleBlockB = makeBlock(url: "https://example.com/staleB.flac", cue: 0,
                                    endEvent: "200", prebuiltSongs: [staleB])
        let api = MockRpApiClient()
        await api.setBlockResponses([staleBlockA, staleBlockB])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coord.play(channelId: 0)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2, "expected exactly one advance retry, not infinite recursion")
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last,
                       .play(url: URL(string: "https://example.com/staleB.flac")!, startSeconds: nil))
    }
}

extension LivePlaybackCoordinatorTests {
    func testPositionUpdateEmitsNowPlayingWhenSongBoundaryCrossed() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.nowPlayingUpdates
        let collector = Task { () -> [Int] in
            var seenIndexes: [Int] = []
            for await np in stream {
                seenIndexes.append(np.songIndexInBlock)
                if seenIndexes.count == 3 { return seenIndexes }
            }
            return seenIndexes
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 30.0))   // still song 0
        await engine.fire(.positionUpdate(seconds: 75.0))   // now song 1
        await engine.fire(.positionUpdate(seconds: 200.0))  // now song 2
        let result = await collector.value
        XCTAssertEqual(result, [0, 1, 2])
    }

    func testPositionUpdatesWithinSameSongDoNotReEmit() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.nowPlayingUpdates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count == 2 { return count }
            }
            return count
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 5.0))    // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 10.0))   // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 15.0))   // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 100.0))  // song 1 — emits
        let result = await collector.value
        // First emission is the initial play() emit (song 0); second is the song 1 boundary cross.
        XCTAssertEqual(result, 2)
    }
}

extension LivePlaybackCoordinatorTests {
    func testSkipForwardWithinBlockSeeksToNextSongStart() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        try await coordinator.skipForward()
        let calls = await engine.recordedCalls()
        XCTAssertEqual(calls.last, .seek(seconds: 60.05))
    }

    func testSkipForwardOnLastSongFetchesNextBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-1.flac",
            songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-2.flac",
            songs: [("s5", 60_000), ("s6", 60_000), ("s7", 60_000), ("s8", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 280.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coordinator.skipForward()
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls.count, 2)
        XCTAssertEqual(apiCalls.last, .play(channel: 0, bitrate: 0, event: 0, action: .play,
                                            audioType: "M", episodeId: 0, sliceNum: nil))
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-2.flac")!, startSeconds: nil))
    }

    func testSkipForwardPastLastSongUsesPlayActionWithSongMetadata() async throws {
        let api = MockRpApiClient()
        let firstSong = PlayListSong(
            songId: "1", artist: "A", title: "T", album: "Al", duration: 60_000,
            event: "100", schedTime: nil, chan: "0", year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
            type: "M", sliceNum: "5"
        )
        let firstBlock = makeBlock(endEvent: "100", prebuiltSongs: [firstSong])
        let secondBlock = makeBlock(songs: [("s2", 60_000)])
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 2 }
        )
        try await coord.play(channelId: 0)
        try await coord.skipForward()

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2)
        guard case let .play(channel, bitrate, event, action, audioType, episodeId, sliceNum) = calls[1] else {
            return XCTFail("expected second call to be .play, got \(calls[1])")
        }
        XCTAssertEqual(channel, 0)
        XCTAssertEqual(bitrate, 2)
        XCTAssertEqual(event, 100)
        XCTAssertEqual(action, .play)
        XCTAssertEqual(audioType, "M")
        XCTAssertEqual(episodeId, 0)
        XCTAssertEqual(sliceNum, "5")
    }

    func testSkipForwardWithoutCurrentBlockThrows() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        do {
            try await coordinator.skipForward()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }
}

extension LivePlaybackCoordinatorTests {
    func testPrefetchTriggeredInLastSongFinalSeconds() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "second play call should have been triggered as prefetch")
    }

    func testPrefetchOnlyHappensOncePerBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.fire(.positionUpdate(seconds: 235.0))
        await engine.fire(.positionUpdate(seconds: 238.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "prefetch should happen at most once per block")
    }

    func testEndOfFileSwapsToPrefetchedBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-B.flac")!, startSeconds: nil))
    }

    func testPrefetchUsesEndEventAsEventParam() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(
            endEvent: "400",
            prebuiltSongs: [makeSong(id: "1", duration: 11_000, elapsed: 0, event: "400")]
        )
        let block2 = makeBlock(songs: [("s2", 60_000)])
        await api.setBlockResponses([block1, block2])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine,
            logger: AppLogger(category: "test"),
            bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 2.0))
        try await Task.sleep(nanoseconds: 100_000_000)

        let calls = await api.calls
        let prefetchEvent: Int? = {
            guard calls.count >= 2 else { return nil }
            if case let .play(_, _, event, _, _, _, _) = calls[1] { return event }
            return nil
        }()
        XCTAssertEqual(prefetchEvent, 400)
    }

    func testPrefetchUsesPlayActionWithLastSongMetadata() async throws {
        let api = MockRpApiClient()
        let lastSong = PlayListSong(
            songId: "1", artist: "A", title: "T", album: "Al", duration: 5_000,
            event: "100", schedTime: nil, chan: "0", year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
            type: "M", sliceNum: "5"
        )
        let firstBlock = makeBlock(cue: 0, endEvent: "100", prebuiltSongs: [lastSong])
        let secondBlock = makeBlock(songs: [("s2", 60_000)])
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 3 }
        )
        try await coord.play(channelId: 0)

        await engine.fire(.positionUpdate(seconds: 1.0))
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2)
        guard case let .play(_, _, event, action, audioType, episodeId, sliceNum) = calls[1] else {
            return XCTFail("expected prefetch call to be .play, got \(calls[1])")
        }
        XCTAssertEqual(event, 100)
        XCTAssertEqual(action, .play)
        XCTAssertEqual(audioType, "M")
        XCTAssertEqual(episodeId, 0)
        XCTAssertEqual(sliceNum, "5")
    }
}

extension LivePlaybackCoordinatorTests {
    func testChangeChannelCancelsPrefetchFromPreviousChannel() async throws {
        let api = MockRpApiClient()
        let chan0Block = makeBlock(
            url: "https://example.com/chan0.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        // Second response is consumed by the in-flight prefetch (the mock's
        // play doesn't observe Task.cancel()). Its result must be discarded
        // by changeChannel's cleanup.
        let prefetchVictim = makeBlock(
            url: "https://example.com/chan0-prefetch.flac",
            songs: [("p1", 60_000), ("p2", 60_000), ("p3", 60_000), ("p4", 60_000)]
        )
        let chan1Block = makeBlock(
            channel: "1",
            url: "https://example.com/chan1.flac",
            songs: [("c1", 60_000), ("c2", 60_000), ("c3", 60_000), ("c4", 60_000)]
        )
        await api.setBlockResponses([chan0Block, prefetchVictim, chan1Block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coordinator.changeChannel(to: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/chan1.flac")!, startSeconds: nil))
        let chan1PlayIndex = engineCalls.lastIndex(of: .play(url: URL(string: "https://example.com/chan1.flac")!, startSeconds: nil))
        XCTAssertEqual(chan1PlayIndex, engineCalls.count - 1, "chan1 play must be the final engine call")
    }
}

extension LivePlaybackCoordinatorTests {
    func testPauseBeforePlayThrowsNotPlaying() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        do {
            try await coordinator.pause()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }

    func testPauseAndResumeForwardToEngineWhenPlaying() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        try await coordinator.pause()
        try await coordinator.resume()
        let calls = await engine.recordedCalls()
        XCTAssertTrue(calls.contains(.pause))
        XCTAssertTrue(calls.contains(.resume))
    }

    func testStalePrefetchResultDiscardedAfterStop() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let prefetchVictim = makeBlock(
            url: "https://example.com/A-prefetch.flac",
            songs: [("p1", 60_000), ("p2", 60_000), ("p3", 60_000), ("p4", 60_000)]
        )
        let restartBlock = makeBlock(
            url: "https://example.com/B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, prefetchVictim, restartBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coordinator.play(channelId: 0)
        // Trigger prefetch (in-flight call to api.play). Sleep gives the
        // eventTask a chance to process the positionUpdate before stop runs,
        // so the prefetch is actually in-flight when we cancel it.
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        // Stop while prefetch is racing.
        try await coordinator.stop()
        // Give the prefetch task time to resolve and try to write back.
        try await Task.sleep(nanoseconds: 100_000_000)
        // Restart playback. If the stale prefetch had resurrected as
        // prefetchedBlock, an EOF would swap to it; instead we should never
        // see A-prefetch.flac played after the new play().
        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertFalse(
            engineCalls.contains(.play(url: URL(string: "https://example.com/A-prefetch.flac")!, startSeconds: nil)),
            "prefetched block from before stop() must not resurface after restart. calls=\(engineCalls)"
        )
    }

    func testResumeAfterLongIdleRefetchesBlockInsteadOfEngineResume() async throws {
        // After paused for >= 59 minutes, mpv's HTTP connection to the CDN is
        // commonly stale (server-side connection eviction, even if block.expiration
        // is still in the future per RP's API). resume() must refetch via play()
        // rather than calling engine.resume() blindly.
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/before.flac",
            expiration: 99_999_999_999,
            songs: [("s1", 60_000), ("s2", 60_000)]
        )
        let refetched = makeBlock(
            url: "https://example.com/after.flac",
            songs: [("s3", 60_000)]
        )
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await coord.pause()
        // 59 minutes + 1 second after pause
        clockState.date = Date(timeIntervalSince1970: 1_000 + 59 * 60 + 1)
        try await coord.resume()

        let engineCalls = await engine.recordedCalls()
        let resumeCount = engineCalls.filter { if case .resume = $0 { return true } else { return false } }.count
        XCTAssertEqual(resumeCount, 0, "expected no engine.resume after long idle")
        XCTAssertEqual(engineCalls.last,
                       .play(url: URL(string: "https://example.com/after.flac")!, startSeconds: nil),
                       "expected engine.play with refetched block")
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "expected bootstrap + refetch (no extra advance)")
        guard case let .play(_, _, _, action2, _, _, _) = apiCalls[1] else {
            return XCTFail("expected second call to be .play")
        }
        XCTAssertEqual(action2, .start, "long-idle refetch goes through play(channelId:) which uses action=start")
    }

    func testResumeWithinIdleThresholdStillCallsEngineResume() async throws {
        // 30 minutes after pause: still within 59m threshold, normal engine.resume() path.
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let block = makeBlock(
            url: "https://example.com/0-1.flac",
            expiration: 99_999_999_999,
            songs: [("s1", 60_000), ("s2", 60_000)]
        )
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await coord.pause()
        clockState.date = Date(timeIntervalSince1970: 1_000 + 30 * 60)
        try await coord.resume()

        let engineCalls = await engine.recordedCalls()
        let resumeCount = engineCalls.filter { if case .resume = $0 { return true } else { return false } }.count
        XCTAssertEqual(resumeCount, 1, "expected exactly one engine.resume within idle threshold")
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 1, "no refetch within threshold")
    }
}

extension LivePlaybackCoordinatorTests {
    func testResumeAfterExpiredBlockFetchesFreshBlock() async throws {
        let api = MockRpApiClient()
        let pastTimestamp = Int(Date().timeIntervalSince1970) - 60
        let staleBlock = makeBlock(channel: "0", url: "https://example.com/STALE.flac",
                                   cue: 0, expiration: pastTimestamp,
                                   songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
        let freshBlock = makeBlock(channel: "0", url: "https://example.com/FRESH.flac",
                                   cue: 0, expiration: pastTimestamp + 600,
                                   songs: [("e", 60_000), ("f", 60_000), ("g", 60_000), ("h", 60_000)])
        await api.setBlockResponses([staleBlock, freshBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 })
        try await coordinator.play(channelId: 0)
        try await coordinator.pause()
        try await coordinator.resume()

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(
            engineCalls.contains(.play(url: URL(string: "https://example.com/FRESH.flac")!, startSeconds: nil)),
            "expected coordinator to fetch fresh block on resume after expiration. calls=\(engineCalls)"
        )
    }

    func testResumeWithFreshBlockJustResumesEngine() async throws {
        let api = MockRpApiClient()
        let futureTimestamp = Int(Date().timeIntervalSince1970) + 600
        let freshBlock = makeBlock(channel: "0", url: "https://example.com/FRESH.flac",
                                   cue: 0, expiration: futureTimestamp,
                                   songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
        await api.setBlockResponses([freshBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 })
        try await coordinator.play(channelId: 0)
        try await coordinator.pause()
        try await coordinator.resume()

        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.filter { $0 == .resume }.count, 1)
        XCTAssertEqual(
            engineCalls.filter { if case .play = $0 { return true } else { return false } }.count, 1,
            "should only have the initial play, not a re-fetch. calls=\(engineCalls)"
        )
    }
}

private actor BitrateBox {
    private(set) var value: Int
    init(_ initial: Int) { value = initial }
    func set(_ newValue: Int) { value = newValue }
}

extension LivePlaybackCoordinatorTests {
    func testCoordinatorReadsBitrateFromProviderOnEveryPlay() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(channel: "0", url: "https://example.com/A.flac",
                               songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
        let block2 = makeBlock(channel: "0", url: "https://example.com/B.flac",
                               songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
        await api.setBlockResponses([block1, block2])
        let engine = MockPlayerEngine()
        let box = BitrateBox(0)
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { await box.value }
        )

        try await coordinator.play(channelId: 0)
        await box.set(4)
        try await coordinator.play(channelId: 0)

        let calls = await api.calls
        let blockCalls = calls.compactMap { call -> (Int, Int)? in
            if case .play(let channel, let bitrate, _, _, _, _, _) = call {
                return (channel, bitrate)
            }
            return nil
        }
        XCTAssertEqual(blockCalls.map { [$0.0, $0.1] }, [[0, 0], [0, 4]],
                       "bitrate change must take effect on next play. calls=\(blockCalls)")
    }
}

extension LivePlaybackCoordinatorTests {
    func testPlayChannelInvokesPlayWithEventZero() async throws {
        let api = MockRpApiClient()
        await api.setBlockResponses([makeBlock(songs: [("s1", 60_000)])])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine,
            logger: AppLogger(category: "test"),
            bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)

        let calls = await api.calls
        XCTAssertEqual(calls.last, .play(channel: 0, bitrate: 4, event: 0, action: .start,
                                         audioType: nil, episodeId: nil, sliceNum: nil))
    }

    func testSkipForwardPastLastSongAdoptsPrefetchedBlockWhenAvailable() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(
            endEvent: "600",
            prebuiltSongs: [makeSong(id: "1", duration: 11_000, elapsed: 0, event: "600")]
        )
        let block2 = makeBlock(songs: [("b1", 60_000), ("b2", 60_000)])
        await api.setBlockResponses([block1, block2])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine,
            logger: AppLogger(category: "test"),
            bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        // Drive into prefetch window.
        await engine.fire(.positionUpdate(seconds: 2.0))
        try await Task.sleep(nanoseconds: 200_000_000)
        // Confirm prefetch fired (2 calls so far).
        var calls = await api.calls
        XCTAssertEqual(calls.count, 2)

        // Now skip past last. Should NOT issue a 3rd fetch.
        try await coordinator.skipForward()
        calls = await api.calls
        XCTAssertEqual(calls.count, 2, "skipForward past-last must adopt prefetched block, not re-fetch")
    }

    func testSkipForwardPastLastSongCancelsInFlightPrefetchAndFetches() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(
            endEvent: "700",
            prebuiltSongs: [makeSong(id: "1", duration: 11_000, elapsed: 0, event: "700")]
        )
        let block2 = makeBlock(songs: [("b1", 60_000), ("b2", 60_000)])
        await api.setBlockResponses([block1, block2])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine,
            logger: AppLogger(category: "test"),
            bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        await api.setPlayDelay(nanos: 2_000_000_000)
        await engine.fire(.positionUpdate(seconds: 2.0))
        // Yield so prefetch task enters Task.sleep before we cancel.
        try await Task.sleep(nanoseconds: 50_000_000)
        await api.setPlayDelay(nanos: 0)
        try await coordinator.skipForward()
        // Yield so cancelled prefetch observes cancellation and records.
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancellations = await api.playCancellations
        XCTAssertEqual(cancellations, 1, "in-flight prefetch must be cancelled by skipForward past-last")
        let np = await coordinator.nowPlaying
        XCTAssertNotNil(np, "coordinator must have nowPlaying after skip")
    }
}

extension LivePlaybackCoordinatorTests {
    func testPositionUpdatesYieldsToSubscribers() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.positionUpdates
        let collector = Task { () -> [Double] in
            var seen: [Double] = []
            for await pos in stream {
                seen.append(pos)
                if seen.count == 3 { return seen }
            }
            return seen
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 12.5))
        await engine.fire(.positionUpdate(seconds: 25.0))
        let result = await collector.value
        // First element is the seeded current position (0 at startup),
        // followed by the two engine emissions.
        XCTAssertEqual(result, [0.0, 12.5, 25.0])
    }

    func testPositionUpdatesSeedsLatestPositionToNewSubscriber() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 17.5))
        // Give the actor a tick to process the event before the new subscriber
        // calls .positionUpdates.
        try await Task.sleep(nanoseconds: 50_000_000)

        let stream = await coordinator.positionUpdates
        let firstYield = await Task { () -> Double? in
            for await pos in stream { return pos }
            return nil
        }.value

        XCTAssertEqual(firstYield, 17.5)
    }

    func testPositionUpdatesFinishOnShutdown() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.positionUpdates
        try await coordinator.play(channelId: 0)
        await coordinator.shutdown()
        for await _ in stream {}

        let postShutdownStream = await coordinator.positionUpdates
        var postShutdownCount = 0
        for await _ in postShutdownStream { postShutdownCount += 1 }
        XCTAssertEqual(postShutdownCount, 0)
    }
}

// MARK: - Telemetry: song-start on bootstrap
extension LivePlaybackCoordinatorTests {
    func testBootstrapFiresUpdateHistoryForFirstSong() async throws {
        let api = MockRpApiClient()
        // Block with cue=3194ms, first song at elapsed=0 → ppm = max(1, 3194 - 0) = 3194
        let block = makeBlock(
            channel: "0", cue: 3194, endEvent: "2869396",
            prebuiltSongs: [
                PlayListSong(songId: "20093", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "2869396", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "5")
            ]
        )
        await api.setBlockResponses([block])
        let fixedDate = Date(timeIntervalSince1970: 1_777_746_855)
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(),
            bitrateProvider: { 0 }, clock: { fixedDate }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 1)
        let call = try XCTUnwrap(historyCalls.first)
        XCTAssertEqual(call.songId, "20093")
        XCTAssertEqual(call.chan, 0)
        XCTAssertEqual(call.event, "2869396")
        XCTAssertEqual(call.audioType, "M")
        XCTAssertEqual(call.sliceNum, "5")
        XCTAssertEqual(call.playPositionMillis, 3194)
        XCTAssertEqual(call.playtimeSecs, 1_777_746_855)
        XCTAssertFalse(call.pauseFlag)
    }

    func testNaturalSongAdvanceFiresUpdateHistory() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "s1", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "ev1", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "1"),
                PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                             duration: 60_000, event: "ev2", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 60_000, slideshow: nil,
                             type: "M", sliceNum: "2"),
            ]
        )
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Simulate engine crossing into song 2 (elapsed=60_000ms → 60.0s start)
        await engine.fire(.positionUpdate(seconds: 60.01))
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)  // bootstrap + boundary
        XCTAssertEqual(historyCalls.last?.songId, "s2")
        XCTAssertEqual(historyCalls.last?.event, "ev2")
        XCTAssertFalse(historyCalls.last?.pauseFlag ?? true)
    }

    func testChannelSwitchFiresUpdateHistoryForFirstSong() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(songs: [("s1", 60_000)])
        let block2 = makeBlock(
            channel: "1",
            prebuiltSongs: [
                PlayListSong(songId: "99", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "9999", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "1")
            ]
        )
        await api.setBlockResponses([block1, block2])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(),
            bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.changeChannel(to: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)
        XCTAssertEqual(historyCalls.last?.songId, "99")
        XCTAssertEqual(historyCalls.last?.chan, 1)
    }

    func testInBlockSkipFiresUpdateHistory() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "s1", artist: "A", title: "T1", album: "Al",
                             duration: 60_000, event: "ev1", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "1"),
                PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                             duration: 60_000, event: "ev2", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 60_000, slideshow: nil,
                             type: "M", sliceNum: "2"),
            ]
        )
        await api.setBlockResponses([block])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.skipForward()
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)  // bootstrap + skip
        XCTAssertEqual(historyCalls.last?.songId, "s2")
        XCTAssertEqual(historyCalls.last?.playPositionMillis, 1)  // hardcoded 1 for skip
    }

    func testPromoSongDoesNotFireUpdateHistory() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "0", artist: "Commercial-free", title: "Listener-supported",
                             album: nil, duration: 5_000, event: "ev1", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "P", sliceNum: nil),
            ]
        )
        await api.setBlockResponses([block])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 0)  // promo skipped
    }

    func testSkipPastLastSongFiresUpdateHistoryForNewBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(songs: [("s1", 60_000)])
        let secondBlock = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "s2", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "ev2", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "1"),
            ]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.skipForward()  // past last song → fetches new block
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)  // bootstrap + new block first song
        XCTAssertEqual(historyCalls.last?.songId, "s2")
        XCTAssertEqual(historyCalls.last?.playPositionMillis, 1)
    }

    func testPrefetchSwapFiresUpdateHistoryForNewBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            endEvent: "100",
            prebuiltSongs: [
                PlayListSong(songId: "s1", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "100", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "5"),
            ]
        )
        let prefetchBlock = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                             duration: 60_000, event: "101", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "6"),
            ]
        )
        await api.setBlockResponses([firstBlock, prefetchBlock])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Trigger prefetch: last song with <10s remaining (totalDuration=60s, position=51s)
        await engine.fire(.positionUpdate(seconds: 51.0))
        try await Task.sleep(nanoseconds: 100_000_000)  // let prefetch complete
        // Simulate EOF to trigger swap
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)  // bootstrap + swap
        XCTAssertEqual(historyCalls.last?.songId, "s2")
    }

    func testFavoritesChannelSendsNullSliceNum() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(
            channel: "99",
            prebuiltSongs: [
                PlayListSong(songId: "42839", artist: "A", title: "T", album: "Al",
                             duration: 300_000, event: "1777746918882", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: nil),
            ]
        )
        await api.setBlockResponses([block])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 99)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 1)
        XCTAssertNil(historyCalls.first?.sliceNum)  // nil in args; LiveRpApiClient writes "null" to URL
        XCTAssertEqual(historyCalls.first?.event, "1777746918882")
        XCTAssertEqual(historyCalls.first?.chan, 99)
    }
}

extension LivePlaybackCoordinatorTests {
    func testPauseResumeFiresUpdatePauseAndUpdateHistory() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(
            prebuiltSongs: [
                PlayListSong(songId: "55464", artist: "A", title: "T", album: "Al",
                             duration: 120_000, event: "2869397", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "6"),
            ]
        )
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.fire(.positionUpdate(seconds: 10.0))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await coord.pause()
        try await Task.sleep(nanoseconds: 50_000_000)
        let pauseCalls = await api.updatePauseCalls
        XCTAssertEqual(pauseCalls.count, 1)
        XCTAssertEqual(pauseCalls.first?.songId, "55464")
        XCTAssertEqual(pauseCalls.first?.playPositionMillis, 10_000)
        XCTAssertEqual(pauseCalls.first?.chan, 0)
        try await coord.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        let resumeHistory = historyCalls.last(where: { $0.pauseFlag })
        XCTAssertNotNil(resumeHistory)
        XCTAssertEqual(resumeHistory?.songId, "55464")
        XCTAssertEqual(resumeHistory?.pauseFlag, true)
    }

    func testPausePositionMillisIsCorrect() async throws {
        final class MutableClock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_000)
        }
        let clockState = MutableClock()
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 120_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 0 }, clock: { clockState.date }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        await engine.fire(.positionUpdate(seconds: 10.0))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await coord.pause()                                    // position captured: 10_000 ms
        clockState.date = Date(timeIntervalSince1970: 1_005)       // advance clock 5s (would have been duration)
        try await coord.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        let pauseCalls = await api.updatePauseCalls
        // pause sends play position in ms (not pause duration); 10s = 10_000 ms, not 5_000
        XCTAssertEqual(pauseCalls.first?.playPositionMillis, 10_000)
    }

    func testResumeWithoutPriorPauseDoesNotFireTelemetry() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try? await coord.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        let pauseCalls = await api.updatePauseCalls
        XCTAssertEqual(pauseCalls.count, 0)
    }
}

extension LivePlaybackCoordinatorTests {
    func testFileEndedWithErrorCodeMinusFourteenYieldsDeviceUnavailableError() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let errorsStream = await coordinator.errors
        let collector = Task { () -> String? in
            for await msg in errorsStream { return msg }
            return nil
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let np = await coordinator.nowPlaying
        XCTAssertNil(np, "nowPlaying must be nil after device error")

        await coordinator.shutdown()
        let errorMessage = await collector.value
        XCTAssertEqual(errorMessage, "Audio device unavailable. Hog mode + Force Max Volume turned off so the next device you pick can't surprise you. Check System Settings → Sound → Output.")
    }

    func testFileEndedWithErrorCodeMinusFourteenClearsBlockState() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        try await coordinator.play(channelId: 0)
        let npBefore = await coordinator.nowPlaying
        XCTAssertNotNil(npBefore)

        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let npAfter = await coordinator.nowPlaying
        XCTAssertNil(npAfter)

        // currentChannelId is private; skipForward throws .notPlaying when both
        // currentBlock and currentChannelId are nil — confirming the full reset.
        do {
            try await coordinator.skipForward()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }

    func testFileEndedWithArbitraryErrorCodeYieldsGenericError() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let errorsStream = await coordinator.errors
        let collector = Task { () -> String? in
            for await msg in errorsStream { return msg }
            return nil
        }

        try await coordinator.play(channelId: 0)
        let npBefore = await coordinator.nowPlaying
        XCTAssertNotNil(npBefore)

        await engine.fire(.fileEnded(reason: .error(code: -99)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let npAfter = await coordinator.nowPlaying
        XCTAssertNil(npAfter)

        await coordinator.shutdown()
        let errorMessage = await collector.value
        XCTAssertEqual(errorMessage, "Playback stopped unexpectedly (error -99).")
    }

    func testFileEndedWithUnplayableCodeAdvancesToNextBlock() async throws {
        let api = MockRpApiClient()
        let badPromo = makeBlock(
            url: "https://example.com/bad-promo.m4a",
            endEvent: "999",
            prebuiltSongs: [makeSong(id: "promo", duration: 5_000, elapsed: 0, event: "999")]
        )
        let recovery = makeBlock(
            url: "https://example.com/recovery.flac",
            endEvent: "1000",
            prebuiltSongs: [makeSong(id: "good", duration: 60_000, elapsed: 0, event: "1000")]
        )
        await api.setBlockResponses([badPromo, recovery])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .error(code: -16)))
        try await Task.sleep(nanoseconds: 150_000_000)

        let np = await coordinator.nowPlaying
        XCTAssertEqual(np?.song.songId, "good", "must advance to recovery block, not wipe state")
        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.play(url: URL(string: "https://example.com/recovery.flac")!, startSeconds: nil)))

        let calls = await api.calls
        // Two play calls: bootstrap (event=0,start) + advance (event=999,play,P).
        XCTAssertEqual(calls.count, 2)
        guard case let .play(_, _, event, action, audioType, _, _) = calls[1] else {
            return XCTFail("expected second .play call")
        }
        XCTAssertEqual(event, 999)
        XCTAssertEqual(action, .play)
        XCTAssertEqual(audioType, "M") // makeSong defaults type=nil → fallback "M"
    }

    func testFileEndedWithUnplayableCodeSurfacesErrorAfterRepeatedFailures() async throws {
        let api = MockRpApiClient()
        let badBlock = makeBlock(
            endEvent: "100",
            prebuiltSongs: [makeSong(id: "bad", duration: 5_000, elapsed: 0, event: "100")]
        )
        // Bootstrap + 3 successful retry fetches; the 4th -16 trips the cap.
        await api.setBlockResponses([badBlock, badBlock, badBlock, badBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let errorsStream = await coordinator.errors
        let collector = Task { () -> String? in
            for await msg in errorsStream { return msg }
            return nil
        }

        try await coordinator.play(channelId: 0)
        // Each -16 triggers an advance; no fileLoaded between them, so the
        // failure counter never resets.
        for _ in 0..<4 {
            await engine.fire(.fileEnded(reason: .error(code: -16)))
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        let np = await coordinator.nowPlaying
        XCTAssertNil(np, "state must be wiped after exceeding retry cap")
        await coordinator.shutdown()
        let message = await collector.value
        XCTAssertEqual(message, "Playback stopped unexpectedly (error -16).")
    }

    func testFileLoadedResetsUnplayableFailureCounter() async throws {
        let api = MockRpApiClient()
        let bad = makeBlock(
            endEvent: "1",
            prebuiltSongs: [makeSong(id: "bad", duration: 5_000, elapsed: 0, event: "1")]
        )
        let mid = makeBlock(
            url: "https://example.com/mid.flac",
            endEvent: "2",
            prebuiltSongs: [makeSong(id: "mid", duration: 60_000, elapsed: 0, event: "2")]
        )
        let recovery = makeBlock(
            url: "https://example.com/recovery.flac",
            endEvent: "3",
            prebuiltSongs: [makeSong(id: "recovery", duration: 60_000, elapsed: 0, event: "3")]
        )
        // Bootstrap + 3 advances to burn the budget → land on mid.
        // After fileLoaded resets the counter, 3 more advances → land on recovery.
        await api.setBlockResponses([bad, bad, bad, mid, bad, bad, recovery])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        for _ in 0..<3 {
            await engine.fire(.fileEnded(reason: .error(code: -16)))
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let midNp = await coordinator.nowPlaying
        XCTAssertEqual(midNp?.song.songId, "mid")

        await engine.fire(.fileLoaded)
        try await Task.sleep(nanoseconds: 50_000_000)

        for _ in 0..<3 {
            await engine.fire(.fileEnded(reason: .error(code: -16)))
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let np = await coordinator.nowPlaying
        XCTAssertEqual(np?.song.songId, "recovery", "counter reset by fileLoaded must permit further recovery")
    }

    func testDeviceErrorCodeStillSurfacesWithoutAdvance() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 1, "device errors must not trigger advance")
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }

    func testFileEndedWithEofDoesNotYieldError() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let errorsStream = await coordinator.errors
        let collector = Task { () -> Bool in
            for await _ in errorsStream { return true }
            return false
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 100_000_000)

        await coordinator.shutdown()
        let errorReceived = await collector.value
        XCTAssertFalse(errorReceived, "eof must not yield an error")
    }

    func testFileEndedWithErrorCancelsPrefetchTask() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            endEvent: "500",
            prebuiltSongs: [makeSong(id: "1", duration: 11_000, elapsed: 0, event: "500")]
        )
        let secondBlock = makeBlock(songs: [("s2", 60_000)])
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        try await coordinator.play(channelId: 0)
        // Put a slow delay on the api so the prefetch remains in-flight.
        await api.setPlayDelay(nanos: 2_000_000_000)
        await engine.fire(.positionUpdate(seconds: 2.0))
        try await Task.sleep(nanoseconds: 50_000_000)

        await api.setPlayDelay(nanos: 0)
        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancellations = await api.playCancellations
        XCTAssertEqual(cancellations, 1, "in-flight prefetch must be cancelled on playback error")
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }
}

private final class LockedArray<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

extension LivePlaybackCoordinatorTests {
    fileprivate func makeSongWithCover(id: String, duration: Int, elapsed: Int, cover: String?) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: cover, elapsed: elapsed, slideshow: nil,
            type: nil, sliceNum: nil
        )
    }

    func testPlayPrefetchesNextSongCover() async throws {
        let api = MockRpApiClient()
        let songs = [
            makeSongWithCover(id: "s1", duration: 60_000, elapsed: 0,      cover: "covers/l/1.jpg"),
            makeSongWithCover(id: "s2", duration: 60_000, elapsed: 60_000, cover: "covers/l/2.jpg"),
        ]
        let block = makeBlock(prebuiltSongs: songs)
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let prefetched = LockedArray<String>()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 },
            prefetchArt: { cover in prefetched.append(cover) }
        )

        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(prefetched.values, ["covers/l/2.jpg"])
    }

    func testSongBoundaryCrossPrefetchesFollowingSongCover() async throws {
        let api = MockRpApiClient()
        let songs = [
            makeSongWithCover(id: "s1", duration: 60_000,  elapsed: 0,       cover: "covers/l/1.jpg"),
            makeSongWithCover(id: "s2", duration: 120_000, elapsed: 60_000,  cover: "covers/l/2.jpg"),
            makeSongWithCover(id: "s3", duration: 90_000,  elapsed: 180_000, cover: "covers/l/3.jpg"),
        ]
        let block = makeBlock(prebuiltSongs: songs)
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let prefetched = LockedArray<String>()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 },
            prefetchArt: { cover in prefetched.append(cover) }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 75.0))
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(prefetched.values, ["covers/l/2.jpg", "covers/l/3.jpg"])
    }

    func testPlayChannelBootstrapsWithEventZeroAndActionStart() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)

        let calls = await api.calls
        XCTAssertEqual(calls.count, 1)
        guard case let .play(channel, bitrate, event, action, audioType, episodeId, sliceNum) = calls[0] else {
            return XCTFail("expected .play call, got \(calls[0])")
        }
        XCTAssertEqual(channel, 0)
        XCTAssertEqual(bitrate, 4)
        XCTAssertEqual(event, 0)
        XCTAssertEqual(action, .start)
        XCTAssertNil(audioType)
        XCTAssertNil(episodeId)
        XCTAssertNil(sliceNum)
    }

    func testStateStreamEmitsPlayingPausedStoppedTransitions() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let observed = ObservedStates()
        let stream = await coordinator.stateUpdates
        let subscription = Task {
            for await state in stream {
                await observed.append(state)
            }
        }

        try await coordinator.play(channelId: 0)
        try await coordinator.pause()
        try await coordinator.resume()
        try await coordinator.stop()

        // Let the AsyncStream drain.
        try await Task.sleep(nanoseconds: 100_000_000)
        subscription.cancel()

        let states = await observed.values
        XCTAssertEqual(states, [.stopped, .playing, .paused, .playing, .stopped])
    }

    func testStateStreamSeedsCurrentStateOnSubscribe() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)

        let stream = await coordinator.stateUpdates
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, .playing)
    }

    func testDeviceUnavailableHandlerInvokedOnCodeMinusFourteen() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()

        let calls = HandlerCalls()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 4 },
            onDeviceUnavailable: { await calls.increment() }
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.fileEnded(reason: .error(code: -14)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testDeviceUnavailableHandlerNotInvokedOnOtherErrors() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()

        let calls = HandlerCalls()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 4 },
            onDeviceUnavailable: { await calls.increment() }
        )
        try await coordinator.play(channelId: 0)
        // -100 is not in the unplayable-block set and not -14; routes through handlePlaybackError.
        await engine.fire(.fileEnded(reason: .error(code: -100)))
        try await Task.sleep(nanoseconds: 100_000_000)

        let count = await calls.count
        XCTAssertEqual(count, 0)
    }
}

private actor ObservedStates {
    var values: [PlaybackState] = []
    func append(_ s: PlaybackState) { values.append(s) }
}

private actor HandlerCalls {
    var count = 0
    func increment() { count += 1 }
}
