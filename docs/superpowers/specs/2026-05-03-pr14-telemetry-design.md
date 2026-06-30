# PR 14 — Telemetry Endpoints Design

**Date:** 2026-05-03\
**Status:** Approved\
**Goal:** Fire `api/update_history` and `api/update_pause` so the RP backend tracks listening position; cross-session resume resumes at the last-played song instead of replaying recently-heard content.

---

## Context

After PR 13 (`api/play` migration), the server tracks per-`(player_id, chan)` cursors. Bootstrap (`event=0&action=start`) returns the slice after the last cursor the server has on record. Without telemetry, the server has no record for desktop clients, so it falls back to replaying recent content. With telemetry, every music-song start is recorded and bootstrap resumes correctly.

Source of truth for endpoint shapes: HAR capture `.temp/radioparadise.com_2.har` (26 telemetry entries). Both endpoints: GET, status 200, empty response body, fire-and-forget.

---

## Decision summary

| Question                | Decision           | Rationale                                                                                                                             |
| ----------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| Settings opt-out toggle | **No** — always on | Required for cross-session resume; opt-out is YAGNI                                                                                   |
| Flush on app quit       | **No**             | Passive telemetry from normal song-boundary fires is sufficient; explicit flush would put the server cursor at the abandoned position |
| Flush on channel switch | **No**             | Same rationale — user switched away intentionally                                                                                     |

---

## Endpoint: `api/update_history`

**Fires:** at every music-song start, and again after resuming from pause.

**Method:** GET, no request body, empty response body.

**Required query params** (alphabetical order, matching existing client convention):

| Param                  | Value                                       | Notes                                |
| ---------------------- | ------------------------------------------- | ------------------------------------ |
| `chan`                 | channel id                                  | Int as String                        |
| `episode_id`           | `"0"`                                       | constant                             |
| `event`                | song's event string                         | `PlayListSong.event ?? ""`           |
| `event_num`            | `"undefined"`                               | literal — matches web player         |
| `pause`                | `"1"`                                       | **only present** on post-resume call |
| `play_position_millis` | ms within song                              | see formula below                    |
| `player_id`            | per-install UUID                            | same as `api/play`                   |
| `slice_num`            | slice string or `"null"`                    | `PlayListSong.sliceNum ?? "null"`    |
| `song_id`              | song's numeric id                           | `PlayListSong.songId` as String      |
| `source`               | `"24"`                                      | constant                             |
| `time_relative`        | `"-\(Int((Double(ppm)/1000.0).rounded()))"` | always negative-prefixed, even `-0`  |
| `type`                 | song's type string                          | `PlayListSong.type ?? "M"`           |

`play_position_millis` (ppm) formula (unified across all trigger sites):

```
ppm = max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
```

At bootstrap/swap, `currentPositionSeconds = Double(block.cue)/1000.0` and `startsAt[0] = song[0].elapsed/1000.0`, so ppm = `max(1, block.cue - song[0].elapsed)`. For natural advance and skip, the position is at the boundary (≈0ms), so ppm = 1. Matches HAR observations.

**Post-resume variant:** same params plus `pause=1`.

---

## Endpoint: `api/update_pause`

**Fires:** once when the user resumes from pause, reporting the duration of the pause.

**Method:** GET, no request body, empty response body.

**Required query params** (alphabetical order):

| Param           | Value                                    |
| --------------- | ---------------------------------------- |
| `chan`          | channel id                               |
| `episode_id`    | `"0"`                                    |
| `event`         | song's event string                      |
| `event_num`     | `"undefined"`                            |
| `pause`         | pause duration in milliseconds as String |
| `player_id`     | per-install UUID                         |
| `playtime_secs` | unix timestamp at fire time (seconds)    |
| `slice_num`     | slice string or `"null"`                 |
| `song_id`       | song's numeric id                        |
| `source`        | `"24"`                                   |
| `type`          | song's type string                       |

Note: no `play_position_millis` or `time_relative` on this call (confirmed from HAR).

**Pause/resume sequence** (both fire at resume time, in order):

1. `update_pause(durationMs: durationMs, ...)`
2. `update_history(ppm: pausePositionMs, pauseFlag: true, ...)`

---

## Architecture

### 1. `RpApiClient` protocol — two new methods

```swift
func updateHistory(
    songId: Int, chan: Int, event: String, audioType: String,
    sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int,
    pauseFlag: Bool
) async throws

func updatePause(
    songId: Int, chan: Int, event: String, audioType: String,
    sliceNum: String?, pauseDurationMillis: Int, playtimeSecs: Int
) async throws
```

### 2. `LiveRpApiClient` — `fire(path:query:)` helper + implementations

Add a private `fire(path:query:)` method that reuses URL construction, cookie injection, and logging from `get<T:Decodable>` but skips JSON decode (response body is empty). Just asserts 2xx.

Implement both protocol methods using `fire`. `time_relative` computed in the `updateHistory` impl.

### 3. `LivePlaybackCoordinator` — new state + four trigger sites

**New state:**

```swift
private var pausedAt: Date? = nil
private var pausePositionMs: Int = 0
private let clock: @Sendable () -> Date  // default { Date() }
```

`clock` injected alongside `bitrateProvider` in `init`. Default `{ Date() }`. Tests pass fixed clock.

**Trigger sites — fire telemetry for music songs only (`song.type != "P"`):**

| Site                       | Method                               | Trigger condition                                        |
| -------------------------- | ------------------------------------ | -------------------------------------------------------- |
| Bootstrap                  | `play(channelId:)`                   | After `engine.play(...)` succeeds, before returning      |
| Prefetch swap              | `swapToPrefetchedBlockIfAvailable()` | After `engine.play(...)` succeeds                        |
| Natural advance            | `handleEngineEvent(.positionUpdate)` | When `newIndex != currentSongIndex` (after index update) |
| Skip in-block              | `skipForward()`                      | After `currentSongIndex = nextIndex` and engine seek     |
| Skip past-last → new block | `skipForward()`                      | After new block engine.play succeeds                     |

All calls are fire-and-forget:

```swift
Task.detached { [api, ...captured params...] in
    try? await api.updateHistory(...)
}
```

Errors dropped silently (server accepts missed pings gracefully).

**Pause state management in `pause()`:**

```swift
pausedAt = clock()
pausePositionMs = max(1, Int(currentPositionSeconds * 1000))
// (position-in-file; post-resume HAR shows play_position_millis = position where resumed)
```

**Resume telemetry in `resume()`** (fires before engine.resume, after guard checks):

```swift
if let at = pausedAt {
    let durationMs = Int(clock().timeIntervalSince(at) * 1000)
    // fire update_pause + update_history(pauseFlag:true) — both detached
    pausedAt = nil
    pausePositionMs = 0
}
```

`pausePositionMs` on the post-resume `update_history` = value captured at pause time (position in file at moment of pause). The HAR shows `play_position_millis=21233` on the post-resume call, matching the `pause=21233` pause duration — this is position within the song, not in the file. The coordinator doesn't currently track per-song position; `currentPositionSeconds` is file-frame. At pause time, `currentPositionSeconds - startsAt[currentSongIndex]` gives the within-song position. Capture that too:

```swift
pausePositionMs = max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
```

### 4. `AppContainer` — no changes needed

`api` is already injected into `LivePlaybackCoordinator`. `clock` defaults to `{ Date() }` so composition root needs no change.

---

## Files changed

| File                                                              | Change                                                                                                                                      |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/RPPlayer/Api/RpApiClient.swift`                          | Add `updateHistory` + `updatePause` to protocol; `fire(path:query:)` + impls to `LiveRpApiClient`                                           |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`             | `clock` param; `pausedAt`/`pausePositionMs` state; `fireSongStartTelemetry(song:block:)` helper; four trigger sites; pause/resume telemetry |
| `Tests/RPPlayerTests/Api/RpApiClientTests.swift`                  | 3 URL-construction tests                                                                                                                    |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` | ~12 new coordinator tests                                                                                                                   |
| Stub doubles (test infrastructure)                                | Add `updateHistory`/`updatePause` capture to `StubRpApiClient`                                                                              |

---

## Test plan

**`RpApiClientTests` — URL construction (3 tests):**

1. `updateHistory` normal — correct alphabetical params, `time_relative` formula, `event_num=undefined`, no `pause` param
2. `updateHistory` with `pauseFlag:true` — `pause=1` present
3. `updatePause` — `pause=<ms>` present, no `play_position_millis`

**`LivePlaybackCoordinatorTests` (~12 tests):** 4. Song start after bootstrap fires history with `songId` + correct `ppm = block.cue` 5. Song start on natural advance fires second history call for new song 6. Song start on in-block skip fires history for new song 7. Song start on channel switch fires history for first song of new block 8. Song start on prefetch swap fires history for new block's first song 9. Promo block (`type=P`) — no history call fired 10. Pause → resume fires `update_pause` + history with `pauseFlag=true` 11. Pause position captured correctly — `ppm` on resume call = within-song ms at pause time 12. Pause duration correct — fixed clock, 5s pause → `durationMs=5000` 13. Resume without prior pause — no telemetry fired (guard) 14. Favorites channel (`chan=99`) — `slice_num=null`, event is large ms timestamp string 15. `slice_num=null` sent literally for favorites (not omitted)

**Expected test count: 251 + ~15 = ~266**

---

## Params left as observed literals (no special handling needed)

- `event_num=undefined` — hardcoded string literal, not derived
- `episode_id=0` — hardcoded constant
- `source=24` — same constant used across all RP calls
- `slice_num=null` — same `?? "null"` pattern as `api/play`
- `player_id` — already stored on `LiveRpApiClient`, accessed same as in `play()`
