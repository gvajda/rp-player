import XCTest
@testable import RPPlayer

final class LibmpvPlayerEngineTests: XCTestCase {
    func testInitAndShutdownDoesNotCrash() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()
    }

    func testShutdownIsIdempotent() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()
        await engine.shutdown()
    }

    func testCommandsAfterShutdownThrowAlreadyShutdown() async throws {
        let engine = try LibmpvPlayerEngine()
        await engine.shutdown()

        let url = URL(string: "https://example.com/audio.mp3")!
        let invocations: [(String, () async throws -> Void)] = [
            ("play",            { try await engine.play(url: url) }),
            ("pause",           { try await engine.pause() }),
            ("resume",          { try await engine.resume() }),
            ("stop",            { try await engine.stop() }),
            ("seek",            { try await engine.seek(to: 1.0) }),
            ("setHogMode",      { try await engine.setHogMode(true) }),
            ("setOutputDevice", { try await engine.setOutputDevice(uid: nil) }),
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

extension LibmpvPlayerEngineTests {
    /// Verifies the pump task converts MPV_EVENT_SHUTDOWN into PlayerEvent.shutdown
    /// and finishes all subscriber streams.
    func testShutdownEventIsEmittedAndStreamFinishes() async throws {
        let engine = try LibmpvPlayerEngine()
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
        let engine = try LibmpvPlayerEngine()
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

extension LibmpvPlayerEngineTests {
    func testSetHogModeEmitsHogModeChanged() async throws {
        let engine = try LibmpvPlayerEngine()
        defer { Task { await engine.shutdown() } }
        let stream = await engine.events

        let collector = Task { () -> PlayerEvent? in
            for await event in stream {
                if case .hogModeChanged = event { return event }
            }
            return nil
        }

        try await engine.setHogMode(true)
        let captured = await collector.value
        XCTAssertEqual(captured, .hogModeChanged(enabled: true))
    }

    func testSetOutputDeviceWithUidEmitsOutputDeviceChanged() async throws {
        let engine = try LibmpvPlayerEngine()
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
        let engine = try LibmpvPlayerEngine()
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
}
