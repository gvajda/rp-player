# PR 46 — DAC Reattach Settle + Stuck-AO Recovery Message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the "silent play after DAC replug" bug by not touching the device during its USB bring-up, and tell the user to relaunch if the in-process CoreAudio HAL still gets stuck.

**Architecture:** The reattach watcher in `AppContainer` currently sets hog + nominal rate + volume ~80 ms after the device reappears, inside the USB driver's own config change. The in-process HAL client then processes a burst of `PauseIO`/`ResumeIO` on multiple threads, one `ResumeIO` is clamped at zero, and the device's IO stays disabled for the life of the process (`HALB_IOThread::_Start: IO is still disabled after waiting` → `AudioOutputUnitStart` error 35). mpv 0.36's `ao_coreaudio` `start()` only warns on that error, so playback looks alive with `time-pos` stuck at 0. Fix: (1) the watcher defers all device writes — skip them entirely when release-on-pause is on (Play acquires via `prePlayHook`), otherwise wait a 2 s settle; (2) the engine turns mpv's `can't start audio unit` warn into a `PlayerEvent.audioOutputStartFailed`; (3) the coordinator stops and tells the user to quit and reopen the app.

**Tech Stack:** Swift 6.2, macOS 14, CoreAudio, libmpv 0.36, XCTest. `swift build` / `swift test`.

**Spec:** Investigation in this session, recorded in `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md` (Task 4 appends the resolution). Evidence lines: app log `.temp/LinkedAppFolder/RP Player/Logs/RPPlayer.log` 2026-09-05T19:07:45Z–19:11:50Z; unified log (`/usr/bin/log show`, process `RP Player`, sender `CoreAudio`) 21:07:45–21:07:46 CEST and 21:11:43–21:11:50 CEST.

## Global Constraints

- Branch: `claude/pr46-dac-reattach-settle` off `claude/pr45-dac-reattach-diagnostics` (PR 45 not merged yet; this builds on its logging). Rebase onto `main` after PR 45 lands if needed. Merge `--ff-only`.
- Comment policy: no comments unless the WHY is non-obvious; single `//` line max. Mark deliberate shortcuts with `// ponytail:`.
- Every task ends with `swift test` green. Test count starts at 600.
- CHANGELOG audience is end users. Cut `## [v1.1.1] - 2026-09-05` inside this PR (CI publishes on merge to `main`).
- Do not change `HogModeController` sample-rate behaviour (the 48 kHz restore on release is not the trigger; deferred).

---

### Task 1: Reattach watcher — defer device writes until the DAC has settled

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift:812-839` (`spawnReattachWatcher`)
- Test: `Tests/RPPlayerTests/DeviceReattachTests.swift`

**Interfaces:**
- Consumes: `HogModeController(logger:)` logs `[WARN] hog acquire: device '<uid>' not found` on acquire of an unknown UID (`RecordingLogger` in `Tests/RPPlayerTests/Helpers/RecordingLogger.swift` captures it; entries are prefixed `[WARN]`/`[INFO]`).
- Produces: `AppContainer.spawnReattachWatcher(heldUID:catalog:hogController:volumeController:store:logger:settle:onReattached:) -> Task<Void, Never>` with new parameter `settle: Duration = .seconds(2)`. Existing callers (`AppContainer.swift:263` and `:401`) keep using the default.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/DeviceReattachTests.swift` inside the class, after `testSpawnReattachWatcherDoesNotFireAfterCancellation`:

```swift
    func testSpawnReattachWatcherSkipsHogWhenReleaseOnPauseIsOn() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "rop-uid"
            $0.hogModeEnabled = true
            $0.releaseHogOnPauseEnabled = true
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogLogger = RecordingLogger()
        let hogController = HogModeController(logger: hogLogger)

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "rop-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: DeviceVolumeController(),
            store: store,
            logger: makeLogger(),
            settle: .zero,
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 150_000_000)
        lister.setDevices([AudioDevice(uid: "rop-uid", name: "ROP DAC", transportType: .usb)])
        await catalog.reload()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(reattachCalled)
        let acquires = hogLogger.entries().filter { $0.contains("hog acquire") }
        XCTAssertTrue(acquires.isEmpty, "watcher must not touch the device when release-on-pause is on: \(acquires)")
    }

    func testSpawnReattachWatcherAcquiresAfterSettleWhenHogIsHeldWhileIdle() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "hold-uid"
            $0.hogModeEnabled = true
            $0.releaseHogOnPauseEnabled = false
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogLogger = RecordingLogger()
        let hogController = HogModeController(logger: hogLogger)

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "hold-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: DeviceVolumeController(),
            store: store,
            logger: makeLogger(),
            settle: .milliseconds(100),
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 150_000_000)
        lister.setDevices([AudioDevice(uid: "hold-uid", name: "Hold DAC", transportType: .usb)])
        await catalog.reload()

        // Before the settle window elapses nothing may have touched the device.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(hogLogger.entries().filter { $0.contains("hog acquire") }.isEmpty)
        XCTAssertFalse(reattachCalled)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(reattachCalled)
        let acquires = hogLogger.entries().filter { $0.contains("hog acquire") && $0.contains("hold-uid") }
        XCTAssertEqual(acquires.count, 1, "expected one acquire attempt after settle: \(hogLogger.entries())")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DeviceReattachTests`
Expected: compile error `extra argument 'settle' in call`.

- [ ] **Step 3: Implement**

Replace `spawnReattachWatcher` in `Sources/RPPlayer/App/AppContainer.swift` with:

```swift
    static func spawnReattachWatcher(
        heldUID: String,
        catalog: CoreAudioDeviceCatalog,
        hogController: HogModeController,
        volumeController: DeviceVolumeController,
        store: JSONConfigStore,
        logger: any Logging,
        settle: Duration = .seconds(2),
        onReattached: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { [catalog, hogController, volumeController, store, logger] in
            let stream = await catalog.changes
            for await devices in stream {
                if Task.isCancelled { return }
                guard devices.contains(where: { $0.uid == heldUID }) else { continue }
                let s = await store.settings
                // Writing hog/rate/volume while the USB driver is still configuring the
                // freshly enumerated device races the HAL client's IO pause counter and
                // leaves IO disabled for the life of the process (see PR 46 note).
                // Release-on-pause: nothing is playing, prePlayHook acquires at Play.
                if s.releaseHogOnPauseEnabled {
                    logger.info("held device '\(heldUID)' reappeared; hog deferred to Play (release-on-pause)")
                } else {
                    logger.info("held device '\(heldUID)' reappeared; re-acquiring hog after settle")
                    // ponytail: fixed settle; poll for a quiet config-change window if it recurs
                    try? await Task.sleep(for: settle)
                    if Task.isCancelled { return }
                    _ = await hogController.acquire(deviceUID: heldUID)
                    if s.volumeMode == .forceMax {
                        _ = await volumeController.setVolumeMax(deviceUID: heldUID)
                    }
                }
                await MainActor.run { onReattached() }
                return
            }
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DeviceReattachTests`
Expected: PASS (4 existing + 2 new). The existing `testSpawnReattachWatcherReacquiresOnReappear` sets `hogModeEnabled = true` with default `releaseHogOnPauseEnabled` (true) → takes the deferred branch, callback still fires within its 200 ms window.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/DeviceReattachTests.swift
git commit -m "fix(hog): defer device writes on DAC reattach until the driver has settled"
```

---

### Task 2: Engine — surface mpv "can't start audio unit" as a PlayerEvent

**Files:**
- Modify: `Sources/RPPlayer/Player/PlayerEngine.swift:32-40` (`PlayerEvent`)
- Modify: `Sources/RPPlayer/Player/MpvEventBridge.swift:20-30` (add predicate)
- Modify: `Sources/RPPlayer/Player/MpvPlayerEngine.swift:187-194` (pump)
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:712` (exhaustive switch — temporary `break`, Task 3 replaces it)
- Test: `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift`

**Interfaces:**
- Produces: `PlayerEvent.audioOutputStartFailed` (no payload). `MpvEventBridge.isAudioOutputStartFailure(_ line: MpvLogLine) -> Bool`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift` inside the class:

```swift
    func testIsAudioOutputStartFailureMatchesCoreaudioStartWarnOnly() {
        XCTAssertTrue(MpvEventBridge.isAudioOutputStartFailure(
            MpvLogLine(level: "warn", prefix: "ao/coreaudio", text: "can't start audio unit ([35][0][0][0]/35)")))
        XCTAssertFalse(MpvEventBridge.isAudioOutputStartFailure(
            MpvLogLine(level: "warn", prefix: "ao/coreaudio", text: "can't reset audio unit (x)")))
        XCTAssertFalse(MpvEventBridge.isAudioOutputStartFailure(
            MpvLogLine(level: "v", prefix: "ao/coreaudio", text: "can't start audio unit (x)")))
        XCTAssertFalse(MpvEventBridge.isAudioOutputStartFailure(
            MpvLogLine(level: "warn", prefix: "demux", text: "can't start audio unit")))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MpvEventBridgeTests`
Expected: compile error `type 'MpvEventBridge' has no member 'isAudioOutputStartFailure'`.

- [ ] **Step 3: Implement**

`Sources/RPPlayer/Player/PlayerEngine.swift` — add a case to `PlayerEvent` after `outputDeviceChanged`:

```swift
    case audioOutputStartFailed
```

`Sources/RPPlayer/Player/MpvEventBridge.swift` — add after `diagnosticText(for:)`:

```swift
    // mpv 0.36 ao_coreaudio start() only warns when AudioOutputUnitStart fails; the
    // core keeps "playing" with time-pos stuck at 0, so this warn is the only signal.
    static func isAudioOutputStartFailure(_ line: MpvLogLine) -> Bool {
        line.level == "warn" && line.prefix == "ao/coreaudio" && line.text.hasPrefix("can't start audio unit")
    }
```

`Sources/RPPlayer/Player/MpvPlayerEngine.swift` — in `pump`, replace the `MPV_EVENT_LOG_MESSAGE` block:

```swift
            if event.event_id == MPV_EVENT_LOG_MESSAGE {
                let logPtr = event.data.assumingMemoryBound(to: mpv_event_log_message.self)
                if let line = MpvEventBridge.logLine(from: logPtr.pointee), line.level != "error" {
                    if let text = MpvEventBridge.diagnosticText(for: line) {
                        (line.level == "warn" || line.level == "fatal") ? logger?.warn(text) : logger?.info(text)
                    }
                    if MpvEventBridge.isAudioOutputStartFailure(line) {
                        await deliver(.audioOutputStartFailed)
                    }
                    continue
                }
            }
```

`Sources/RPPlayer/Playback/PlaybackCoordinator.swift:712` — make the switch compile:

```swift
        case .outputDeviceChanged, .shutdown, .audioOutputStartFailed:
            break
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS, 603 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/PlayerEngine.swift Sources/RPPlayer/Player/MpvEventBridge.swift Sources/RPPlayer/Player/MpvPlayerEngine.swift Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Player/MpvEventBridgeTests.swift
git commit -m "feat(engine): emit audioOutputStartFailed when mpv cannot start the audio unit"
```

---

### Task 3: Coordinator — stop and tell the user to relaunch

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:709-714` (`handleEngineEvent`)
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PlayerEvent.audioOutputStartFailed` (Task 2), `MockPlayerEngine.fire(_:)`, `LivePlaybackCoordinator.errors: AsyncStream<String>`, existing public `stop()`.
- Produces: user message `"Audio output failed to start after the device reconnected. Quit and reopen RP Player to restore sound."` on `errors`. The VM already subscribes to `errors` (sets `errorMessage`, `isPlaying = false`, opens the popover).

- [ ] **Step 1: Write the failing test**

Append inside `LivePlaybackCoordinatorTests`, after `testEngineErrorCode14ClearsAllStateAndYieldsDeviceMessage`:

```swift
    /// audioOutputStartFailed: the AU never renders, so stop and tell the user to relaunch.
    func testAudioOutputStartFailedStopsAndYieldsRelaunchMessage() async throws {
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
        await engine.fire(.audioOutputStartFailed)

        let message = await errorTask.value
        XCTAssertEqual(
            message,
            "Audio output failed to start after the device reconnected. Quit and reopen RP Player to restore sound."
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        let np = await coord.nowPlaying
        XCTAssertNil(np, "playback must be stopped — the AU will never render in this process")
        let state = await coord.currentPlaybackState
        XCTAssertEqual(state, .stopped)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LivePlaybackCoordinatorTests/testAudioOutputStartFailedStopsAndYieldsRelaunchMessage`
Expected: FAIL — `errorTask` never resolves (test hangs on `await errorTask.value`) or `nowPlaying` non-nil. If it hangs, that is the failing signal; proceed.

- [ ] **Step 3: Implement**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` `handleEngineEvent`, replace the temporary line from Task 2:

```swift
        case .audioOutputStartFailed:
            logger.error("audio unit failed to start; stopping (in-process CoreAudio IO is stuck until relaunch)")
            try? await stop()
            errorsContinuation?.yield(
                "Audio output failed to start after the device reconnected. Quit and reopen RP Player to restore sound."
            )

        case .outputDeviceChanged, .shutdown:
            break
```

Check `stop()` (`PlaybackCoordinator.swift`, search `public func stop()`): it must clear the engine playlist, reset queue/current state and `emitState(.stopped)`. If `stop()` throws `notPlaying` when the queue is empty, the `try?` swallows it — acceptable.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS, 604 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "fix(playback): stop and ask for relaunch when the audio unit cannot start"
```

---

### Task 4: Docs + release cut

**Files:**
- Modify: `CHANGELOG.md` (cut v1.1.1)
- Modify: `docs/pr-history.md` (row 46 + deferred section)
- Modify: `docs/test-counts.md` (append)
- Modify: `docs/architecture.md` (Audio pipeline bullet)
- Modify: `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md` (append resolution)
- Modify: `CLAUDE.md` (Current state)

- [ ] **Step 1: CHANGELOG**

Replace the top of `CHANGELOG.md` (`## [Unreleased]` line) with:

```markdown
## [Unreleased]

## [v1.1.1] - 2026-09-05

### Fixed

- **No sound after reconnecting a USB DAC.** Unplugging and replugging the selected DAC, then pressing Play, could leave the app looking like it was playing with no audio and the progress bar stuck at 0 until you relaunched. The app now waits for the device to finish initialising before taking it over, which avoids the macOS audio glitch that caused this. If the glitch still happens, playback stops and a message asks you to quit and reopen RP Player instead of playing silently.
```

- [ ] **Step 2: pr-history**

Add after the PR 45 row in the status table of `docs/pr-history.md`:

```markdown
| 46   | claude/pr46-dac-reattach-settle | ⏳ | DAC reattach settle + stuck-AO recovery (2026-09-05): root cause of the silent-play-after-replug bug found via unified log — `spawnReattachWatcher` wrote hog/rate/volume ~80 ms after device activation, inside the USB driver's `RequestConfigChange`; the in-process HAL client's `PauseIO`/`ResumeIO` on the device's IO context raced across threads, one resume clamped at 0, IO stayed disabled for the process (`HALB_IOThread::_Start: IO is still disabled after waiting` → `AudioOutputUnitStart` error 35). mpv 0.36 `ao_coreaudio.start()` only warns, so the core "plays" with `time-pos` 0. Fix: watcher skips device writes when release-on-pause is on (Play acquires via `prePlayHook`), otherwise sleeps `settle` (default 2 s) first. New `PlayerEvent.audioOutputStartFailed` from `MpvEventBridge.isAudioOutputStartFailure` (warn `ao/coreaudio` `can't start audio unit`); coordinator stops and yields a relaunch message. 4 new tests. 604 tests. Ships as v1.1.1. |
```

Replace the deferred entry `### PR 45 — Silent AO after DAC replug: root cause + recovery` and its paragraph with:

```markdown
### PR 46 — DAC reattach follow-ups

- Reattach watcher missed two reappearances (3 Sep 12:52→14:29, 5 Sep 17:26→17:38): the device came back with no `reappeared` line and hog was never re-acquired. `CoreAudioDeviceCatalog.changes` delivery after a lost device needs a look.
- `HogModeController.releaseHog` restores the pre-hog rate (48 kHz on the Qudelix) on every pause when release-on-pause is on, so each pause/resume is two device config changes under a live AUHAL. Balanced in the 5 Sep log, but skip the restore on release-on-pause releases if a pause-time drift ever shows up.
- In-process recovery is not possible: a new AUHAL on the same device inherits the disabled IO state. Only relaunch (or unplug/replug creating a new device object — unverified) clears it.
```

- [ ] **Step 3: test-counts**

Append to `docs/test-counts.md`:

```markdown
- 2026-09-05: 600 → 604 (+4) — PR 46 DAC reattach settle + stuck-AO recovery. `DeviceReattachTests`: watcher skips hog when release-on-pause is on (1), watcher acquires once after settle when hog is held while idle (1). `MpvEventBridgeTests`: isAudioOutputStartFailure matches coreaudio start warn only (1). `LivePlaybackCoordinatorTests`: audioOutputStartFailed stops and yields relaunch message (1).
```

- [ ] **Step 4: architecture**

In `docs/architecture.md` under `## Audio pipeline`, add a bullet after the **Release-on-pause** bullet:

```markdown
- **Never write to a USB device during its bring-up (PR 46).** The reattach watcher (`AppContainer.spawnReattachWatcher`) used to set hog + 44.1 kHz + volume ~80 ms after the device reappeared, while the USB driver's own `RequestConfigChange` was in flight. The in-process HAL client then delivers `HALC_ProxyIOContext::PauseIO`/`ResumeIO` for the device's IO context on several threads; one `ResumeIO` gets clamped at count 0 and the matching pause is never undone, so IO on that device stays disabled for the life of the process (`HALB_IOThread::_Start: IO is still disabled after waiting`, `AudioOutputUnitStart` → 35). A fresh AUHAL on the same device inherits the state; only relaunch clears it. mpv 0.36 `ao_coreaudio.c` `start()` is `void` + `CHECK_CA_WARN`, so the core keeps "playing" with `time-pos` at 0 — no error surfaces. The watcher now skips device writes when release-on-pause is on (Play acquires in `prePlayHook`, minutes later on a settled device) and otherwise sleeps `settle` (2 s; the observed driver config change took 0.9 s). `MpvEventBridge.isAudioOutputStartFailure` turns the warn into `PlayerEvent.audioOutputStartFailed`; the coordinator stops and asks the user to relaunch. Diagnose with `/usr/bin/log show --predicate 'process == "RP Player" AND sender CONTAINS "CoreAudio"' --info --debug` (note: zsh shadows `log` with a builtin).
```

- [ ] **Step 5: investigation note**

Append to `docs/notes/pr45-dac-reattach-investigation-2026-09-03.md`:

```markdown

## Resolved (2026-09-05, PR 46)

Recurred 5 Sep with PR 45 logging on. App log: `hog acquired id=17683 rateBefore=48000.0 rateNow=48000.0` 80 ms after `reappeared`; Play 4 min later → AUHAL init fine, 7 s stall, `mpv[ao/coreaudio] can't start audio unit ([35][0][0][0]/35)`, `time-pos` 0 on every skip.

Unified log (`/usr/bin/log show`, process `RP Player`, sender `CoreAudio`):
- 21:07:45.344 coreaudiod `HALS_PlugInDevice::HandlePlugIn_RequestConfigChange` (driver bring-up, returned 46.198, restarting IO 46.230).
- 21:07:45.345–46.276 our process: `HALC_ProxyIOContext::PauseIO/ResumeIO` on IO context 446040 across 5 threads; a `ResumeIO` at 45.609 lands at count 0 (`-> 0 0 0 <- 0 0 0`, clamped); pause at 46.0299 never resumed; final `ResumeIO: <- 0 1 1`. Counter still 1 at 21:13.
- 21:11:45.403 `HALB_IOThread::_Start: IO is still disabled after waiting`; 21:11:50.675 `HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState returned error 35`.
- Baseline: acquire on an already-44.1 kHz device (4 Sep 20:56) produces no HAL lines at all.

Hypothesis 1 was directionally right (rate flip on a fresh device) but the mechanism is the HAL client pause-counter race, not resampling. Hypothesis 2 ruled out (AUHAL and hog ids match: 17683). mpv is stateless as expected. Fix in PR 46: no device writes during bring-up + relaunch message when the warn appears.
```

- [ ] **Step 6: CLAUDE.md**

Replace the *Current state* block's first two bullets with:

```markdown
- Last merged: **PR 46** — DAC reattach settle + stuck-AO recovery. Root cause of silent-play-after-replug: reattach watcher wrote hog/rate/volume during the USB driver's bring-up config change → in-process HAL IO pause counter drifted → IO disabled for the process; mpv 0.36 only warns. Watcher now defers device writes (skip when release-on-pause, else 2 s settle); `PlayerEvent.audioOutputStartFailed` stops playback with a relaunch message. 4 new tests. 604 tests.
- **Released:** **v1.1.1** (2026-09-05, published automatically when PR 46 merged to `main`). Previous: v1.1.0 (2026-09-03, PR 44–45), v1.0.0 (2026-06-09).
```

and the *Next up* bullet with:

```markdown
- **Next up:** TBD — deferred list in `docs/pr-history.md` (reattach watcher missed reappearances is the closest follow-up).
```

- [ ] **Step 7: Verify and commit**

Run: `swift test 2>&1 | tail -3` — expect `Executed 604 tests, with 0 failures`.
Run: `scripts/extract-changelog.sh v1.1.1` — expect the Fixed section printed, exit 0.

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md docs/architecture.md docs/notes/pr45-dac-reattach-investigation-2026-09-03.md CLAUDE.md
git commit -m "docs: PR 46 DAC reattach settle, cut v1.1.1"
```

---

## Manual verification (after merge, on the real Qudelix)

1. Settings: hog on, release-on-pause on. Play, pause, unplug DAC, wait 5 s, replug, wait 10 s, Play. Expect app log: `reappeared; hog deferred to Play`, then at Play `hog acquired ... rateBefore=48000.0`, no `can't start audio unit`, audio audible, progress moves.
2. Settings: release-on-pause off. Same sequence. Expect `re-acquiring hog after settle` then `hog acquired` ≥2 s later.
3. If `can't start audio unit` still appears: popover shows the relaunch message and playback state is stopped. Collect `/usr/bin/log show --start "<t-10s>" --end "<t+10s>" --predicate 'process == "RP Player" AND sender CONTAINS "CoreAudio"' --info --debug` for the reattach window.
