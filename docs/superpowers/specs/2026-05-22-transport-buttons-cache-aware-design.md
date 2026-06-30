# Cache-Aware Transport Buttons + Stop Action

**Date:** 2026-05-22
**Scope:** PR after PR 41 (PR 42 candidate)
**Touches:** `MiniPlayerView`, `MiniPlayerViewModel`, `PlaybackCoordinator` (protocol + Live impl), test mocks.

## Goal

Make the popover transport reflect cache state honestly:

1. Loading icon moves to the **skip slot** when the next song isn't yet queued in mpv (preserves user's ability to pause the currently-playing track).
2. When paused, the second slot becomes a **stop** button that clears the queue and now-playing/art state (returns popover to the just-launched look while keeping the channel selection).

Slot 1 (left) keeps the existing play/pause/loading-on-initial-start behavior unchanged.

## Motivation

- Today the play/pause button itself can be replaced by the loading spinner mid-session (skipForward defer path at `PlaybackCoordinator.swift:357` emits `.loading`). When that happens the user loses the ability to pause an actively-playing song. The reported symptom — "song plays but the loading icon is still on" — is this state leaking.
- The skip button is currently always enabled while playing, so a skip request can outrun the cache and produce a stall.
- There is no way to fully clear queue/art/now-playing from the UI without quitting.

## State table (final)

| Condition | Slot 1 | Slot 2 |
|---|---|---|
| `nowPlaying == nil && !isLoading` (stopped / fresh app) | `play.circle` — plays selected channel | `forward.end.fill`, **disabled** (unchanged) |
| `isLoading` (initial play, before first audio) | spinner, disabled (unchanged) | `forward.end.fill`, **disabled** |
| `isPlaying && nextReady` | `pause.circle` | `forward.end.fill`, **enabled**, `skipForward` |
| `isPlaying && !nextReady` | `pause.circle` | spinner, **disabled** |
| `nowPlaying != nil && !isPlaying && !isLoading` (paused) | `play.circle` — resume | **`stop.fill`, enabled, `stopPlayback`** |

`nextReady := queue.count >= 2 && queueNextEventId == queue[1].eventId`.

## Architecture

### New signal: `nextReady`

Add to `PlaybackCoordinator` protocol:

```swift
var nextReady: Bool { get async }
var nextReadyUpdates: AsyncStream<Bool> { get async }
```

`LivePlaybackCoordinator` implementation:

- Private `private var nextReadyValue: Bool = false`.
- Private `private var nextReadyContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]`.
- Public computed `nextReady` returns `nextReadyValue`.
- Public `nextReadyUpdates` mirrors the existing `stateUpdates` pattern (broadcast stream, replay current value on subscribe).
- Private helper `private func updateNextReady()` recomputes `queue.count >= 2 && queueNextEventId == queue[1].eventId`, yields on change only.
- Call sites that must call `updateNextReady()`:
  - After every `queueNextEventId =` assignment (set or nil).
  - After every `queue =` assignment (queue mutated → membership/index could change).
  - In `tryQueueNextOrDefer` after both success (sets `queueNextEventId`) and defer (clears it via `deferredQueueNextAt`).
  - In `stop()` (forces `false`).
- Ergonomic option: wrap `queueNextEventId` mutations in a `didSet`. Swift property observers fire on every set, including no-op writes, so `updateNextReady` must early-out when value unchanged. Same idea for `queue`. **Recommendation: explicit calls, not didSet** — too many sites already mutate both fields, and `didSet` runs even when the new value equals the old, causing redundant emissions and noisy logs.

### View model: subscribe + derive

`MiniPlayerViewModel`:

- New `@Published private(set) var nextReady: Bool = false`.
- In `start()`: seed from `await coordinator.nextReady`, then `Task { for await ready in await coordinator.nextReadyUpdates { ... } }` updating on MainActor.
- New `func stopPlayback() async`:
  - Clear `errorMessage`.
  - Call `try await coordinator.stop()`. Coordinator already emits `.stopped`.
  - View model's `.stopped` handler does the visual clearing (see below).
- Extend the `.stopped` branch in `stateUpdates` listener to also clear: `nowPlaying = nil`, `currentArt = nil`, `lastLoadedCoverPath = nil`, `ambientTopColor = nil`, `currentRating = nil`, `currentBitrateLabel = nil`, `songElapsedSeconds = 0`, `songDurationSeconds = 0`, `lastNotifiedSongId = ""`.
  - **Why on `.stopped` (not in `stopPlayback()` directly):** keeps view model invariants symmetric — anywhere the coordinator transitions to stopped (user-initiated or otherwise) the popover ends up in the fresh-app state. Today there is no automatic `.stopped` transition outside `stop()` and `errors`, so the change is behavior-equivalent for non-stop paths.
- Do NOT touch `selectedChannelId` — channel selection persists across stop.

### View: slot 2 logic

`MiniPlayerView.transport`:

- Compute slot-2 mode once: `isPaused = nowPlaying != nil && !isPlaying && !isLoading`; `showLoadingInSkipSlot = isPlaying && !nextReady`.
- Three branches:
  - `isPaused` → render stop button (`stop.fill`, 22pt, `PressOpacityButtonStyle`, calls `viewModel.stopPlayback()`, label "Stop").
  - `showLoadingInSkipSlot` → render the existing loading composition (the `ZStack` with `Image("circle")` + small `ProgressView`) scaled down to fit the 38×38 frame at ~22pt visual weight. **Decision:** use the same ZStack pattern as slot 1 but with `Image(systemName: "circle")` at `.font(.system(size: 22))` and the small ProgressView; disabled; accessibility label "Loading next track".
  - else → existing skip button.

Slot size stays `38×38`. No layout shift across modes.

### Test mocks

`MockPlaybackCoordinator` (used by `MiniPlayerViewModelTests` + others):

- Add `var nextReadyValue: Bool = false` and broadcast continuations matching `stateUpdates`.
- Add helper `func setNextReady(_ value: Bool)` for tests to flip the signal and assert UI / view-model state.
- Update existing tests that observe `stateUpdates` to ignore the new stream (no-op if not subscribed).

## Tests to add

**Coordinator (LivePlaybackCoordinatorTests):**
- `nextReady starts false`.
- After `play(channelId:)` succeeds with queue[1] cached → emits `true`.
- After `play(channelId:)` succeeds with queue[1] cache miss → emits `false` initially; emits `true` once `tryQueueNextIfPending(landed:)` fires.
- After `skipForward()` defer path → emits `false` then `true`.
- After `stop()` → emits `false`.
- No duplicate emissions on same value (test counts continuation yields via mock).

**View model (MiniPlayerViewModelTests):**
- `nextReady` published value mirrors stream.
- `stopPlayback()` calls `coordinator.stop()` and after `.stopped` arrives, `nowPlaying`, `currentArt`, `ambientTopColor`, etc. are nil; `selectedChannelId` unchanged.
- Sequence: `.playing` + `nextReady=false` produces expected combined view state (covered indirectly via existing isPlaying/isLoading tests + the new nextReady channel — a small dedicated combinator test).

**View (snapshot or property check):** none. SwiftUI view body has no current snapshot harness in the repo; rely on view-model tests + manual verification per `run` skill.

## Out of scope

- Reworking `skipForward()`'s internal `.loading` emit. The new `nextReady` signal makes the user-facing behavior correct because the play/pause icon no longer flips to loading mid-skip. `PlaybackState.loading` retains its session-startup meaning and is still emitted by skipForward defer, which is now visually ignored by slot 1 (covered by `isPlaying` staying true… actually false — see open question below).
- Stop confirmation prompt. Single click, irreversible. Channel reselect costs nothing.
- Keyboard shortcuts.

## Open issue: `.loading` emit during active playback

`.loading` is currently emitted from several sites mid-playback while audio is still being produced by mpv:
- `skipForward()` defer branch (`PlaybackCoordinator.swift:357`).
- `applyBitrateChange()` (line 391).
- `handleSongPlaybackError()` recovery path.
- `syncQueueHeadFromMpv` advance branch (recovery flow around line 615).

Each of these sets `isLoading=true, isPlaying=false` in the view model, producing the exact bug the user reported ("song plays but loading icon is still on"). With the new spec, slot 1 must stay on `pause.circle` whenever mpv is actually producing audio.

**Resolution:** redefine `PlaybackState.loading` to mean "no audio is being produced right now" — emitted only when:
- session is starting from stopped (current `play()` use at line 148), or
- mpv has actually stopped/halted and we're rebuilding (e.g., `handleSongPlaybackError` after an engine error).

Refactor:
- Remove the `emitState(.loading)` at `skipForward()` defer (357), `applyBitrateChange()` (391), and the syncQueueHeadFromMpv advance branch. These pre-load the *next* track while the current track is still playing — that's `nextReady=false`, not session loading.
- Keep `.loading` in `play()` initial path and in `handleSongPlaybackError` recovery when engine has actually stopped (audit per case).
- Add a regression test: with mpv state "playing" and queue[0] producing audio, no path may emit `.loading` until queue[0] finishes / errors.

This is part of the PR, not a follow-up. The button rules and the state semantics are co-dependent — shipping the buttons without the state cleanup would still flash spinner-instead-of-pause.

## Risks

- **Race between `queue` mutation and `queueNextEventId` mutation.** Recompute both immediately after the pair settles, not in between. The actor isolation guarantees no interleaving across awaits within a single mutator, but care needed if either field is touched across an `await` boundary. Audit each call site during planning.
- **State stream replay semantics.** New stream must replay current value on subscribe (matches `stateUpdates` pattern). Otherwise a subscriber that joins after a `true` emission stays at `false`.

## Acceptance

- All five rows of the state table verified in app (manual via `run` skill).
- Test count moves from 548 → ~560 (rough estimate; final in PR).
- `CHANGELOG.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md` updated per project convention.
