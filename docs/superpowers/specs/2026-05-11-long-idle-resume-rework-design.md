# Long-Idle Resume Rework — Design

**Date:** 2026-05-11
**Working title:** PR 33 — long-idle resume preserves cached song; remove network-stall watchdog

## Problem

`LivePlaybackCoordinator.resume()` currently treats a multi-hour pause as a recovery
event: it drops the in-mpv playlist, wipes the coordinator queue, and re-runs
`play(channelId:)`. That re-run synchronously fetches `api/gapless` and then calls
`engine.play(url:)` on the new head song — which abruptly cancels the user's paused
song mid-playback.

The recovery was correct in the HTTP-streaming era (PR 24 + PR 30): the CDN had a
~1-hour TCP idle eviction, and after a long pause the open mpv stream was as good as
dead. With PR 32's local-cache pipeline (`LiveSongFileCache`), the paused song is a
local `file://` URL — there is no network connection to evict, and the user's song
should simply continue when they hit play.

Observed in `.temp/LinkedAppFolder/RP Player/Logs/RPPlayer.log` (truncated):

```text
03:13:04 pause()
10:05:16 resume()
10:05:16 resume: long idle (24731s >= 3540s), refetching gapless
10:05:16 engine.clearPlaylist
10:05:16 play(channelId: 0)
10:05:16 GET https://api.radioparadise.com/api/gapless?...
10:05:27 resume()                     <-- user clicked play again, no audio yet
10:05:27 resume: short idle, engine.resume()
10:05:57 play queue: ... [0] event=2872797 Gnarls Barkley — Pictures
10:05:57 engine.play url=file://.../3ac24c9b...flac (cache hit=true)
```

The user's paused queue (event 2872685 "Catching Flies — Satisfied") was discarded
even though both queue[0] and queue[1] were on disk and intact in mpv's playlist.

## Goals

- Resume continues the cached, paused song with no audible disruption.
- Resume keeps queue[1] (next song, also cached and queueNext'd in mpv) so a slow or
  failing refetch never strands playback.
- A background refetch on long-idle resume catches up to the backend's current
  cursor; the catch-up jump happens at the queue[1]→queue[2] boundary (one extra
  song of "old" programming, which is acceptable).
- The 11-second double-resume race in the log goes away because `engine.resume()`
  now returns essentially instantly — no more "no audio for 30+s while we wait for
  api/gapless".
- Remove PR 30's stall watchdog. Local file:// playback cannot suffer mpv's
  network-stuck-on-`ffurl_read` failure mode that the watchdog defended against.

## Non-Goals

- Telemetry shape changes. `update_history`, `update_pause` continue to fire as
  today.
- UI affordances for "catching up to live" (no spinner / banner). Optional polish
  PR if user feedback requests it.
- Wider audit of `handleSongPlaybackError`, `fileEnded(.error)`, device-unplug
  recovery (mpv code -14). Each remains relevant; left untouched.
- Cache-eviction tuning. LRU `maxFiles=10` stays. Stale tail files evict naturally.

## Architecture

### `resume()` rewrite

Replace [PlaybackCoordinator.swift:225-274](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L225-L274) with a single converged path:

```swift
public func resume() async throws {
    logger.debug("resume()")
    guard !queue.isEmpty, let channelId = currentChannelId else {
        throw PlaybackCoordinatorError.notPlaying
    }
    let now = clock()
    let pausedFor: TimeInterval? = pausedAt.map { now.timeIntervalSince($0) }
    let longIdle = (pausedFor ?? 0) >= Self.longIdleResumeThresholdSeconds

    // Cache-miss defense for queue[0]. If the paused song is no longer on disk,
    // mpv will fail when it tries to re-open the file. Fall back to the legacy
    // refetch + restart path (which is also today's long-idle path).
    if songFileCache.cachedFile(for: queue[0]) == nil {
        logger.warn("resume: cache miss for queue[0]; falling back to refetch+restart")
        try? await engine.clearPlaylist()
        queue = []
        currentResponse = nil
        lastStartedEventId = nil
        pausedAt = nil
        pausePositionMs = 0
        try await play(channelId: channelId)
        return
    }

    await prePlayHook()
    do { try await engine.resume() } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitState(.playing)

    // update_pause telemetry — lifted from today's short-idle branch unchanged.
    fireUpdatePauseTelemetryIfApplicable(channelId: channelId)

    // Long-idle catch-up: drop stale tail beyond queue[1]; refetch in background.
    if longIdle {
        logger.info("resume: long idle (\(Int(pausedFor ?? 0))s), kicking background catch-up")
        if queue.count > 2 {
            queue = Array(queue.prefix(2))
        }
        // Stop downloading the old tail; new tail starts after refetch resolves.
        let cacheRef = songFileCache
        Task { await cacheRef.cancelInFlightDownloads() }
        downloaderTask?.cancel()
        downloaderTask = nil
        kickRefetch()
    }
}

private func fireUpdatePauseTelemetryIfApplicable(channelId: String) {
    guard pausedAt != nil, currentSongInQueueAvailable() else {
        pausedAt = nil
        pausePositionMs = 0
        return
    }
    let song = queue[0]
    guard song.updateHistory else {
        pausedAt = nil
        pausePositionMs = 0
        return
    }
    let ppm = pausePositionMs
    let ts = Int(clock().timeIntervalSince1970)
    let songId = song.songId
    let event = String(song.eventId)
    let audioType = song.type
    let sliceNum = String(song.sliceNum)
    let api = self.api
    pausedAt = nil
    pausePositionMs = 0
    Task.detached {
        try? await api.updateHistory(
            songId: songId, chan: channelId, event: event, audioType: audioType,
            sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts,
            pauseFlag: true
        )
    }
}
```

Key invariants:

- **No `engine.clearPlaylist`** in the happy path. mpv's playlist
  `[queue[0] paused, queue[1] queued]` is exactly what we want.
- **No `engine.play(url:)`** in the happy path. No abrupt cancel.
- The 59-min threshold (`longIdleResumeThresholdSeconds`) stays. Original CDN
  rationale is gone, but the same threshold separates "drift acceptable" from
  "worth catching up to live" in the new model.

### `kickRefetch` filter shift (B1)

Today's `kickRefetch` ([PlaybackCoordinator.swift:813](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L813)) snapshots `queue.first?.eventId` and
filters `response.songs` by `eventId > snapshot`. This rebuilds the queue as
`[queue[0]] + filtered`, which would drop our preserved queue[1] in the long-idle
case.

Change: snapshot **both** `queue.first?.eventId` and `queue.last?.eventId`
pre-await; race-check both post-await; filter by `eventId > queue.last.eventId`;
merge as `queue + filtered` (preserves the entire current queue, appends fresh
tail).

In steady state this is a strict generalization:

- Boundary advance with `queue.count < 3`: queue is `[head, q1, q2]`, server
  returns from current cursor (covers `head..head+19`), filter strips
  overlap (`<= q2.eventId`), keeps `head+3` onward, queue becomes
  `[head, q1, q2, head+3, ...]`. Same effective result as today's
  `[queue[0]] + filtered` (today's collapses to `[head, head+1, head+2,
  head+3, ...]` if response includes head — the rebuild loses the live
  ordering of intermediate q1/q2 entries that today happen to be identical,
  but the new logic preserves them explicitly).
- Long-idle path: queue is `[oldQ0=2872685, oldQ1=2872686]`, server returns
  `[2872790-2872810]`, filter `> 2872686` keeps everything, queue becomes
  `[2872685, 2872686, 2872790, ..., 2872810]`. The `queue[1]→queue[2]`
  boundary is the catch-up jump.

Race-guard: `kickRefetch` cancels any in-flight `refetchTask` before starting
a fresh one ([PlaybackCoordinator.swift:813](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L813)). The post-await re-check rejects the response
if either `currentChannelId` or the snapshotted `queue.first.eventId` /
`queue.last.eventId` changed during the network round-trip.

### Stall watchdog deletion

PR 30's `armLongIdleStallWatchdog` was the only arm site, and that site is being
removed. Delete:

- `armLongIdleStallWatchdog`, `cancelStallWatchdog`, `surfaceStallError`,
  `waitForFirstPositionUpdate` in `PlaybackCoordinator.swift`.
- `stallWatchdogTask` field.
- `sleep:` parameter on `LivePlaybackCoordinator.init` + the
  `LivePlaybackCoordinator.defaultSleep` static helper.
- All `cancelStallWatchdog()` call sites (8 of them per PR 30 entry).
- `Tests/RPPlayerTests/Helpers/ControllableSleep.swift` (or wherever it lives).
- `AppContainer.live()` and any other production call site that passes `sleep:`.

CLAUDE.md PR 30 entry already captures the historical rationale; the deletion
is recoverable from git if the failure mode resurfaces.

## Edge Cases

| ID | Scenario | Behavior |
|----|----------|----------|
| E1a | queue[0] cache miss on resume | Fall through to legacy clearPlaylist + queue wipe + `play(channelId:)`. Same as today's long-idle path. Logged at WARN. |
| E1b | queue[1] cache miss on resume | `engine.resume()` proceeds (queue[0] is fine). Sequential downloader re-acquires queue[1]. If queue[1] is not ready by mpv boundary advance → `fileEnded(.eof)` recovery at [PlaybackCoordinator.swift:514-560](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L514-L560) handles it (await cache → re-download → `engine.play`). Self-healing. |
| E2 | queue.count == 1 on resume | Truncate is no-op (`prefix(2)` of length-1 array is the same array). `engine.resume()` runs, kickRefetch refills. |
| E3 | Refetch fails (network down at resume time) | `kickRefetch` swallows + logs. Queue stays `[oldQ0, oldQ1]`. queue[0] plays through, boundary advance to queue[1], queue[1] plays through, then `fileEnded(.eof)` at [PlaybackCoordinator.swift:551-560](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L551-L560) calls `play(channelId:)` for full restart. Existing recovery covers it. |
| E4 | Second resume() during in-flight refetch (the 11s log race) | 1st resume returns fast (engine.resume() ≈ instant). 2nd click is most likely "pause" (mpv now playing) or no-op resume (`pausedAt` already nilled). kickRefetch's task cancel + race-guard handles overlapping refetches. |
| E5 | Pre-pause queue had a promo at queue[1] | No special handling. Promo plays its 5s, boundary advance to queue[2] which is now backend-current music. |
| E6 | Channel change during in-flight long-idle refetch | `kickRefetch`'s post-await `currentChannelId` check rejects the result. `changeChannel` already calls `cancelInFlightDownloads` + clearPlaylist + queue=[]. |

## Components Touched

| File | Change |
|------|--------|
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Rewrite `resume()`. Update `kickRefetch` filter/snapshot. Delete stall-watchdog functions + field. Drop `sleep:` init param. |
| `Sources/RPPlayer/App/AppContainer.swift` | Drop `sleep:` arg from `LivePlaybackCoordinator.init`. |
| `Tests/RPPlayerTests/Helpers/ControllableSleep.swift` (or wherever) | Delete. |
| `Tests/RPPlayerTests/PlaybackCoordinator+*Tests.swift` | Add 7 new tests (see Testing). Delete 6 PR 30 watchdog tests. Update assertions in any tests that touched the long-idle clearPlaylist+replace path. |
| `CHANGELOG.md` | Add Unreleased > Fixed (long-idle resume) + Removed (stall watchdog). |
| `CLAUDE.md` | Add PR 33 row. Update "Coordinator playback" long-idle bullet. Update "Test counts by PR". |
| `README.md` | No user-facing change. |

## Testing

### New tests

1. **`testLongIdleResumePreservesCurrentSongAndQueue`** — pause at queue[0],
   advance clock 60min, resume(). Assert: `engine.resume()` called once;
   `engine.clearPlaylist` NOT called; `engine.play(url:)` NOT called; queue ==
   `[oldQ0, oldQ1]`; one `kickRefetch` task in flight.
2. **`testLongIdleResumeMergesFreshTailAfterRefetch`** — as above, then deliver
   pending `api.gapless` response with eventIds strictly greater than
   `oldQ1.eventId`. Assert: queue == `[oldQ0, oldQ1] + freshSongs`.
3. **`testLongIdleResumeWithCacheMissForCurrentSongFallsBackToReplay`** — evict
   queue[0] from cache before resume. Assert: `engine.clearPlaylist` called;
   queue wiped; `play(channelId:)` invoked; new `engine.play(url:)` for backend
   head. (Legacy path.)
4. **`testLongIdleResumeWithCacheMissForQueue1ContinuesAndReDownloads`** — evict
   queue[1] only. Assert: `engine.resume()` called for queue[0]; sequential
   downloader kicks for queue[1]; no playback interruption.
5. **`testLongIdleResumeQueueCountOneSkipsTruncate`** — pre-resume queue =
   `[oldQ0]`. Assert: no crash; `engine.resume()` called; kickRefetch fires;
   queue length stays 1 until refetch resolves.
6. **`testKickRefetchFiltersByQueueLastEventId`** — direct test. queue =
   `[a(1), b(2), c(3)]`; mock response = `[b(2), d(4), e(5)]` (overlap on b).
   Assert: post-merge queue == `[a, b, c, d, e]`.
7. **`testSecondResumeDuringInFlightRefetchIsIdempotent`** — call resume()
   twice in rapid succession during long-idle. Assert: single `engine.resume()`
   call; single in-flight refetch task; no duplicate truncate.

### Tests deleted (PR 30 watchdog suite)

- `testLongIdleResumeArmsStallWatchdog`
- `testStallWatchdogTimeoutTriggersRetry`
- `testStallWatchdogDoubleTimeoutSurfacesError`
- `testStallWatchdogClearedOnPositionUpdate`
- `testStopCancelsStallWatchdog`
- `testFreshResumeDoesNotArmWatchdog`

### Tests updated

- `testResumeShortIdleEngineResume` — also assert no kickRefetch fired.
- Any test asserting `engine.clearPlaylist` on long-idle resume → invert.
- Any test passing `sleep:` to `LivePlaybackCoordinator.init` → drop the arg.

### Net test delta

After: `399 - 6 + 7 = 400`.

## Implementation Order

Recommended sequence for the implementation plan:

1. Add `kickRefetch` filter shift + snapshot of `queue.last`. Land + tests
   first (smallest blast radius — generalizes today's logic, keeps existing
   call sites working).
2. Rewrite `resume()` (long-idle branch). Land + new resume tests.
3. Delete stall-watchdog code + tests + `sleep:` init param. Land last
   (mechanical cleanup once the arm site is gone).
4. Doc updates (CHANGELOG, CLAUDE.md table + bullet, test counts).

Each step is independently verifiable with `swift test`.

## Open Questions

None at design time. Implementation may surface naming nits (e.g. whether to
rename `longIdleResumeThresholdSeconds` to drop "long-idle"; the threshold's
meaning shifted from "treat as failure" to "trigger catch-up", but the constant
name is still accurate).
