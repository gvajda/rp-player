import XCTest
@testable import RPPlayer

final class PlaybackCoordinatorSkipTests: XCTestCase {
    private func silentLogger() -> AppLogger { AppLogger(category: "PlaybackCoordinatorSkipTests") }

    /// Skip-bound songs are filtered out of the queue: never played, never queueNext'd, never downloaded.
    func testSkipBoundSongsExcludedFromQueue() async throws {
        let api = MockRpApiClient()
        let good1 = makeGaplessSong(songId: "good1", eventId: 100, gaplessUrl: "https://example.com/good1.flac", userRating: 8)
        let bad   = makeGaplessSong(songId: "bad",   eventId: 101, gaplessUrl: "https://example.com/bad.flac",   userRating: 2)
        let good2 = makeGaplessSong(songId: "good2", eventId: 102, gaplessUrl: "https://example.com/good2.flac", userRating: 0)
        let response = makeGaplessResponse(songs: [good1, bad, good2])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        // Pre-seed cache so tryQueueNextOrDefer gets a hit and calls queueNext inline.
        await cache.markDownloaded([good1, good2])
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))
        try await coord.play(channelId: 0)

        let engineCalls = await engine.recordedCalls()
        // First playable song is good1; the "bad" rating-2 song is never queued.
        XCTAssertEqual(engineCalls.first, .play(url: URL(string: "https://example.com/good1.flac")!, startSeconds: nil))
        XCTAssertFalse(engineCalls.contains { call in
            if case .play(let url, _) = call { return url.absoluteString.contains("bad") }
            if case .queueNext(let url, _) = call { return url.absoluteString.contains("bad") }
            return false
        }, "skip-bound song must never be played or queued. calls=\(engineCalls)")
        // queueNext goes to good2 (the next playable), skipping bad.
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/good2.flac")!, startSeconds: nil)))
    }

    /// A block where every song is skip-bound stops playback and emits the no-matches message.
    func testAllSkippedStopsAndMessages() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "b1", eventId: 100, gaplessUrl: "https://example.com/b1.flac", userRating: 1),
            makeGaplessSong(songId: "b2", eventId: 101, gaplessUrl: "https://example.com/b2.flac", userRating: 2),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))

        final class MessageBag: @unchecked Sendable {
            private var lock = NSLock()
            private var msgs: [String] = []
            func append(_ m: String) { lock.withLock { msgs.append(m) } }
            func snapshot() -> [String] { lock.withLock { msgs } }
        }
        let bag = MessageBag()
        let errorsStream = await coord.errors
        let collector = Task<Void, Never> {
            for await m in errorsStream { bag.append(m) }
        }

        try await coord.play(channelId: 0)
        let noMatchesMessage = "No upcoming songs match your rating filter — raise the threshold in Settings."
        try await waitUntil({ bag.snapshot().contains(noMatchesMessage) }, timeout: 2)
        collector.cancel()

        let engineCalls = await engine.recordedCalls()
        XCTAssertFalse(engineCalls.contains { if case .play = $0 { return true } else { return false } },
                       "nothing should play when all songs are skip-bound. calls=\(engineCalls)")
        XCTAssertTrue(bag.snapshot().contains(noMatchesMessage),
                      "expected no-matches message. emitted=\(bag.snapshot())")
    }

    /// A song that becomes skip-bound after a mid-playback policy change is auto-skipped when it becomes head.
    func testHeadBecomingSkipBoundIsAutoSkipped() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac", userRating: 8),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac", userRating: 2),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac", userRating: 9),
            makeGaplessSong(songId: "s4", eventId: 103, gaplessUrl: "https://example.com/s4.flac", userRating: 9),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        await cache.markDownloaded(response.songs)
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        // Start with policy disabled so s2 (rating 2) is queued normally.
        try await coord.play(channelId: 0)
        await engine.fire(.fileStarted)  // initial: head = s1

        // Now enable the policy mid-playback. s2 is already in the queue (downloaded/queued).
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))

        // mpv advances to s2 → Layer B sees a skip-bound head and skips forward to s3.
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/s2.flac"))
        await engine.fire(.fileStarted)
        try await waitUntil({ await engine.recordedCalls().contains(.advanceToQueued) }, timeout: 2)

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.advanceToQueued),
                      "Layer B should advance past the skip-bound head. calls=\(engineCalls)")
    }

    /// applyBitrateChange must apply the skip filter to the fresh gapless response.
    func testApplyBitrateChangeFiltersSkipBoundSongs() async throws {
        let api = MockRpApiClient()
        let head = makeGaplessSong(songId: "head", eventId: 100, gaplessUrl: "https://example.com/head.flac", userRating: 8)
        let low  = makeGaplessSong(songId: "low",  eventId: 101, gaplessUrl: "https://example.com/low.flac",  userRating: 2)
        let good = makeGaplessSong(songId: "good", eventId: 102, gaplessUrl: "https://example.com/good.flac", userRating: 9)
        let initial = makeGaplessResponse(songs: [head, low, good])
        let refetched = makeGaplessResponse(songs: [head, low, good])
        await api.setGaplessResponses([initial, refetched, refetched])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        await cache.markDownloaded([head, low, good])
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))
        try await coord.play(channelId: 0)
        await engine.fire(.fileStarted)

        await coord.applyBitrateChange()

        let engineCalls = await engine.recordedCalls()
        XCTAssertFalse(engineCalls.contains { call in
            if case .play(let url, _) = call { return url.absoluteString.contains("low") }
            if case .queueNext(let url, _) = call { return url.absoluteString.contains("low") }
            return false
        }, "skip-bound song must not reach engine after applyBitrateChange. calls=\(engineCalls)")
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/good.flac")!, startSeconds: nil)),
                      "queueNext must target the good song. calls=\(engineCalls)")
    }

    /// Policy disabled → no filtering; low-rated songs play normally.
    func testDisabledPolicyPlaysLowRated() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "low", eventId: 100, gaplessUrl: "https://example.com/low.flac", userRating: 1),
            makeGaplessSong(songId: "low2", eventId: 101, gaplessUrl: "https://example.com/low2.flac", userRating: 1),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        // No updateSkipPolicy call → defaults to disabled.
        try await coord.play(channelId: 0)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.first, .play(url: URL(string: "https://example.com/low.flac")!, startSeconds: nil))
    }
}
