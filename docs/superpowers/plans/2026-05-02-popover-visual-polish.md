# Popover Visual Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five popover-visible improvements (edge-to-edge album art, song progress bar, narrow rating dropdown, no press-state blue on play button, Quit menu item) plus the minimum coordinator/view-model wiring needed to drive a live progress bar.

**Architecture:** Add a new `positionUpdates: AsyncStream<Double>` to `PlaybackCoordinator` (same multi-subscriber pattern as `nowPlayingUpdates`). The view model subscribes to it and derives in-song elapsed/duration from `NowPlaying.songStartSeconds` / `songEndSeconds`. UI changes are pure SwiftUI restructuring of `MiniPlayerView`. The settings gear becomes a `Menu` exposing both Settings and Quit; Quit calls `NSApp.terminate(nil)` and the existing `applicationWillTerminate` handles graceful shutdown.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSApp.terminate`, `NSHostingController` for tests), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-02-popover-visual-polish-design.md`

**Branch:** `claude/popover-visual-polish` (off `main`).

---

## Pre-flight

- [ ] **Step 0a: Create branch**

```bash
git checkout main
git pull --ff-only
git checkout -b claude/popover-visual-polish
```

- [ ] **Step 0b: Confirm baseline tests pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed at ...` with 209 tests.

If fails, stop. Investigate before proceeding.

---

## Task 1: Add `positionUpdates` to `PlaybackCoordinator` protocol

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

- [ ] **Step 1: Add protocol requirement**

Edit `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` lines 3–14. The protocol becomes:

```swift
public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }
    var positionUpdates: AsyncStream<Double> { get async }

    func play(channelId: Int) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func skipForward() async throws
    func changeChannel(to channelId: Int) async throws
    func shutdown() async
}
```

- [ ] **Step 2: Try to build — expect protocol-conformance failures**

Run: `swift build 2>&1 | head -30`
Expected: errors at `LivePlaybackCoordinator` and `MockPlaybackCoordinator` ("does not conform to protocol 'PlaybackCoordinator'"). This confirms the protocol change took effect.

- [ ] **Step 3: Commit (intentional WIP — protocol-only)**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git commit -m "wip(coordinator): add positionUpdates to protocol"
```

---

## Task 2: Implement `positionUpdates` on `LivePlaybackCoordinator`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (the `LivePlaybackCoordinator` actor)
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (new tests added in Task 3)

- [ ] **Step 1: Add a position-continuation map and the `positionUpdates` getter**

In `LivePlaybackCoordinator`, add a stored property next to the existing `continuations` line (around line 29):

```swift
private var positionContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
```

Add the new computed property next to `nowPlayingUpdates` (right after its closing brace, around line 60):

```swift
public var positionUpdates: AsyncStream<Double> {
    let id = UUID()
    return AsyncStream { continuation in
        if self.isShutdown { continuation.finish(); return }
        self.positionContinuations[id] = continuation
        continuation.yield(self.currentPositionSeconds)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.unregisterPosition(id: id) }
        }
    }
}
```

Add the unregister helper next to the existing `unregister(id:)` method (around line 292):

```swift
private func unregisterPosition(id: UUID) { positionContinuations.removeValue(forKey: id) }
```

- [ ] **Step 2: Yield to subscribers from `handleEngineEvent`**

In `handleEngineEvent` (around line 235), the `.positionUpdate(let seconds)` branch currently begins:

```swift
case .positionUpdate(let seconds):
    currentPositionSeconds = seconds
```

Insert a yield right after the assignment:

```swift
case .positionUpdate(let seconds):
    currentPositionSeconds = seconds
    for c in positionContinuations.values { c.yield(seconds) }
```

(Leave the rest of the case body — boundary detection, prefetch, etc. — unchanged.)

- [ ] **Step 3: Finish position continuations on shutdown**

In `shutdown()` (line 209), the body currently ends:

```swift
for c in continuations.values { c.finish() }
continuations.removeAll()
```

Append:

```swift
for c in positionContinuations.values { c.finish() }
positionContinuations.removeAll()
```

- [ ] **Step 4: Reset `currentPositionSeconds` on stop / changeChannel paths if not already**

Skim the file for assignments to `currentPositionSeconds`. Existing `play()` sets it to `startPos`; existing `stop()` and `changeChannel()` paths reset it to `0` (lines 129, 335). No new resets needed. The position stream simply yields whatever the engine reports next.

- [ ] **Step 5: Build the package**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds for production code; `MockPlaybackCoordinator` still fails to conform (Task 4 fixes it). If you see *any other* errors, stop and reconcile.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git commit -m "feat(coordinator): yield engine position to subscribers via positionUpdates"
```

---

## Task 3: Tests — `LivePlaybackCoordinator.positionUpdates`

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Add the failing tests**

At the very end of the file (after the last `}` of the last extension), append a new extension namespace:

```swift
extension LivePlaybackCoordinatorTests {
    func testPositionUpdatesYieldsToSubscribers() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.positionUpdates
        let collector = Task { () -> [Double] in
            var seen: [Double] = []
            for await pos in stream {
                seen.append(pos)
                if seen.count == 3 { return seen }
            }
            return seen
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 12.5))
        await engine.fire(.positionUpdate(seconds: 25.0))
        let result = await collector.value
        // First element is the seeded current position (0 at startup),
        // followed by the two engine emissions.
        XCTAssertEqual(result, [0.0, 12.5, 25.0])
    }

    func testPositionUpdatesSeedsLatestPositionToNewSubscriber() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 17.5))
        // Give the actor a tick to process the event before the new subscriber
        // calls .positionUpdates.
        try await Task.sleep(nanoseconds: 50_000_000)

        let stream = await coordinator.positionUpdates
        let firstYield = await Task { () -> Double? in
            for await pos in stream { return pos }
            return nil
        }.value

        XCTAssertEqual(firstYield, 17.5)
    }

    func testPositionUpdatesFinishOnShutdown() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
        )

        let stream = await coordinator.positionUpdates
        try await coordinator.play(channelId: 0)
        await coordinator.shutdown()

        var count = 0
        for await _ in stream { count += 1 }
        // Stream finished cleanly. count is 1 (the seed) or 0 depending on
        // ordering, but the for-await must terminate.
        XCTAssertLessThanOrEqual(count, 5)
    }
}
```

- [ ] **Step 2: Run tests — expect failures because `MockPlaybackCoordinator` still doesn't conform**

Run: `swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -20`
Expected: build error in `MockPlaybackCoordinator.swift` (missing `positionUpdates`). That blocks the test run — fix it in the next task.

- [ ] **Step 3: Commit (still WIP — tests added but suite won't build until Task 4)**

```bash
git add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "test(coordinator): cover positionUpdates yield, seed, shutdown"
```

---

## Task 4: Update `MockPlaybackCoordinator` to conform

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`

- [ ] **Step 1: Add position-continuation plumbing + a `firePosition(_:)` helper**

Replace the body of `MockPlaybackCoordinator.swift` with:

```swift
import Foundation
@testable import RPPlayer

actor MockPlaybackCoordinator: PlaybackCoordinator {
    enum Call: Sendable, Equatable {
        case play(channelId: Int)
        case pause
        case resume
        case stop
        case skipForward
        case changeChannel(to: Int)
        case shutdown
    }

    private(set) var calls: [Call] = []
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var positionContinuations: [UUID: AsyncStream<Double>.Continuation] = [:]
    private var lastPosition: Double = 0
    private var nextError: Error?

    func setNextError(_ error: Error) { nextError = error }
    func setNowPlaying(_ value: NowPlaying?) {
        current = value
        if let value = value {
            for c in continuations.values { c.yield(value) }
        }
    }
    func firePosition(_ seconds: Double) {
        lastPosition = seconds
        for c in positionContinuations.values { c.yield(seconds) }
    }
    func recordedCalls() -> [Call] { calls }

    var nowPlaying: NowPlaying? { current }

    var nowPlayingUpdates: AsyncStream<NowPlaying> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            if let current = self.current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    var positionUpdates: AsyncStream<Double> {
        let id = UUID()
        return AsyncStream { continuation in
            self.positionContinuations[id] = continuation
            continuation.yield(self.lastPosition)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregisterPosition(id: id) }
            }
        }
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }
    private func unregisterPosition(id: UUID) { positionContinuations.removeValue(forKey: id) }

    private func recordOrThrow(_ call: Call) throws {
        if let err = nextError {
            nextError = nil
            throw err
        }
        calls.append(call)
    }

    func play(channelId: Int) async throws { try recordOrThrow(.play(channelId: channelId)) }
    func pause() async throws { try recordOrThrow(.pause) }
    func resume() async throws { try recordOrThrow(.resume) }
    func stop() async throws { try recordOrThrow(.stop) }
    func skipForward() async throws { try recordOrThrow(.skipForward) }
    func changeChannel(to channelId: Int) async throws {
        try recordOrThrow(.changeChannel(to: channelId))
    }
    func shutdown() async {
        calls.append(.shutdown)
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        for c in positionContinuations.values { c.finish() }
        positionContinuations.removeAll()
    }
}
```

- [ ] **Step 2: Run the new coordinator tests**

Run: `swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10`
Expected: all `LivePlaybackCoordinatorTests` pass, including the three new ones.

- [ ] **Step 3: Run the full suite to confirm no other regression**

Run: `swift test 2>&1 | tail -5`
Expected: all 212 tests pass (209 baseline + 3 new).

- [ ] **Step 4: Commit**

```bash
git add Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift
git commit -m "test(coordinator): MockPlaybackCoordinator conforms to positionUpdates"
```

---

## Task 5: View model — subscribe to `positionUpdates`, expose elapsed/duration

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`, immediately before the closing `}` of the test class:

```swift
    func testPositionUpdateDerivesElapsedAndDuration() async throws {
        let np = NowPlaying(
            channelId: 0,
            song: TestFixtures.song(songId: 1, durationMs: 180_000),
            songIndexInBlock: 0,
            blockDurationSeconds: 600,
            songStartSeconds: 100,
            songEndSeconds: 280,
            blockBitrate: nil
        )
        await coordinator.setNowPlaying(np)
        await sut.start()
        // Allow the start() subscription tasks to register.
        try await Task.sleep(nanoseconds: 50_000_000)

        await coordinator.firePosition(145)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 45, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 180, accuracy: 0.001)
    }

    func testSongChangeResetsElapsed() async throws {
        let np1 = NowPlaying(
            channelId: 0,
            song: TestFixtures.song(songId: 1, durationMs: 180_000),
            songIndexInBlock: 0,
            blockDurationSeconds: 600,
            songStartSeconds: 100,
            songEndSeconds: 280,
            blockBitrate: nil
        )
        await coordinator.setNowPlaying(np1)
        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.firePosition(200)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(sut.songElapsedSeconds, 0)

        let np2 = NowPlaying(
            channelId: 0,
            song: TestFixtures.song(songId: 2, durationMs: 240_000),
            songIndexInBlock: 1,
            blockDurationSeconds: 600,
            songStartSeconds: 280,
            songEndSeconds: 520,
            blockBitrate: nil
        )
        await coordinator.setNowPlaying(np2)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 240, accuracy: 0.001)
    }

    func testElapsedClampedToDuration() async throws {
        let np = NowPlaying(
            channelId: 0,
            song: TestFixtures.song(songId: 1, durationMs: 180_000),
            songIndexInBlock: 0,
            blockDurationSeconds: 600,
            songStartSeconds: 100,
            songEndSeconds: 280,
            blockBitrate: nil
        )
        await coordinator.setNowPlaying(np)
        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Position past songEnd — clamp to duration.
        await coordinator.firePosition(310)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.songElapsedSeconds, 180, accuracy: 0.001)
        XCTAssertEqual(sut.songDurationSeconds, 180, accuracy: 0.001)
    }
```

If `TestFixtures.song(songId:durationMs:)` does not yet exist in the test target, search for an existing helper:

```bash
grep -rn "func song(" Tests/RPPlayerTests/ | head -5
```

Use whatever helper the existing `MiniPlayerViewModelTests` use to construct `PlayListSong`. If none exists, add one inline at the top of the test class (or in a small helper file) of the form:

```swift
private enum TestFixtures {
    static func song(songId: Int, durationMs: Int) -> PlayListSong {
        // Construct PlayListSong with the minimum fields the view model reads.
        // Mirror the construction style used elsewhere in this test file.
    }
}
```

(If the existing tests already construct `PlayListSong` literals inline, copy that pattern instead of inventing a helper.)

- [ ] **Step 2: Run tests to confirm failure**

Run: `swift test --filter MiniPlayerViewModelTests.testPositionUpdateDerivesElapsedAndDuration 2>&1 | tail -10`
Expected: build error — `sut.songElapsedSeconds` and `sut.songDurationSeconds` don't exist yet, and `coordinator.firePosition` is fine.

- [ ] **Step 3: Add the published properties + the second subscription Task**

Open `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`. Add two `@Published` properties next to the existing ones (around lines 6–14):

```swift
@Published public var songElapsedSeconds: Double = 0
@Published public var songDurationSeconds: Double = 0
```

Add a new private property next to `subscriptionTask` (around line 24):

```swift
private var positionSubscriptionTask: Task<Void, Never>?
```

In `start()` (around lines 46–84), after the `subscriptionTask = Task { … }` block but before the closing `}`, append a second subscription:

```swift
let positionStream = await coordinator.positionUpdates
positionSubscriptionTask = Task { [weak self] in
    for await pos in positionStream {
        guard let self else { return }
        await MainActor.run {
            guard let np = self.nowPlaying else { return }
            let duration = max(0, np.songEndSeconds - np.songStartSeconds)
            let elapsed = max(0, pos - np.songStartSeconds)
            self.songElapsedSeconds = min(elapsed, duration)
            self.songDurationSeconds = duration
        }
    }
}
```

Inside the existing `nowPlayingUpdates` subscription (the `subscriptionTask = Task { … }` block), the `MainActor.run` body currently sets `self.nowPlaying`, `self.isPlaying`, `self.isSignedIn`, `self.currentRating`, `self.currentBitrateLabel`, and the cover handling. After `self.currentBitrateLabel = …` and before the cover-change check, insert:

```swift
let newDuration = max(0, np.songEndSeconds - np.songStartSeconds)
if np.songStartSeconds != self.lastSongStartSeconds {
    self.lastSongStartSeconds = np.songStartSeconds
    self.songElapsedSeconds = 0
    self.songDurationSeconds = newDuration
} else {
    self.songDurationSeconds = newDuration
}
```

Add a private property next to `lastLoadedCoverPath` (around line 26):

```swift
private var lastSongStartSeconds: Double?
```

Update `stop()` (around lines 86–89) so it also cancels the position subscription:

```swift
public func stop() {
    subscriptionTask?.cancel(); subscriptionTask = nil
    positionSubscriptionTask?.cancel(); positionSubscriptionTask = nil
}
```

(Match the existing `stop()` signature; if it's `func stop()` without `public`, keep as-is. Just add the second cancel pair.)

In `start()`, immediately after the existing `subscriptionTask?.cancel(); subscriptionTask = nil` lines, also add:

```swift
positionSubscriptionTask?.cancel()
positionSubscriptionTask = nil
```

- [ ] **Step 4: Run the new tests, expect them to pass**

Run: `swift test --filter MiniPlayerViewModelTests 2>&1 | tail -15`
Expected: all `MiniPlayerViewModelTests` pass, including the three new ones.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 215 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift
git commit -m "feat(view-model): derive song elapsed/duration from coordinator positionUpdates"
```

---

## Task 6: New file — `PressOpacityButtonStyle`

**Files:**
- Create: `Sources/RPPlayer/Shell/PressOpacityButtonStyle.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// Suppresses the default press-state background tint that SwiftUI's plain
/// button style flashes blue on macOS. Used by the popover transport buttons
/// and the gear menu button — neither needs a press-state background.
struct PressOpacityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/PressOpacityButtonStyle.swift
git commit -m "feat(shell): add PressOpacityButtonStyle for press-state opacity (no blue flash)"
```

---

## Task 7: New file — `RatingMenu`

**Files:**
- Create: `Sources/RPPlayer/Shell/RatingMenu.swift`

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

struct RatingMenu: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(Array((1...10).reversed()), id: \.self) { value in
                Button("\(value)") { onRate(value) }
            }
        } label: {
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 22, alignment: .center)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isSignedIn)
        .help(isSignedIn ? "Rate this song" : "Sign in to rate")
        .accessibilityLabel(isSignedIn ? "Rate this song" : "Rating (sign in to rate)")
    }

    private var label: String {
        if let r = currentRating { return "\(r)" }
        return "—"
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/RatingMenu.swift
git commit -m "feat(shell): add RatingMenu — narrow dropdown showing rating digit or dash"
```

---

## Task 8: Tests — `RatingMenu`

**Files:**
- Create: `Tests/RPPlayerTests/Shell/RatingMenuTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class RatingMenuTests: XCTestCase {
    func testRendersWithRatingValue() {
        var rated: [Int] = []
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: 7, isSignedIn: true) { rated.append($0) }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }

    func testRendersWithoutRating() {
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: nil, isSignedIn: true) { _ in }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWhenSignedOut() {
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: nil, isSignedIn: false) { _ in }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter RatingMenuTests 2>&1 | tail -10`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/RPPlayerTests/Shell/RatingMenuTests.swift
git commit -m "test(shell): smoke-test RatingMenu hosting in three states"
```

---

## Task 9: Restructure `MiniPlayerView`

This is the biggest task — five visible changes converge in this one file. The tests are smoke (`testHostingControllerRendersWithoutCrash`); manual smoke in Task 12 is the real validation.

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 1: Replace the file body**

Open `Sources/RPPlayer/Shell/MiniPlayerView.swift` and replace its full contents with:

```swift
import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 318)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            albumArt
            VStack(spacing: 12) {
                titleRow
                progressRow
                channelRow
                transport
                footer
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }

    private var albumArt: some View {
        Group {
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 342, height: 342)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(80)
                    .foregroundStyle(.secondary)
                    .frame(width: 342, height: 342)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.nowPlaying?.song.title ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.nowPlaying?.song.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let song = viewModel.nowPlaying?.song,
                   let album = song.album,
                   !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(
                currentRating: viewModel.currentRating,
                isSignedIn: viewModel.isSignedIn
            ) { value in
                Task { await viewModel.rate(value) }
            }
        }
        .frame(width: 318)
    }

    private var progressRow: some View {
        VStack(spacing: 2) {
            ProgressView(
                value: viewModel.songElapsedSeconds,
                total: max(viewModel.songDurationSeconds, 0.001)
            )
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

    private var channelRow: some View {
        HStack(spacing: 8) {
            channelPicker
                .frame(maxWidth: .infinity, alignment: .leading)

            if let label = viewModel.currentBitrateLabel {
                Text(label)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
            .accessibilityLabel("Settings and Quit")
        }
        .frame(width: 318)
    }

    private var channelPicker: some View {
        Picker(selection: Binding(
            get: { viewModel.selectedChannelId },
            set: { newId in Task { await viewModel.selectChannel(newId) } }
        )) {
            ForEach(viewModel.channels, id: \.chan) { channel in
                if let id = Int(channel.chan) {
                    Text(channel.title).tag(id)
                }
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(PressOpacityButtonStyle())
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(PressOpacityButtonStyle())
            .frame(width: 38, height: 38)
            .disabled(!viewModel.isPlaying)
            .accessibilityLabel("Skip Forward")
        }
    }

    private var footer: some View {
        Text("RP Player")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

Notes:

- The previous outer `.padding(12)` is gone. Inner stack carries its own 12pt padding so the channel row, progress, transport, footer keep the same visual offset.
- The error banner picks up its own padding (12pt horizontal + 12pt top) so it doesn't slam against the top edge when shown.
- `albumArt` is now full popover width (342) with `scaledToFill` + `clipped()` so non-square covers don't letterbox.
- `RatingMenu` replaces the old `RatingRow` invocation.
- Gear is a `Menu` exposing `Settings…` and `Quit RP Player`.
- Play and Skip buttons use `PressOpacityButtonStyle()` instead of `.buttonStyle(.plain)`.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds. If you see a missing-import error for `AppKit`, double-check the import line at the top of the file.

- [ ] **Step 3: Run the existing view smoke test**

Run: `swift test --filter MiniPlayerViewTests 2>&1 | tail -10`
Expected: `testHostingControllerRendersWithoutCrash` passes.

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests still pass (215 plus the 3 RatingMenu tests = 218; minus the deletions in Task 10 once they happen).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat(shell): edge-to-edge album art + progress bar + rating menu + gear→Settings/Quit menu + press-opacity buttons"
```

---

## Task 10: Delete the old `RatingRow`

**Files:**
- Delete: `Sources/RPPlayer/Shell/RatingRow.swift`
- Delete: `Tests/RPPlayerTests/Shell/RatingRowTests.swift`

- [ ] **Step 1: Confirm no references remain**

Run: `grep -rn "RatingRow" Sources/ Tests/`
Expected: zero matches. (The view now uses `RatingMenu`.)

If any remain, address them before deletion.

- [ ] **Step 2: Delete files**

```bash
git rm Sources/RPPlayer/Shell/RatingRow.swift Tests/RPPlayerTests/Shell/RatingRowTests.swift
```

- [ ] **Step 3: Build + run tests**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: build succeeds; tests pass (217 = 218 from Task 9 minus 1 deleted RatingRowTest).

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(shell): drop RatingRow (replaced by RatingMenu)"
```

---

## Task 11: Manual smoke

There are no automated tests for the visual layout itself (album art fill, gear-menu, press-state) — these are pure SwiftUI structural edits. Validate by running the app.

- [ ] **Step 1: Run the app**

```bash
swift run RPPlayer
```

(If your environment uses `RPSmoke` for some steps, that's a CLI; the popover lives in `RPPlayer`.)

- [ ] **Step 2: Walk the smoke checklist from the spec**

1. Open popover (click status item icon). Album art fills the top edge-to-edge with no visible border.
2. Toggle System Settings → Appearance → Light/Dark. Popover edges still rounded; bottom of art meets inner content cleanly in both modes.
3. Press play. Watch the linear progress bar advance and the elapsed counter on the left increment in `mm:ss`. The total duration on the right matches the song length.
4. Press skip. The progress bar resets to 0; the new song's elapsed/total appear.
5. Press pause. The bar stops advancing. Press play. The bar resumes from where it was.
6. Click the rating dropdown. Pick a value. The dropdown closes and the new digit appears as the label.
7. Sign out (or test with a fresh account before signing in). The rating dropdown shows `—` and is disabled (greyed).
8. Mash the play button rapidly. No blue flash — only the opacity dim. Same for the skip button.
9. Click the gear icon. A menu opens with `Settings…` and `Quit RP Player`. Click Settings — the settings window opens. Re-open the popover, click gear again, click Quit — the app terminates cleanly with no log spam.
10. Re-launch. Re-open popover. Confirm the gear menu works again.

If any step fails, file the bug, fix it, re-run.

- [ ] **Step 3: No commit required for smoke unless a fix lands.**

---

## Task 12: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump test count + add a section under "Test counts by PR"**

Append a line under the existing list (the line currently reads `- After promo block fix … : 209`). Add:

```
- After popover visual polish (positionUpdates stream + RatingMenu + edge-to-edge art + Quit menu + press-opacity buttons; deletes RatingRow): 217
```

(Adjust the final number to match the actual `swift test` output after Task 10.)

- [ ] **Step 2: Add a one-paragraph note in the "Coordinator playback" section**

Find the section in CLAUDE.md beginning `### Coordinator playback`. Append a new bullet under the existing ones:

```
- `LivePlaybackCoordinator` exposes `positionUpdates: AsyncStream<Double>` (block-position seconds, same reference frame as `NowPlaying.songStartSeconds` / `songEndSeconds`). Multi-subscriber: per-call continuation, seeded with the current `currentPositionSeconds`, yields on every `.positionUpdate` engine event, finished on `shutdown`. The mini-player view model subscribes once per `start()` and derives in-song elapsed/duration for the popover progress bar.
```

- [ ] **Step 3: Add a note in the "Shell (AppKit + SwiftUI)" section**

Find the section in CLAUDE.md beginning `### Shell (AppKit + SwiftUI)`. Append a new bullet:

```
- The settings gear in `channelRow` is a SwiftUI `Menu` exposing `Settings…` and `Quit RP Player`. Quit calls `NSApp.terminate(nil)`; `AppDelegate.applicationWillTerminate` already handles the graceful coordinator shutdown.
- Transport buttons (play/pause + skip) use `PressOpacityButtonStyle` instead of `.buttonStyle(.plain)`. Plain style flashed the system blue on press; the custom style dims to 0.55 opacity with no background.
- `MiniPlayerView` body is `VStack(spacing: 0)` with the album art at full popover width (342×342, `scaledToFill+clipped`) and the inner stack carrying its own 12pt padding. The popover's existing 10pt corner radius + `masksToBounds` clips the top of the art so the popover appears as an extension of the artwork.
- `RatingMenu` replaces the previous full-width `RatingRow`. Narrow dropdown sitting in the title row right-aligned; label is the rating digit or `—`; disabled when signed out.
```

- [ ] **Step 4: Update the "Current state" line at the top**

The current top line reads:

```
- Last merged: **PR 12.5** … 209 tests passing on `main`.
- Next: **PR 13** — distribution CI workflow + `.app` bundling.
```

Change the second line to:

```
- Next: **popover visual polish** branch in flight (then PR 13 — distribution CI workflow + `.app` bundling).
```

(After this branch ff-merges, the next conversation will move the line again.)

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): note popover visual polish (positionUpdates, gear menu, press-opacity, edge-to-edge art)"
```

---

## Task 13: Final verification

- [ ] **Step 1: Build everything**

```bash
swift build 2>&1 | tail -5
```

Expected: succeeds with no warnings (or the same warnings the baseline already had).

- [ ] **Step 2: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Test Suite 'All tests' passed at ...` with the count noted in CLAUDE.md.

- [ ] **Step 3: Verify branch state**

```bash
git status
git log --oneline main..HEAD
```

Expected: clean working tree; ~10 commits between `main` and `HEAD`.

- [ ] **Step 4: Hand back to user for ff-merge**

The user is the merge gatekeeper (CLAUDE.md: "Merge strategy: fast-forward only (`git merge --ff-only`) to main after all reviews pass."). Do not merge yourself.

Surface to the user: branch is ready for review and merge. Final test count and a one-paragraph summary of what changed.

---

## Self-review notes

- Spec coverage:
  - Edge-to-edge art → Task 9
  - Progress bar (data + UI) → Tasks 1–5 (data) + Task 9 (UI)
  - Rating dropdown → Tasks 7–8 (component) + Task 9 (placement)
  - No press-state blue → Task 6 (style) + Task 9 (apply to play+skip)
  - Quit → Task 9 (gear `Menu` with terminate call)
  - Coordinator stream + view-model wiring → Tasks 1–5
  - Manual smoke → Task 11
  - CLAUDE.md update → Task 12
- Type consistency: `positionUpdates` named identically in protocol, live impl, and mock. `RatingMenu` used in `MiniPlayerView`. `PressOpacityButtonStyle` referenced as `PressOpacityButtonStyle()` (no init args).
- No placeholders. Every step has either exact code or an exact command + expected output.
- TDD: Tasks 1–4 introduce a protocol change → tests → impl → mock-conformance. Tasks 5, 8 are TDD on view model and rating component. Task 9 is restructuring covered by an existing smoke test plus manual smoke (Task 11). Task 6 has no behavior to TDD (pure styling).
