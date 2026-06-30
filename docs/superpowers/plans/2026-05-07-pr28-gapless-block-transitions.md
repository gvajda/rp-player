# PR 28 — Gapless block transitions (mpv playlist append-play)

**Date:** 2026-05-07
**Branch:** `claude/pr28-gapless-block-transitions`
**Goal:** Eliminate audible 200–2000 ms gap on every block boundary (most painful around promo blocks: music → promo → music = two `loadfile replace` cycles back-to-back). Concurrently widen prefetch trigger to "last song of block starts" so single-song blocks (promo, favorites, occasional 1-song music) start prefetching from the moment they begin playing instead of waiting for the time-based 10 s window.

---

## Problem recap

Current flow on EOF (`PlaybackCoordinator.swift:415-419`, `:639-675`):

1. mpv emits `MPV_EVENT_END_FILE` with `MPV_END_FILE_REASON_EOF`.
2. Coordinator calls `swapToPrefetchedBlockIfAvailable` → `engine.play(url:startSeconds:)`.
3. Engine runs `loadfile <url> replace` (`MpvPlayerEngine.swift:173-180`).
4. mpv tears down current AO + demuxer, opens new HTTP, fills demuxer cache, restarts AO. Cost: 200 ms (warm CDN) – 2000 ms (cold network / FLAC start). User hears silence.

Prefetch handles only the API round-trip — once the JSON is in hand, mpv still does the entire HTTP open + buffer fill synchronously after EOF. The gap is mpv's, not the API's.

Additionally `maybeStartPrefetch` (`:595-620`) gates on `currentSongIndex == orderedSongs.count - 1 && remaining < 10.0`. For multi-song blocks the 10 s ceiling is fine; for single-song blocks it forces a wait inside a ≤5 s file. We want prefetch the moment the last song begins regardless of block length.

## Fix at a glance

- mpv has `--prefetch-playlist=yes` plus `loadfile <url> append-play` which, together, open the next playlist entry on mpv's demuxer thread *while the current entry is still playing*. At EOF mpv switches without rebuilding the AO. This is the same mechanism mpv-mpris / smarttv setups use for gapless album playback.
- Coordinator queues the next block as soon as prefetch lands instead of waiting for EOF.
- Coordinator's "swap state" moves from `fileEnded(.eof)` to a new `MPV_EVENT_START_FILE → PlayerEvent.fileStarted` so the state flip happens precisely when mpv switches to the queued file (avoids a window where audio = new block but `currentBlock` = old).
- Prefetch trigger: drop the `remaining < 10.0` guard. Add a single-shot trigger in `emitNowPlaying` so single-song blocks prefetch without waiting for the first whole-second `time-pos` tick.

## Detailed design

### 1. Engine surface

```swift
// PlayerEngine.swift (protocol)
func queueNext(url: URL, startSeconds: Double?) async throws

// PlayerEvent.swift
case fileStarted          // mpv started playing a new playlist entry
```

`MpvPlayerEngine`:

- Add `("prefetch-playlist", "yes")` to baseline options. Required for mpv to actually pre-open the queued URL; without it `append-play` only starts the HTTP after the previous entry ends (no benefit).
- `queueNext(url:startSeconds:)` runs `loadfile <url> append-play start=<n>` (`start=` omitted when `nil`). One mpv command, no waiting on `MPV_EVENT_FILE_LOADED` (the bridge will surface it later when mpv's worker thread is ready).
- `MpvEventBridge.playerEvent(from:)` translates `MPV_EVENT_START_FILE` → `.fileStarted`.

### 2. Coordinator state machine

Add private state: `var queuedToEngine: Bool = false`.

Flow in normal music → music transition:

| Step | Coordinator state | Engine state |
| --- | --- | --- |
| Last song of block A starts | `prefetchTask` fires | A playing |
| Prefetch lands | `prefetchedBlock = B`, `queueNext(B.url, B.cue)`, `queuedToEngine = true` | A playing, B opening on demuxer thread |
| A reaches EOF | `fileEnded(.eof)` arrives. **Skip** the existing `swapToPrefetchedBlockIfAvailable` call when `queuedToEngine`. State unchanged. | mpv auto-advances to B (gapless) |
| mpv emits START_FILE for B | `.fileStarted` → `swapToPrefetchedBlockIfAvailable` runs the **state-only** path (no engine call) | B playing |

Flow when prefetch did *not* land before EOF (fallback to today's behaviour):

| Step | Coordinator state | Engine state |
| --- | --- | --- |
| EOF | `fileEnded(.eof)`, `queuedToEngine == false` | A torn down |
| Coordinator | `swapToPrefetchedBlockIfAvailable` → `engine.play(replace)` (existing path) | B opening |
| START_FILE | `.fileStarted` ignored when state was already swapped synchronously | B playing |

Idempotency guard for `.fileStarted`: only swap when `queuedToEngine == true`. Reset the flag at the bottom of every swap.

### 3. swapToPrefetchedBlockIfAvailable refactor

Split current method into:

- `swapToPrefetchedBlockState()` — pure state mutation (assigns `currentBlock`, `orderedSongs`, `startsAt`, `currentSongIndex = 0`, `currentPositionSeconds = startPos`, calls `emitNowPlaying`, fires telemetry). No engine call.
- `swapToPrefetchedBlockIfAvailable()` — current behaviour, calls `swapToPrefetchedBlockState` then `engine.play(replace)`. Used only on the fallback path.

`.fileStarted` handler calls `swapToPrefetchedBlockState`. `.fileEnded(.eof)` handler runs the gapless-vs-fallback decision:

```swift
case .fileEnded(let reason):
    if case .eof = reason {
        if queuedToEngine {
            // mpv auto-advanced; defer swap until START_FILE arrives.
            // Logging only.
        } else {
            await swapToPrefetchedBlockIfAvailable()  // existing fallback
        }
    }
    // unplayable-block branch unchanged
```

### 4. Prefetch trigger

```swift
private func maybeStartPrefetch() {
    guard let channelId = currentChannelId,
          !orderedSongs.isEmpty,
          currentSongIndex == orderedSongs.count - 1,
          prefetchedBlock == nil,
          prefetchTask == nil else { return }
    // (drop the remaining < 10.0 guard)
    ...
}
```

Also call `maybeStartPrefetch()` at the end of `emitNowPlaying(forSongIndex:)`. This covers two cases the position-update path doesn't: (a) single-song blocks where `currentSongIndex == 0 == count - 1` from the start, and (b) `skipForward` in-block to the last song before any new position event arrives.

`absorbPrefetchResult` extension: after assigning `prefetchedBlock`, also call `engine.queueNext(url:startSeconds:)` and set `queuedToEngine = true`. Wrap in `try?`; on failure log and leave `queuedToEngine = false` so the EOF fallback path picks up.

### 5. skipForward interactions

Today `skipForward` past last song (`:305-348`):

- If `prefetchedBlock != nil` → `swapToPrefetchedBlockIfAvailable` (currently does engine.play replace).
- Else cancel prefetch task and fetch synchronously.

With queued-to-engine state we have a third case:

- `queuedToEngine == true && prefetchedBlock != nil` → user wants *immediate* advance, not gapless. Fastest path: run `playlist-next force` (mpv command — drops the rest of the current entry and jumps to queued). Fall through to the existing state-flip via `START_FILE`. Add an engine method `advanceToQueued()`.
- `queuedToEngine == false && prefetchedBlock != nil` → existing replace path.
- Neither → existing synchronous fetch.

For in-block skipForward (`nextIndex < count`) nothing changes.

### 6. changeChannel / stop

`changeChannel` and `stop` must drop any queued-but-not-started entry from mpv's playlist before tearing down. Add `engine.clearPlaylist()` issuing `playlist-clear`. Call before `engine.stop()`. Reset `queuedToEngine = false` in coordinator's existing prefetch-cleanup blocks (`stop`, `changeChannel`, `handlePlaybackError`, `advancePastUnplayableBlock`).

### 7. Block-expiration / long-idle resume

Resume path (`:215-261`) refetches via `play(channelId:)`. Before the new fetch, we need to clear any queued entry (otherwise mpv might auto-advance to a stale URL). Easiest: wrap the existing `try await play(channelId:)` with `engine.clearPlaylist()` first. Reset `queuedToEngine = false`.

### 8. Edge cases / verification

- **FLAC → AAC AO format change.** mpv defaults to `audio-format=auto` — when the next file's format differs the AO may need to be reopened. With hog mode active, mpv holds the device, but a brief mute/click is possible. Verify by listening to a music (FLAC) → promo (AAC) transition under hog mode. If audible: try `--audio-format=floatp --audio-channels=stereo --audio-samplerate=48000` to pin the AO format (RP delivers everything at 48 kHz / 2 ch).
- **Signed CDN URL TTL.** RP block URLs come from `api/play`. Check `block.expiration` vs the URL's effective lifetime — `expiration` is the *playlist* expiration in the JSON, separate from any signed-URL TTL on the audio file. If audio URLs expire faster than the queue lead time (e.g. last-song duration), the queued open will 404 and mpv will emit `END_FILE error`. The existing `advancePastUnplayableBlock` recovery handles this — but worth measuring TTL on a few real URLs first to know whether it's a daily issue or rare.
- **Prefetch arrives after EOF.** Race window: EOF emits, coordinator runs fallback `engine.play(replace)`, then prefetch lands and `queueNext` queues B *behind* the now-playing B. Guard: in `absorbPrefetchResult`, only `queueNext` when there's still a `currentBlock` whose URL matches `engine`'s current entry. Cleanest is to track `queuedFor: GetBlock?` and bail if it doesn't match the present `currentBlock` at queue time.
- **Pause across block boundary.** User pauses mid-last-song. mpv keeps the queued entry. On resume, position update resumes, EOF eventually fires, queued switch happens. No special handling. (Long-idle resume path *does* need clearPlaylist as noted.)
- **Engine error mid-queue.** `currentBlock` AO fails (`-14`). `handlePlaybackError` already cancels prefetch and clears state. Also call `clearPlaylist` so mpv doesn't auto-advance into the queued entry while the error is being surfaced.
- **Two consecutive single-song blocks (promo → favorites quirk?).** If RP ever serves promo→promo, single-song each, prefetch fires immediately on entering the first promo, queue lands, EOF, fileStarted, prefetch fires again on entering the second promo. Each block prefetches once because `prefetchedBlock != nil` + `prefetchTask != nil` guard the `maybeStartPrefetch` call from re-entering. Verify the reset: `prefetchedBlock = nil` in `swapToPrefetchedBlockState`. Already true in current code.

### 9. Tests

Existing tests rely on `swapToPrefetchedBlockIfAvailable` running `engine.play` from `fileEnded(.eof)`. Need updating once the engine path moves to `START_FILE`. New + updated tests:

- `MpvPlayerEngineTests`:
  - `queueNext_appendsLoadfileWithAppendPlay` — verify command shape via existing fake mpv capture.
  - `queueNext_omitsStartWhenNil`.
  - `prefetchPlaylistOptionSetAtInit`.
- `MpvEventBridgeTests`:
  - `startFileEventTranslatesToFileStarted`.
- `LivePlaybackCoordinatorTests`:
  - `prefetchFiresOnLastSongRegardlessOfRemainingTime` — single-song block, position update at 1 s out of 5 s total ⇒ prefetch task set.
  - `prefetchFiresFromEmitNowPlayingForSingleSongBlock` — bypasses position-update-driven trigger.
  - `absorbPrefetchResultQueuesNextOnEngine` — fake engine records `queueNext(url:start:)`.
  - `fileEndedEofWithQueuedDoesNotInvokeEnginePlay` — assertion: zero new `engine.play` calls.
  - `fileStartedWithQueuedSwapsState` — currentBlock flips to prefetched on `.fileStarted`.
  - `fileEndedEofWithoutQueuedFallsBackToReplace` — preserves today's behaviour when prefetch missed.
  - `skipForwardPastLastWithQueuedAdvancesViaPlaylistNext` — fake engine records `advanceToQueued`.
  - `changeChannelClearsPlaylistBeforeStop`.
  - `resumeLongIdleClearsPlaylistBeforeRefetch`.
  - `handlePlaybackErrorClearsPlaylist`.
- Update existing tests that drove the swap through `fileEnded(.eof)` to also emit `.fileStarted` after.

Total expected delta: +10–12 new tests, ~5 modified.

### 10. Observability

Add debug logs:

- `engine queueNext url=… start=…s` (engine).
- `prefetch absorbed; queueing on engine` (coordinator success).
- `prefetch absorbed; queue failed: …` (coordinator failure → fallback).
- `gapless transition: file started, swapping state` (coordinator on fileStarted with queued).
- `eof fallback: prefetch missed, replacing` (coordinator on eof without queued).
- `clearPlaylist on changeChannel/stop/error/long-idle-resume`.

Default logging level. Verbose unchanged.

## Implementation order (subagent-driven)

Each step: subagent writes code + tests, second subagent reviews quality, main loop verifies, commit.

1. **Engine: queueNext + clearPlaylist + advanceToQueued + fileStarted event + prefetch-playlist option.** Self-contained engine PR within a PR. Tests in `MpvPlayerEngineTests` + `MpvEventBridgeTests`. No coordinator wiring yet. Existing tests must pass.
2. **Coordinator: prefetch trigger widening (drop time guard, hook emitNowPlaying).** Doesn't touch engine. Fixes the single-song prefetch latency on its own. Tests pass.
3. **Coordinator: gapless wiring.** absorbPrefetchResult → queueNext. fileStarted → swapToPrefetchedBlockState. fileEnded(.eof) split. skipForward / changeChannel / resume / handlePlaybackError clearPlaylist. Update affected tests.
4. **Manual smoke.** Real RP stream via `swift run RPSmoke` (or `.app` if hog mode is needed for verification). Listen to a full music → promo → music transition. Confirm no audible gap on either boundary. Try with hog mode on + force-max on. Try with the network throttled (`Network Link Conditioner` 3G profile) to confirm graceful fallback when prefetch can't keep up.
5. **Update CLAUDE.md** with the gapless mechanism + the new engine surface + the new prefetch trigger semantics.

## Risks & open questions

- **mpv AO behaviour at format boundary.** Most likely fine but worth listening for clicks. If problematic, pin AO format. Quick experiment before locking the PR scope.
- **Signed-URL expiry.** Need to inspect a few real `block.url` strings for HMAC/TTL params. If TTL < typical block duration this fix changes failure mode (queued URL 404 instead of fresh fetch). Still better UX overall but worth confirming the recovery path covers it cleanly.
- **`playlist-next force`.** mpv docs say it works on idle/playing playlists. Verify it doesn't deadlock the AO. Alternative: `playlist-remove current` then `loadfile replace`.
- **Test bundle behaviour with `prefetch-playlist=yes`.** Tests use `ao=null` under XCTest. Prefetch shouldn't open real network in tests because the URLs are stubbed via `StubURLProtocol` — but mpv's HTTP fetch goes through its own demuxer, not URLSession. Verify tests don't hit real CDNs. If they do: gate prefetch-playlist on `!underXCTest`.

## Out of scope (defer)

- Cross-channel gapless. `changeChannel` always runs `stop` then `play` — the change is a hard cut by definition.
- Skip-backward / rewind. RP is live; not supported.
- Visual indicator that the next block is ready. Possible UX nice-to-have, not required.
