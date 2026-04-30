import XCTest
@testable import RPPlayer

final class LivePlaybackCoordinatorTests: XCTestCase {
    fileprivate func makeSong(id: String, duration: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    fileprivate func makeBlock(channel: String = "0", url: String = "https://example.com/0-0.flac",
                                cue: Int = 0,
                                expiration: Int = 0,
                                songs: [(String, Int)]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = makeSong(id: pair.0, duration: pair.1)
        }
        return GetBlock(
            url: url, chan: channel, bitrate: nil, cue: cue, expiration: expiration,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil, filename: nil
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls, [.getBlock(channel: 0, bitrate: 4, info: true)])
        XCTAssertEqual(engineCalls, [.play(url: URL(string: "https://example.com/0-0.flac")!)])
    }

    func testPlaySeeksToCueOffsetAfterFileLoad() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(cue: 90_000,
                              songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.fileLoaded)
        try await Task.sleep(nanoseconds: 50_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls, [
            .play(url: URL(string: "https://example.com/0-0.flac")!),
            .seek(seconds: 90.0),
        ])
    }

    func testPlayThrowsWhenBlockHasNoSongs() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }
}

extension LivePlaybackCoordinatorTests {
    func testPositionUpdateEmitsNowPlayingWhenSongBoundaryCrossed() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 280.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coordinator.skipForward()
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls.count, 2)
        XCTAssertEqual(apiCalls.last, .getBlock(channel: 0, bitrate: 0, info: true))
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-2.flac")!))
    }

    func testSkipForwardWithoutCurrentBlockThrows() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "second getBlock call should have been triggered as prefetch")
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-B.flac")!))
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
        // getBlock doesn't observe Task.cancel()). Its result must be discarded
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coordinator.changeChannel(to: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/chan1.flac")!))
        let chan1PlayIndex = engineCalls.lastIndex(of: .play(url: URL(string: "https://example.com/chan1.flac")!))
        XCTAssertEqual(chan1PlayIndex, engineCalls.count - 1, "chan1 play must be the final engine call")
    }
}

extension LivePlaybackCoordinatorTests {
    func testPauseBeforePlayThrowsNotPlaying() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
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
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        // Trigger prefetch (in-flight call to api.getBlock). Sleep gives the
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
            engineCalls.contains(.play(url: URL(string: "https://example.com/A-prefetch.flac")!)),
            "prefetched block from before stop() must not resurface after restart. calls=\(engineCalls)"
        )
    }
}

extension LivePlaybackCoordinatorTests {
    func testCoordinatorFallsBackToSharedModeOnAudioInitFailure() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.error(message: "Failed to initialize audio driver 'coreaudio_exclusive'"))
        try await Task.sleep(nanoseconds: 100_000_000)

        let calls = await engine.recordedCalls()
        XCTAssertTrue(
            calls.contains(.setHogMode(enabled: false)),
            "expected setHogMode(false) on hog acquisition failure. calls=\(calls)"
        )
        let playCount = calls.filter {
            if case .play(url: URL(string: "https://example.com/0-0.flac")!) = $0 { return true }
            return false
        }.count
        XCTAssertEqual(playCount, 2, "expected initial play + retry. calls=\(calls)")
    }

    func testCoordinatorFallbackOnlyTriggersOnce() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.error(message: "Failed to initialize audio driver 'coreaudio_exclusive'"))
        try await Task.sleep(nanoseconds: 80_000_000)
        await engine.fire(.error(message: "Failed to initialize audio driver 'coreaudio_exclusive'"))
        try await Task.sleep(nanoseconds: 80_000_000)

        let calls = await engine.recordedCalls()
        let setHogModeFalseCount = calls.filter { $0 == .setHogMode(enabled: false) }.count
        XCTAssertEqual(setHogModeFalseCount, 1, "fallback must not loop. calls=\(calls)")
    }

    func testUnrelatedEngineErrorDoesNotTriggerFallback() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.error(message: "some unrelated mpv error"))
        try await Task.sleep(nanoseconds: 80_000_000)

        let calls = await engine.recordedCalls()
        XCTAssertFalse(
            calls.contains(.setHogMode(enabled: false)),
            "non-audio-init errors must not trigger hog fallback. calls=\(calls)"
        )
    }

    func testCoordinatorInvokesFallbackCallbackOnHogAcquisitionFailure() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let counter = CallCounter()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4,
            onHogModeFallback: { await counter.increment() }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.error(message: "Failed to initialize audio driver 'coreaudio_exclusive'"))
        try await Task.sleep(nanoseconds: 100_000_000)

        let value = await counter.value
        XCTAssertEqual(value, 1, "expected onHogModeFallback to fire exactly once")
    }

    func testCoordinatorDoesNotFireFallbackCallbackForUnrelatedErrors() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 60_000), ("s3", 60_000), ("s4", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let counter = CallCounter()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4,
            onHogModeFallback: { await counter.increment() }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.error(message: "some unrelated mpv error"))
        try await Task.sleep(nanoseconds: 80_000_000)

        let value = await counter.value
        XCTAssertEqual(value, 0, "fallback callback must not fire for unrelated errors")
    }

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
        let coordinator = LivePlaybackCoordinator(api: api, engine: engine, logger: silentLogger(), bitrate: 4)
        try await coordinator.play(channelId: 0)
        try await coordinator.pause()
        try await coordinator.resume()

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(
            engineCalls.contains(.play(url: URL(string: "https://example.com/FRESH.flac")!)),
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
        let coordinator = LivePlaybackCoordinator(api: api, engine: engine, logger: silentLogger(), bitrate: 4)
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

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
