# PR 41 — `tryQueueNextOrDefer` helper (generalise PR 40 pattern to remaining await sites)

**Date:** 2026-05-22
**Predecessor:** PR 40 (eof recovery non-blocking)
**Deferred-from:** `docs/pr-history.md` § Deferred → "PR 40 — remaining `await songFileCache.localFile(...)` call sites"

## Motivation

PR 40 fixed a silent-playback cascade in the `.fileEnded(.eof)` recovery branch by replacing one blocking `await songFileCache.localFile(for: next)` call with a synchronous `cachedFile(for:)` probe + a deferred-queueNext mechanism. The actor-blocking risk is structural, not specific to that branch. Five other call sites in `PlaybackCoordinator` still suspend the coordinator's actor on an in-flight download, each capable of queueing subsequent mpv events behind the wait and producing the same queue/mpv desync (UI shows "playing", audio is silent).

This PR generalises the fix: extract a `tryQueueNextOrDefer(_:)` helper, convert the 5 risk-bearing next-resolve sites to use it. Cache-hit path is unchanged; cache-miss path defers via the same mechanism PR 40 introduced.

## Scope

### In-scope (5 call sites converted)

| Site | Function | Trigger | Risk |
|---|---|---|---|
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:867` | `syncQueueHeadFromMpv()` advance | every mpv `.fileStarted` (song advance) | **highest** — identical surface to PR 40's cascade |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:774` | `handleSongPlaybackError()` next | unplayable-song recovery | high |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:528` | `applyBitrateChange()` next | user bitrate toggle | medium |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:449` | `skipForward()` shallow-refetch next | queue depleted + refetch | low (rare path) |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:204` | `play(channelId:)` next | fresh playback start | low (mpv idle before our first event) |

### Excluded

- **`skipForward()` mid-skip next (L374):** the only next-resolve site where the queue head hasn't yet started playing under mpv's auto-advance — mpv is idle waiting for our `engine.advanceToQueued()`, so no events can queue behind the await. Converting would force the user's explicit skip to bail out on cache miss, degrading UX. Keep the await; add a single-line comment noting the intentional exception.
- **Head resolves (L175, L429, L624, L754):** precede `engine.play(url:)` which needs the URL. Converting would mean handing mpv the remote URL on cache miss (stream-from-network), a behaviour change rather than a risk fix.

## Architecture

### New private method on `PlaybackCoordinator`

```swift
// Resolves queue[1] (or any candidate "next" song) for engine.queueNext using
// a synchronous cache probe. Returns true on cache hit + successful queueNext.
// Returns false on cache miss (deferred — kickSequentialDownload's post-download
// hook tryQueueNextIfPending(landed:) will fire queueNext and lift state once
// the download lands) or queueNext error.
private func tryQueueNextOrDefer(_ next: GaplessSong) async -> Bool {
    if let url = songFileCache.cachedFile(for: next) {
        do {
            try await engine.queueNext(url: url, startSeconds: nil)
            queueNextEventId = next.eventId
            return true
        } catch {
            logger.warn("queueNext failed event=\(next.eventId): \(error)")
            return false
        }
    }
    logger.debug("deferring queueNext (not cached) event=\(next.eventId)")
    deferredQueueNextAt = clock()
    emitState(.loading)
    return false
}
```

Symmetric naming with existing `tryQueueNextIfPending(landed:)` (the post-download hook). No new fields; reuses `deferredQueueNextAt` and `queueNextEventId`.

### Call-site shape after conversion

Before (representative — `syncQueueHeadFromMpv` advance branch, ~13 lines):

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
            logger.warn("syncQueueHead: queueNext failed: \(error)")
        }
    }
}
```

After (~3 lines):

```swift
if queue.count >= 2 {
    _ = await tryQueueNextOrDefer(queue[1])
}
```

Race-guard (`queue[1].eventId == next.eventId` after the `localFile` await) becomes dead code at all 5 sites — `cachedFile(for:)` is synchronous, no actor suspension, no mid-await queue mutation possible.

## State transitions

### Cache-hit (unchanged behaviour)

```
caller → tryQueueNextOrDefer(next)
        → cachedFile(for:) returns URL                    [synchronous]
        → engine.queueNext(url:)                          [await, no localFile blocking]
        → queueNextEventId = next.eventId
        → returns true
caller continues (state untouched)
```

### Cache-miss / defer

```
caller → tryQueueNextOrDefer(next)
        → cachedFile(for:) returns nil                    [synchronous]
        → deferredQueueNextAt = clock()
        → emitState(.loading)
        → returns false
caller continues (no-op on false at most sites)

  ... [download runs inside kickSequentialDownload Task — not on actor] ...

downloader lands song → tryQueueNextIfPending(landed:)    [hops back to actor]
        → guards pass (queue.count >= 2, queue[1].eventId == landed.eventId,
                       queueNextEventId != next.eventId)
        → cachedFile(for:) returns URL
        → engine.queueNext(url:)
        → queueNextEventId = next.eventId
        → logs "recovery: deferred queueNext fired event=<id> elapsedSinceDeferMs=<n>"
        → deferredQueueNextAt = nil
        → if currentState == .loading: emitState(.playing)
```

### Invariants

- `deferredQueueNextAt != nil` ⟺ a queueNext is pending download
- `queueNextEventId == nil` while deferred
- `.loading` state covers both initial-load and deferred-queueNext (single UI signal)
- Cleared on: successful queueNext (via `tryQueueNextIfPending`), error recovery (`handlePlaybackError` already clears at L695), channel change (`changeChannel` already clears)

## Edge cases

### `cancelInFlightDownloads`

Called in `applyBitrateChange` (L525), `handlePlaybackError` (L698), `shutdown` (L552). After cancellation, deferred queueNext relies on a re-kick of `kickSequentialDownload`:

- `applyBitrateChange` re-kicks at L542 ✓
- `handlePlaybackError` clears `deferredQueueNextAt` at L695 ✓
- `shutdown` doesn't need to ✓

No new path needed.

### UI flicker at `play()`

`play()` emits `.playing` at L200 before reaching the converted site. On cache miss, helper drops to `.loading`. UI transition `.playing → .loading → .playing` lasts until the download lands. Acceptable — matches today's behaviour when queue[1] is not cached (the user sees a brief spinner). Document this in a one-line comment at the call site.

### `applyBitrateChange` defer UX

State is typically `.playing` when user toggles bitrate. Helper drops to `.loading` on cache miss. User sees spinner until queue[1] for the new bitrate downloads. Strictly better than today's silent wait (UI lies that audio is playing while queueNext is in-flight).

### Cascade-protection lift (PR 40 carryover)

`.fileEnded(.eof)` recovery branch at L651-653 already lifts `.loading → .playing` if `deferredQueueNextAt == nil` after recovery completes. Still required — recovery clears `deferredQueueNextAt` at L622 before the queueNext branch runs. Keep as-is.

### Concurrent `tryQueueNextIfPending` vs `syncQueueHeadFromMpv`

Both touch `queueNextEventId`. Actor serialises; whichever runs first wins. If sync sets `queueNextEventId` before the pending-check, `tryQueueNextIfPending`'s `queueNextEventId != next.eventId` guard short-circuits. ✓

### `engine.queueNext` throws inside helper

Logs warn, returns `false`, leaves `deferredQueueNextAt = nil`, leaves `queueNextEventId` unchanged. Caller continues. Failure mode: if downloader has already landed by the time we threw, `tryQueueNextIfPending` won't re-fire (it ran once, queue[1] state already passed its guards). On the next real `.fileEnded(.eof)`, recovery branch catches it. Rare in practice (engine errors mid-session). Don't add retry logic.

## Diagnostic logs

Helper logs at debug level on both paths:

- Hit: existing log shape unchanged (caller-level logs removed since helper handles it consistently).
- Miss: `"deferring queueNext (not cached) event=<id>"`

Existing PR 40 log `"recovery: deferred queueNext fired event=<id> elapsedSinceDeferMs=<n>"` continues to fire from `tryQueueNextIfPending`. Site-of-origin tracking (which call site triggered the defer) is intentionally NOT added — `elapsedSinceDeferMs` carries the useful signal, and the deferring site is whatever most recently emitted the "deferring queueNext" log.

## Testing

Reuse PR 40 infra: `MockSongFileCache.cachedFileOverride`, `markDownloaded([eventIds])`, `MockPlayerEngine.fire(...)`, log capture.

### Per-site defer tests (5)

Each asserts: when called with queue[1] uncached, helper defers (no `engine.queueNext` call), emits `.loading`, sets `deferredQueueNextAt`.

| Test name | Trigger | Setup |
|---|---|---|
| `test_play_defersQueueNextWhenNextNotCached` | `coordinator.play(channelId:)` | `markDownloaded([head.eventId])` only |
| `test_skipForwardShallowRefetch_defersQueueNext` | `coordinator.skipForward()` w/ depleted queue | Mock API returns 1 song initially; skip triggers refetch; queue[1] uncached after |
| `test_applyBitrateChange_defersQueueNext` | `coordinator.applyBitrateChange()` | Play first; toggle bitrate; queue[1] uncached after refresh |
| `test_handleSongPlaybackError_defersQueueNext` | `engine.fire(.fileEnded(.error(code: -12)))` | Queue[1] uncached when recovery promotes queue[2] |
| `test_syncQueueHeadFromMpv_defersQueueNextOnAdvance` | `engine.fire(.fileStarted)` after queue shift | Queue[1] uncached at advance time |

### Cross-cutting lift test (1)

`test_deferredQueueNext_liftsStateWhenDownloaderLands`

- Uses `syncQueueHeadFromMpv` advance as the trigger (most common path)
- After defer, `cache.markDownloaded([queue[1].eventId])`
- Asserts: `tryQueueNextIfPending` fires `queueNext`; state transitions `.loading → .playing`; `"elapsedSinceDeferMs"` log entry present

### NOT added

- Per-site lift tests — helper extraction means one lift assertion covers all
- Race tests for queue-shifted-mid-defer — sync probe makes this impossible
- L374 skipForward mid-skip — out of scope (intentionally not converted)

### Test count

543 → 549 (+6)

### Regression risk

Existing `cascadeRecovery` test (PR 40) asserts the `.fileEnded(.eof)` recovery still works. Helper extraction must not break it. Run full `swift test`, especially `LivePlaybackCoordinatorTests`.

## Documentation updates (per CLAUDE.md workflow)

- `CHANGELOG.md` → `## [Unreleased]` § Changed: helper extraction + generalisation
- `docs/pr-history.md` → new row for PR 41; remove the "PR 40 — remaining await sites" entry from § Deferred
- `docs/test-counts.md` → append new line
- `docs/architecture.md` → no entry needed (mechanism is PR 40's, already documented)
- `CLAUDE.md` → refresh *Current state*: last merged = PR 41
- `README.md` → no user-facing change

## Out of scope

- Head-resolve conversion (L175, L429, L624, L754) — would change cache-or-stream behaviour, not just risk profile
- Adding retry on `engine.queueNext` throw inside helper
- Site-tracking field on `deferredQueueNextAt`
- Refactor of `tryQueueNextIfPending` itself (already good shape from PR 40)
