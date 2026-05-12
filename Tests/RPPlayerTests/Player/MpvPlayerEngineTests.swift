import XCTest
@testable import RPPlayer

final class MpvPlayerEngineTests: XCTestCase {
    func testInitAndShutdownDoesNotCrash() async throws {
        let engine = try MpvPlayerEngine()
        await engine.shutdown()
    }

    func testShutdownIsIdempotent() async throws {
        let engine = try MpvPlayerEngine()
        await engine.shutdown()
        await engine.shutdown()
    }

    func testCommandsAfterShutdownThrowAlreadyShutdown() async throws {
        let engine = try MpvPlayerEngine()
        await engine.shutdown()

        let url = URL(string: "https://example.com/audio.mp3")!
        let invocations: [(String, () async throws -> Void)] = [
            ("play",            { try await engine.play(url: url) }),
            ("pause",           { try await engine.pause() }),
            ("resume",          { try await engine.resume() }),
            ("stop",            { try await engine.stop() }),
            ("seek",            { try await engine.seek(to: 1.0) }),
            ("setOutputDevice", { try await engine.setOutputDevice(uid: nil) }),
            ("queueNext",       { try await engine.queueNext(url: url, startSeconds: nil) }),
            ("advanceToQueued", { try await engine.advanceToQueued() }),
            ("clearPlaylist",   { try await engine.clearPlaylist() }),
        ]
        for (name, call) in invocations {
            do {
                try await call()
                XCTFail("expected alreadyShutdown for \(name)")
            } catch let error as PlayerEngineError {
                XCTAssertEqual(error, .alreadyShutdown, "command \(name) threw unexpected error")
            }
        }
    }
}

extension MpvPlayerEngineTests {
    /// Verifies the pump task converts MPV_EVENT_SHUTDOWN into PlayerEvent.shutdown
    /// and finishes all subscriber streams.
    func testShutdownEventIsEmittedAndStreamFinishes() async throws {
        let engine = try MpvPlayerEngine()
        let stream = await engine.events
        let collector = Task { () -> [PlayerEvent] in
            var events: [PlayerEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        // Give the pump a moment to start.
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.shutdown()
        let collected = await collector.value
        XCTAssertEqual(collected.last, .shutdown)
    }

    /// Smoke: play a stable RP audio stream and verify positionUpdate events arrive.
    /// Exits early after the first 3 positionUpdate events to keep the test fast.
    /// NOTE: this test depends on `play(url:)` being implemented (Task 6). It will
    /// FAIL after Task 5 lands and PASS once Task 6 lands.
    func testPositionUpdatesArriveDuringPlayback() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }
        let stream = await engine.events

        let positionTask = Task { () -> Int in
            var positionEventCount = 0
            for await event in stream {
                if case .positionUpdate = event {
                    positionEventCount += 1
                    if positionEventCount >= 3 { return positionEventCount }
                }
            }
            return positionEventCount
        }

        try await engine.play(url: URL(string: "https://stream.radioparadise.com/mp3-320")!)

        let outcome = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { await positionTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000) // 8 s
                positionTask.cancel()
                return -1
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        XCTAssertGreaterThanOrEqual(outcome, 3, "expected at least 3 position updates within 8 seconds")
    }
}

extension MpvPlayerEngineTests {
    func testSetOutputDeviceWithUidEmitsOutputDeviceChanged() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }
        let stream = await engine.events

        let collector = Task { () -> PlayerEvent? in
            for await event in stream {
                if case .outputDeviceChanged = event { return event }
            }
            return nil
        }

        try await engine.setOutputDevice(uid: "BuiltInSpeakerDevice")
        let captured = await collector.value
        XCTAssertEqual(captured, .outputDeviceChanged(uid: "BuiltInSpeakerDevice"))
    }

    func testSetOutputDeviceWithNilEmitsClearedEvent() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }
        let stream = await engine.events

        let collector = Task { () -> PlayerEvent? in
            for await event in stream {
                if case .outputDeviceChanged = event { return event }
            }
            return nil
        }

        try await engine.setOutputDevice(uid: nil)
        let captured = await collector.value
        XCTAssertEqual(captured, .outputDeviceChanged(uid: nil))
    }

    func testSetOutputDeviceUsesCoreAudioAO() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        try await engine.setOutputDevice(uid: "TestDeviceUID")

        let device = await engine.currentAudioDeviceForTesting()
        XCTAssertEqual(device, "coreaudio/TestDeviceUID")
    }

    func testNilUidSelectsAuto() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        try await engine.setOutputDevice(uid: nil)
        let device = await engine.currentAudioDeviceForTesting()
        XCTAssertEqual(device, "auto")
    }

    func testInitWithInitialDeviceAppliesAudioDeviceBeforeInitialize() async throws {
        let engine = try MpvPlayerEngine(initialDeviceUID: "TestDeviceUID")
        defer { Task { await engine.shutdown() } }

        let device = await engine.currentAudioDeviceForTesting()
        XCTAssertEqual(device, "coreaudio/TestDeviceUID",
                       "init should leave audio-device set to the standard coreaudio AO with the supplied UID")
    }

    func testInitWithoutInitialDeviceLeavesAudioDeviceAsAuto() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        let device = await engine.currentAudioDeviceForTesting()
        XCTAssertEqual(device, "auto", "no initial UID should leave the default 'auto'")
    }

}

extension MpvPlayerEngineTests {
    func testPrefetchPlaylistOptionSetAtInit() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        let value = await engine.prefetchPlaylistOptionForTesting()
        XCTAssertEqual(value, "yes")
    }

    func testGaplessAudioOptionSetAtInit() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        let value = await engine.gaplessAudioOptionForTesting()
        XCTAssertEqual(value, "yes")
    }

    func testDemuxerMaxBytesOptionSetAtInit() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        let value = await engine.demuxerMaxBytesOptionForTesting()
        XCTAssertEqual(value, "33554432")
    }



    func testQueueNextRunsLoadfileAppendPlay() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        try await engine.queueNext(url: URL(string: "https://example.com/a.mp3")!, startSeconds: nil)
        let countAfterFirst = await engine.playlistCountForTesting()
        XCTAssertEqual(countAfterFirst, "1")

        try await engine.queueNext(url: URL(string: "https://example.com/b.mp3")!, startSeconds: nil)
        let countAfterSecond = await engine.playlistCountForTesting()
        XCTAssertEqual(countAfterSecond, "2")
    }

    func testClearPlaylistResetsPlaylistCount() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        try await engine.queueNext(url: URL(string: "https://example.com/a.mp3")!, startSeconds: nil)
        try await engine.queueNext(url: URL(string: "https://example.com/b.mp3")!, startSeconds: nil)
        let preClear = await engine.playlistCountForTesting()
        XCTAssertEqual(preClear, "2")

        try await engine.clearPlaylist()
        // playlist-clear preserves the implicit current entry; sandbox has nothing playing -> count == 1, not 0.
        let postClear = await engine.playlistCountForTesting()
        XCTAssertEqual(postClear, "1")
    }

    func testAdvanceToQueuedAdvancesPlaylistPos() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        try await engine.queueNext(url: URL(string: "https://example.com/a.mp3")!, startSeconds: nil)
        try await engine.queueNext(url: URL(string: "https://example.com/b.mp3")!, startSeconds: nil)
        let initialPos = await engine.playlistPosForTesting()
        try await engine.advanceToQueued()
        let advancedPos = await engine.playlistPosForTesting()
        XCTAssertNotEqual(advancedPos, initialPos, "advanceToQueued should change playlist-pos (initial=\(initialPos ?? "nil"), after=\(advancedPos ?? "nil"))")
    }

    func testMuteImmediatelySetsMuteProperty() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        let initial = await engine.muteForTesting()
        XCTAssertEqual(initial, "no")

        engine.muteImmediately()

        let after = await engine.muteForTesting()
        XCTAssertEqual(after, "yes")
    }

    func testMuteImmediatelyAfterShutdownIsNoop() async throws {
        let engine = try MpvPlayerEngine()
        await engine.shutdown()
        // Must not crash on a freed handle.
        engine.muteImmediately()
    }

    func testSetAudioFilterChainAppliesAfProperty() async throws {
        let engine = try MpvPlayerEngine()
        defer { Task { await engine.shutdown() } }

        // mpv normalizes the `af` property string on readback (e.g.
        // `lavfi=[...]` graph syntax becomes `lavfi=graph=%46%...`). Assert the
        // observable invariants — non-empty after set, empty after clear, and
        // that the equalizer label survives normalization — rather than the
        // exact echo of our input.
        try await engine.setAudioFilterChain("lavfi=[volume=-1.2dB,equalizer=f=1000:t=q:w=0.7:g=2.0]")
        let stored = await engine.currentAudioFilterChainForTesting()
        XCTAssertNotNil(stored)
        XCTAssertFalse(stored?.isEmpty ?? true)
        XCTAssertTrue(stored?.contains("equalizer") ?? false, "expected mpv-stored af to mention equalizer; got \(stored ?? "nil")")

        try await engine.setAudioFilterChain(nil)
        let cleared = await engine.currentAudioFilterChainForTesting()
        XCTAssertEqual(cleared, "")
    }
}
