import XCTest
@testable import RPPlayer

// Controllable sleep stub — lets tests simulate the 10s watchdog timeout deterministically.
// withTaskCancellationHandler is required so a cancelled Task (e.g. when withTaskGroup's
// position-update child wins) resumes its parked continuation; without it, CheckedContinuation's
// resume-exactly-once invariant is violated and the runtime aborts the process.
final class ControllableSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var manualReleaseAll = false

    var sleep: @Sendable (UInt64) async -> Void {
        { _ in
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self.manualReleaseAll || Task.isCancelled {
                        self.lock.unlock()
                        cont.resume()
                        return
                    }
                    self.pendingContinuations[id] = cont
                    self.lock.unlock()
                }
            } onCancel: {
                self.lock.lock()
                let cont = self.pendingContinuations.removeValue(forKey: id)
                self.lock.unlock()
                cont?.resume()
            }
        }
    }

    /// Release all pending sleeps and make future sleeps return immediately.
    func releaseAll() {
        lock.lock()
        let pending = pendingContinuations
        pendingContinuations = [:]
        manualReleaseAll = true
        lock.unlock()
        for cont in pending.values { cont.resume() }
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingContinuations.count
    }
}

@discardableResult
func pollUntil(timeout: TimeInterval = 2.0, _ predicate: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

final class LivePlaybackCoordinatorStallWatchdogTests: XCTestCase {

    // MARK: - Helpers

    private func makeSong(id: String, duration: Int, elapsed: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: elapsed, slideshow: nil,
            type: nil, sliceNum: nil
        )
    }

    private func makeBlock(url: String, expiration: Int, songs: [(String, Int)]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        var elapsed = 0
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = makeSong(id: pair.0, duration: pair.1, elapsed: elapsed)
            elapsed += pair.1
        }
        return GetBlock(
            url: url, chan: "0", bitrate: nil, cue: 0, expiration: expiration,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil
        )
    }

    private func silentLogger() -> AppLogger {
        AppLogger(category: "StallWatchdogTests")
    }

    // MutableClock lets tests advance time without real delays.
    final class MutableClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func makeCoord(
        api: MockRpApiClient,
        engine: MockPlayerEngine,
        clock: MutableClock,
        sleeper: ControllableSleep
    ) -> LivePlaybackCoordinator {
        LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(),
            bitrateProvider: { 4 }, clock: { clock.date }, sleep: sleeper.sleep
        )
    }

    // MARK: - Tests

    func testLongIdleResumeWatchdogClearsOnFirstPositionUpdate() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        // 2-song blocks: coordinator only prefetches when on the last song, avoiding an extra API call.
        let firstBlock = makeBlock(url: "https://example.com/before.flac", expiration: 99_999_999_999, songs: [("s1", 60_000), ("s1b", 60_000)])
        let refetched = makeBlock(url: "https://example.com/after.flac", expiration: 99_999_999_999, songs: [("s2", 60_000), ("s2b", 60_000)])
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        // Wait for watchdog to park on sleep
        let armed = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed, "watchdog should arm after long-idle resume")

        // A position update different from the snapshot (0.0) clears the watchdog
        await engine.fire(.positionUpdate(seconds: 5.0))
        // Poll until the watchdog Task itself completes: the stallWatchdog finishes
        // once the position-update side wins the withTaskGroup race and returns true.
        // We observe this indirectly — the watchdog would only issue engine.stop if it
        // timed out, so polling recordedCalls until stable is the deterministic signal.
        // 200ms matches the convention used in LivePlaybackCoordinatorTests.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let calls = await engine.recordedCalls()
        let stopCount = calls.filter { if case .stop = $0 { return true } else { return false } }.count
        let playCount = calls.filter { if case .play = $0 { return true } else { return false } }.count
        XCTAssertEqual(stopCount, 0, "no engine.stop expected — watchdog cleared by positionUpdate")
        XCTAssertEqual(playCount, 2, "expected initial play + long-idle refetch only, no retry")
    }

    func testLongIdleResumeWatchdogRetriesAfterTimeout() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        let firstBlock = makeBlock(url: "https://example.com/before.flac", expiration: 99_999_999_999, songs: [("s1", 60_000), ("s1b", 60_000)])
        let refetched = makeBlock(url: "https://example.com/after.flac", expiration: 99_999_999_999, songs: [("s2", 60_000), ("s2b", 60_000)])
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let armed2 = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed2, "watchdog should arm after long-idle resume")

        // Simulate 10s timeout — watchdog will stop + replay
        sleeper.releaseAll()

        // Wait for retry: engine.stop + engine.play should appear (manualReleaseAll=true so second sleep also fires)
        // After retry, watchdog calls waitForFirstPositionUpdate again (second attempt), which also times out immediately.
        // That triggers surfaceStallError → coord errors stream. We just wait for the retry play calls here.
        let sawStop = await pollUntil {
            let calls = await engine.recordedCalls()
            return calls.contains { if case .stop = $0 { return true } else { return false } }
        }
        XCTAssertTrue(sawStop, "expected engine.stop from watchdog retry")

        let sawThreePlays = await pollUntil {
            let calls = await engine.recordedCalls()
            let playCount = calls.filter { if case .play = $0 { return true } else { return false } }.count
            return playCount >= 3
        }
        XCTAssertTrue(sawThreePlays, "expected initial play + refetch + retry play")

        let calls = await engine.recordedCalls()
        let stopCount = calls.filter { if case .stop = $0 { return true } else { return false } }.count
        let playCount = calls.filter { if case .play = $0 { return true } else { return false } }.count
        XCTAssertGreaterThanOrEqual(stopCount, 1, "expected at least 1 engine.stop from watchdog retry")
        XCTAssertEqual(playCount, 3, "expected initial play + long-idle refetch + watchdog retry")
    }

    func testLongIdleResumeWatchdogSurfacesErrorAfterDoubleTimeout() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        let firstBlock = makeBlock(url: "https://example.com/before.flac", expiration: 99_999_999_999, songs: [("s1", 60_000), ("s1b", 60_000)])
        let refetched = makeBlock(url: "https://example.com/after.flac", expiration: 99_999_999_999, songs: [("s2", 60_000), ("s2b", 60_000)])
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        let errors = await coord.errors
        let errorTask = Task<String?, Never> {
            var iterator = errors.makeAsyncIterator()
            return await iterator.next()
        }

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let armed3 = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed3, "watchdog should arm after long-idle resume")

        // Both timeouts fire immediately (manualReleaseAll=true after releaseAll)
        sleeper.releaseAll()

        let errorMessage = await errorTask.value
        XCTAssertEqual(errorMessage, "Playback stalled. Try Pause/Play to recover.")

        let nowPlaying = await coord.nowPlaying
        XCTAssertNil(nowPlaying, "coordinator state should be cleared after stall error")
    }

    func testStallWatchdogCancelledByStop() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        let firstBlock = makeBlock(url: "https://example.com/before.flac", expiration: 99_999_999_999, songs: [("s1", 60_000), ("s1b", 60_000)])
        let refetched = makeBlock(url: "https://example.com/after.flac", expiration: 99_999_999_999, songs: [("s2", 60_000), ("s2b", 60_000)])
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let armed4 = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed4, "watchdog should arm after long-idle resume")

        let callsBeforeStop = await engine.recordedCalls()
        try await coord.stop()

        // Releasing the sleep after stop should not trigger a retry
        sleeper.releaseAll()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let callsAfterStop = await engine.recordedCalls()
        let newPlaysAfterStop = callsAfterStop.dropFirst(callsBeforeStop.count)
            .filter { if case .play = $0 { return true } else { return false } }.count
        XCTAssertEqual(newPlaysAfterStop, 0, "no engine.play after stop — watchdog must be cancelled")
    }

    func testStallWatchdogCancelledByPause() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        let firstBlock = makeBlock(url: "https://example.com/before.flac", expiration: 99_999_999_999, songs: [("s1", 60_000), ("s1b", 60_000)])
        let refetched = makeBlock(url: "https://example.com/after.flac", expiration: 99_999_999_999, songs: [("s2", 60_000), ("s2b", 60_000)])
        await api.setBlockResponses([firstBlock, refetched])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 60 * 60)
        try await coord.resume()

        let armed5 = await pollUntil { sleeper.pendingCount > 0 }
        XCTAssertTrue(armed5, "watchdog should arm after long-idle resume")

        let callsBeforePause = await engine.recordedCalls()
        try await coord.pause()

        sleeper.releaseAll()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let callsAfterPause = await engine.recordedCalls()
        let newPlaysAfterPause = callsAfterPause.dropFirst(callsBeforePause.count)
            .filter { if case .play = $0 { return true } else { return false } }.count
        XCTAssertEqual(newPlaysAfterPause, 0, "no engine.play after pause — watchdog must be cancelled")
    }

    func testStallWatchdogNotArmedOnFreshBlockResume() async throws {
        let clock = MutableClock()
        let api = MockRpApiClient()
        let block = makeBlock(url: "https://example.com/block.flac", expiration: 99_999_999_999, songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let sleeper = ControllableSleep()
        let coord = makeCoord(api: api, engine: engine, clock: clock, sleeper: sleeper)

        try await coord.play(channelId: 0)
        try await coord.pause()
        clock.date = Date(timeIntervalSince1970: 1_000 + 30 * 60)  // 30 min — below 59 min threshold
        try await coord.resume()

        XCTAssertEqual(sleeper.pendingCount, 0, "watchdog must not arm on fresh-block (short-idle) resume")
    }
}
