# Popover Visual Polish — Design

Date: 2026-05-02
Status: Approved (design phase)
Scope: A single, focused PR that updates the menu-bar popover layout and one piece of underlying playback plumbing required to drive it.

## Goals

Five user-visible changes to the popover, plus the minimum coordinator/view-model wiring required to drive them:

1. Album art fills the top of the popover edge-to-edge (no surrounding padding; popover appears as an extension of the artwork).
2. A non-interactive progress bar for the current song with elapsed time on the left and total duration on the right, both under the bar.
3. Replace the full-width 1–10 rating strip with a narrow dropdown (`Menu`) sitting in the title row, right-aligned. Label shows the current rating digit or `-`.
4. Drop the SwiftUI press-state blue background on the play button (and skip button, for consistency).
5. Add a Quit action. The settings gear becomes a `Menu` containing **Settings…** and **Quit RP Player**.

## Non-goals

- No changes to the bitrate label, channel picker, error banner, or footer copy.
- No changes to engine, hog mode, API client, or persistence layer.
- No new tests beyond the ones listed in §Testing.
- No new time-format helper (inline `String(format:)` is fine for `mm:ss`).
- No animation/styling beyond default `ProgressView` visuals.

## Architecture

### Coordinator: position stream

`PlaybackCoordinator` (protocol) gains:

```swift
var positionUpdates: AsyncStream<Double> { get async }
```

`Double` is the block-position in seconds (same reference frame as `NowPlaying.songStartSeconds` / `songEndSeconds` — i.e. absolute file offset, not in-song offset).

`LivePlaybackCoordinator` already receives `.positionUpdate(seconds)` engine events inside `handleEngineEvent`; the new stream yields each value to all registered continuations. Implementation mirrors `nowPlayingUpdates`:

- Per-call continuation registered in a `[UUID: AsyncStream<Double>.Continuation]` map.
- `getter` builds a fresh `AsyncStream`, registers the continuation, and seeds it with the current `currentPositionSeconds` (so first subscriber sees a value immediately).
- On every `.positionUpdate(seconds)` engine event, the actor yields to all continuations.
- On `shutdown`, finishes all continuations.

A noop coordinator stub used by tests returns `AsyncStream { _ in }` (never yields).

### View model

`MiniPlayerViewModel` gains:

- `@Published var songElapsedSeconds: Double = 0`
- `@Published var songDurationSeconds: Double = 0`
- A second subscription `Task` started by `start()` that consumes `coordinator.positionUpdates`.

Update rule on each yielded `position` (block-position seconds):

```
let np = self.nowPlaying  // captured snapshot, may be nil
guard let np else { return }
let elapsed = max(0, position - np.songStartSeconds)
let duration = max(0, np.songEndSeconds - np.songStartSeconds)
let clamped = min(elapsed, duration)
self.songElapsedSeconds = clamped
self.songDurationSeconds = duration
```

On every `nowPlaying` change (existing subscription path), reset `songElapsedSeconds` to 0 and update `songDurationSeconds` to `np.songEndSeconds - np.songStartSeconds` so the bar resets at song boundaries before the first new position tick lands.

Existing `inFlightChannelId`-style guards do not apply — the position stream is a passive update stream.

### View

`MiniPlayerView` body restructured to permit edge-to-edge album art:

```
VStack(spacing: 0) {
    errorBanner            // unchanged content; needs its own padding now
    albumArt               // 342×342, no horizontal padding, top-aligned
    VStack(spacing: 12) {
        titleStack         // now an HStack with rating menu on the right
        progressRow        // new
        channelRow         // unchanged
        transport          // updated button style
        footer             // unchanged copy
    }
    .padding(12)
}
.frame(width: 342)
.task { await viewModel.start() }
```

Outer `.padding(12)` on the root is removed. Inner content keeps 12pt padding via the inner `VStack`.

#### `albumArt`

- `frame(width: 342, height: 342)` (was 318×318 with 6pt corner radius).
- Drop `cornerRadius(6)`. Outer popover already has 10pt rounded corners with `masksToBounds = true`, so the top corners of the art are clipped naturally as part of the popover shape. Bottom of the art is flush with the inner stack.
- Placeholder (when `currentArt == nil`): same `music.note` symbol, scaled to fit, centered, with `.background(Color(nsColor: .controlBackgroundColor))` so the area is visible before art loads.
- `Image(nsImage:).resizable().scaledToFill().frame(width: 342, height: 342).clipped()` — `scaledToFill` (not `scaledToFit`) so non-square art covers the area; clipping prevents overflow. RP album art is consistently square in practice, but `scaledToFill+clipped` is a defensive default.

#### `titleStack` (now horizontal)

```
HStack(alignment: .center, spacing: 8) {
    VStack(spacing: 2) { title; artist; album-if-present }
        .frame(maxWidth: .infinity, alignment: .leading)
    RatingMenu(currentRating: vm.currentRating, isSignedIn: vm.isSignedIn) { ... }
}
.frame(width: 318)
```

Width 318 keeps the inner content column the same as before (popover 342 minus 12pt left/right inner padding).

#### `RatingMenu` (new SwiftUI view, replaces `RatingRow` in the layout)

```swift
struct RatingMenu: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        Menu {
            ForEach((1...10).reversed(), id: \.self) { value in
                Button("\(value)") { onRate(value) }
            }
        } label: {
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isSignedIn)
        .help(isSignedIn ? "Rate this song" : "Sign in to rate")
        .accessibilityLabel("Rating")
    }

    private var label: String {
        if let r = currentRating { return "\(r)" }
        return "—"
    }
}
```

Notes:
- Items reversed (10 → 1) so the highest rating is at the top of the menu. Optional but conventional for "stars-style" pickers; flip if you prefer ascending.
- No "Clear" item. The RP API endpoint for clearing isn't wired up; if needed later, add a `Button("Clear", role: .destructive)` and an `onClear` callback. Out of scope for this spec.
- `RatingRow` (the 1–10 strip) is **deleted** from the codebase along with its tests, since it has no remaining usage. Tests for the new `RatingMenu` cover the same surface.

#### `progressRow` (new)

```swift
private var progressRow: some View {
    VStack(spacing: 2) {
        ProgressView(value: viewModel.songElapsedSeconds,
                     total: max(viewModel.songDurationSeconds, 0.001))
            .progressViewStyle(.linear)
        HStack {
            Text(formatTime(viewModel.songElapsedSeconds))
            Spacer()
            Text(formatTime(viewModel.songDurationSeconds))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .frame(width: 318)
}

private func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}
```

`max(duration, 0.001)` avoids `ProgressView` div-by-zero when `nowPlaying == nil` (the bar renders empty in that case).

#### `transport` — drop press-state blue

New file `Sources/RPPlayer/Shell/PressOpacityButtonStyle.swift`:

```swift
import SwiftUI

struct PressOpacityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .contentShape(Rectangle())
    }
}
```

Apply via `.buttonStyle(PressOpacityButtonStyle())` to both transport buttons (play/pause and skip). Replaces the existing `.buttonStyle(.plain)` calls. The existing `.foregroundStyle(.tint)` on play/pause is preserved.

#### `channelRow` — gear becomes a Menu

```swift
Menu {
    Button("Settings…") { viewModel.openSettings() }
    Divider()
    Button("Quit RP Player") { NSApp.terminate(nil) }
} label: {
    Image(systemName: "gearshape")
        .font(.system(size: 14, weight: .regular))
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
.frame(width: 22, height: 22)
.accessibilityLabel("Settings")
```

`NSApp.terminate(nil)` calls into the standard AppKit termination path. `AppDelegate.applicationWillTerminate` already handles graceful coordinator shutdown, so no new shutdown plumbing is needed.

## Data flow summary

```
Engine ──positionUpdate(s)──▶ LivePlaybackCoordinator.handleEngineEvent
                                  │
                                  ├─▶ existing: currentPositionSeconds, song-boundary detection, NowPlaying emit
                                  └─▶ NEW: yield s to all positionUpdates continuations
                                            │
                                            ▼
                                  MiniPlayerViewModel position-subscription Task
                                            │  derives songElapsedSeconds, songDurationSeconds
                                            ▼
                                  MiniPlayerView progressRow re-renders
```

## Testing

New unit tests in `Tests/RPPlayerTests/`:

1. **`LivePlaybackCoordinatorTests.testPositionUpdatesYieldsToSubscribers`** — drives the coordinator with engine events including `.positionUpdate(12.5)`, asserts subscribers receive `12.5`.
2. **`LivePlaybackCoordinatorTests.testPositionUpdatesSeedsCurrentPositionToNewSubscribers`** — after some position events have flowed, a fresh subscriber receives the most recent value as its first element.
3. **`MiniPlayerViewModelTests.testPositionUpdateDerivesElapsedAndDuration`** — given `NowPlaying(songStartSeconds: 100, songEndSeconds: 280)` and a position yield of `145`, asserts `songElapsedSeconds == 45` and `songDurationSeconds == 180`.
4. **`MiniPlayerViewModelTests.testSongChangeResetsElapsed`** — after some non-zero elapsed, emitting a new `NowPlaying` (different `songStartSeconds`) resets `songElapsedSeconds` to 0 before the next position tick lands.
5. **`MiniPlayerViewModelTests.testElapsedClampedToDuration`** — position past `songEndSeconds` clamps elapsed to duration (avoids progress > 1.0 during the boundary-crossing race window).

Existing `RatingRow` tests are deleted; new tests added:

6. **`RatingMenuTests.testLabelShowsDashWhenUnrated`**
7. **`RatingMenuTests.testLabelShowsRatingValue`**
8. **`RatingMenuTests.testDisabledWhenSignedOut`**

(Implementation detail: rating menu tests use the existing `NSHostingController` smoke pattern from `RatingRowTests` — render the view, assert no crash and non-zero intrinsic size, then exercise the `onRate` closure path indirectly via the `MiniPlayerViewModel` when needed. Disabled-when-signed-out is asserted by checking the rendered view's accessibility / `isSignedIn` flag pass-through, not by simulating user interaction.)

No new tests for the layout changes themselves (album-art fill, gear-menu, press-state). These are pure SwiftUI structural edits and are validated by manual smoke.

## Manual smoke checklist (post-implementation)

1. Open popover. Album art fills the top edge-to-edge; no visible border between art and popover top.
2. Light mode and dark mode: popover edges still rounded; bottom of art meets inner content cleanly.
3. Press play, watch progress bar advance and elapsed counter increment. Total duration matches song length.
4. Skip forward: progress bar resets; elapsed and total update for the new song.
5. Pause: progress bar stops; resume: progress bar continues from where it was.
6. Rating menu: shows current rating digit or `-`. Open it; pick a value; menu closes; new digit appears.
7. Sign-out state: rating menu shows `-` and is disabled (greyed).
8. Tap play button rapidly: no blue flash, just the opacity dim. Same for skip.
9. Tap gear: menu opens with "Settings…" and "Quit RP Player". Settings opens settings window. Quit terminates the app cleanly.
10. Gear menu vs. press-state: no blue press-flash on the gear itself.

## Files touched

| Path | Change |
|---|---|
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Add `positionUpdates: AsyncStream<Double>` to protocol; implement on `LivePlaybackCoordinator` (continuation map + yield in `handleEngineEvent`'s `.positionUpdate` branch + finish on shutdown). |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | Add `songElapsedSeconds`, `songDurationSeconds`. Start position-subscription Task in `start()`. Reset elapsed on `NowPlaying` change. |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift` | Restructure body: remove root padding; add inner padded VStack; convert `titleStack` to HStack with rating menu; new `progressRow`; gear → Menu with Settings/Quit; transport uses `PressOpacityButtonStyle`; `albumArt` 342×342 with `scaledToFill+clipped`. |
| `Sources/RPPlayer/Shell/RatingRow.swift` | **Delete** (replaced by `RatingMenu`). |
| `Sources/RPPlayer/Shell/RatingMenu.swift` | **New**. Narrow `Menu` view. |
| `Sources/RPPlayer/Shell/PressOpacityButtonStyle.swift` | **New**. Press-opacity button style. |
| `Tests/RPPlayerTests/RatingRowTests.swift` | **Delete** (if present). |
| `Tests/RPPlayerTests/RatingMenuTests.swift` | **New**. |
| `Tests/RPPlayerTests/MiniPlayerViewModelTests.swift` | Add 3 tests (position, song-change reset, clamp). |
| `Tests/RPPlayerTests/LivePlaybackCoordinatorTests.swift` | Add 2 tests (yield-to-subscribers, seed). |
| `CLAUDE.md` | Bump test count line; note new `positionUpdates` stream + popover layout shift in the relevant sections. |

## Risk / open questions

- **`scaledToFill` + clipping for art.** RP serves square album art per the public API; if a future cover is non-square, `scaledToFill+clipped` matches the rest of the popover better than `scaledToFit` (which would letterbox). Low risk.
- **Position stream subscriber bookkeeping.** Same pattern as `nowPlayingUpdates`; the existing implementation has been multi-subscriber-safe since PR 6 — confidence is high. New tests cover the seeding path explicitly.
- **`NSApp.terminate(nil)` from a SwiftUI menu inside the popover.** The popover's outside-click monitor must not race the terminate call; AppKit's terminate is synchronous from the main run loop and `applicationWillTerminate` already blocks on coordinator shutdown for up to 2 s. No change needed.
- **Rating menu items 10 → 1 vs. 1 → 10.** Both are defensible. Spec picks 10 → 1 (highest at top). Trivial to flip.
