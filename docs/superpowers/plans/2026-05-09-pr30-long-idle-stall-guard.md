# PR 30 — Long-idle resume stall guard

**Branch:** `claude/pr30-long-idle-stall-guard`
**Base:** `main` (last merged: PR 29 update checker, 432 tests)
**Scope:** small, surgical. Two changes: (1) coordinator-side watchdog after long-idle refetch + retry; (2) tighter mpv `network-timeout` in engine baseline.

---

## Why

Reproduced 2026-05-08 on `main`:

```
15:29:39 pause()
19:42:52 resume()                          (4h13m idle = 15192s ≥ 3540s)
         long idle path triggered
19:42:52 GET api/play?action=start&...     (refetch OK)
19:42:53 play engine.play startSeconds=689.555
19:42:53 engine fileEnded: stopped         (old file torn down — normal)
19:42:57 engine fileLoaded                 (~4.5s — demuxer headers OK)
         <2m25s of silence — no positionUpdate>
19:45:02 user pause()
19:45:02 user resume() → engine.resume()   (audio resumes immediately)
19:45:17 [ERROR] tcp: ffurl_read returned 0xdfb9b0bb
                 (the OLD stuck connection finally surfacing)
```

Diagnosis: HTTP read to `audio-geo.radioparadise.com` stalled mid-stream after demuxer headers came in. mpv loaded the file, never started the AO because the audio-byte buffer wasn't filling. The user's manual pause+resume kicked a fresh TCP connection and audio recovered. The lingering `ffurl_read` eventually returned an FFmpeg I/O error (0xdfb9b0bb) — but only ~15s after the pause, by which time the user had already worked around it.

Why long-idle is the riskiest case:

- 4h+ idle gives time for Wi-Fi reassoc / VPN reconnect / mac sleep — network-state transitions that can leave a half-open socket on either side.
- The CDN's edge layer may have stale TCP state.
- We're rebuilding playback from scratch (`engine.play(replace)`), so a stalled load means total silence, not a brief gap.

Existing 59-min refetch threshold (`Self.longIdleResumeThresholdSeconds = 59 * 60`) defends against the OUTBOUND side closing connections during the idle. It does NOT protect against the NEW connection itself stalling after handshake. PR 30 closes that gap.

---

## Scope (final)

1. **Watchdog in `LivePlaybackCoordinator.resume()`'s long-idle/expired branch** — after the awaited `play(channelId:)` returns (i.e. `engine.play` has been issued), spawn a Task that waits for the first `positionUpdate` engine event within 10s. Timeout → `engine.stop()` + retry `engine.play(url:startSeconds:)` once with the same URL/start. Second timeout → emit a user-facing error via `errorsContinuation` ("Playback stalled. Try Pause/Play to recover.") and call existing state-cleanup. Cancelled by every state-cleanup site (next `play`, `stop`, `changeChannel`, `pause`, `handlePlaybackError`, `shutdown`, prefetch swap).

2. **`network-timeout=15` in `MpvPlayerEngine` baseline options** — default is 60s. Reduces the window where a stuck `ffurl_read` keeps mpv blocked before it surfaces as `MPV_END_FILE_REASON_ERROR` and the existing `handlePlaybackError(code:)` recovery path takes over. Engine-wide; benefits every playback path, not just long-idle.

**Out of scope:**

- `paused-for-cache` property observer (option #2 from the brainstorm). Larger surgery — new property observer + dispatcher in `MpvPlayerEngine` and `MpvEventBridge`. Watchdog + tighter timeout cover the failure mode without it. Reconsider if PR 30 lands and stalls still slip through.
- Watchdog on non-resume paths (channel switch, normal song-boundary swap). Those are cheap to recover via user action; adding watchdogs there risks masking real CDN issues that should fail loud.
- Server-driven retry-with-different-URL. The same URL is fine — we know it works (manual pause+resume proves it). The issue is mpv's stuck socket, not the resource.

---

## Implementation sketch

### Engine baseline (`Sources/RPPlayer/Player/MpvPlayerEngine.swift`)

Add one line to the `baseline` tuple list (around line 56):

```swift
("prefetch-playlist", "yes"),
("network-timeout", "15"),  // default 60s; fail stuck ffurl_read fast → error event triggers handlePlaybackError recovery
```

That's it engine-side. Existing `handlePlaybackError(code:)` already handles `fileEnded(reason: .error(code:))` events with user-facing error strings.

### Coordinator watchdog (`Sources/RPPlayer/Playback/PlaybackCoordinator.swift`)

State:

```swift
private var stallWatchdog: Task<Void, Never>?
private static let stallWatchdogTimeoutSeconds: TimeInterval = 10
```

Helper:

```swift
private func cancelStallWatchdog() {
    stallWatchdog?.cancel()
    stallWatchdog = nil
}
```

Arm site — only the long-idle/expired branch of `resume()`:

```swift
if (longIdle || blockExpired), let channelId = currentChannelId {
    // ... existing logging + clearPlaylist + state reset ...
    try await play(channelId: channelId)
    armLongIdleStallWatchdog()
    return
}
```

`armLongIdleStallWatchdog()` body:

```swift
private func armLongIdleStallWatchdog() {
    cancelStallWatchdog()
    let block = currentBlock
    let startSeconds = currentSongStartSeconds  // for retry
    stallWatchdog = Task { [weak self] in
        guard let self else { return }
        // attempt 1: wait for first positionUpdate
        if await self.waitForFirstPositionUpdate(timeout: Self.stallWatchdogTimeoutSeconds) { return }
        if Task.isCancelled { return }
        await self.logger.info("stall watchdog: no positionUpdate within \(Int(Self.stallWatchdogTimeoutSeconds))s; retrying engine.play")
        // retry: engine.stop + engine.play with same URL/start
        guard let block = block, let url = URL(string: block.url) else {
            await self.surfaceStallError(); return
        }
        do {
            try await self.engine.stop()
            try await self.engine.play(url: url, startSeconds: startSeconds)
        } catch {
            await self.surfaceStallError(); return
        }
        // attempt 2
        if await self.waitForFirstPositionUpdate(timeout: Self.stallWatchdogTimeoutSeconds) { return }
        if Task.isCancelled { return }
        await self.surfaceStallError()
    }
}
```

`waitForFirstPositionUpdate(timeout:)` — race a sleep against the coordinator's existing multi-subscriber `positionUpdates` AsyncStream:

```swift
private func waitForFirstPositionUpdate(timeout: TimeInterval) async -> Bool {
    let stream = positionUpdates  // multi-subscriber, per-call continuation
    let snapshot = currentPositionSeconds
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await pos in stream {
                if pos > snapshot { return true }  // ignore the seeded initial value
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
```

(Snapshot-vs-new comparison handles the case where `positionUpdates` seeds the subscriber with the existing `currentPositionSeconds` — without the comparison the watchdog would return `true` immediately on the seeded value.)

`surfaceStallError()` — reuse existing error path:

```swift
private func surfaceStallError() async {
    cancelStallWatchdog()
    errorsContinuation.yield("Playback stalled. Try Pause/Play to recover.")
    // mirror handlePlaybackError state cleanup
    try? await engine.stop()
    try? await engine.clearPlaylist()
    queuedToEngine = false
    prefetchTask?.cancel(); prefetchTask = nil; prefetchedBlock = nil
    currentBlock = nil; orderedSongs = []; startsAt = []; currentSongIndex = 0
    currentPositionSeconds = 0; pausedAt = nil; pausePositionMs = 0
    currentChannelId = nil
    emitState(.stopped)
}
```

Cancel sites — call `cancelStallWatchdog()` at top of:

- `play(channelId:)` — watchdog from previous resume must die before new playback arms its own.
- `stop()` — already clears state; clear watchdog too.
- `changeChannel(to:)` — same reason.
- `pause()` — user-initiated pause is a definitive "stop waiting" signal.
- `handlePlaybackError(code:)` — engine already failed; watchdog has nothing useful to add.
- `shutdown()` — process exit.
- `swapToPrefetchedBlockState()` / `swapToPrefetchedBlockIfAvailable()` — successful swap = audio is flowing, watchdog no longer relevant. (Edge: prefetched-block swap during the watchdog's window means the original engine.play succeeded long enough to prefetch. Cancelling is correct.)

Note: the watchdog in resume() arms AFTER `play(channelId:)` completes — so when `play()` cancels it on entry, that's fine because we re-arm immediately after. The cancel-on-entry guards re-entrance.

---

## Tests (new — target ~6 new, total 438)

In `Tests/RPPlayerTests/Player/PlaybackCoordinatorTests.swift` (or a new `PlaybackCoordinatorStallWatchdogTests.swift` if the file is unwieldy):

1. **`testLongIdleResumeWatchdogClearsOnFirstPositionUpdate`** — pause for 60+ min in test clock, resume, drive a positionUpdate within the watchdog window. Assert: no engine.stop/replay called, no error emitted.
2. **`testLongIdleResumeWatchdogRetriesAfterTimeout`** — pause 60+ min, resume, no positionUpdate within 10s of test clock. Assert: engine.stop called once + engine.play called twice total (once from `play(channelId:)`, once from retry).
3. **`testLongIdleResumeWatchdogSurfacesErrorAfterDoubleTimeout`** — pause 60+ min, resume, no positionUpdate within either attempt. Assert: errorsContinuation yields "Playback stalled. Try Pause/Play to recover.", state is reset (currentBlock == nil), emitState(.stopped) fired.
4. **`testStallWatchdogCancelledByStop`** — arm watchdog (long-idle resume path), call `stop()` before timeout, verify no retry occurs after the would-be-timeout instant.
5. **`testStallWatchdogCancelledByPause`** — same but with pause.
6. **`testStallWatchdogNotArmedOnFreshBlockResume`** — pause < 59 min, resume, drive no positionUpdate. Verify no retry — fresh-block path doesn't arm.

Engine-side: no new tests for `network-timeout=15`. The option string is set the same way as the other baseline options (covered by `LibmpvLinkageTests` indirectly — if the option name is unknown libmpv would log a warning but not fail). Could add a verification test reading the property back via `mpv_get_property_string` — match the pattern used by `prefetchPlaylistOptionForTesting()`.

Test infrastructure: existing `MockClock` + `StubEngine` + `StubRpApiClient` already cover what we need. Watchdog timing tests will use `Task.yield()` / `await fulfillment` patterns from the existing `testResumeRefetchesAfterLongIdle` test as the template.

Time control: the watchdog uses real `Task.sleep`, not the injected clock. For deterministic tests, either (a) inject the sleep function (`@Sendable (UInt64) async -> Void`) into the coordinator alongside `clock`, defaulting to `Task.sleep(nanoseconds:)`, or (b) keep real sleeps but lower the timeout to e.g. 50ms in tests via a test-only `setStallWatchdogTimeoutForTesting(_:)` method. Option (a) is cleaner — follow the existing `clock` injection pattern. Pre-existing `pollUntil` helper in tests can drive the position-update yield.

---

## Subagent task breakdown

Per `superpowers:subagent-driven-development`. Each task ends with the code building + tests passing.

- **Task 1 — Engine `network-timeout=15`.** One-line baseline option add. Optional verification test via `mpv_get_property_string`. Tiny task; acceptable to merge with Task 2 if review preference is fewer commits.
- **Task 2 — Coordinator watchdog state + helper + cancel sites.** Add `stallWatchdog` field, `cancelStallWatchdog()`, inject `sleep` function alongside `clock`, no behavior change yet (helper unused). Wire `cancelStallWatchdog()` into all listed cancel sites. Builds + 432 tests still pass.
- **Task 3 — Watchdog body + arm site in resume().** Add `armLongIdleStallWatchdog()`, `waitForFirstPositionUpdate`, `surfaceStallError`. Arm at end of long-idle/expired branch in `resume()`. Behavior live, no tests yet. Builds.
- **Task 4 — Tests.** All 6 new coordinator tests. Tests fail without Task 3 changes (verify by reverting locally), pass with them.
- **Task 5 — Docs.** CLAUDE.md PR table row 30, test count update (432 → 438), CHANGELOG.md `## [Unreleased]` entry under Fixed.

Quality review checkpoint after Task 3 (behavior implemented, no tests): does the watchdog cancel-on-success path handle the "engine.play succeeded but positionUpdate seeded with old value" edge case? Verify the snapshot comparison in `waitForFirstPositionUpdate`.

---

## Risks + mitigations

- **Watchdog races with normal playback start.** A slow but legitimate buffer fill could be flagged as a stall. Mitigation: 10s budget covers the observed 4.5s `fileLoaded` + several seconds of AO open. Tune up to 15s if smoke testing flags false positives. Real stalls observed are >2 minutes — 10s vs 15s budget doesn't move the needle.
- **`network-timeout=15` may break weak networks (cellular, hotel Wi-Fi) where 15s is normal RTT.** Mitigation: 15s is still generous for live HTTP audio (typical CDN RTT < 200ms). Default 60s is overkill from mpv's video-streaming heritage. Worst case: weak network surfaces as `MPV_ERROR_AO_INIT_FAILED` more often, which the user already sees today after the 60s timeout. Net effect: faster-failing same error.
- **Re-entrance during retry.** If `engine.stop` + `engine.play` race with another `play(channelId:)` call (e.g. user spamming channels mid-watchdog), the watchdog's retry could land after the new play started. Mitigation: cancel-on-entry of `play(channelId:)` already neutralizes this. The retry's `engine.stop` would clobber the new play, but only briefly — the new `play(channelId:)` already issued its own `engine.play`, and a stop+play race here is the same shape that exists today on rapid channel changes.
- **Test flakiness.** Real-time `Task.sleep` in tests is flaky. Mitigation: inject the sleep function so tests can advance the watchdog deterministically. Same pattern as `clock` injection.

---

## Acceptance criteria

- [ ] `swift test` passes (438 tests).
- [ ] `swift build` clean (no new warnings).
- [ ] Manual smoke: pause >1h, resume — verify no regression on the happy path (fresh socket, audio starts within seconds).
- [ ] Manual smoke (synthetic): block coordinator's positionUpdates artificially in a debug build to verify error surfaces correctly. (Optional — covered by tests.)
- [ ] CLAUDE.md PR 30 row added; test count line updated.
- [ ] CHANGELOG.md `## [Unreleased]` Fixed entry added.

---

## Notes for execution

- Keep diffs small. Two source files modified: `MpvPlayerEngine.swift` (one line), `PlaybackCoordinator.swift` (~70 lines added). Plus test file.
- No behavioral changes to non-resume paths.
- No new public API on `PlayerEngineProtocol`. The watchdog reuses existing `engine.stop()` + `engine.play(url:startSeconds:)`.
- Comment policy: WHY-only single-line comments at the watchdog arm site + the snapshot-comparison in `waitForFirstPositionUpdate`. No multi-line docstrings.
