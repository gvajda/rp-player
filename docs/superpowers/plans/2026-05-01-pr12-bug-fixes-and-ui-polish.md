# PR 12 — Smoke fixes + UI polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two bugs (stale track info during pause/swap, hog mode acquisition failure on user's USB DAC) and land six UI/UX polish items (rp.ico menu icon, tighter popover margins, 318 pt album art, live stream-bitrate display, Layout E reorganisation, Settings window title).

**Architecture:** Engine adds a `streamFormatChanged` event sourced from mpv `audio-bitrate` / `audio-params/codec` / `audio-params/samplerate` after `fileLoaded`. Coordinator forwards to view models via the existing `nowPlayingUpdates` payload (`NowPlaying.streamFormat`). UI rebuilds `MiniPlayerView` to Layout E shape: gear next to channel picker, 318 pt album art, "RP Player" centered footer. `rp.ico` ships as a SPM resource via `Bundle.module`.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI + AppKit, libmpv, XCTest. Builds + tests via `swift build` / `swift test`.

**Spec:** `docs/superpowers/specs/2026-05-01-pr12-bug-fixes-and-ui-polish-design.md`.

---

## Pre-flight

- [ ] **P.1: Create the PR 12 worktree**

```bash
git -C /Users/gergely/git/rp-player worktree add /Users/gergely/git/rp-player-pr12 -b claude/pr12-polish main
cd /Users/gergely/git/rp-player-pr12
```

- [ ] **P.2: Move `rp.ico` from PR 11 worktree into the new worktree**

```bash
mv /Users/gergely/git/rp-player-pr11/rp.ico /Users/gergely/git/rp-player-pr12/rp.ico
```

(The file is at the PR 11 worktree because that's where the user dropped it. Move it once into the active branch's worktree; it'll get repositioned into `Resources/` in Task 3.)

- [ ] **P.3: Verify clean baseline**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 184 tests, with 0 failures`.

---

## Task 1: Bug 1 investigation — pin root cause

**Goal:** Identify which of the four hypotheses (cue offset on prefetch swap, block expiration on resume, album-art cache stale, off-by-one in `indexOfSong`) actually causes the stale track info, with file:line evidence. **No code changes in this task.**

This is a research-only task. Dispatch an Explore subagent.

- [ ] **Step 1.1: Dispatch a research subagent to map the relevant code paths**

Prompt the subagent (general-purpose Explore-style):

> Working directory: `/Users/gergely/git/rp-player-pr12`. Read these files end-to-end and produce a short report (≤ 400 words):
> - `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — focus on `play(channelId:)`, `swapToPrefetchedBlockIfAvailable`, `pause`, `resume`, `handleEngineEvent` `.positionUpdate` and `.fileLoaded` cases.
> - `Sources/RPPlayer/Playback/BlockSongs.swift` — `indexOfSong(at:in:)` and `startsAtSeconds(songs:)` — verify boundary semantics for `position == startsAt[n]` exactly.
> - `Sources/RPPlayer/Notifications/AlbumArtCache.swift` — confirm cache key is by cover path SHA-256, not by song id.
> - `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — focus on `loadArt` and the `start()` `for await np in nowPlayingUpdates` loop. Check whether `currentArt` is reset to `nil` when `np.song` changes but cover is the same vs different vs nil.
>
> For each of the four hypotheses below, classify as: confirmed-cause / contributing / not-the-cause / cannot-tell-without-runtime:
> 1. `pendingCueSeekSeconds` / `currentSongIndex` / `startsAt` not reset when `swapToPrefetchedBlockIfAvailable` runs.
> 2. Block expiration (`block.expiration`) not checked on `resume()`.
> 3. Album-art cache key collisions or `currentArt` not cleared between songs that share a cover path with a different actual album.
> 4. Off-by-one in `BlockSongs.indexOfSong(at:in:)` at exact boundary `position == startsAt[n]`.
>
> Final paragraph: which single hypothesis is the most likely cause, with file:line evidence. If the data points to a 5th hypothesis, describe it.
>
> Don't write or change any code. Don't run tests. Just read and report.

- [ ] **Step 1.2: Read the report; pick the fix target**

Based on the report, identify the single most likely cause and the file:line where the fix lands. If the report is inconclusive, dispatch a follow-up subagent to add temporary debug logging and ask the user to repro.

**Deliverable for Task 1:** the report itself (no commit). Task 2 implements the fix.

---

## Task 2: Bug 1 fix + regression test

**Goal:** Apply the minimal change that fixes whichever hypothesis Task 1 identified, gated by a failing test.

The exact code is hypothesis-dependent. The plan locks the SHAPE of the work:

- [ ] **Step 2.1: Write the regression test that reproduces the symptom**

Use `MockPlayerEngine` + `MockRpApiClient` to stage the scenario. For example, if Task 1 names hypothesis 1 (prefetch swap):

```swift
func testPrefetchSwapResetsCueOffsetAndStartsAt() async throws {
    let api = MockRpApiClient()
    let block1 = makeBlock(channel: "0", url: "https://example.com/A.flac", cue: 30_000,
                           songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
    let block2 = makeBlock(channel: "0", url: "https://example.com/B.flac", cue: 5_000,
                           songs: [("e", 60_000), ("f", 60_000), ("g", 60_000), ("h", 60_000)])
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrate: 4
    )
    var captured: [NowPlaying] = []
    let collector = Task {
        for await np in await coordinator.nowPlayingUpdates {
            captured.append(np)
            if captured.count >= 3 { break }
        }
    }
    try await coordinator.play(channelId: 0)
    // Drive prefetch by signaling near end of last song
    await engine.fire(.positionUpdate(seconds: 230))
    try await Task.sleep(nanoseconds: 100_000_000)
    await engine.fire(.fileEnded(reason: .eof))
    try await Task.sleep(nanoseconds: 100_000_000)
    await engine.fire(.positionUpdate(seconds: 0))
    await collector.value

    let last = captured.last!
    XCTAssertEqual(last.song.songId, "e", "first song of swapped block must be at position 0")
}
```

Adjust to match the actual cause Task 1 identified. The test must FAIL on the current `main` and PASS after the fix.

- [ ] **Step 2.2: Verify RED**

```bash
swift test --filter <test-name> 2>&1 | tail -10
```

Expected: failure that matches the symptom.

- [ ] **Step 2.3: Implement the minimal fix at the file:line Task 1 identified**

Concrete code depends on the hypothesis. For example, hypothesis 1 fix sketch in `LivePlaybackCoordinator.swapToPrefetchedBlockIfAvailable`:

```swift
private func swapToPrefetchedBlockIfAvailable() async {
    guard let next = prefetchedBlock else { return }
    prefetchedBlock = nil
    prefetchTask = nil
    let songs = BlockSongs.orderedSongs(from: next)
    guard !songs.isEmpty else { return }
    currentBlock = next
    orderedSongs = songs
    startsAt = BlockSongs.startsAtSeconds(songs: songs)
    currentSongIndex = 0
    currentPositionSeconds = 0
    pendingCueSeekSeconds = next.cue > 0 ? Double(next.cue) / 1000.0 : nil
    hogModeFallbackTriggered = false
    guard let url = URL(string: next.url) else { return }
    do { try await engine.play(url: url) } catch {
        logger.error("prefetch swap play failed: \(error)")
    }
    emitNowPlaying(forSongIndex: 0)
}
```

- [ ] **Step 2.4: Verify GREEN + full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 185 tests, with 0 failures` (184 baseline + 1 regression test).

- [ ] **Step 2.5: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
fix(pr12): <hypothesis-specific summary> for stale track info

<one-paragraph why>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: rp.ico → menu-bar icon

**Goal:** Move `rp.ico` into the SPM target's resource bundle, set as `statusItem.button.image` at launch.

**Files:**
- Move: `rp.ico` → `Sources/RPPlayer/Resources/rp.ico`
- Modify: `Package.swift` — add resources declaration to RPPlayer target
- Modify: `Sources/RPPlayer/Shell/StatusItemController.swift`
- Test: `Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift`

- [ ] **Step 3.1: Move the file and declare the resource in Package.swift**

```bash
mkdir -p Sources/RPPlayer/Resources
mv rp.ico Sources/RPPlayer/Resources/rp.ico
```

Edit `Package.swift`. Find the `RPPlayer` target block (around line 33–35):

```swift
.executableTarget(
    name: "RPPlayer",
    dependencies: ["CMpv"],
    path: "Sources/RPPlayer",
    ...
)
```

Add `resources:` parameter (and any required `linkerSettings` etc. unchanged):

```swift
.executableTarget(
    name: "RPPlayer",
    dependencies: ["CMpv"],
    path: "Sources/RPPlayer",
    exclude: [],  // keep existing
    resources: [.process("Resources")],
    ...
)
```

Verify `swift build` still completes:

```bash
swift build 2>&1 | tail -3
```

Expected: `Build complete!`.

- [ ] **Step 3.2: Write a failing test for icon loading**

Append to `Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift`:

```swift
@MainActor
func testStatusItemUsesRpIconAsButtonImage() throws {
    let popover = PopoverController(rootView: AnyView(EmptyView()))
    let controller = StatusItemController(popover: popover)
    let image = try XCTUnwrap(controller.statusItem.button?.image, "status item must have an image")
    XCTAssertGreaterThan(image.size.width, 0)
    XCTAssertGreaterThan(image.size.height, 0)
}
```

This requires `StatusItemController.statusItem` to be exposed. If currently `private`, change to `internal` (no test-only API needed; the existing tests already touch the controller).

- [ ] **Step 3.3: Verify RED**

```bash
swift test --filter testStatusItemUsesRpIconAsButtonImage 2>&1 | tail -10
```

Expected: failure (image is nil today — controller currently uses an SF Symbol or text).

- [ ] **Step 3.4: Wire `rp.ico` into `StatusItemController`**

Read `Sources/RPPlayer/Shell/StatusItemController.swift`. The init currently sets `statusItem.button.image` to something else (probably `NSImage(systemSymbolName:)`). Replace with:

```swift
if let url = Bundle.module.url(forResource: "rp", withExtension: "ico"),
   let image = NSImage(contentsOf: url) {
    image.size = NSSize(width: 18, height: 18)  // menu-bar standard
    statusItem.button?.image = image
} else {
    // Fallback to SF symbol if the resource is missing — keeps the app launchable.
    statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "RP Player")
}
```

`Bundle.module` is auto-generated by SPM when a target has resources. Available inside the module.

- [ ] **Step 3.5: Verify GREEN + full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 186 tests, 0 failures.

- [ ] **Step 3.6: Commit**

```bash
git add Package.swift Sources/RPPlayer/Resources/rp.ico Sources/RPPlayer/Shell/StatusItemController.swift Tests/RPPlayerTests/Shell/StatusItemControllerTests.swift
git commit -m "$(cat <<'EOF'
feat(pr12): rp.ico as menu-bar icon

Ships rp.ico as a SPM resource via Bundle.module. Falls back to
music.note SF symbol if the resource is missing at runtime.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Live stream-bitrate plumbing

**Goal:** Engine emits a `streamFormatChanged` event after `fileLoaded`; coordinator forwards into `nowPlayingUpdates`; view model exposes it; view displays it under the channel picker.

**Files:**
- Create: `Sources/RPPlayer/Player/StreamFormat.swift`
- Modify: `Sources/RPPlayer/Player/PlayerEngine.swift` — `PlayerEvent` adds `.streamFormatChanged(StreamFormat)`
- Modify: `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift` — read mpv properties + emit
- Modify: `Sources/RPPlayer/Playback/NowPlaying.swift` — add `streamFormat: StreamFormat?`
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — forward into nowPlayingUpdates
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — `currentStreamFormat` published
- Tests: new `StreamFormatTests.swift`, additions to `LibmpvPlayerEngineTests`, `LivePlaybackCoordinatorTests`, `MiniPlayerViewModelTests`

- [ ] **Step 4.1: Define the model + display helper (with tests)**

Test (`Tests/RPPlayerTests/Player/StreamFormatTests.swift`):

```swift
import XCTest
@testable import RPPlayer

final class StreamFormatTests: XCTestCase {
    func testDisplayStringForFLAC() {
        let f = StreamFormat(codec: "flac", sampleRateHz: 44100, kbps: 850)
        XCTAssertEqual(f.displayString, "FLAC 44.1 kHz")
    }
    func testDisplayStringForMP3() {
        let f = StreamFormat(codec: "mp3", sampleRateHz: 44100, kbps: 320)
        XCTAssertEqual(f.displayString, "MP3 320 kbps")
    }
    func testDisplayStringForUnknownCodec() {
        let f = StreamFormat(codec: "aac", sampleRateHz: 48000, kbps: 256)
        XCTAssertEqual(f.displayString, "AAC 48000 Hz")
    }
    func testDisplayStringHandlesMissingKbps() {
        let f = StreamFormat(codec: "flac", sampleRateHz: 96000, kbps: nil)
        XCTAssertEqual(f.displayString, "FLAC 96.0 kHz")
    }
}
```

Implementation (`Sources/RPPlayer/Player/StreamFormat.swift`):

```swift
import Foundation

public struct StreamFormat: Equatable, Sendable {
    public let codec: String
    public let sampleRateHz: Int
    public let kbps: Double?

    public init(codec: String, sampleRateHz: Int, kbps: Double?) {
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.kbps = kbps
    }

    public var displayString: String {
        let upper = codec.uppercased()
        switch upper {
        case "FLAC":
            return "FLAC \(Self.formatKHz(sampleRateHz))"
        case "MP3":
            if let kbps { return "MP3 \(Int(kbps.rounded())) kbps" }
            return "MP3 \(Self.formatKHz(sampleRateHz))"
        default:
            return "\(upper) \(sampleRateHz) Hz"
        }
    }

    private static func formatKHz(_ hz: Int) -> String {
        let khz = Double(hz) / 1000.0
        if khz == khz.rounded() {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }
}
```

Verify the four tests pass after implementation.

- [ ] **Step 4.2: Add the new event case to `PlayerEvent`**

In `Sources/RPPlayer/Player/PlayerEngine.swift`:

```swift
public enum PlayerEvent: Sendable, Equatable {
    case positionUpdate(seconds: Double)
    case fileLoaded
    case fileEnded(reason: PlayerEndReason)
    case error(message: String)
    case hogModeChanged(enabled: Bool)
    case outputDeviceChanged(uid: String?)
    case streamFormatChanged(StreamFormat)   // new
    case shutdown
}
```

`MockPlayerEngine.Call` does NOT need a new case — `streamFormatChanged` is event-only, no setter.

The existing exhaustive `switch` over `PlayerEvent` in `LivePlaybackCoordinator.handleEngineEvent` will fail to compile until you handle the new case (Task 4.5).

- [ ] **Step 4.3: Read mpv properties after fileLoaded and emit the event**

In `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`, find the place where `MPV_EVENT_FILE_LOADED` is handled (inside `pump()`). Today it should do `deliver(.fileLoaded)`. After the existing `deliver(.fileLoaded)` line, add:

```swift
if let format = readCurrentStreamFormat() {
    deliver(.streamFormatChanged(format))
}
```

And add the helper at the bottom of the class:

```swift
private func readCurrentStreamFormat() -> StreamFormat? {
    guard let h = handle else { return nil }
    let codec = readStringProperty(h, "audio-params/codec")
    let rate = readIntProperty(h, "audio-params/samplerate")
    let bitrate = readDoubleProperty(h, "audio-bitrate")
    guard let codec, let rate, rate > 0 else { return nil }
    return StreamFormat(
        codec: codec,
        sampleRateHz: rate,
        kbps: bitrate.map { $0 / 1000.0 }
    )
}

private func readStringProperty(_ h: OpaquePointer, _ name: String) -> String? {
    guard let raw = mpv_get_property_string(h, name) else { return nil }
    defer { mpv_free(raw) }
    return String(cString: raw)
}

private func readIntProperty(_ h: OpaquePointer, _ name: String) -> Int? {
    var value: Int64 = 0
    let status = mpv_get_property(h, name, MPV_FORMAT_INT64, &value)
    return status >= 0 ? Int(value) : nil
}

private func readDoubleProperty(_ h: OpaquePointer, _ name: String) -> Double? {
    var value: Double = 0
    let status = mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &value)
    return status >= 0 ? value : nil
}
```

mpv properties may be unavailable for a few hundred ms after `fileLoaded`. If readCurrentStreamFormat returns nil here, no event fires (acceptable — UI shows blank). A future enhancement can poll for it; out of scope for this task.

- [ ] **Step 4.4: Test the engine event end-to-end against the live MP3 stream**

Add to `Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift`:

```swift
func testStreamFormatChangedEmittedAfterFileLoaded() async throws {
    let engine = try LibmpvPlayerEngine()
    defer { Task { await engine.shutdown() } }
    let stream = await engine.events
    let collector = Task { () -> StreamFormat? in
        for await event in stream {
            if case .streamFormatChanged(let format) = event {
                return format
            }
        }
        return nil
    }
    try await engine.play(url: URL(string: "https://stream.radioparadise.com/mp3-320")!)
    let outcome = try await withThrowingTaskGroup(of: StreamFormat?.self) { group in
        group.addTask { await collector.value }
        group.addTask {
            try await Task.sleep(nanoseconds: 8_000_000_000)
            collector.cancel()
            return nil
        }
        return try await group.next()!
    }
    let format = try XCTUnwrap(outcome, "expected streamFormatChanged within 8 s")
    XCTAssertEqual(format.codec.lowercased(), "mp3")
    XCTAssertEqual(format.sampleRateHz, 44100)
    XCTAssertGreaterThan(format.kbps ?? 0, 0)
}
```

Run with `swift test --filter testStreamFormatChangedEmittedAfterFileLoaded`. If `audio-params/codec` arrives slightly after `fileLoaded`, increase the wait inside `readCurrentStreamFormat` or schedule a one-shot retry — but try the simple version first.

- [ ] **Step 4.5: Forward through the coordinator + NowPlaying model**

In `Sources/RPPlayer/Playback/NowPlaying.swift`, add the optional field. If `NowPlaying` is a struct with a memberwise init, update call sites (`emitNowPlaying`, fixtures) accordingly. Default `streamFormat: StreamFormat? = nil`.

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:

- Add `private var currentStreamFormat: StreamFormat?` to `LivePlaybackCoordinator`.
- In `handleEngineEvent`, add a `case .streamFormatChanged(let f):` that stores `currentStreamFormat = f` and re-emits `emitNowPlaying(forSongIndex: currentSongIndex)`.
- Update `emitNowPlaying(forSongIndex:)` to populate `streamFormat: currentStreamFormat`.

Coordinator test:

```swift
func testStreamFormatPropagatesIntoNowPlayingUpdates() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(songs: [("a", 60_000), ("b", 60_000), ("c", 60_000), ("d", 60_000)])
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(api: api, engine: engine, logger: silentLogger(), bitrate: 4)
    var captured: NowPlaying?
    let sub = Task {
        for await np in await coordinator.nowPlayingUpdates {
            captured = np
            if np.streamFormat != nil { break }
        }
    }
    try await coordinator.play(channelId: 0)
    await engine.fire(.streamFormatChanged(StreamFormat(codec: "flac", sampleRateHz: 44100, kbps: 850)))
    try await Task.sleep(nanoseconds: 100_000_000)
    sub.cancel()
    XCTAssertEqual(captured?.streamFormat?.codec, "flac")
    XCTAssertEqual(captured?.streamFormat?.sampleRateHz, 44100)
}
```

- [ ] **Step 4.6: Surface in `MiniPlayerViewModel`**

Add `@Published private(set) var currentStreamFormat: StreamFormat?` and update it inside the `for await np` loop:

```swift
for await np in coordinator.nowPlayingUpdates {
    nowPlaying = np
    currentStreamFormat = np.streamFormat
    // ... existing art / sign-in logic ...
}
```

Test:

```swift
func testCurrentStreamFormatReflectsCoordinator() async throws {
    auth.loggedIn = false
    await sut.start()
    let np = NowPlaying.fixture(songId: "1").with(streamFormat: StreamFormat(codec: "flac", sampleRateHz: 44100, kbps: 850))
    await coordinator.setNowPlaying(np)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(sut.currentStreamFormat?.codec, "flac")
}
```

`NowPlaying.with(streamFormat:)` is a small in-test extension. If that doesn't fit cleanly, set `streamFormat` directly via the memberwise init in the fixture.

- [ ] **Step 4.7: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 191 tests, 0 failures (186 baseline + 4 StreamFormat + 1 engine + 1 coordinator + 1 viewmodel — adjust if Tasks 1–2 added differently).

- [ ] **Step 4.8: Commit**

```bash
git add Sources/RPPlayer/Player/StreamFormat.swift Sources/RPPlayer/Player/PlayerEngine.swift Sources/RPPlayer/Player/LibmpvPlayerEngine.swift Sources/RPPlayer/Playback/NowPlaying.swift Sources/RPPlayer/Playback/PlaybackCoordinator.swift Sources/RPPlayer/Shell/MiniPlayerViewModel.swift Tests/RPPlayerTests/Player/StreamFormatTests.swift Tests/RPPlayerTests/Player/LibmpvPlayerEngineTests.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(pr12): live stream-format event from engine to view model

LibmpvPlayerEngine reads audio-params/codec, audio-params/samplerate,
and audio-bitrate after MPV_EVENT_FILE_LOADED, packages them into a new
StreamFormat struct, and emits PlayerEvent.streamFormatChanged.
Coordinator stores and re-emits via nowPlayingUpdates so the view model
sees the format alongside the song. UI display lands in Task 5.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Layout E rebuild

**Goal:** Rewrite `MiniPlayerView` to Layout E — 318 pt album art, channel picker + bitrate + gear in one row, rating bar, controls, "RP Player" centered footer. Tighter outer padding (12 pt). Reuses existing rating row + control buttons.

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Possibly modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` if accessor helpers needed

- [ ] **Step 5.1: Read the current `MiniPlayerView` end-to-end**

```bash
cat Sources/RPPlayer/Shell/MiniPlayerView.swift
```

Note: existing pieces to preserve / move:
- Album art image binding (`viewModel.currentArt`)
- Title / artist / album labels (`viewModel.nowPlaying?.song`)
- Channel picker (currently somewhere — possibly in a separate `ChannelPicker` component)
- Rating row (existing component; 318 pt wide as user measured)
- Controls (play/pause + forward)
- Settings gear button (currently in some position; needs to move next to channel picker)
- Error banner (`viewModel.errorMessage`) — keep wherever it was, not part of Layout E spec

- [ ] **Step 5.2: Rewrite the body to Layout E**

The full new body:

```swift
var body: some View {
    VStack(spacing: 12) {
        Group {
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 318, height: 318)
                    .cornerRadius(6)
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 318, height: 318)
                    .foregroundStyle(.secondary)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
            }
        }

        VStack(spacing: 2) {
            Text(viewModel.nowPlaying?.song.title ?? "—")
                .font(.headline)
                .lineLimit(1)
            Text(viewModel.nowPlaying?.song.artist ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let album = viewModel.nowPlaying?.song.album, !album.isEmpty {
                Text(album)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)

        HStack(spacing: 8) {
            Picker("Channel", selection: channelBinding) {
                ForEach(viewModel.channels, id: \.chan) { ch in
                    Text(ch.title).tag(ch.chan)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let format = viewModel.currentStreamFormat {
                Text(format.displayString)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                viewModel.openSettings()
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14, weight: .regular))
            }
            .buttonStyle(.borderless)
            .frame(width: 22, height: 22)
        }
        .frame(width: 318)

        RatingRow(rating: viewModel.currentRating) { value in
            Task { await viewModel.rate(value) }
        }
        .frame(width: 318)

        HStack(spacing: 18) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .frame(width: 38, height: 38)
        }

        Text("RP Player")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
    .padding(12)
    .frame(width: 342)  // 318 + 12+12 padding
}
```

`channelBinding` is a `Binding<Int>` computed property that maps `viewModel.selectedChannelId` (with `selectChannel` on set). If the existing view already has this helper, reuse it. If not, add:

```swift
private var channelBinding: Binding<Int> {
    Binding(
        get: { viewModel.selectedChannelId ?? 0 },
        set: { newValue in Task { await viewModel.selectChannel(newValue) } }
    )
}
```

If error banner is in scope: place it ABOVE the album art (small `.background(Color.red.opacity(0.1))` Text). Don't drop it in the rebuild.

- [ ] **Step 5.3: Adjust `MiniPlayerViewTests` if assertions reference the old layout**

Most existing assertions probably check that the view compiles + that the SwiftUI binding fires. Layout-shape assertions are rare in this codebase. Run the existing tests and update only if they fail.

```bash
swift test --filter MiniPlayerViewTests 2>&1 | tail -10
```

- [ ] **Step 5.4: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 191 tests, 0 failures.

- [ ] **Step 5.5: Manual smoke (developer)**

Run the app:

```bash
swift run RPPlayer
```

Click the menu bar icon. Verify:
- Album art is 318 pt square.
- Channel picker, bitrate label (if a stream is loaded), and gear icon are in a single row, all visible.
- Rating row spans the same width as the album art.
- Play/pause and forward are centered.
- "RP Player" text appears at the bottom center.
- Outer margins are tight (~12 pt).

If anything looks off, iterate the SwiftUI body until it matches the Variant E mockup.

- [ ] **Step 5.6: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "$(cat <<'EOF'
feat(pr12): MiniPlayerView Layout E

318 pt album art on top, channel picker + live bitrate label + gear in
one row, rating row, transport controls, "RP Player" centered footer
wordmark. Outer padding tightened to 12 pt.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Settings window title

**Goal:** Set the Settings window title to `"RP Player Settings"`.

- [ ] **Step 6.1: Read `SettingsWindowController`**

```bash
cat Sources/RPPlayer/Shell/SettingsWindowController.swift
```

Find where the `NSWindow` is created or configured.

- [ ] **Step 6.2: Set the title**

Wherever the `NSWindow` is constructed (likely an `init` or a lazy var), add:

```swift
window.title = "RP Player Settings"
```

If the window is a `NSHostingController(rootView: SettingsView(...))` wrapped in an `NSWindow`, set the title on that window after wrapping.

- [ ] **Step 6.3: Add a regression test**

```swift
@MainActor
func testWindowTitleIsRPPlayerSettings() {
    let viewModel = SettingsViewModel(
        configStore: StubConfigStore(initial: .default),
        deviceCatalog: StubAudioDeviceCatalog(initial: []),
        auth: StubKeychainAuth(),
        openLoginWindow: { },
        openApplicationData: { }
    )
    let controller = SettingsWindowController(viewModel: viewModel)
    XCTAssertEqual(controller.window.title, "RP Player Settings")
}
```

If `SettingsWindowController` doesn't currently expose `window`, add a public/internal accessor.

- [ ] **Step 6.4: Run + commit**

```bash
swift test 2>&1 | tail -3
git add Sources/RPPlayer/Shell/SettingsWindowController.swift Tests/RPPlayerTests/Shell/SettingsWindowControllerTests.swift
git commit -m "$(cat <<'EOF'
feat(pr12): set Settings window title to "RP Player Settings"

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Bug 2 — hog mode investigation, three bounded attempts

**Goal:** Get `coreaudio_exclusive` working on the user's USB DAC. Three attempts, each followed by a user smoke run. Defer with logs if all fail.

This task is **interactive** — each attempt commits, waits for user smoke result, then either lands or moves to the next attempt.

- [ ] **Step 7.1: Attempt 1 — set `audio-device` BEFORE `mpv_initialize`**

Today, `LibmpvPlayerEngine.init` does:

1. `mpv_create()`
2. Set baseline options (vid, video, idle, audio-channels, etc.)
3. `mpv_initialize(h)`
4. (Later, via the ConfigStore binder) `setOutputDevice(uid:)` writes `audio-device`

mpv may negotiate the device's mixer-mode format on init when `audio-device` is `auto`, then fail to flip to exclusive cleanly. Hypothesis: setting `audio-device` BEFORE init lets mpv negotiate exclusive from the start.

**Implementation sketch:**

Add a parameter to `LibmpvPlayerEngine.init`:

```swift
public init(initialDeviceUID: String? = nil, initialHogMode: Bool = false) throws {
    // ... existing mpv_create + baseline options ...
    if initialHogMode {
        try setOptionString(h, "audio-exclusive", "yes")
    }
    if let uid = initialDeviceUID, !uid.isEmpty {
        let ao = initialHogMode ? "coreaudio_exclusive" : "coreaudio"
        try setOptionString(h, "audio-device", "\(ao)/\(uid)")
    }
    // ... mpv_initialize ...
}
```

`AppContainer.live()` reads `JSONConfigStore` synchronously to get the persisted `outputDeviceUID` + `hogModeEnabled` and passes them in:

```swift
let initial = Self.loadSettings(from: configURL)
// ...
engine = try LibmpvPlayerEngine(
    initialDeviceUID: initial.outputDeviceUID,
    initialHogMode: initial.hogModeEnabled
)
```

This requires `LibmpvPlayerEngine.init` to NOT be `async`-isolated; `AppContainer.live()` is `@MainActor` (synchronous-throwing) so synchronous read of `JSONConfigStore`'s on-disk JSON file is fine (`Self.loadSettings(from:)` is already used).

The post-init ConfigStore-stream binder still applies subsequent changes via `setHogMode(_:)` / `setOutputDevice(uid:)` exactly as today — no behavior change after the first file-load.

**Smoke gate:**

```bash
swift run RPPlayer
# User smoke: hog mode ON, USB DAC selected, click play.
# Capture: ~/Library/Application Support/RP\ Player/Logs/RPPlayer.log
```

If log shows `Failed to initialize audio driver 'coreaudio_exclusive'` again → attempt 1 failed, move to 7.2. Otherwise commit + done with hog mode.

- [ ] **Step 7.2: Attempt 2 — pre-set `audio-format` and `audio-samplerate`**

If attempt 1 didn't land, augment the engine baseline options with explicit format / rate matching RP's FLAC stream: `audio-samplerate=44100`. Try with `audio-format=s16` first; if the DAC reports the wrong native format, try `s32`.

```swift
let baseline: [(String, String)] = [
    // ... existing ...
    ("audio-samplerate", "44100"),
    // ("audio-format", "s16"),  // try without first; only add if needed
]
```

Smoke gate same as 7.1. If it works, commit. If not, move to 7.3.

- [ ] **Step 7.3: Attempt 3 — IINA recipe diff**

Pull the audio-related properties from IINA's mpv config. Specifically check:

- `audio-fallback-to-null` (default `yes` per mpv; IINA may set `no`)
- `audio-stream-silence` (default `no`)
- `audio-wait-open` (timeout)
- `gapless-audio` (default `weak`; IINA uses `yes`)
- Whether IINA opens the device with `--audio-device=coreaudio_exclusive/<UID>` or `--audio-device=auto` + `--audio-exclusive=yes`

Apply the relevant ones. Smoke gate.

- [ ] **Step 7.4: If all three attempts fail, defer with log capture**

Write `docs/notes/hog-mode-investigation-2026-05-01.md` containing:

- Each attempt's exact mpv option set.
- The full `[ERROR] [shell] player engine reported error: ...` lines from each smoke run.
- Hypotheses for next round (e.g., subscribe to MPV_EVENT_LOG_MESSAGE at level `verbose` to capture the device negotiation handshake).

Commit the doc, and update `CLAUDE.md`'s "Open follow-ups" to point at it.

- [ ] **Step 7.5: Commit (whichever attempt succeeded, or the deferral)**

For a successful attempt:

```bash
git add Sources/RPPlayer/Player/LibmpvPlayerEngine.swift Sources/RPPlayer/App/AppContainer.swift Tests/...
git commit -m "$(cat <<'EOF'
fix(pr12): hog mode acquisition on USB DAC

Set audio-device + audio-exclusive BEFORE mpv_initialize so the
coreaudio_exclusive AO negotiates the DAC's native format from the
start instead of trying to flip from mixer-mode.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

For deferral:

```bash
git add docs/notes/hog-mode-investigation-2026-05-01.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(pr12): capture hog-mode investigation logs, defer fix

Three attempts (audio-device pre-init, explicit samplerate, IINA
recipe diff) all returned 'Failed to initialize audio driver
coreaudio_exclusive'. Log captures + next-round hypotheses recorded
for the next session.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: CLAUDE.md update + final verification

- [ ] **Step 8.1: Update PR table**

Change the PR 12 row from `pending` to `merged to main` with new content:

```
| 12  | merged to main | ✅      | Smoke fixes (track-info, hog mode TBD) + UI polish (rp.ico, Layout E, live bitrate)      |
```

Add PR 13 row:

```
| 13  | pending        | ⬜      | Distribution CI workflow                                                                  |
```

- [ ] **Step 8.2: Add post-PR-12 test count**

```
- After PR 12: <N> tests
```

(N = whatever `swift test` reports.)

- [ ] **Step 8.3: Add a paragraph summarizing PR 12 scope**

Mirror the format of the PR 9 / PR 10 / PR 11 summary paragraphs already in CLAUDE.md.

- [ ] **Step 8.4: Add technical-decisions notes for the new patterns**

- The `streamFormatChanged` event flow: engine reads mpv properties on `fileLoaded`, packages into `StreamFormat`, coordinator stores + re-emits through `nowPlayingUpdates`.
- `Bundle.module` is the resource lookup mechanism (SPM auto-generates it once `.process("Resources")` is declared).
- Whatever Bug 1 fix landed — the invariant it preserves.
- Whatever Bug 2 attempt landed (or, if deferred, point to the notes file).

- [ ] **Step 8.5: Run final suite + build**

```bash
swift test 2>&1 | tail -3
swift build 2>&1 | tail -5
```

- [ ] **Step 8.6: Commit + ff-merge**

```bash
git add CLAUDE.md
git commit -m "docs(pr12): mark PR 12 merged, record polish + bug fixes"
cd /Users/gergely/git/rp-player
git merge --ff-only claude/pr12-polish
```

If the main worktree has uncommitted CLAUDE.md changes again (linter / user reformatting), repeat the stash + manual conflict resolve dance from PR 11. The pattern is documented in this session.

---

## Self-review

**Spec coverage:**
- Bug 1 stale info → Tasks 1–2.
- Bug 2 hog mode → Task 7.
- rp.ico menu icon → Task 3.
- Tighter margins → Task 5.
- 318 pt album art → Task 5.
- Live bitrate → Task 4.
- Layout E → Task 5.
- Settings window title → Task 6.
- CLAUDE.md update → Task 8.

**Placeholders:** Task 2's regression test is hypothesis-shaped — concrete code locked once Task 1's report identifies the cause. Task 7's three attempts are sequential with smoke gates, not pre-locked code. Both intentional given the investigative nature.

**Type consistency:** `StreamFormat(codec:sampleRateHz:kbps:)` signature appears identically in Task 4.1 (definition), 4.4 (engine emit), 4.5 (coordinator forward), and 4.6 (view model). `streamFormatChanged(StreamFormat)` event matches.

**Test count drift:** 184 → ~192 (+8) is the rough target. Bug 1 adds 1, rp.ico adds 1, StreamFormat adds 4, engine event adds 1, coordinator forward adds 1, view model adds 1, settings title adds 1 = 10 if everything tracks; some may merge or skip.
