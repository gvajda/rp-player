# EOF Recovery — Non-Blocking Next-Slot Resolve + Post-Download QueueNext

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the coordinator actor from blocking on an in-flight download inside the `.fileEnded(.eof)` recovery branch. Convert next-slot resolution to a non-blocking cache check; defer `engine.queueNext` to a post-download hook driven by the existing sequential downloader.

**Branch:** `claude/pr40-eof-recovery-nonblocking`
**Base:** `main` (last merged: PR 39 EQ Preset Editor, 540 tests)
**Scope:** small, surgical. Two coordinator changes + downloader callback wiring + diagnostic logging. No protocol changes outside coordinator.

---

## Why

Reproduced 2026-05-21 from `RPPlayer.log` (lines 800–825). Tail of the log:

```
21:27:21.030 fileEnded eof                              (Beck "Nobody's Fault" ended)
21:27:21.033 WARN fileEnded(.eof) without queued entry; recovering
21:27:21.036 engine.play file:Marc-Rebillet            (recovery plays Marc-Rebillet, 156s)
21:27:21.037 engine.queueNext file:promo               (promo 379KB, cached)
21:27:21.038 SongFileCache miss event=2876930 kicking download   (next real song)
...
21:29:57.369 fileEnded eof                              (Marc-Rebillet ended)
21:29:57.370 WARN fileEnded(.eof) without queued entry; recovering
21:29:57.371 SongFileCache hit event=2876929           (promo — recovery head)
21:29:57.372 engine.play file:promo
21:29:57.373 SongFileCache join-in-flight event=2876930   ← await blocks here
21:29:57.415 GET list_chan
<silence, log ends>
```

Diagnosis: in [PlaybackCoordinator.swift:619](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L619) the `.fileEnded(.eof)` recovery path calls

```swift
let nextUrl = await songFileCache.localFile(for: next) ?? URL(string: next.gaplessUrl)
```

[SongFileCache.swift:57-60](Sources/RPPlayer/Playback/SongFileCache.swift#L57-L60): `localFile(for:)` **awaits the in-flight download task to completion** before returning. So when recovery fires and `queue[1]` is mid-download, the actor blocks inside this `await` until bytes land. No `engine.queueNext` is issued; mpv has nothing teed up.

Cascade hazard:

1. Recovery plays `queue[0]` (the promo, ~5s).
2. Actor parks on `await localFile(for: 2876930)`.
3. Promo ends in mpv ~5s later → another `fileEnded(.eof)` queues at actor (actor reentrancy).
4. State user sees: silence + UI still "playing" (no `emitState` in this recovery path), no loading spinner.
5. When 2876930 finally downloads, first handler resumes and tries `queueNext(2876930)`, but the second handler already did `queue.removeFirst()`. The guard `queue[1].eventId == next.eventId` (line 621) is now false. `queueNext` skipped. Queue/mpv desync. Audio silent until user pause/resume or app restart.

Why it's rare: triggers only when the recovered head is a **short promo** (~5s) AND the next real song's download budget is tight (Marc-Rebillet's 2876930 had been downloading 156s by promo-end; typical music downloads in this log run 90–310s).

Why the existing `WARN: fileEnded(.eof) without queued entry; recovering` log fires every song: that warning is normal for the current architecture — every song ends with EOF and falls into this recovery because gapless `queueNext` advance doesn't always produce a proper mpv playlist-pos increment (the always-paired `engine fileEnded: stopped` 1ms later is the recovery's `engine.play` aborting the queued tee). Worth a separate look but unrelated.

---

## Scope (final)

1. **Non-blocking next-slot resolve in `.fileEnded(.eof)` recovery** ([PlaybackCoordinator.swift:617-629](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L617-L629)). Replace `await songFileCache.localFile(for: next)` with `songFileCache.cachedFile(for: next)` (sync, fs-exists only). If nil, skip `queueNext` now and log `recovery: deferring queueNext (not cached) event=X`. Do NOT fall back to `next.gaplessUrl` — that would double-fetch and bypass the cache.

2. **Post-download `queueNext` hook in `kickSequentialDownload`** ([PlaybackCoordinator.swift:924-937](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L924-L937)). After each `await cache.localFile(for: song)` returns successfully, hop back to the actor and call a new `tryQueueNextIfPending()` helper that: (a) checks `queue.count >= 2 && queue[1].eventId == song.eventId && queueNextEventId != queue[1].eventId`, (b) resolves the URL via `cachedFile` (must now be present), (c) fires `engine.queueNext` and updates `queueNextEventId`. Logs `recovery: deferred queueNext fired event=X elapsedSinceDeferMs=Y`.

3. **`.loading` state emit when recovery defers queueNext**. Currently the recovery branch never touches `emitState`. When we defer queueNext for a missing cache file, emit `.loading` (UI spinner). The post-download hook emits `.playing` after queueNext lands and the engine's existing `.fileStarted` signal lifts state. Verify `PlaybackState.loading` exists and check how `.playing` is reasserted elsewhere — if no clean post-hook path exists, log a TODO and just emit `.loading` (best-effort UX, the spinner is the meaningful signal).

4. **Diagnostic logging across the recovery flow**:
   - `recovery: head=event=X (cached|in-flight|missing) next=event=Y (cached|in-flight|missing)` at entry to the recovery branch.
   - `recovery: deferring queueNext (not cached) event=Y` when skipping queueNext.
   - `recovery: deferred queueNext fired event=Y elapsedSinceDeferMs=Z` from the post-download hook.
   - `recovery: skipping queueNext — queue mutated mid-await (expected=X, got=Y)` on the existing line-621 false branch (currently silent).
   - `kickSequentialDownload: download landed event=X, checking pending queueNext` after each downloader iteration.

5. **Do NOT touch other awaiting-localFile sites in this PR**:
   - `syncQueueHeadFromMpv` ([line 843](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L843))
   - `handleSongPlaybackError` ([line 752](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L752))
   - `play` initial ([line 209](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L209))
   - `skipForward` ([line 381](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L381))
   - `applyBitrateChange` ([line 523](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L523))

   Same anti-pattern, but only the eof recovery cascades on actor reentrancy. Capture a deferred-tech-debt entry in `docs/pr-history.md` § Deferred: "Audit remaining `await songFileCache.localFile(...)` call sites in PlaybackCoordinator; same blocking-actor risk as the one fixed in PR 40." Address when a second symptom appears or before any further refactor of the queue lifecycle.

**Out of scope:**

- Watchdog/timeout on stuck downloads. PR 30 added `network-timeout=15` engine-side; if URLSession is the one stuck, we'd need a separate `URLSessionConfiguration.timeoutIntervalForRequest` tightening on the cache's session. Defer until logs prove URLSession stalls are the failure mode (current log doesn't — Marc-Rebillet's 2876930 had only been downloading 156s, within typical 90–310s budget).
- Rewriting `localFile(for:)` to be non-blocking. That'd break every caller that legitimately wants to await a download (the initial `play()` path, sequential downloader). The non-blocking semantics belong at the call site, not the cache API.
- Mass migration of all 5 other awaiting sites. Each is a separate scope/risk decision; bundle would explode test surface.

---

## Implementation sketch

### A. Recovery branch ([PlaybackCoordinator.swift:617-629](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L617-L629))

Replace:

```swift
if queue.count >= 2 {
    let next = queue[1]
    let nextUrl = await songFileCache.localFile(for: next)
        ?? URL(string: next.gaplessUrl)
    if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
        do {
            try await engine.queueNext(url: nextUrl, startSeconds: nil)
            queueNextEventId = next.eventId
        } catch {
            logger.warn("fileEnded recovery: queueNext failed: \(error)")
        }
    }
}
```

with:

```swift
if queue.count >= 2 {
    let next = queue[1]
    if let nextUrl = songFileCache.cachedFile(for: next) {
        do {
            try await engine.queueNext(url: nextUrl, startSeconds: nil)
            queueNextEventId = next.eventId
        } catch {
            logger.warn("recovery: queueNext failed event=\(next.eventId): \(error)")
        }
    } else {
        logger.debug("recovery: deferring queueNext (not cached) event=\(next.eventId)")
        deferredQueueNextAt = Date()
        emitState(.loading)
    }
}
```

Add coordinator state:

```swift
private var deferredQueueNextAt: Date?
```

Clear in every `queueNextEventId = nil` site (search-and-update — 12 sites per grep above).

### B. Post-download hook in `kickSequentialDownload` ([line 924](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L924))

Rewrite to call back into the actor after each landed download:

```swift
private func kickSequentialDownload() {
    downloaderTask?.cancel()
    let snapshot = queue
    let cache = songFileCache
    downloaderTask = Task { [weak self] in
        for song in snapshot.dropFirst().prefix(2) {
            if Task.isCancelled { return }
            _ = await cache.localFile(for: song)
            if Task.isCancelled { return }
            await self?.tryQueueNextIfPending(landed: song)
        }
    }
}

private func tryQueueNextIfPending(landed: GaplessSong) async {
    guard queue.count >= 2 else { return }
    let next = queue[1]
    guard next.eventId == landed.eventId else { return }
    guard queueNextEventId != next.eventId else { return }
    guard let url = songFileCache.cachedFile(for: next) else { return }
    do {
        try await engine.queueNext(url: url, startSeconds: nil)
        queueNextEventId = next.eventId
        let elapsedMs = deferredQueueNextAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        logger.debug("recovery: deferred queueNext fired event=\(next.eventId) elapsedSinceDeferMs=\(elapsedMs)")
        deferredQueueNextAt = nil
        if currentPositionSeconds == 0, state == .loading {
            emitState(.playing)
        }
    } catch {
        logger.warn("recovery: deferred queueNext failed event=\(next.eventId): \(error)")
    }
}
```

(Adjust `state == .loading` access — coordinator may not retain last-emitted state; if not, track it via a stored property updated inside `emitState`.)

### C. Logging additions

- Entry to recovery branch: log resolved cache state for `head` and `next` via `cachedFile != nil` checks (no `await`).
- Line-621 false branch (queue mutated mid-await): currently silent — add `logger.debug("recovery: skipping queueNext — queue mutated mid-await")`.
- `kickSequentialDownload` per-iteration: `logger.debug("downloader: landed event=\(song.eventId), checking pending queueNext")` after each `await cache.localFile(...)`.

---

## File Map

| Action | Path |
|--------|------|
| Modify | `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` |
| Modify | `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift` |
| Modify | `docs/pr-history.md` (status row + deferred entry for other localFile sites) |
| Modify | `docs/test-counts.md` (new total) |
| Modify | `CHANGELOG.md` (Unreleased → Fixed) |
| Modify | `CLAUDE.md` (Current state block) |

---

## Tasks (TDD)

### Task 1 — Failing test: eof recovery defers queueNext when next not cached

- [ ] Add a `MockSongFileCache` variant (or extend the existing one) with a way to mark a song as "in-flight" — `cachedFile(for:)` returns nil, `localFile(for:)` returns a Task that doesn't complete until the test releases it.
- [ ] Write `testEofRecoveryDoesNotBlockWhenNextDownloadInFlight`:
  - Seed queue with 3 songs: `[A, B, C]`. A and B "playing", C in-flight.
  - Fire `.fileEnded(.eof)` for A.
  - Assert: `engine.play(B)` called, `engine.queueNext(C)` NOT called yet, state emitted `.loading`.
  - Complete C's download via the mock.
  - Assert: `engine.queueNext(C)` is now called, state emitted `.playing`.
- [ ] Run `swift test --filter testEofRecoveryDoesNotBlockWhenNextDownloadInFlight`. Expect compile or assertion failure.

### Task 2 — Implement non-blocking recovery + post-download hook

- [ ] Edit `PlaybackCoordinator.swift` per sketch A + B.
- [ ] Add `deferredQueueNextAt` state + clear-on-cleanup sites.
- [ ] Add `tryQueueNextIfPending(landed:)` helper.
- [ ] Wire the post-download callback in `kickSequentialDownload`.
- [ ] Run failing test → expect pass.

### Task 3 — Add the cascade-protection test (regression for the actual log scenario)

- [ ] Write `testEofRecoveryCascadeOnShortPromoDoesNotDesyncQueue`:
  - Seed queue `[A, promo, C]` where A just ended, promo is cached (5ms duration in mock), C in-flight.
  - Fire `.fileEnded(.eof)` for A.
  - Assert: engine.play(promo), queueNext deferred.
  - Fire `.fileEnded(.eof)` for promo (simulates promo ending while C still downloading).
  - Assert: actor handles cleanly, no engine crash, deferred queueNext eventually fires for C, state ends up `.playing` after C lands.

### Task 4 — Logging instrumentation

- [ ] Add the 5 log lines per "Implementation sketch §C".
- [ ] Write `testRecoveryEmitsExpectedLogLinesForDeferredQueueNext` capturing logger output; assert the three key lines appear in order.

### Task 5 — Docs + cleanup

- [ ] Update `CHANGELOG.md` § Unreleased → Fixed: "Playback no longer hangs after a song boundary when the next song's download is still in flight (rare; previously required a short promo and a slow CDN response to trigger)."
- [ ] Update `docs/pr-history.md`:
  - Status row for PR 40 (link, date, tests, summary).
  - Deferred section: "Audit remaining `await songFileCache.localFile(...)` call sites in PlaybackCoordinator (`syncQueueHeadFromMpv` L843, `handleSongPlaybackError` L752, `play` L209, `skipForward` L381, `applyBitrateChange` L523). Same blocking-actor risk as PR 40."
- [ ] Update `docs/test-counts.md` with new total.
- [ ] Update `CLAUDE.md` Current state block (last merged → PR 40, next up TBD).

### Task 6 — Verify in real app

- [ ] `swift test` — full suite green.
- [ ] `swift build` — release build clean.
- [ ] Manual verification per CLAUDE.md UI-change rule (audio is UI-adjacent): launch app, play a station, observe a song boundary in the log. Confirm the new `recovery: ...` debug lines appear. Cannot easily reproduce the original failure mode without throttling CDN, so document the limitation: "Real-world repro requires throttled network or short-promo timing window; verified via mock-cache tests."

---

## Risk + rollback

- **Risk:** post-download hook fires `queueNext` while a concurrent path (skipForward, new play, channel change) has already mutated `queue`/`queueNextEventId`. Mitigation: the helper's three guards (count, eventId match, queueNextEventId mismatch) catch all known races. The downloader Task is also cancelled in every cleanup site, so a stale callback can't fire after teardown.
- **Risk:** `.loading` state emit in the recovery branch causes UI flicker for the common case where the next download lands within ms. Mitigation: only emit when the cache miss is real; for cache hits the existing fast path runs synchronously and no state change happens.
- **Rollback:** revert single coordinator file. No data migrations, no persisted state, no protocol changes.
