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

        let errorsStream = await coord.errors
        let collector = Task<[String], Never> {
            var msgs: [String] = []
            for await m in errorsStream { msgs.append(m) }
            return msgs
        }

        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()
        let emitted = await collector.value

        let engineCalls = await engine.recordedCalls()
        XCTAssertFalse(engineCalls.contains { if case .play = $0 { return true } else { return false } },
                       "nothing should play when all songs are skip-bound. calls=\(engineCalls)")
        XCTAssertTrue(emitted.contains("No upcoming songs match your rating filter — raise the threshold in Settings."),
                      "expected no-matches message. emitted=\(emitted)")
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
