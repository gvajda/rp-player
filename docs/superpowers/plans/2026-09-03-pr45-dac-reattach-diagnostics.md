# PR 45 — DAC Reattach Diagnostics + Play Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the "DAC replugged → Play shows Pause but silence, progress stuck at 0" failure diagnosable from the log, and stop the one sequence known to precede it (Play pressed while the held device is still absent).

**Architecture:** Three independent, small changes. (1) mpv log messages at `warn` level and `ao*`-prefixed `info`/`v` messages are forwarded into the app log via the existing engine pump; `error` keeps its current `.error` event path. (2) `HogModeController` gets an optional logger and logs acquire/release outcomes with CoreAudio device IDs and sample rates. (3) `prePlayHook` becomes throwing; the AppContainer hook throws a new `PlaybackCoordinatorError.outputDeviceUnavailable(name:)` while `DeviceReattachState.heldUID` is set, so mpv never tries to open an absent device.

**Tech Stack:** Swift 6.2, XCTest, libmpv 0.36 (`CMpv`), CoreAudio.

**Spec:** No separate spec. Investigation summary: `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md` (written in Task 4 from the findings below).

## Global Constraints

- `swift build` and `swift test` must pass at the end of every task.
- Comment policy: no comments unless the WHY is non-obvious; single `//` line max.
- Branch: `claude/pr45-dac-reattach-diagnostics` off `main`. Fast-forward merge only.
- Do not change user-visible behavior beyond: the new "disconnected" message when Play is pressed while the device is absent.
- Do not attempt to "fix" the silent-AO stall itself — root cause is unconfirmed; this PR produces the evidence.

## Investigation findings (context for executors)

- Log 3 Sep 2026: 12:52 DAC disappeared (hog on, app stopped mpv, waited). 14:29 user pressed Play while DAC still absent → mpv `[ao/coreaudio] could not check whether device is alive`, end-file `-14`. 14:30:40 DAC reappeared, hog re-acquired. 14:30:52 Play → `fileLoaded`, **no** mpv errors, `time-pos` never advanced, a `loadfile append-play` command blocked ~7s (mpv core thread stalled inside CoreAudio). Relaunch fixed it.
- Reattach → Play worked in ~15 earlier occurrences across all log files. This is the only occurrence of "failed AO init on absent device, then reattach", and the only silent play.
- mpv 0.36 `ao_coreaudio.c` `init()` is stateless on failure (verified from source), so leftover state is in-process CoreAudio HAL/AudioUnit, not mpv.
- Evidence gaps: mpv log requested at `error` only (`MpvPlayerEngine.swift:123`); `HogModeController` never logs acquire result, device ID, or the sample-rate restore/re-set that happens on every stop→play cycle when release-on-pause is on.

---

### Task 1: Forward mpv warn + `ao` diagnostics into the app log

**Files:**
- Modify: `Sources/RPPlayer/Player/MpvEventBridge.swift`
- Modify: `Sources/RPPlayer/Player/MpvPlayerEngine.swift:123` (log level), `:137-153` (`startPump`), `:177-192` (`pump`)
- Test: `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift`

**Interfaces:**
- Produces: `struct MpvLogLine: Equatable { let level: String; let prefix: String; let text: String }`
- Produces: `static func MpvEventBridge.logLine(from log: mpv_event_log_message) -> MpvLogLine?`
- Produces: `static func MpvEventBridge.diagnosticText(for line: MpvLogLine) -> String?` — non-nil for `warn` (any prefix) and for `info`/`v` when `prefix` has prefix `ao`; nil otherwise (including `error`, which stays on the `.error` event path).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift` inside the class:

```swift
    private func withLogMessage<T>(
        level: String, prefix: String, text: String,
        _ body: (mpv_event_log_message) -> T
    ) -> T {
        level.withCString { levelPtr in
            prefix.withCString { prefixPtr in
                text.withCString { textPtr in
                    var msg = mpv_event_log_message()
                    msg.level = levelPtr
                    msg.prefix = prefixPtr
                    msg.text = textPtr
                    return body(msg)
                }
            }
        }
    }

    func testLogLineParsesFieldsAndTrimsNewline() {
        let line = withLogMessage(level: "warn", prefix: "ao/coreaudio", text: "can't start audio unit\n") {
            MpvEventBridge.logLine(from: $0)
        }
        XCTAssertEqual(line, MpvLogLine(level: "warn", prefix: "ao/coreaudio", text: "can't start audio unit"))
    }

    func testDiagnosticTextForwardsWarnAndAoVerboseOnly() {
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "warn", prefix: "demux", text: "x")),
            "mpv[demux] x"
        )
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "v", prefix: "ao/coreaudio", text: "selected audio output device: Q (78)")),
            "mpv[ao/coreaudio] selected audio output device: Q (78)"
        )
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "info", prefix: "ao", text: "y")),
            "mpv[ao] y"
        )
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "v", prefix: "demux", text: "x")))
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "info", prefix: "cplayer", text: "x")))
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "error", prefix: "ao/coreaudio", text: "x")))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MpvEventBridgeTests 2>&1 | tail -20`
Expected: compile error — `MpvLogLine` / `logLine(from:)` / `diagnosticText(for:)` not defined.

- [ ] **Step 3: Implement the bridge helpers**

In `Sources/RPPlayer/Player/MpvEventBridge.swift`, add above `enum MpvEventBridge`:

```swift
struct MpvLogLine: Equatable, Sendable {
    let level: String
    let prefix: String
    let text: String
}
```

Add inside `enum MpvEventBridge`:

```swift
    static func logLine(from log: mpv_event_log_message) -> MpvLogLine? {
        guard let levelPtr = log.level, let prefixPtr = log.prefix, let textPtr = log.text else { return nil }
        return MpvLogLine(
            level: String(cString: levelPtr),
            prefix: String(cString: prefixPtr),
            text: String(cString: textPtr).trimmingCharacters(in: .newlines)
        )
    }

    // Only AO-related verbose lines are worth the log volume; everything else at v/info is demux/decoder chatter.
    static func diagnosticText(for line: MpvLogLine) -> String? {
        switch line.level {
        case "warn":
            return "mpv[\(line.prefix)] \(line.text)"
        case "info", "v":
            return line.prefix.hasPrefix("ao") ? "mpv[\(line.prefix)] \(line.text)" : nil
        default:
            return nil
        }
    }
```

Replace the `MPV_EVENT_LOG_MESSAGE` case body in `playerEvent(from:)` with:

```swift
        case MPV_EVENT_LOG_MESSAGE:
            let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
            guard let line = logLine(from: logPtr.pointee), line.level == "error" else { return nil }
            return .error(message: line.text)
```

- [ ] **Step 4: Run bridge tests to verify they pass**

Run: `swift test --filter MpvEventBridgeTests 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 5: Wire the pump**

In `Sources/RPPlayer/Player/MpvPlayerEngine.swift`:

Line 123: change `_ = mpv_request_log_messages(h, "error")` to `_ = mpv_request_log_messages(h, "v")` and update the comment above it to one line: `// "v" so ao/coreaudio device-selection lines reach the log; the pump drops everything else below warn.`

In `startPump()`, pass the logger:

```swift
        let box = HandleBox(handle: handle)
        let logger = self.logger
        pumpTask = Task.detached { [weak self] in
            await Self.pump(
                handle: box.handle,
                logger: logger,
                deliver: { [weak self] event in
                    await self?.deliver(event)
                }
            )
        }
```

Change `pump` signature and body:

```swift
    private static func pump(
        handle: OpaquePointer,
        logger: (any Logging)?,
        deliver: @Sendable @escaping (PlayerEvent) async -> Void
    ) async {
        while !Task.isCancelled {
            guard let eventPtr = mpv_wait_event(handle, /*timeout*/ 5.0) else { continue }
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { continue }
            if event.event_id == MPV_EVENT_LOG_MESSAGE {
                let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
                if let line = MpvEventBridge.logLine(from: logPtr.pointee), line.level != "error" {
                    if let text = MpvEventBridge.diagnosticText(for: line) {
                        line.level == "warn" ? logger?.warn(text) : logger?.debug(text)
                    }
                    continue
                }
            }
            if let translated = MpvEventBridge.playerEvent(from: event) {
                await deliver(translated)
                if case .shutdown = translated { return }
            } else if event.event_id == MPV_EVENT_SHUTDOWN {
                return
            }
        }
    }
```

- [ ] **Step 6: Build and run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build OK; `Executed 594 tests, with 0 failures` (592 + 2).

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Player/MpvEventBridge.swift Sources/RPPlayer/Player/MpvPlayerEngine.swift Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift
git commit -m "feat(engine): forward mpv warn + ao verbose lines to app log

mpv log was requested at error level only, so the ao/coreaudio device
selection and AudioUnit warnings from a silent-play incident were lost.
Request v, forward warn + ao-prefixed info/v via the pump, keep error on
the .error event path.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Log hog acquire/release with device IDs and sample rates

**Files:**
- Modify: `Sources/RPPlayer/Audio/HogModeController.swift`
- Modify: `Sources/RPPlayer/App/AppContainer.swift:207`
- Test: `Tests/RPPlayerTests/Audio/HogModeControllerTests.swift`

**Interfaces:**
- Produces: `HogModeController.init(logger: (any Logging)? = nil)`; existing call sites using `HogModeController()` keep compiling.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/Audio/HogModeControllerTests.swift` inside the class:

```swift
    func testAcquireWithUnknownUIDLogsWarnWithUID() async {
        let logger = RecordingLogger()
        let controller = HogModeController(logger: logger)
        let uid = "definitely-not-a-real-uid-\(UUID().uuidString)"
        _ = await controller.acquire(deviceUID: uid)
        let warns = logger.entries().filter { $0.hasPrefix("[WARN]") && $0.contains(uid) }
        XCTAssertEqual(warns.count, 1, "expected one WARN naming the missing device, got \(logger.entries())")
    }

    func testReleaseWithoutAcquireLogsNothing() async {
        let logger = RecordingLogger()
        let controller = HogModeController(logger: logger)
        await controller.release()
        XCTAssertTrue(logger.entries().isEmpty, "unexpected log lines: \(logger.entries())")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HogModeControllerTests 2>&1 | tail -20`
Expected: compile error — `HogModeController` has no `init(logger:)`.

- [ ] **Step 3: Implement logging in HogModeController**

In `Sources/RPPlayer/Audio/HogModeController.swift`:

Replace the property block and init:

```swift
public actor HogModeController {
    private var hoggedDeviceID: AudioDeviceID?
    internal private(set) var originalSampleRate: Double?
    private let logger: (any Logging)?

    public init(logger: (any Logging)? = nil) {
        self.logger = logger
    }
```

Replace `acquire(deviceUID:)`:

```swift
    public func acquire(deviceUID: String) async -> Bool {
        guard let target = deviceID(forUID: deviceUID) else {
            logger?.warn("hog acquire: device '\(deviceUID)' not found")
            return false
        }
        if let current = hoggedDeviceID, current == target { return true }
        if hoggedDeviceID != nil {
            await releaseHog()
        }
        let savedRate = readSampleRate(deviceID: target)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = getpid()
        let setStatus = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        guard setStatus == noErr else {
            logger?.warn("hog acquire: set failed id=\(target) status=\(setStatus)")
            return false
        }
        var size = UInt32(MemoryLayout<pid_t>.size)
        var actual: pid_t = -1
        let getStatus = AudioObjectGetPropertyData(
            target, &address, 0, nil, &size, &actual
        )
        guard getStatus == noErr, actual == getpid() else {
            logger?.warn("hog acquire: verify failed id=\(target) status=\(getStatus) owner=\(actual)")
            return false
        }
        // RP streams are always 44.1 kHz; enforce matching hardware rate to
        // prevent CoreAudio resampling when the device is configured otherwise.
        let rateOK = await setSampleRateInternal(44100.0, deviceID: target, settle: true)
        if !rateOK {
            logger?.warn("hog acquire: setSampleRate(44100) failed id=\(target) — playback may resample")
        }
        hoggedDeviceID = target
        originalSampleRate = savedRate
        logger?.info("hog acquired id=\(target) rateBefore=\(savedRate.map { String($0) } ?? "nil") rateNow=\(readSampleRate(deviceID: target).map { String($0) } ?? "nil")")
        return true
    }
```

Replace `releaseHog()`:

```swift
    private func releaseHog() async {
        guard let target = hoggedDeviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        let status = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        hoggedDeviceID = nil
        var restored = "none"
        if let rate = originalSampleRate {
            // No settle sleep on restore — we are releasing, not about to open IO.
            let ok = await setSampleRateInternal(rate, deviceID: target, settle: false)
            restored = ok ? String(rate) : "failed(\(rate))"
            originalSampleRate = nil
        }
        logger?.info("hog released id=\(target) status=\(status) restoredRate=\(restored)")
    }
```

Delete the old `fputs("[HogModeController] setSampleRate(44100) failed …")` line (replaced by the warn above).

In `Sources/RPPlayer/App/AppContainer.swift:207` change `let hogController = HogModeController()` to `let hogController = HogModeController(logger: logger)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HogModeControllerTests 2>&1 | tail -20`
Expected: all pass, including the 6 pre-existing tests.

- [ ] **Step 5: Build and run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: `Executed 596 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Audio/HogModeController.swift Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/Audio/HogModeControllerTests.swift
git commit -m "feat(audio): log hog acquire/release with device id + sample rates

Every stop->play cycle restores the device's original rate then re-sets
44.1 kHz right before mpv opens the AudioUnit; none of it was logged.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Refuse Play while the held device is absent

**Files:**
- Modify: `Sources/RPPlayer/Playback/NowPlaying.swift:35-41` (`PlaybackCoordinatorError`)
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:77`, `:88`, `:224`, `:300`
- Modify: `Sources/RPPlayer/App/AppContainer.swift:278-289` (prePlayHook closure)
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

**Interfaces:**
- Produces: `PlaybackCoordinatorError.outputDeviceUnavailable(name: String)`; its `errorDescription` (existing `LocalizedError` extension) = `"<name> is disconnected — waiting for it to come back."`.
- Changes: `LivePlaybackCoordinator.init(... prePlayHook: @escaping @Sendable () async throws -> Void = {})`. Non-throwing closures at existing call sites still convert.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` inside the class, after `testPrePlayHookFiresBeforeEnginePlay`:

```swift
    func testPrePlayHookThrowingAbortsPlayBeforeEngine() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac"),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 },
            prePlayHook: { throw PlaybackCoordinatorError.outputDeviceUnavailable(name: "Test DAC") }
        )
        do {
            try await coord.play(channelId: 0)
            XCTFail("play must rethrow the hook error")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .outputDeviceUnavailable(name: "Test DAC"))
        }
        let calls = await engine.recordedCalls()
        let played = calls.contains { if case .play = $0 { return true } else { return false } }
        XCTAssertFalse(played, "engine.play must not run when the hook throws; calls=\(calls)")
        let state = await coord.currentPlaybackState
        XCTAssertNotEqual(state, .playing)
    }

    func testOutputDeviceUnavailableErrorDescription() {
        let error = PlaybackCoordinatorError.outputDeviceUnavailable(name: "Test DAC")
        XCTAssertEqual(error.localizedDescription, "Test DAC is disconnected \u{2014} waiting for it to come back.")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -20`
Expected: compile error — no `outputDeviceUnavailable` case / hook closure not allowed to throw.

- [ ] **Step 3: Add the error case + description**

In `Sources/RPPlayer/Playback/NowPlaying.swift` add a case to the enum:

```swift
public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case notPlaying
    case channelNotFound(channelId: Int)
    case blockHasNoSongs
    case engineError(message: String)
    case underlying(message: String)
    case outputDeviceUnavailable(name: String)
}
```

`PlaybackCoordinatorError` already conforms to `LocalizedError` in `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:1073-1088` with an exhaustive `switch`. Add the new case there, after `.underlying`:

```swift
        case .outputDeviceUnavailable(let name):
            return "\(name) is disconnected \u{2014} waiting for it to come back."
```

The compiler will flag any other exhaustive `switch` over the enum; there are none in `Sources` or `Tests` today.

- [ ] **Step 4: Make the hook throwing**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:

Line 77: `private let prePlayHook: @Sendable () async throws -> Void`
Line 88: `prePlayHook: @escaping @Sendable () async throws -> Void = {},`
Line 224: `try await prePlayHook()`
Line 300: `try await prePlayHook()`

- [ ] **Step 5: Throw from the AppContainer hook while the device is held**

In `Sources/RPPlayer/App/AppContainer.swift`, replace the `prePlayHook:` closure (currently at lines 278-289) with:

```swift
            prePlayHook: { [store, hogController, reattachState] in
                let held = await MainActor.run { (reattachState.heldUID, reattachState.lastKnownDeviceNames) }
                if let uid = held.0 {
                    throw PlaybackCoordinatorError.outputDeviceUnavailable(name: held.1[uid] ?? uid)
                }
                // Acquire hog BEFORE mpv opens the CoreAudio AO. Without this,
                // mpv's shared-mode AO open can race with hog acquisition (which
                // currently fires on the .playing state transition, after engine.play
                // returns) and end up registered but silent until the user toggles
                // pause+play to force an AO recreate. Especially visible when another
                // app (e.g. a YouTube tab) was already feeding the device.
                guard let store else { return }
                let s = await store.settings
                guard s.hogModeEnabled, let uid = s.outputDeviceUID, !uid.isEmpty else { return }
                _ = await hogController.acquire(deviceUID: uid)
            }
```

`reattachState` is declared at line 220, before the coordinator, so the capture is valid.

- [ ] **Step 6: Run coordinator tests, then the full suite**

Run: `swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -20`
Expected: pass.

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: `Executed 598 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/NowPlaying.swift Sources/RPPlayer/Playback/PlaybackCoordinator.swift Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(playback): refuse Play while the held output device is absent

Pressing Play with the DAC unplugged made mpv attempt AO init on a dead
device (end-file -14); that sequence preceded the only silent-play
incident on record. prePlayHook now throws outputDeviceUnavailable and
the popover shows the waiting message instead.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Docs

**Files:**
- Create: `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`
- Modify: `CHANGELOG.md` (`## [Unreleased]`), `docs/pr-history.md` (table + deferred), `docs/test-counts.md`, `docs/architecture.md` (one bullet), `CLAUDE.md` (Current state)

- [ ] **Step 1: Write the investigation note**

Create `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`:

```markdown
# DAC reattach → silent play (investigated 2026-09-03)

## Symptom
After the Qudelix-5K was unplugged and replugged, Play flipped to Pause, progress bar stayed at 0, no audio, no error. Relaunch fixed it.

## Log timeline (RPPlayer.log, 3 Sep)
- 12:52:52 device disappeared, hog on → app stopped mpv, held selection.
- 14:29:12 Play pressed while device still absent → mpv `[ao/coreaudio] could not check whether device is alive`, end-file -14.
- 14:30:40 device reappeared, hog re-acquired.
- 14:30:52 Play → fileStarted/fileLoaded, no mpv errors, time-pos stuck at 0, `loadfile append-play` blocked ~7s (mpv core thread stalled in CoreAudio).
- 14:32:39 relaunch → fine.

## What is known
- Reattach → Play worked in ~15 earlier occurrences (all five log files). This is the only "failed AO init on absent device, then reattach" sequence and the only silent play.
- mpv 0.36 `ao_coreaudio.c` `init()` is stateless on failure (checked against tag v0.36.0). Leftover state is in-process CoreAudio HAL / AudioUnit.
- Evidence gaps closed by PR 45: mpv log was error-only; hog acquire/release + sample-rate flips were unlogged.

## Open hypotheses (ranked)
1. Sample-rate flip immediately before AU open (release restores original rate, acquire re-sets 44.1 kHz, ~1 s before mpv `AudioUnitInitialize`) leaves the HAL mid-reconfigure on a freshly enumerated device → AU starts but never renders.
2. Stale HAL object for the old AudioDeviceID (touched by mpv's `DeviceIsAlive` query at 14:29) poisons the new device's IO in this process.

## If it recurs
Collect the `mpv[ao/coreaudio]` and `hog acquired/released` lines around the Play. If the AU "selected audio output device" ID differs from the hog `id=`, hypothesis 2. If `rateBefore != 44100`, hypothesis 1 — candidate fix: skip the rate restore on release-on-pause releases, or settle before `engine.play`.
Recovery candidate: if `time-pos` stays 0 for ~3 s after `fileLoaded`, issue mpv `ao-reload`.
```

- [ ] **Step 2: CHANGELOG**

Under `## [Unreleased]`, after the existing `### Added` bullet, add:

```markdown
- Pressing Play while the selected output device is disconnected (hog mode on) now shows "<Device> is disconnected — waiting for it to come back." instead of handing mpv an absent device.

### Changed

- Log: mpv `warn` lines and `ao*` verbose lines (device selection, AudioUnit warnings) are now written to the app log; hog acquire/release log the CoreAudio device ID and sample rate before/after. Diagnostics for the silent-playback-after-DAC-replug report (see `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`).
```

- [ ] **Step 3: pr-history**

Add a row after PR 44 in the status table:

```markdown
| 45   | claude/pr45-dac-reattach-diagnostics | ⏳ | DAC reattach diagnostics + Play guard (2026-09-03): mpv log requested at `v`, pump forwards `warn` (any prefix) + `info`/`v` with `ao` prefix via `MpvEventBridge.logLine`/`diagnosticText`; `error` stays on the `.error` event path. `HogModeController(logger:)` logs acquire/release with device id + rateBefore/rateNow/restoredRate. `prePlayHook` is now throwing; AppContainer throws `PlaybackCoordinatorError.outputDeviceUnavailable(name:)` while `DeviceReattachState.heldUID` is set (`LocalizedError` text surfaces in the popover). Investigation note in `docs/notes/`. 6 new tests. 598 tests. |
```

Add under `## Deferred / tech debt`:

```markdown
### PR 45 — Silent AO after DAC replug: root cause + recovery

Only one occurrence (3 Sep 2026). PR 45 adds the logging needed; when it recurs, follow `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`. Candidate recovery: `ao-reload` when `time-pos` stays 0 for ~3 s after `fileLoaded`.
```

- [ ] **Step 4: test-counts**

Append to `docs/test-counts.md`:

```markdown
- 2026-09-03: 592 → 598 (+6) — PR 45 DAC reattach diagnostics. `MpvEventBridgeTests`: logLine parses + trims (1), diagnosticText forwards warn + ao verbose only (1). `HogModeControllerTests`: unknown UID logs WARN with uid (1), release without acquire logs nothing (1). `LivePlaybackCoordinatorTests`: throwing prePlayHook aborts before engine.play (1), outputDeviceUnavailable errorDescription (1).
```

- [ ] **Step 5: architecture.md**

Add one bullet in the logging section (near the `AppLogger` bullet at line ~140):

```markdown
- **mpv log level is `v`, filtered in the engine pump.** `mpv_request_log_messages(h, "v")` so `[ao/coreaudio]` device-selection lines exist at all; `MpvEventBridge.diagnosticText` forwards `warn` (any prefix) and `ao*`-prefixed `info`/`v` to `Logging`, drops the rest, and `error` still becomes `PlayerEvent.error`. Don't lower the request level back to `error` — the 2026-09-03 silent-play incident had zero evidence because of it.
```

- [ ] **Step 6: CLAUDE.md**

Replace the *Current state* "Last merged" line with:

```markdown
- Last merged: **PR 45** — DAC reattach diagnostics + Play guard. mpv `warn` + `ao*` verbose lines and hog acquire/release (device id, sample rates) now reach the app log; Play while the held device is absent shows a waiting message instead of a failed mpv AO init. Investigation note: `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`. 6 new tests. 598 tests.
```

Keep the *Released* and *Next up* lines; set *Next up* to: `TBD — if the silent-play-after-replug recurs, read the new log lines per the PR 45 note; otherwise pick from the deferred list.`

- [ ] **Step 7: Verify and commit**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 598 tests, with 0 failures`.

```bash
git add docs CHANGELOG.md CLAUDE.md
git commit -m "docs(pr45): document DAC reattach diagnostics + investigation note

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- Coverage: log forwarding (T1), hog logging (T2), Play guard (T3), docs incl. note (T4). Optional `ao-reload` recovery deliberately deferred (recorded in pr-history).
- Names used consistently: `MpvLogLine`, `MpvEventBridge.logLine(from:)`, `MpvEventBridge.diagnosticText(for:)`, `HogModeController(logger:)`, `PlaybackCoordinatorError.outputDeviceUnavailable(name:)`, throwing `prePlayHook`.
- Known unknown flagged in T3 Step 1: the `MockPlayerEngine` accessor name for recorded plays.
