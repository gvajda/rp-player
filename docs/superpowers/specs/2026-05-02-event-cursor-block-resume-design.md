# Event-Cursor Block Resume — Design

**Date:** 2026-05-02 **Scope:** Replace the `now_playing`-based song-match path with a deterministic per-channel event cursor that drives `get_block`'s `event` query parameter. **Target PR:** Lands before PR 13 (distribution CI). Naming TBD when the implementation plan is written.

---

## 1. Background

PR 12 + follow-ups introduced two stacked fixes for the song-offset bug:

- `BlockSongs.startsAtSeconds` reads `song.elapsed / 1000` directly (absolute file offset).
- `play(channelId:)` fetches `api/now_playing` concurrently with `getBlock`, then `resolveStart(...)` matches the now-playing entry against the block's song list (artist+title, case-insensitive) to pick the in-block start position. `block.cue` is the fallback when no match; first listed song is the final fallback.

Empirical investigation of the `get_block` endpoint reveals a simpler, deterministic protocol that makes the now-playing match unnecessary.

### Verified `get_block` semantics

- `get_block?event=X` returns the block whose **first listed song is event X+1** ("songs after event X").
- Within that response: `event` field = X+1 (first returned song's event id); songs list is trimmed to start at X+1; `cue` = where the first returned song begins inside the audio file (≈ `song[0].elapsed`, ±1 ms).
- The `url` field still points to the same audio file containing event X+1. Multiple `event=X` responses for the same audio block share that URL.
- `end_event` = event id of the last song in the block.

Therefore: passing the previous block's `end_event` as `event` to `get_block` returns the **next** block, with songs starting after that boundary. There is no need to match `now_playing` to a song — the server tells us authoritatively where the listener is by the cursor we hand it.

### Reference fixtures

- `.temp/block.json` (request: `event=2868950`) → response `event=2868951`, song[0] is event 2868951.
- `.temp/block2.json` (request: `event=2868951`) → response `event=2868952`, song[0] is event 2868952.
- Both fixtures share `url=...1919-0.mp3`. `block2.cue` (521275) = `block.cue` (286931) + `block.song[0].duration` (234344).

---

## 2. Goals

- Drop the `now_playing` match path entirely.
- Per-channel in-memory cursor: when the user returns to a channel, resume from where they left off (song granularity).
- Block-end transition uses `event=<end_event>` to fetch the deterministic next block.
- App start / first selection of a channel: no event param → server picks the live block.

## Non-Goals

- Sub-song position resume (millisecond-accurate). Cursor is at song granularity.
- Persisting cursors across app restarts. In-memory only.
- Backwards compatibility with `now_playing` callers — there are none outside the coordinator.
- New tests for `now_playing` API. Path is removed.

---

## 3. Cursor model

`channelCursors: [Int: Int]` lives on `LivePlaybackCoordinator` (actor-isolated). Key = `channelId`. Value = "the event id to pass to `get_block` next time we need a fresh block for this channel" — equivalently, **the event id of the song most recently *finished* or *skipped from* on this channel**.

**Initial state.** Empty. App-start and first channel select find no cursor → `get_block` is issued with `event=nil` and the server returns the live block.

**Update points.** Cursor mutates at exactly four moments. Each writes `channelCursors[currentChannelId] = <event id>` for the **current** channel.

1. **In-block auto-advance.** Engine `positionUpdate` crosses `startsAt[i+1]`. Before incrementing `currentSongIndex`, write `channelCursors[currentChannelId] = orderedSongs[currentSongIndex].event` (the song that just finished).
2. `skipForward()`**in-block** (`nextIndex < orderedSongs.count`). Write `channelCursors[currentChannelId] = orderedSongs[currentSongIndex].event` before mutating index. Engine seeks to `startsAt[nextIndex] + 0.05`.
3. `skipForward()`**past last song.** Write `channelCursors[currentChannelId] = Int(currentBlock.endEvent)`. Then either adopt the prefetched block (preferred) or issue `get_block(event: endEvent)`.
4. **Auto-swap on natural block end** (inside `swapToPrefetchedBlockIfAvailable`). Before swapping, write `channelCursors[currentChannelId] = Int(oldBlock.endEvent)`.

Note that points (3) and (4) write the same value (the just-finishing block's `end_event`).

**No cursor update on channel switch-away.** Cursor already reflects "the last finished/skipped event" by virtue of the four points above. When the user returns to a channel, `play(channelId:)` reads the cursor and issues `get_block(event: cursor)` to resume.

`endEvent`**parsing.** `GetBlock.endEvent` is `String?` in the model. Convert via `Int(endEvent ?? "")`. If parsing fails (nil or non-numeric), log an error and fall back to a no-event call. This is a defensive case — production responses always include a numeric `end_event`.

---

## 4. API surface change

### `RpApiClient`

```swift
func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock
```

`event: nil` issues the no-event call (current behavior). Non-nil appends `event=<id>` to the query.

### `LiveRpApiClient.getBlock`

Append `"event": String(id)` to the query dict when non-nil. Existing alphabetical-sort behavior in `LiveRpApiClient` produces query items in order: `bitrate`, `chan`, `event`, `info`. URL-shape tests must match.

### Removed surface

- `RpApiClient.nowPlaying(channel:)` protocol method.
- `LiveRpApiClient.nowPlaying` impl.
- `NowPlayingEntry` struct in `ApiModels.swift`.
- All `nowPlaying` mocks (`MockRpApiClient.setNowPlayingResponse`, `setNowPlayingError`, recorded-request entries).
- All `nowPlaying` API tests (request URL, decoding, error paths) and fixture files.
- `LivePlaybackCoordinator.resolveStart(...)` private method.

---

## 5. Coordinator changes

### State

- **Add:** `private var channelCursors: [Int: Int] = [:]`
- **Remove:** none. (Existing `currentChannelId`, `currentBlock`, `orderedSongs`, `startsAt`, `currentSongIndex`, `currentPositionSeconds`, `prefetchedBlock`, `prefetchTask` all stay.)

### `play(channelId:)` — simplified

Replaces today's concurrent `async let` + `resolveStart` chain.

```
1. await ensureEventSubscription()
2. let bitrate = await bitrateProvider()
3. let cursor = channelCursors[channelId]                  // may be nil
4. let block = try await api.getBlock(
       channel: channelId, bitrate: bitrate, info: true, event: cursor)
1. let songs = BlockSongs.orderedSongs(from: block)
   guard !songs.isEmpty else { throw .blockHasNoSongs }
1. let starts = BlockSongs.startsAtSeconds(songs: songs)
2. currentChannelId = channelId
   currentBlock     = block
   orderedSongs     = songs
   startsAt         = starts
   currentSongIndex = 0
   currentPositionSeconds = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
1. let startSeconds: Double? = currentPositionSeconds > 0 ? currentPositionSeconds : nil
2. guard let url = URL(string: block.url) else { throw .engineError(...) }
3. try await engine.play(url: url, startSeconds: startSeconds)
4. emitNowPlaying(forSongIndex: 0)
```

No `now_playing` fetch. No matching. The first listed song in the response is what we play; `block.cue` is its starting offset in the audio file.

### `skipForward()`

Same shape as today, with cursor updates inserted:

- **In-block** (`nextIndex < orderedSongs.count`): write cursor (point 2 above) **before** seeking + index advance.
- **Past last song** (`nextIndex == orderedSongs.count`):
  - Write cursor (point 3 above): `channelCursors[currentChannelId] = Int(currentBlock.endEvent ?? "")`.
  - If `prefetchedBlock != nil`: adopt it via `swapToPrefetchedBlockIfAvailable()`. (Cursor is already written, so the swap path's own write is redundant but harmless — see §5.4.)
  - Else, if `prefetchTask != nil`: `prefetchTask?.cancel()`, then issue a synchronous `getBlock(event: cursor)` and replace block.
  - Else: issue a synchronous `getBlock(event: cursor)` and replace block.

In all past-last-song variants, after the new block is in place: `currentSongIndex = 0`, `currentPositionSeconds = newBlock.cue / 1000.0`, `engine.play(url:startSeconds:)`, `emitNowPlaying(0)`.

### `maybeStartPrefetch()`

Trigger logic unchanged (last song + <10s remaining + idempotent guards). Inside the prefetch `Task`:

```swift
let endEvent = Int(currentBlock?.endEvent ?? "")
let bitrate  = await provider()
let result   = try? await api.getBlock(
    channel: channelId, bitrate: bitrate, info: true, event: endEvent)
await self?.absorbPrefetchResult(result)
```

If `endEvent` parses to nil, log error and pass `event: nil`. This is a defensive fallback — production responses always have a numeric `end_event`.

### `swapToPrefetchedBlockIfAvailable()`

Same shape. Insert cursor write (point 4) **before** swapping:

```swift
guard let block = prefetchedBlock else { /* clear state, return */ }
if let oldEnd = Int(currentBlock?.endEvent ?? ""), let chan = currentChannelId {
    channelCursors[chan] = oldEnd
}
prefetchedBlock = nil
// existing swap logic: assign currentBlock/orderedSongs/startsAt/index/position,
// engine.play, emitNowPlaying(0)
```

Seek the engine to `block.cue / 1000.0` rather than `nil` so the new song actually starts where it should — current code passes `startSeconds: nil` which assumes the new audio file begins at song[0]. That assumption was true under the old model (no event param) but is also still true under the new model for prefetched blocks (cue ≈ song[0].elapsed). Use `block.cue / 1000.0` to be explicit and consistent with `play(channelId:)`.

### Engine event handler

In `handleEngineEvent`, the existing in-block boundary-cross path (where `currentSongIndex` increments on position update) is the hook site for cursor update point 1. Insert the write **before** the increment:

```swift
if let chan = currentChannelId,
   let finishedEvent = Int(orderedSongs[currentSongIndex].event) {
    channelCursors[chan] = finishedEvent
}
currentSongIndex = nextIndex
emitNowPlaying(forSongIndex: nextIndex)
```

`PlayListSong.event` is `String` in the model. If `Int(...)` parse fails, skip the cursor write (defensive — production data is always numeric). Same `if let` pattern applies at all four cursor update points.

### `resume()`

Unchanged behaviorally. Still re-issues `play(channelId:)` on expired block. The re-issued call now reads the cursor and resumes correctly.

### `changeChannel(to:)`

Unchanged. The receiving `play(channelId:)` reads `channelCursors[channelId]` for the new channel automatically.

---

## 6. Removed: `now_playing` path

- `RpApiClient.nowPlaying(channel:)` and `LiveRpApiClient.nowPlaying` deleted.
- `NowPlayingEntry` struct deleted from `ApiModels.swift`.
- `LivePlaybackCoordinator.resolveStart(songs:starts:entry:cue:)` deleted.
- The `async let blockFetch` / `async let nowPlayingFetch` pattern in `play` is gone — single `await` on `getBlock`.
- `MockRpApiClient.setNowPlayingResponse(_:)`, `setNowPlayingError(_:)`, recorded-request entries deleted.
- All `LiveRpApiClient` tests for `nowPlaying` request URL and decoding deleted.
- All coordinator tests that mock `nowPlaying` (the three `testPlay…NowPlaying…` cases listed in §7) deleted.
- `now_playing` fixtures deleted from `Tests/RPPlayerTests/Resources/` if present.

---

## 7. Tests

### Delete

- `testPlaySeeksToStartOfSongMatchedByNowPlaying`
- `testPlayUsesCueFallbackWhenNowPlayingHasNoMatch`
- `testPlayStartsFromFirstListedSongWhenBothNowPlayingAndCueMissing`
- `MockRpApiClient.setNowPlayingResponse` / `setNowPlayingError` + related state
- All `nowPlaying` `LiveRpApiClient` URL-shape and decoding tests
- `NowPlayingEntry` decode tests

### Add

- `testPlayWithoutCursorCallsGetBlockWithoutEventParam` — fresh coordinator; play channel 0; assert `MockRpApiClient.recordedRequests.last.event == nil`.
- `testPlayWithCursorCallsGetBlockWithEventParam` — seed cursor via internal hook (or by playing + crossing a boundary); play channel 0 again; assert recorded `event == seeded value`.
- `testInBlockAutoAdvanceUpdatesCursorToFinishedSongEvent` — drive engine `positionUpdate` past `startsAt[1]`; assert cursor for current channel == song[0].event.
- `testSkipForwardInBlockUpdatesCursorBeforeAdvance` — playing song[0]; `skipForward()`; assert cursor == song[0].event AND `currentSongIndex == 1`.
- `testSkipForwardPastLastSongUsesEndEventAsCursorAndFetchParam` — at song[last]; `skipForward()` with no prefetch; assert cursor == old block's endEvent AND new `getBlock` call was issued with `event == endEvent`.
- `testSkipForwardPastLastSongAdoptsPrefetchedBlockWhenAvailable` — set up prefetched block; `skipForward()` past last; assert no extra `getBlock` request, prefetched block adopted, cursor == old endEvent.
- `testSkipForwardPastLastSongCancelsInFlightPrefetchAndFetches` — prefetch task in-flight (mock blocks); `skipForward()` past last; assert prefetch cancelled, synchronous `getBlock(event: endEvent)` issued.
- `testPrefetchUsesEndEventAsEventParam` — drive position into the <10s tail of the last song; assert prefetch issued `getBlock` with `event == currentBlock.endEvent`.
- `testSwapToPrefetchedBlockUpdatesCursorToOldEndEvent` — prefetch present; drive position past `totalDurationSeconds`; assert cursor == old endEvent AND new block in `currentBlock`.
- `testChannelSwitchPreservesCursors` — play channel 0, advance past song[0] (cursor populated), `changeChannel(to: 1)` (no cursor for ch1, no-event call), `changeChannel(to: 0)` (cursor present, event-param call). Assert recorded request sequence.
- `testCursorClearOnFreshAppStartIsNoEvent` — implicit; covered by `testPlayWithoutCursorCallsGetBlockWithoutEventParam`.

### Update

- `MockRpApiClient.getBlock` signature gains `event: Int?`. Recorded-request type gains `event` field.
- `LiveRpApiClient` URL-shape test gains a case asserting `event=...` is appended in alphabetical order (`bitrate`, `chan`, `event`, `info`).
- Existing `getBlock`-call tests assert `event == nil` where they previously didn't care.
- `BlockSongs` tests unchanged (offset model is correct already).
- `MiniPlayerViewModel` / NowPlaying view-model tests unchanged.

### Keep as-is

All engine, hog-mode, settings, album-art, popover, login, keychain, logger, and view-model tests.

### Test-count expectation

Net change: ≈ –10 (delete six now-playing tests including LiveRpApiClient + decoder + 3 coordinator) + ≈ –4 (NowPlayingEntry) + ≈ +11 (new). Land near current 201, within ±5. Final count to be reported in CLAUDE.md after implementation.

---

## 8. Edge cases

- **Cursor for a channel whose block has expired since last listen.** `get_block?event=<old_event>` should still resolve server-side to "the block containing the song after `<old_event>`," which by then is many blocks in the past or simply rolled forward. Per user observation the API tolerates this — we do not need an explicit expiration check. If the response errors, the standard `play` error path applies (user sees error, can re-trigger).
- **App-start cursor on a never-played channel.** No entry → `event: nil` → live block. Correct.
- **Skip-past-last while prefetch still pending.** Cancel `prefetchTask` and issue synchronous fetch with the same `event=endEvent`. Single source of truth, no race.
- `endEvent`**parse failure.** Log error, fall back to `event: nil` (server returns live block). Defensive.
- **Multiple rapid channel switches.** Existing `inFlightChannelId` token in `MiniPlayerViewModel.selectChannel` already handles this; cursor logic does not interact with it because cursor is read once at the top of `play(channelId:)`.

---

## 9. Files touched

- `Sources/RPPlayer/Api/RpApiClient.swift` — protocol + impl signature change; remove `nowPlaying`.
- `Sources/RPPlayer/Api/ApiModels.swift` — remove `NowPlayingEntry`.
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — cursor map, simplified `play`, cursor writes in 4 places, remove `resolveStart`, prefetch event param, swap path cursor write.
- `Tests/RPPlayerTests/Api/RpApiClientTests.swift` (or equivalent) — drop `nowPlaying` tests, add `event` query test.
- `Tests/RPPlayerTests/Mocks/MockRpApiClient.swift` — signature change, add `event` recording, remove `nowPlaying` mocks.
- `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift` — drop 3 now-playing tests, add ~10 cursor tests.
- `Tests/RPPlayerTests/Resources/` — delete `now_playing*.json` fixtures if present.
- `CLAUDE.md` — update "Coordinator playback" and "API client" sections to reflect cursor model + dropped `now_playing`. Update test-count line after impl.

`docs/DESIGN.md` is not touched (this is internal coordinator behavior, not the user-facing architecture).
