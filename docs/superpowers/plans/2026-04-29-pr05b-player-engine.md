# PR 5b: PlayerEngine (libmpv Swift actor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap libmpv's C API in a Swift actor (`LibmpvPlayerEngine`) that exposes async commands (`play`, `pause`, `resume`, `stop`, `seek`, `setHogMode`, `setOutputDevice`, `shutdown`) and publishes state changes via `AsyncStream<PlayerEvent>`. This is the playback engine consumed by `PlaybackCoordinator` in PR 6.

**Architecture:** A `PlayerEngine` protocol defines the engine surface so `PlaybackCoordinator` (PR 6) can be tested against a `MockPlayerEngine`. The real implementation, `LibmpvPlayerEngine`, owns an `mpv_handle*` and runs a single detached event-pump task that calls `mpv_wait_event` in a loop, parses each `mpv_event` into a `PlayerEvent`, and yields to subscriber continuations. Shutdown is initiated by the actor (calls `mpv_terminate_destroy`), which causes `mpv_wait_event` to return `MPV_EVENT_SHUTDOWN`; the pump exits cleanly. Bit-perfect mpv options (audio-exclusive, audio-device, audio-pitch-correction=no) are applied at `mpv_initialize` time and on subsequent setting changes per DESIGN.md §6.1.

**Tech Stack:** Swift 6.2 actors, AsyncStream, libmpv 2.1 C API (vendored in PR 5a), XCTest with real-libmpv integration smoke tests.

---

## File map

**New source files:**
- `Sources/RPPlayer/Player/PlayerEngine.swift` — `PlayerEngine` protocol, `PlayerEvent` enum, `PlayerEndReason` enum, `PlayerEngineError`
- `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift` — `LibmpvPlayerEngine` actor implementation
- `Sources/RPPlayer/Player/MpvEventBridge.swift` — pure functions that parse `mpv_event` C structs into `PlayerEvent` Swift values

**New test files:**
- `Tests/RPPlayerTests/Player/MockPlayerEngine.swift` — programmable test double for PR 6+
- `Tests/RPPlayerTests/Player/PlayerEventTests.swift` — pure-Swift tests for `PlayerEvent` value-type behavior
- `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift` — synthetic-event tests for the bridge (build mock `mpv_event` structs, verify mapping)
- `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift` — integration tests against real libmpv (init, shutdown, play short URL, observe time-pos events)

**Modified:**
- `Package.swift` — `RPPlayer` executable target gains `dependencies: ["CMpv"]` and `linkerSettings: mpvLinker` so the production code can link libmpv too.

---

## Public API surface (locked here for downstream consumers)

```swift
public protocol PlayerEngine: Sendable {
    var events: AsyncStream<PlayerEvent> { get async }

    func play(url: URL) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func seek(to seconds: Double) async throws
    func setHogMode(_ enabled: Bool) async throws
    func setOutputDevice(uid: String?) async throws
    func shutdown() async
}

public enum PlayerEvent: Sendable, Equatable {
    case positionUpdate(seconds: Double)
    case fileLoaded
    case fileEnded(reason: PlayerEndReason)
    case error(message: String)
    case hogModeChanged(enabled: Bool)
    case outputDeviceChanged(uid: String?)
    case shutdown
}

public enum PlayerEndReason: Sendable, Equatable {
    case eof
    case stopped
    case quit
    case error(code: Int)
    case redirect
    case unknown(rawValue: UInt32)
}

public enum PlayerEngineError: Error, Sendable, Equatable {
    case createFailed
    case initializeFailed(code: Int, message: String)
    case setOptionFailed(name: String, code: Int, message: String)
    case commandFailed(name: String, code: Int, message: String)
    case alreadyShutdown
}
```

PR 6 consumes `events` and the seven action methods. `setOutputDevice(uid: nil)` clears the device pin so libmpv falls back to system default.

---

## Task 1: PlayerEvent + PlayerEngine protocol + PlayerEngineError

**Files:**
- Create: `Tests/RPPlayerTests/Player/PlayerEventTests.swift`
- Create: `Sources/RPPlayer/Player/PlayerEngine.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Player/PlayerEventTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class PlayerEventTests: XCTestCase {
    func testEqualityForPositionUpdate() {
        XCTAssertEqual(
            PlayerEvent.positionUpdate(seconds: 12.5),
            PlayerEvent.positionUpdate(seconds: 12.5)
        )
        XCTAssertNotEqual(
            PlayerEvent.positionUpdate(seconds: 12.5),
            PlayerEvent.positionUpdate(seconds: 12.6)
        )
    }

    func testEqualityForFileEnded() {
        XCTAssertEqual(PlayerEvent.fileEnded(reason: .eof), PlayerEvent.fileEnded(reason: .eof))
        XCTAssertNotEqual(PlayerEvent.fileEnded(reason: .eof), PlayerEvent.fileEnded(reason: .stopped))
    }

    func testEqualityForOutputDeviceChanged() {
        XCTAssertEqual(
            PlayerEvent.outputDeviceChanged(uid: "uid-1"),
            PlayerEvent.outputDeviceChanged(uid: "uid-1")
        )
        XCTAssertEqual(
            PlayerEvent.outputDeviceChanged(uid: nil),
            PlayerEvent.outputDeviceChanged(uid: nil)
        )
        XCTAssertNotEqual(
            PlayerEvent.outputDeviceChanged(uid: "uid-1"),
            PlayerEvent.outputDeviceChanged(uid: nil)
        )
    }

    func testPlayerEndReasonUnknownPreservesRawValue() {
        XCTAssertEqual(PlayerEndReason.unknown(rawValue: 99), .unknown(rawValue: 99))
        XCTAssertNotEqual(PlayerEndReason.unknown(rawValue: 99), .unknown(rawValue: 100))
    }

    func testPlayerEngineErrorEquality() {
        XCTAssertEqual(
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail"),
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail")
        )
        XCTAssertNotEqual(
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail"),
            PlayerEngineError.commandFailed(name: "loadfile", code: -4, message: "fail")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter PlayerEventTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'PlayerEvent'`.

- [ ] **Step 3: Implement PlayerEngine.swift**

Create `Sources/RPPlayer/Player/PlayerEngine.swift`:

```swift
import Foundation

public protocol PlayerEngine: Sendable {
    var events: AsyncStream<PlayerEvent> { get async }

    func play(url: URL) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func seek(to seconds: Double) async throws
    func setHogMode(_ enabled: Bool) async throws
    func setOutputDevice(uid: String?) async throws
    func shutdown() async
}

public enum PlayerEvent: Sendable, Equatable {
    case positionUpdate(seconds: Double)
    case fileLoaded
    case fileEnded(reason: PlayerEndReason)
    case error(message: String)
    case hogModeChanged(enabled: Bool)
    case outputDeviceChanged(uid: String?)
    case shutdown
}

public enum PlayerEndReason: Sendable, Equatable {
    case eof
    case stopped
    case quit
    case error(code: Int)
    case redirect
    case unknown(rawValue: UInt32)
}

public enum PlayerEngineError: Error, Sendable, Equatable {
    case createFailed
    case initializeFailed(code: Int, message: String)
    case setOptionFailed(name: String, code: Int, message: String)
    case commandFailed(name: String, code: Int, message: String)
    case alreadyShutdown
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter PlayerEventTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/PlayerEngine.swift \
        Tests/RPPlayerTests/Player/PlayerEventTests.swift
git commit -m "feat(pr05b): add PlayerEngine protocol and PlayerEvent value types"
```

---

## Task 2: MpvEventBridge — pure-function parsing of mpv_event into PlayerEvent

**Files:**
- Create: `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift`
- Create: `Sources/RPPlayer/Player/MpvEventBridge.swift`

The bridge is a `enum MpvEventBridge` with static functions. Splitting parsing out of the actor (a) makes it pure-testable without owning a real mpv handle, and (b) keeps the actor's command/event surface focused.

The mpv `MPV_EVENT_END_FILE` payload (`mpv_event_end_file`) has a `reason` enum:

| `mpv_end_file_reason` | C value | maps to `PlayerEndReason` |
|---|---|---|
| `MPV_END_FILE_REASON_EOF` | 0 | `.eof` |
| `MPV_END_FILE_REASON_STOP` | 2 | `.stopped` |
| `MPV_END_FILE_REASON_QUIT` | 3 | `.quit` |
| `MPV_END_FILE_REASON_ERROR` | 4 | `.error(code:)` (read `error` field) |
| `MPV_END_FILE_REASON_REDIRECT` | 5 | `.redirect` |
| anything else | — | `.unknown(rawValue:)` |

`MPV_EVENT_PROPERTY_CHANGE` for `time-pos` (format `MPV_FORMAT_DOUBLE`) → `.positionUpdate(seconds:)`. Other properties currently ignored.

`MPV_EVENT_FILE_LOADED` → `.fileLoaded`.
`MPV_EVENT_SHUTDOWN` → `.shutdown`.
`MPV_EVENT_LOG_MESSAGE` at error level → `.error(message:)`.

Anything else (idle-active, start-file, video-reconfig, etc.) → bridge returns `nil` (not surfaced to subscribers).

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift`:

```swift
import XCTest
import CMpv
@testable import RPPlayer

final class MpvEventBridgeTests: XCTestCase {
    func testEndFileReasonsMapCorrectly() {
        var endEof = mpv_event_end_file()
        endEof.reason = MPV_END_FILE_REASON_EOF
        XCTAssertEqual(MpvEventBridge.endReason(from: endEof), .eof)

        var endStop = mpv_event_end_file()
        endStop.reason = MPV_END_FILE_REASON_STOP
        XCTAssertEqual(MpvEventBridge.endReason(from: endStop), .stopped)

        var endQuit = mpv_event_end_file()
        endQuit.reason = MPV_END_FILE_REASON_QUIT
        XCTAssertEqual(MpvEventBridge.endReason(from: endQuit), .quit)

        var endRedirect = mpv_event_end_file()
        endRedirect.reason = MPV_END_FILE_REASON_REDIRECT
        XCTAssertEqual(MpvEventBridge.endReason(from: endRedirect), .redirect)
    }

    func testEndFileErrorPreservesCode() {
        var endError = mpv_event_end_file()
        endError.reason = MPV_END_FILE_REASON_ERROR
        endError.error = -7
        XCTAssertEqual(MpvEventBridge.endReason(from: endError), .error(code: -7))
    }

    func testEndFileUnknownReasonFallsBack() {
        var endUnknown = mpv_event_end_file()
        endUnknown.reason = mpv_end_file_reason(rawValue: 999)
        XCTAssertEqual(MpvEventBridge.endReason(from: endUnknown), .unknown(rawValue: 999))
    }

    func testTimePosPropertyChangeBecomesPositionUpdate() {
        var pos: Double = 42.5
        let event = withUnsafeMutablePointer(to: &pos) { posPtr -> PlayerEvent? in
            "time-pos".withCString { namePtr in
                var prop = mpv_event_property()
                prop.name = namePtr
                prop.format = MPV_FORMAT_DOUBLE
                prop.data = UnsafeMutableRawPointer(posPtr)
                return MpvEventBridge.propertyChange(from: prop)
            }
        }
        XCTAssertEqual(event, .positionUpdate(seconds: 42.5))
    }

    func testNonTimePosPropertyChangeReturnsNil() {
        var dummy: Double = 0
        let event = withUnsafeMutablePointer(to: &dummy) { ptr -> PlayerEvent? in
            "volume".withCString { namePtr in
                var prop = mpv_event_property()
                prop.name = namePtr
                prop.format = MPV_FORMAT_DOUBLE
                prop.data = UnsafeMutableRawPointer(ptr)
                return MpvEventBridge.propertyChange(from: prop)
            }
        }
        XCTAssertNil(event)
    }

    func testTimePosWithWrongFormatReturnsNil() {
        var prop = mpv_event_property()
        "time-pos".withCString { namePtr in
            prop.name = namePtr
            prop.format = MPV_FORMAT_NONE
            prop.data = nil
            XCTAssertNil(MpvEventBridge.propertyChange(from: prop))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter MpvEventBridgeTests 2>&1 | head -20
```

Expected: compile error containing `cannot find 'MpvEventBridge'`.

- [ ] **Step 3: Implement MpvEventBridge.swift**

Create `Sources/RPPlayer/Player/MpvEventBridge.swift`:

```swift
import CMpv
import Foundation

enum MpvEventBridge {
    static func endReason(from event: mpv_event_end_file) -> PlayerEndReason {
        switch event.reason {
        case MPV_END_FILE_REASON_EOF:      return .eof
        case MPV_END_FILE_REASON_STOP:     return .stopped
        case MPV_END_FILE_REASON_QUIT:     return .quit
        case MPV_END_FILE_REASON_ERROR:    return .error(code: Int(event.error))
        case MPV_END_FILE_REASON_REDIRECT: return .redirect
        default:                           return .unknown(rawValue: event.reason.rawValue)
        }
    }

    static func propertyChange(from prop: mpv_event_property) -> PlayerEvent? {
        guard let namePtr = prop.name else { return nil }
        let name = String(cString: namePtr)
        switch (name, prop.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            guard let dataPtr = prop.data?.assumingMemoryBound(to: Double.self) else { return nil }
            return .positionUpdate(seconds: dataPtr.pointee)
        default:
            return nil
        }
    }

    static func playerEvent(from event: mpv_event) -> PlayerEvent? {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_END_FILE:
            let endPtr = event.data.assumingMemoryBound(to: mpv_event_end_file.self)
            return .fileEnded(reason: endReason(from: endPtr.pointee))
        case MPV_EVENT_PROPERTY_CHANGE:
            let propPtr = event.data.assumingMemoryBound(to: mpv_event_property.self)
            return propertyChange(from: propPtr.pointee)
        case MPV_EVENT_LOG_MESSAGE:
            let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
            let log = logPtr.pointee
            // Only escalate "error" level to PlayerEvent.error; lower levels stay quiet.
            if let levelPtr = log.level, String(cString: levelPtr) == "error",
               let textPtr = log.text {
                return .error(message: String(cString: textPtr).trimmingCharacters(in: .newlines))
            }
            return nil
        case MPV_EVENT_SHUTDOWN:
            return .shutdown
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter MpvEventBridgeTests 2>&1 | tail -10
```

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/MpvEventBridge.swift \
        Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift
git commit -m "feat(pr05b): add MpvEventBridge for mpv_event → PlayerEvent translation"
```

---

## Task 3: MockPlayerEngine — programmable test double

**Files:**
- Create: `Tests/RPPlayerTests/Player/MockPlayerEngine.swift`

The mock is consumed by `PlaybackCoordinator` tests in PR 6. It records every command call and lets the test driver fire `PlayerEvent`s into the subscriber stream.

- [ ] **Step 1: Create the mock**

Create `Tests/RPPlayerTests/Player/MockPlayerEngine.swift`:

```swift
import Foundation
@testable import RPPlayer

actor MockPlayerEngine: PlayerEngine {
    enum Call: Sendable, Equatable {
        case play(url: URL)
        case pause
        case resume
        case stop
        case seek(seconds: Double)
        case setHogMode(enabled: Bool)
        case setOutputDevice(uid: String?)
        case shutdown
    }

    private var calls: [Call] = []
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var nextError: Error?

    func recordedCalls() -> [Call] { calls }

    /// Causes the next non-shutdown command to throw the given error and record nothing.
    func setNextError(_ error: Error) { nextError = error }

    /// Pushes an event to every active subscriber.
    func fire(_ event: PlayerEvent) {
        for c in continuations.values { c.yield(event) }
    }

    var events: AsyncStream<PlayerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func recordOrThrow(_ call: Call) throws {
        if let err = nextError {
            nextError = nil
            throw err
        }
        calls.append(call)
    }

    func play(url: URL) async throws    { try recordOrThrow(.play(url: url)) }
    func pause() async throws           { try recordOrThrow(.pause) }
    func resume() async throws          { try recordOrThrow(.resume) }
    func stop() async throws            { try recordOrThrow(.stop) }
    func seek(to seconds: Double) async throws { try recordOrThrow(.seek(seconds: seconds)) }
    func setHogMode(_ enabled: Bool) async throws {
        try recordOrThrow(.setHogMode(enabled: enabled))
    }
    func setOutputDevice(uid: String?) async throws {
        try recordOrThrow(.setOutputDevice(uid: uid))
    }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}
```

- [ ] **Step 2: Verify build is clean (no test for the mock itself; it is exercised by PR 6)**

```
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: build complete; full suite still 48 + 5 + 6 = 59 tests.

- [ ] **Step 3: Commit**

```bash
git add Tests/RPPlayerTests/Player/MockPlayerEngine.swift
git commit -m "test(pr05b): add MockPlayerEngine programmable test double for PR 6"
```

---

## Task 4: LibmpvPlayerEngine — actor scaffold (init, shutdown, baseline options)

**Files:**
- Create: `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`
- Create: `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`
- Modify: `Package.swift` (link `RPPlayer` target with `CMpv`)

This task introduces the actor with init/shutdown only. No event pump, no commands yet. Verifies the actor can spin up + tear down a real libmpv handle on the dev Mac.

- [ ] **Step 1: Update `Package.swift`**

The existing `Package.swift` doesn't link `CMpv` into the main `RPPlayer` target. Replace the `RPPlayer` `.executableTarget` with the version below, preserving all other targets:

```swift
        .executableTarget(
            name: "RPPlayer",
            dependencies: ["CMpv"],
            path: "Sources/RPPlayer",
            linkerSettings: mpvLinker
        ),
```

- [ ] **Step 2: Verify the build is still clean**

```
swift build 2>&1 | tail -5
```

Expected: `Build complete!`. (No new code yet; just adding the dependency line.)

- [ ] **Step 3: Write the failing tests**

Create `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`:

```swift
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
        do {
            try await engine.pause()
            XCTFail("expected alreadyShutdown")
        } catch let error as PlayerEngineError {
            XCTAssertEqual(error, .alreadyShutdown)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

```
swift test --filter LibmpvPlayerEngineTests 2>&1 | head -20
```

Expected: compile error containing `cannot find 'LibmpvPlayerEngine'`.

- [ ] **Step 5: Implement LibmpvPlayerEngine.swift (scaffold only — pump + commands come in later tasks)**

Create `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`:

```swift
import CMpv
import Foundation

public actor LibmpvPlayerEngine: PlayerEngine {
    private var handle: OpaquePointer?
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var isShutdown = false

    public init() throws {
        guard let h = mpv_create() else {
            throw PlayerEngineError.createFailed
        }

        // Apply baseline options that match DESIGN.md §6.1: bit-perfect, audio-only,
        // no terminal/input handling. Hog mode and output device come from settings
        // and are applied via setHogMode / setOutputDevice (Task 6).
        let baseline: [(String, String)] = [
            ("vid", "no"),
            ("video", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
            ("audio-pitch-correction", "no"),
            ("audio-channels", "auto"),
            ("volume-max", "100"),
        ]
        for (key, value) in baseline {
            let status = mpv_set_option_string(h, key, value)
            if status < 0 {
                let message = String(cString: mpv_error_string(status))
                mpv_terminate_destroy(h)
                throw PlayerEngineError.setOptionFailed(name: key, code: Int(status), message: message)
            }
        }

        let initStatus = mpv_initialize(h)
        if initStatus < 0 {
            let message = String(cString: mpv_error_string(initStatus))
            mpv_terminate_destroy(h)
            throw PlayerEngineError.initializeFailed(code: Int(initStatus), message: message)
        }

        self.handle = h
    }

    public var events: AsyncStream<PlayerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func play(url: URL) async throws        { try requireHandle(); throw PlayerEngineError.commandFailed(name: "play", code: -100, message: "play not implemented yet") }
    public func pause() async throws               { try requireHandle(); throw PlayerEngineError.commandFailed(name: "pause", code: -100, message: "pause not implemented yet") }
    public func resume() async throws              { try requireHandle(); throw PlayerEngineError.commandFailed(name: "resume", code: -100, message: "resume not implemented yet") }
    public func stop() async throws                { try requireHandle(); throw PlayerEngineError.commandFailed(name: "stop", code: -100, message: "stop not implemented yet") }
    public func seek(to seconds: Double) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "seek", code: -100, message: "seek not implemented yet") }
    public func setHogMode(_ enabled: Bool) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setHogMode", code: -100, message: "setHogMode not implemented yet") }
    public func setOutputDevice(uid: String?) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setOutputDevice", code: -100, message: "setOutputDevice not implemented yet") }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        if let h = handle {
            mpv_terminate_destroy(h)
        }
        handle = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func requireHandle() throws {
        guard !isShutdown else { throw PlayerEngineError.alreadyShutdown }
    }
}
```

The "not implemented yet" code `-100` is a sentinel that future tasks replace. By making each method throwable from the start, future-task implementations only need to swap the body, not the signature.

- [ ] **Step 6: Run tests to verify they pass**

```
swift test --filter LibmpvPlayerEngineTests 2>&1 | tail -10
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 7: Run full suite**

```
swift test 2>&1 | tail -5
```

Expected: `Executed 62 tests, with 0 failures` (48 prior + 5 PlayerEvent + 6 MpvEventBridge + 3 LibmpvPlayerEngine).

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Player/LibmpvPlayerEngine.swift \
        Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift \
        Package.swift
git commit -m "feat(pr05b): LibmpvPlayerEngine actor scaffold with init/shutdown"
```

---

## Task 5: Event pump task — translate mpv events into PlayerEvent stream

**Files:**
- Modify: `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`
- Modify: `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`

The event pump is a detached `Task` that loops on `mpv_wait_event(handle, -1)` (block forever). For each event, it asks `MpvEventBridge.playerEvent(from:)` for a `PlayerEvent`, and yields to a `dispatch` closure that re-isolates onto the actor and yields to subscribers.

`mpv_wait_event` is documented thread-safe with respect to other client API calls (only one thread may call `mpv_wait_event` at a time — that's the pump). The handle remains live until `mpv_terminate_destroy`. After destroy, `mpv_wait_event` returns `MPV_EVENT_SHUTDOWN`; the pump exits.

- [ ] **Step 1: Append the integration test**

Append to `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`:

```swift
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
        // The stream finishes after shutdown; the .shutdown event is the last yielded.
        XCTAssertEqual(collected.last, .shutdown)
    }

    /// Smoke: play a stable RP audio stream and verify positionUpdate events arrive.
    /// Exits early after the first 3 positionUpdate events to keep the test fast.
    func testPositionUpdatesArriveDuringPlayback() async throws {
        let engine = try LibmpvPlayerEngine()
        defer { Task { await engine.shutdown() } }
        let stream = await engine.events

        // Wait for events on a background task so the engine command can fire.
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

        // Cap the wait so the test cannot hang the suite.
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
```

`testPositionUpdatesArriveDuringPlayback` depends on Task 6 (`play(url:)` real implementation). Until then, it will fail because of the placeholder body. That is intentional — it doubles as the failing test that drives Task 6.

- [ ] **Step 2: Implement the event pump in `LibmpvPlayerEngine.swift`**

Replace the `events` getter and `shutdown()` body, and add a private `startPump()` method. Full updated file:

```swift
import CMpv
import Foundation

public actor LibmpvPlayerEngine: PlayerEngine {
    private var handle: OpaquePointer?
    private var continuations: [UUID: AsyncStream<PlayerEvent>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var isShutdown = false

    public init() throws {
        guard let h = mpv_create() else {
            throw PlayerEngineError.createFailed
        }

        let baseline: [(String, String)] = [
            ("vid", "no"),
            ("video", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
            ("audio-pitch-correction", "no"),
            ("audio-channels", "auto"),
            ("volume-max", "100"),
        ]
        for (key, value) in baseline {
            let status = mpv_set_option_string(h, key, value)
            if status < 0 {
                let message = String(cString: mpv_error_string(status))
                mpv_terminate_destroy(h)
                throw PlayerEngineError.setOptionFailed(name: key, code: Int(status), message: message)
            }
        }

        let initStatus = mpv_initialize(h)
        if initStatus < 0 {
            let message = String(cString: mpv_error_string(initStatus))
            mpv_terminate_destroy(h)
            throw PlayerEngineError.initializeFailed(code: Int(initStatus), message: message)
        }

        // Subscribe to time-pos changes so position updates flow through the pump.
        _ = mpv_observe_property(h, /*reply_userdata*/ 0, "time-pos", MPV_FORMAT_DOUBLE)

        self.handle = h
        startPump(handle: h)
    }

    public var events: AsyncStream<PlayerEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown {
                continuation.finish()
                return
            }
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    private func startPump(handle: OpaquePointer) {
        pumpTask = Task.detached { [weak self] in
            await Self.pump(handle: handle, deliver: { event in
                await self?.deliver(event)
            })
        }
    }

    /// Runs on a detached background task. Calls `mpv_wait_event` in a loop and
    /// pushes parsed events back to the actor via `deliver`. Exits when the
    /// MPV_EVENT_SHUTDOWN event arrives (which mpv_terminate_destroy triggers).
    private static func pump(
        handle: OpaquePointer,
        deliver: @Sendable @escaping (PlayerEvent) async -> Void
    ) async {
        while !Task.isCancelled {
            guard let eventPtr = mpv_wait_event(handle, /*timeout*/ -1) else { continue }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { continue }
            if let translated = MpvEventBridge.playerEvent(from: event) {
                await deliver(translated)
                if case .shutdown = translated { return }
            } else if event.event_id == MPV_EVENT_SHUTDOWN {
                // Bridge already returns .shutdown for this; safety net.
                return
            }
        }
    }

    private func deliver(_ event: PlayerEvent) {
        for c in continuations.values { c.yield(event) }
        if case .shutdown = event {
            for c in continuations.values { c.finish() }
            continuations.removeAll()
        }
    }

    public func play(url: URL) async throws        { try requireHandle(); throw PlayerEngineError.commandFailed(name: "play", code: -100, message: "play not implemented yet") }
    public func pause() async throws               { try requireHandle(); throw PlayerEngineError.commandFailed(name: "pause", code: -100, message: "pause not implemented yet") }
    public func resume() async throws              { try requireHandle(); throw PlayerEngineError.commandFailed(name: "resume", code: -100, message: "resume not implemented yet") }
    public func stop() async throws                { try requireHandle(); throw PlayerEngineError.commandFailed(name: "stop", code: -100, message: "stop not implemented yet") }
    public func seek(to seconds: Double) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "seek", code: -100, message: "seek not implemented yet") }
    public func setHogMode(_ enabled: Bool) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setHogMode", code: -100, message: "setHogMode not implemented yet") }
    public func setOutputDevice(uid: String?) async throws { try requireHandle(); throw PlayerEngineError.commandFailed(name: "setOutputDevice", code: -100, message: "setOutputDevice not implemented yet") }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        if let h = handle {
            mpv_terminate_destroy(h)
        }
        handle = nil
        await pumpTask?.value
        pumpTask = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func requireHandle() throws {
        guard !isShutdown else { throw PlayerEngineError.alreadyShutdown }
    }
}
```

- [ ] **Step 3: Run the shutdown event test (the playback test will fail; that is expected and drives Task 6)**

```
swift test --filter "testShutdownEventIsEmittedAndStreamFinishes" 2>&1 | tail -10
```

Expected: 1 test passes. (The other new test, `testPositionUpdatesArriveDuringPlayback`, drives Task 6.)

- [ ] **Step 4: Run the full suite to confirm no regression on other tests; the playback test will fail because `play` is still a placeholder**

```
swift test 2>&1 | tail -10
```

Expected: 1 failure (the playback integration test). 62 + 2 = 64 tests, 1 failing.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/LibmpvPlayerEngine.swift \
        Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift
git commit -m "feat(pr05b): LibmpvPlayerEngine event pump and shutdown event flow"
```

(Yes, this commit leaves a known-failing test in the suite. The next task fixes it. The plan trades temporary red for visible TDD progress; the alternative is mixing pump + play implementation in one giant task.)

---

## Task 6: Commands — play / pause / resume / stop / seek

**Files:**
- Modify: `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`

mpv command reference:
- Play a URL: `command(["loadfile", url])`. The actor stores the URL; `play(url:)` runs `loadfile`.
- Pause: `set_property("pause", true)` (boolean flag). Resume: `set_property("pause", false)`.
- Stop: `command(["stop"])` releases the file but keeps the handle.
- Seek: `command(["seek", "<seconds>", "absolute"])`.

Implement each, then verify the previously failing `testPositionUpdatesArriveDuringPlayback` test now passes.

- [ ] **Step 1: Replace the placeholder bodies**

In `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`, replace the seven placeholder method bodies (the ones that throw `code: -100`) with these real implementations. Leave `setHogMode` and `setOutputDevice` as placeholders for now — Task 7 owns those.

```swift
    public func play(url: URL) async throws {
        try requireHandle()
        try runCommand(["loadfile", url.absoluteString])
    }

    public func pause() async throws {
        try requireHandle()
        try setBoolProperty("pause", true)
    }

    public func resume() async throws {
        try requireHandle()
        try setBoolProperty("pause", false)
    }

    public func stop() async throws {
        try requireHandle()
        try runCommand(["stop"])
    }

    public func seek(to seconds: Double) async throws {
        try requireHandle()
        try runCommand(["seek", String(seconds), "absolute"])
    }
```

Add these helpers to the actor (private):

```swift
    private func runCommand(_ args: [String]) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        let cstrings = args.map { strdup($0)! }
        defer { for s in cstrings { free(s) } }
        var argv = cstrings.map { UnsafePointer<CChar>?($0) }
        argv.append(nil)
        let status = argv.withUnsafeMutableBufferPointer { buf -> Int32 in
            mpv_command(h, buf.baseAddress!)
        }
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: args.first ?? "<unknown>", code: Int(status), message: message)
        }
    }

    private func setBoolProperty(_ name: String, _ value: Bool) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        var flag: Int32 = value ? 1 : 0
        let status = mpv_set_property(h, name, MPV_FORMAT_FLAG, &flag)
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: name, code: Int(status), message: message)
        }
    }
```

- [ ] **Step 2: Run the integration playback test**

```
swift test --filter testPositionUpdatesArriveDuringPlayback 2>&1 | tail -10
```

Expected: `Executed 1 test, with 0 failures` (the test from Task 5 now passes against the real `play` impl).

- [ ] **Step 3: Run full suite**

```
swift test 2>&1 | tail -5
```

Expected: `Executed 64 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Player/LibmpvPlayerEngine.swift
git commit -m "feat(pr05b): LibmpvPlayerEngine play/pause/resume/stop/seek commands"
```

---

## Task 7: Settings — hog mode + output device

**Files:**
- Modify: `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`
- Modify: `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`

mpv settings:
- Hog mode: `set_property_string("audio-exclusive", "yes" | "no")`. Takes effect on next file open.
- Output device: `set_property_string("audio-device", "coreaudio_exclusive/<UID>")`. Setting to `"auto"` clears the pin (DESIGN.md §6.2: when no UID is set, fall back to system default).

Both setters emit confirmation events: `.hogModeChanged(enabled:)` and `.outputDeviceChanged(uid:)`. The actor calls `deliver(...)` directly after a successful property write so subscribers don't need to wait for an mpv property-change event.

- [ ] **Step 1: Replace the two placeholder bodies**

```swift
    public func setHogMode(_ enabled: Bool) async throws {
        try requireHandle()
        try setStringProperty("audio-exclusive", enabled ? "yes" : "no")
        deliver(.hogModeChanged(enabled: enabled))
    }

    public func setOutputDevice(uid: String?) async throws {
        try requireHandle()
        let value: String
        if let uid, !uid.isEmpty {
            value = "coreaudio_exclusive/\(uid)"
        } else {
            value = "auto"
        }
        try setStringProperty("audio-device", value)
        deliver(.outputDeviceChanged(uid: uid))
    }
```

Add the `setStringProperty` helper (private):

```swift
    private func setStringProperty(_ name: String, _ value: String) throws {
        guard let h = handle else { throw PlayerEngineError.alreadyShutdown }
        let status = mpv_set_property_string(h, name, value)
        if status < 0 {
            let message = String(cString: mpv_error_string(status))
            throw PlayerEngineError.commandFailed(name: name, code: Int(status), message: message)
        }
    }
```

- [ ] **Step 2: Add tests**

Append to `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`:

```swift
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
```

- [ ] **Step 3: Run new tests**

```
swift test --filter "LibmpvPlayerEngineTests/testSetHogModeEmitsHogModeChanged|LibmpvPlayerEngineTests/testSetOutputDeviceWithUidEmitsOutputDeviceChanged|LibmpvPlayerEngineTests/testSetOutputDeviceWithNilEmitsClearedEvent" 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 4: Run full suite**

```
swift test 2>&1 | tail -5
```

Expected: `Executed 67 tests, with 0 failures` (64 prior + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/LibmpvPlayerEngine.swift \
        Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift
git commit -m "feat(pr05b): LibmpvPlayerEngine setHogMode and setOutputDevice"
```

---

## Task 8: CLAUDE.md updates

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump the PR table**

Replace:

```markdown
| 5a  | **next**       | ⬜      | libmpv vendoring + RPSmoke CLI                                    |
| 5b  | pending        | ⬜      | PlayerEngine (libmpv Swift actor)                                 |
```

with:

```markdown
| 5a  | merged to main | ✅      | libmpv vendoring + RPSmoke CLI                                    |
| 5b  | **next**       | ⬜      | PlayerEngine (libmpv Swift actor)                                 |
```

(After this PR merges, swap `**next**` → `merged to main` and `⬜` → `✅` in a follow-up commit, mirroring the PR 4 / PR 5a pattern. The "next" pointer should move to PR 6.)

- [ ] **Step 2: Add a "PlayerEngine threading" bullet to "Key technical decisions"**

Append:

```markdown
- `LibmpvPlayerEngine` runs a single detached event-pump task that calls `mpv_wait_event` with no timeout. The pump exits when `mpv_terminate_destroy` causes mpv to emit `MPV_EVENT_SHUTDOWN`. mpv's client API is thread-safe except for `mpv_wait_event` (only one thread at a time) — the pump is the only caller. The actor's commands run concurrently with the pump and use other thread-safe API calls.
```

- [ ] **Step 3: Update test count and PR scope line**

Append `- After PR 5b: 67 tests` to the test count list.

Replace the "PR 5a scope" paragraph with a "PR 5b scope" paragraph:

```markdown
PR 5b scope: wrap libmpv in a Swift actor (`LibmpvPlayerEngine`) that exposes `play`/`pause`/`resume`/`stop`/`seek`/`setHogMode`/`setOutputDevice`/`shutdown` as `async throws` methods and emits state changes via `AsyncStream<PlayerEvent>`. Consumed by `PlaybackCoordinator` in PR 6.
```

- [ ] **Step 4: Verify the suite still passes**

```
swift test 2>&1 | tail -5
```

Expected: `Executed 67 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(pr05b): record PlayerEngine threading note and post-PR5b test count"
```

---

## Self-review

**Spec coverage check (DESIGN.md §4 + §6.1 + §6.3):**

| Requirement | Covered by |
|---|---|
| `play(url:)`, `pause`, `resume`, `stop`, `seek(to:)` commands | Tasks 1 + 6 |
| `setHogMode(_:)`, `setOutputDevice(uid:)` settings | Tasks 1 + 7 |
| `AsyncStream<PlayerEvent>` of `positionUpdate`, `fileEnded`, `error`, `hogModeChanged`, `outputDeviceChanged` | Tasks 1 (types), 2 (parser), 5 (pump), 6 (commands), 7 (settings) |
| Bit-perfect mpv config (audio-exclusive, audio-device, audio-pitch-correction=no) | Task 4 baseline + Task 7 setHogMode + setOutputDevice |
| `audio-format` and `audio-samplerate` left unset | Task 4 baseline does not set them ✓ |
| Software volume off, `volume-max=100` | Task 4 baseline includes `volume-max=100` ✓ |
| On `stop`, libmpv releases the device (DESIGN.md §6.3) | Task 6 `runCommand(["stop"])` — mpv's `stop` command releases the file/device per the docs |
| Test double for PR 6 PlaybackCoordinator | Task 3 `MockPlayerEngine` |

**Placeholder scan:** searched for "TBD", "implement later", "appropriate", "similar to". The Task 4 placeholder bodies (`code: -100, message: "X not implemented yet"`) are intentional sentinel values that get replaced in Tasks 6/7; not planning placeholders. The Task 5 commit deliberately leaves one test failing (drives Task 6) — also intentional and documented.

**Type/signature consistency:**
- `PlayerEngine` protocol surface defined in Task 1 used unchanged in Tasks 3/4/5/6/7 ✓
- `PlayerEvent` cases defined in Task 1 produced by Task 2 (bridge), Task 5 (pump), Task 7 (settings) ✓
- `PlayerEndReason` cases defined in Task 1 produced by Task 2 `endReason(from:)` ✓
- `MpvEventBridge.playerEvent(from:)` defined in Task 2 used in Task 5's pump ✓
- `MockPlayerEngine.Call` used by PR 6 — its case names match the protocol method names ✓

**Test-count math:**

| After | Tests | Delta |
|---|---|---|
| PR 5a | 48 | — |
| Task 1 | 53 | +5 (PlayerEvent) |
| Task 2 | 59 | +6 (MpvEventBridge) |
| Task 3 | 59 | — (no test for the mock) |
| Task 4 | 62 | +3 (init/shutdown/idempotency) |
| Task 5 | 64 | +2 (one passes, one fails until Task 6) |
| Task 6 | 64 | — (the Task 5 failing test now passes; no new tests) |
| Task 7 | 67 | +3 (hog mode + 2× output device) |

Total after PR 5b: **67 tests**. Reflected in Task 7 Step 4 and Task 8 Step 3.

**Risk register:**
- Integration tests against real libmpv require audio hardware on the dev Mac. Build pass on a headless CI runner is OK because libmpv defaults to a "null" audio output if no device is present, but `mpv_initialize` may surface non-fatal warnings. Tests assert positive behaviour (events arrive, no thrown errors), not the absence of all warnings.
- The `testPositionUpdatesArriveDuringPlayback` test makes a real network request. If `stream.radioparadise.com` is unreachable, the test fails — that is acceptable and surfaces a real environmental issue. For a future CI workflow, gating this test with `XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil)` would prevent flakes on the runner.
- The deliberate Task 5 → Task 6 red→green hand-off is unusual for the subagent-driven-development workflow. If the controller dispatches Tasks 5 and 6 to separate subagents, the second subagent must accept that the suite has one pre-existing failing test (drives the task) and not interpret it as a regression.
