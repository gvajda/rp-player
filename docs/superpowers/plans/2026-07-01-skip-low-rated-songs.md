# Skip Low-Rated Songs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-skip songs rated below a user-chosen threshold — immediately when the current song is rated low, and silently (no audio download) for already-low-rated songs reached in the queue, while marking them in the upcoming list.

**Architecture:** A single `SkipPolicy` value (`enabled`, `threshold`) derived from two new `AppSettings` fields drives every consumer. The playback coordinator filters skip-bound songs out of its queue at fetch time (Layer A — they're never downloaded or queued) and re-checks the head at playback time (Layer B — catches songs queued before a mid-playback settings change). `MiniPlayerViewModel.rate` triggers an immediate `skipForward` after a low rating. The upcoming list (a separate gapless fetch) keeps skip-bound songs and renders them dimmed with a SKIP pill.

**Tech Stack:** Swift 6.2, macOS 14, SwiftUI + AppKit, XCTest, libmpv, actor-based concurrency.

## Global Constraints

- Rating scale is **1–10** (`GaplessSong.userRating`, `0` = unrated). Threshold is on this scale.
- `shouldSkip(userRating) = enabled && userRating > 0 && userRating < threshold` (strict less-than). Default threshold **5** → skips 1–4, keeps 5–10.
- Promos (`type == "P"`) and unrated songs (`userRating == 0`) are never skipped.
- Comment policy (strict): no comments unless the WHY is non-obvious; single `//` line max; no docstrings.
- Test command: `swift test`. Build command: `swift build`.
- Every new `AppSettings` field needs all four: stored property, `init` parameter+assignment, `init(from:)` decode-with-default, `encode` line, and a `CodingKeys` case.
- `updateSkipPolicy` stays a method on the concrete `LivePlaybackCoordinator` (not the `PlaybackCoordinator` protocol) — AppContainer and tests hold the concrete type. Do **not** add it to the protocol or to `MockPlaybackCoordinator`.
- Empty-block message string (exact, reused verbatim): `No upcoming songs match your rating filter — raise the threshold in Settings.`

---

### Task 1: SkipPolicy value type

**Files:**
- Create: `Sources/RPPlayer/Playback/SkipPolicy.swift`
- Test: `Tests/RPPlayerTests/Playback/SkipPolicyTests.swift`

**Interfaces:**
- Produces: `struct SkipPolicy: Equatable, Sendable { let enabled: Bool; let threshold: Int; init(enabled: Bool, threshold: Int); func shouldSkip(_ userRating: Int) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

final class SkipPolicyTests: XCTestCase {
    func testDisabledNeverSkips() {
        let policy = SkipPolicy(enabled: false, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(1))
        XCTAssertFalse(policy.shouldSkip(10))
    }

    func testUnratedNeverSkips() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(0))
    }

    func testBelowThresholdSkips() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertTrue(policy.shouldSkip(1))
        XCTAssertTrue(policy.shouldSkip(4))
    }

    func testAtOrAboveThresholdKept() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(5))
        XCTAssertFalse(policy.shouldSkip(6))
        XCTAssertFalse(policy.shouldSkip(10))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkipPolicyTests`
Expected: FAIL (compile error — `SkipPolicy` not defined).

- [ ] **Step 3: Write minimal implementation**

```swift
public struct SkipPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let threshold: Int

    public init(enabled: Bool, threshold: Int) {
        self.enabled = enabled
        self.threshold = threshold
    }

    public func shouldSkip(_ userRating: Int) -> Bool {
        enabled && userRating > 0 && userRating < threshold
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkipPolicyTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Playback/SkipPolicy.swift Tests/RPPlayerTests/Playback/SkipPolicyTests.swift
git commit -m "feat(skip): add SkipPolicy value type"
```

---

### Task 2: AppSettings fields

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Test: `Tests/RPPlayerTests/Config/SkipSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.skipLowRatedEnabled: Bool` (default `false`), `AppSettings.skipRatingThreshold: Int` (default `5`), both `init` params.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

final class SkipSettingsTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings.default
        XCTAssertFalse(s.skipLowRatedEnabled)
        XCTAssertEqual(s.skipRatingThreshold, 5)
    }

    func testDecodeMissingKeysUsesDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(s.skipLowRatedEnabled)
        XCTAssertEqual(s.skipRatingThreshold, 5)
    }

    func testRoundTrip() throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 7
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.skipLowRatedEnabled)
        XCTAssertEqual(decoded.skipRatingThreshold, 7)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkipSettingsTests`
Expected: FAIL (compile error — no `skipLowRatedEnabled` member).

- [ ] **Step 3: Add the stored properties**

In `AppSettings.swift`, after the `public var frostedUpcomingEnabled: Bool` line, add:

```swift
    public var skipLowRatedEnabled: Bool
    public var skipRatingThreshold: Int
```

- [ ] **Step 4: Add init parameters + assignments**

In the `public init(...)` parameter list, after `frostedUpcomingEnabled: Bool = false,` add:

```swift
        skipLowRatedEnabled: Bool = false,
        skipRatingThreshold: Int = 5,
```

In the init body, after `self.frostedUpcomingEnabled = frostedUpcomingEnabled`, add:

```swift
        self.skipLowRatedEnabled = skipLowRatedEnabled
        self.skipRatingThreshold = skipRatingThreshold
```

- [ ] **Step 5: Add decode-with-default**

In `init(from decoder:)`, after the `self.frostedUpcomingEnabled = try c.decodeIfPresent(...)` line, add:

```swift
        self.skipLowRatedEnabled = try c.decodeIfPresent(Bool.self, forKey: .skipLowRatedEnabled) ?? false
        self.skipRatingThreshold = try c.decodeIfPresent(Int.self, forKey: .skipRatingThreshold) ?? 5
```

- [ ] **Step 6: Add CodingKeys + encode**

In the `CodingKeys` enum, add to the `ambientBackgroundEnabled, popoverStyle, frostedUpcomingEnabled` line so it reads:

```swift
        case ambientBackgroundEnabled, popoverStyle, frostedUpcomingEnabled
        case skipLowRatedEnabled, skipRatingThreshold
```

In `encode(to:)`, after `try c.encode(frostedUpcomingEnabled, forKey: .frostedUpcomingEnabled)`, add:

```swift
        try c.encode(skipLowRatedEnabled, forKey: .skipLowRatedEnabled)
        try c.encode(skipRatingThreshold, forKey: .skipRatingThreshold)
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter SkipSettingsTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift Tests/RPPlayerTests/Config/SkipSettingsTests.swift
git commit -m "feat(skip): add skipLowRatedEnabled + skipRatingThreshold to AppSettings"
```

---

### Task 3: SettingsViewModel published state + setters

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelSkipTests.swift`

**Interfaces:**
- Consumes: `AppSettings.skipLowRatedEnabled`, `AppSettings.skipRatingThreshold` (Task 2).
- Produces: `SettingsViewModel.skipLowRatedEnabled: Bool` (`@Published private(set)`), `SettingsViewModel.skipRatingThreshold: Int` (`@Published private(set)`), `func setSkipLowRatedEnabled(_ value: Bool) async`, `func setSkipRatingThreshold(_ value: Int) async`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelSkipTests: XCTestCase {
    private func makeVM(_ settings: AppSettings) -> (SettingsViewModel, StubConfigStore) {
        let store = StubConfigStore(initial: settings)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {}, openApplicationData: {}
        )
        return (vm, store)
    }

    func testInitialReflectsSnapshot() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 7
        let (vm, _) = makeVM(s)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.skipLowRatedEnabled)
        XCTAssertEqual(vm.skipRatingThreshold, 7)
        await vm.stop()
    }

    func testSetTogglePersists() async throws {
        let (vm, store) = makeVM(.default)
        await vm.start()
        await vm.setSkipLowRatedEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.current.skipLowRatedEnabled)
        XCTAssertTrue(vm.skipLowRatedEnabled)
        await vm.stop()
    }

    func testSetThresholdPersists() async throws {
        let (vm, store) = makeVM(.default)
        await vm.start()
        await vm.setSkipRatingThreshold(3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.skipRatingThreshold, 3)
        XCTAssertEqual(vm.skipRatingThreshold, 3)
        await vm.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsViewModelSkipTests`
Expected: FAIL (compile error — no `skipLowRatedEnabled` on `SettingsViewModel`).

- [ ] **Step 3: Add published properties**

After `@Published private(set) var frostedUpcomingEnabled: Bool` (near line 18), add:

```swift
    @Published private(set) var skipLowRatedEnabled: Bool = false
    @Published private(set) var skipRatingThreshold: Int = 5
```

- [ ] **Step 4: Initialize from snapshot in init**

In `init(...)`, after `self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled`, add:

```swift
        self.skipLowRatedEnabled = snapshot.skipLowRatedEnabled
        self.skipRatingThreshold = snapshot.skipRatingThreshold
```

- [ ] **Step 5: Sync from configStore stream in start()**

In `start()`, inside the `for await snapshot in configStream` `MainActor.run` block, after `self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled`, add:

```swift
                    self.skipLowRatedEnabled = snapshot.skipLowRatedEnabled
                    self.skipRatingThreshold = snapshot.skipRatingThreshold
```

- [ ] **Step 6: Add setters**

After `setFrostedUpcomingEnabled(_:)` (near line 303), add:

```swift
    func setSkipLowRatedEnabled(_ value: Bool) async {
        await update { $0.skipLowRatedEnabled = value }
    }

    func setSkipRatingThreshold(_ value: Int) async {
        await update { $0.skipRatingThreshold = value }
    }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter SettingsViewModelSkipTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelSkipTests.swift
git commit -m "feat(skip): SettingsViewModel skip toggle + threshold setters"
```

---

### Task 4: Settings UI section

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsViewModel.skipLowRatedEnabled`, `skipRatingThreshold`, `setSkipLowRatedEnabled`, `setSkipRatingThreshold` (Task 3).

No unit test: SwiftUI section rendering is not unit-tested in this repo (logic lives in the tested view model). Verify via `swift build` + manual smoke (Step 4).

- [ ] **Step 1: Add the section view**

After the `notificationsSection` computed property (near line 618), add:

```swift
    private var skipLowRatedSection: some View {
        Section("Playback") {
            Toggle("Skip songs rated below a threshold", isOn: skipLowRatedBinding)
            if viewModel.skipLowRatedEnabled {
                Picker("Skip below", selection: skipRatingThresholdBinding) {
                    ForEach(2...10, id: \.self) { n in
                        Text("★ \(n)").tag(n)
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: Add the bindings**

After the `notificationsBinding` computed property (near line 804), add:

```swift
    private var skipLowRatedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.skipLowRatedEnabled },
            set: { newValue in Task { await viewModel.setSkipLowRatedEnabled(newValue) } }
        )
    }

    private var skipRatingThresholdBinding: Binding<Int> {
        Binding(
            get: { viewModel.skipRatingThreshold },
            set: { newValue in Task { await viewModel.setSkipRatingThreshold(newValue) } }
        )
    }
```

- [ ] **Step 3: Insert the section into the Form**

In `body`, in the `Form { ... }`, after `notificationsSection`, add `skipLowRatedSection`:

```swift
                notificationsSection
                skipLowRatedSection
                appearanceSection
```

- [ ] **Step 4: Build + manual verify**

Run: `swift build`
Expected: builds clean. Then run the app, open Settings: a "Playback" section shows the toggle; enabling it reveals a "Skip below" picker defaulting to ★ 5 with options ★ 2…★ 10; disabling hides the picker.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(skip): Settings Playback section — toggle + threshold picker"
```

---

### Task 5: Coordinator — skip policy state, queue filter (Layer A), empty-block stop

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Test: `Tests/RPPlayerTests/Playback/PlaybackCoordinatorSkipTests.swift`

**Interfaces:**
- Consumes: `SkipPolicy` (Task 1).
- Produces (on `LivePlaybackCoordinator`): `func updateSkipPolicy(_ policy: SkipPolicy) async`, private `var skipPolicy: SkipPolicy`, private `func shouldSkip(_ userRating: Int) -> Bool`, private `func applySkipFilter(_ songs: [GaplessSong]) -> [GaplessSong]`, private `func stopWithNoMatchesMessage() async`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

final class PlaybackCoordinatorSkipTests: XCTestCase {
    private func silentLogger() -> AppLogger { AppLogger(category: "PlaybackCoordinatorSkipTests") }

    /// Skip-bound songs are filtered out of the queue: never played, never queueNext'd, never downloaded.
    func testSkipBoundSongsExcludedFromQueue() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "good1", eventId: 100, gaplessUrl: "https://example.com/good1.flac", userRating: 8),
            makeGaplessSong(songId: "bad",   eventId: 101, gaplessUrl: "https://example.com/bad.flac",   userRating: 2),
            makeGaplessSong(songId: "good2", eventId: 102, gaplessUrl: "https://example.com/good2.flac", userRating: 0),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))
        try await coord.play(channelId: 0)

        let engineCalls = await engine.recordedCalls()
        // First playable song is good1; the "bad" rating-2 song is never queued.
        XCTAssertEqual(engineCalls.first, .play(url: URL(string: "https://example.com/good1.flac")!, startSeconds: nil))
        XCTAssertFalse(engineCalls.contains { call in
            if case .play(let url, _) = call { return url.absoluteString.contains("bad") }
            if case .queueNext(let url, _) = call { return url.absoluteString.contains("bad") }
            return false
        }, "skip-bound song must never be played or queued. calls=\(engineCalls)")
        // queueNext goes to good2 (the next playable), skipping bad.
        XCTAssertTrue(engineCalls.contains(.queueNext(url: URL(string: "https://example.com/good2.flac")!, startSeconds: nil)))
    }

    /// A block where every song is skip-bound stops playback and emits the no-matches message.
    func testAllSkippedStopsAndMessages() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "b1", eventId: 100, gaplessUrl: "https://example.com/b1.flac", userRating: 1),
            makeGaplessSong(songId: "b2", eventId: 101, gaplessUrl: "https://example.com/b2.flac", userRating: 2),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))

        var emitted: [String] = []
        let errorsStream = await coord.errors
        let collector = Task { for await m in errorsStream { emitted.append(m) } }

        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()

        let engineCalls = await engine.recordedCalls()
        XCTAssertFalse(engineCalls.contains { if case .play = $0 { return true } else { return false } },
                       "nothing should play when all songs are skip-bound. calls=\(engineCalls)")
        XCTAssertTrue(emitted.contains("No upcoming songs match your rating filter — raise the threshold in Settings."),
                      "expected no-matches message. emitted=\(emitted)")
    }

    /// Policy disabled → no filtering; low-rated songs play normally.
    func testDisabledPolicyPlaysLowRated() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "low", eventId: 100, gaplessUrl: "https://example.com/low.flac", userRating: 1),
            makeGaplessSong(songId: "low2", eventId: 101, gaplessUrl: "https://example.com/low2.flac", userRating: 1),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: MockSongFileCache(), logger: silentLogger(), bitrateProvider: { 4 }
        )
        // No updateSkipPolicy call → defaults to disabled.
        try await coord.play(channelId: 0)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.first, .play(url: URL(string: "https://example.com/low.flac")!, startSeconds: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackCoordinatorSkipTests`
Expected: FAIL (compile error — no `updateSkipPolicy`).

- [ ] **Step 3: Add policy state + helpers**

In `LivePlaybackCoordinator`, add a stored property near `private var queue` (it's an actor, so plain `var`):

```swift
    private var skipPolicy: SkipPolicy = SkipPolicy(enabled: false, threshold: 5)
```

Add these methods (place them right after the `emitUserMessage` method near line 574):

```swift
    public func updateSkipPolicy(_ policy: SkipPolicy) async {
        skipPolicy = policy
    }

    private func shouldSkip(_ userRating: Int) -> Bool {
        skipPolicy.shouldSkip(userRating)
    }

    private func applySkipFilter(_ songs: [GaplessSong]) -> [GaplessSong] {
        guard skipPolicy.enabled else { return songs }
        return songs.filter { !shouldSkip($0.userRating) }
    }

    private func stopWithNoMatchesMessage() async {
        try? await stop()
        await emitUserMessage("No upcoming songs match your rating filter — raise the threshold in Settings.")
    }
```

- [ ] **Step 4: Filter in playInternal**

In `playInternal`, replace:

```swift
        let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        guard !response.songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        queue = response.songs
```

with:

```swift
        let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        guard !response.songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        let filtered = applySkipFilter(response.songs)
        guard !filtered.isEmpty else {
            await stopWithNoMatchesMessage()
            return
        }
        queue = filtered
```

- [ ] **Step 5: Filter in skipForward shallow path**

In `skipForward`, in the shallow-queue branch, replace:

```swift
        guard !response.songs.isEmpty else {
            emitState(.playing)
            errorsContinuation?.yield("Cannot skip — no upcoming songs.")
            return
        }
        // Drop the skipped song; jump to the new response's first song.
        queue = response.songs
```

with:

```swift
        guard !response.songs.isEmpty else {
            emitState(.playing)
            errorsContinuation?.yield("Cannot skip — no upcoming songs.")
            return
        }
        let filtered = applySkipFilter(response.songs)
        guard !filtered.isEmpty else {
            await stopWithNoMatchesMessage()
            return
        }
        // Drop the skipped song; jump to the new response's first song.
        queue = filtered
```

- [ ] **Step 6: Filter appended songs in runRefetch**

In `runRefetch`, replace:

```swift
        let newSongs = response.songs.filter { $0.eventId > tailEvent }
```

with:

```swift
        let newSongs = applySkipFilter(response.songs.filter { $0.eventId > tailEvent })
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swift test --filter PlaybackCoordinatorSkipTests`
Expected: PASS (3 tests).

- [ ] **Step 8: Run the full coordinator suite to check for regressions**

Run: `swift test --filter LivePlaybackCoordinatorTests`
Expected: PASS (no regressions — existing tests use `userRating: 0`, which is never skipped).

- [ ] **Step 9: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/PlaybackCoordinatorSkipTests.swift
git commit -m "feat(skip): coordinator queue filter (Layer A) + empty-block stop"
```

---

### Task 6: Coordinator — playback-time skip (Layer B)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Test: `Tests/RPPlayerTests/Playback/PlaybackCoordinatorSkipTests.swift` (add to the Task 5 file)

**Interfaces:**
- Consumes: `shouldSkip`, `skipForward` (Task 5).

Layer B catches a song that entered the queue **before** a settings change (Layer A only filters fresh fetches). When such a song becomes the playing head, re-check it and `skipForward` past it. It reuses `skipForward`, so the briefly-played song may emit minimal play telemetry — acceptable for this rare mid-change case; the no-download/no-telemetry guarantee holds firmly for Layer A.

- [ ] **Step 1: Write the failing test**

Add to `PlaybackCoordinatorSkipTests`:

```swift
    /// A song that becomes skip-bound after a mid-playback policy change is auto-skipped when it becomes head.
    func testHeadBecomingSkipBoundIsAutoSkipped() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "s1", eventId: 100, gaplessUrl: "https://example.com/s1.flac", userRating: 8),
            makeGaplessSong(songId: "s2", eventId: 101, gaplessUrl: "https://example.com/s2.flac", userRating: 2),
            makeGaplessSong(songId: "s3", eventId: 102, gaplessUrl: "https://example.com/s3.flac", userRating: 9),
            makeGaplessSong(songId: "s4", eventId: 103, gaplessUrl: "https://example.com/s4.flac", userRating: 9),
        ])
        await api.setGaplessResponse(response)
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        await cache.markDownloaded(response.songs)
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        // Start with policy disabled so s2 (rating 2) is queued normally.
        try await coord.play(channelId: 0)
        await engine.fire(.fileStarted)  // initial: head = s1
        try await Task.sleep(nanoseconds: 50_000_000)

        // Now enable the policy mid-playback. s2 is already in the queue (downloaded/queued).
        await coord.updateSkipPolicy(SkipPolicy(enabled: true, threshold: 5))

        // mpv advances to s2 → Layer B sees a skip-bound head and skips forward to s3.
        await engine.setSimulatedCurrentPath(URL(string: "https://example.com/s2.flac"))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 150_000_000)

        let engineCalls = await engine.recordedCalls()
        XCTAssertTrue(engineCalls.contains(.advanceToQueued),
                      "Layer B should advance past the skip-bound head. calls=\(engineCalls)")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackCoordinatorSkipTests/testHeadBecomingSkipBoundIsAutoSkipped`
Expected: FAIL (no `.advanceToQueued` triggered — Layer B not implemented).

- [ ] **Step 3: Add the Layer B check in syncQueueHeadFromMpv**

In `syncQueueHeadFromMpv`, after the `emitNowPlaying(forSongAt: 0)` + `fireSongStartTelemetry(...)` block and before the `if isAdvance { ... }` re-queue block, insert:

```swift
        if shouldSkip(queue[0].userRating), queue.count >= 1 {
            logger.info("auto-skip head (rating \(queue[0].userRating) below threshold) \(describeSong(queue[0]))")
            try? await skipForward()
            return
        }
```

Note: `skipForward` handles both the queue-deep advance and the shallow refetch (which re-filters and, if empty, stops with the no-matches message), so a run of consecutive skip-bound songs terminates correctly.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlaybackCoordinatorSkipTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full coordinator suite**

Run: `swift test --filter LivePlaybackCoordinatorTests`
Expected: PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/PlaybackCoordinatorSkipTests.swift
git commit -m "feat(skip): coordinator playback-time skip (Layer B)"
```

---

### Task 7: MiniPlayerViewModel — immediate skip after low rating

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelSkipTests.swift`

**Interfaces:**
- Consumes: `AppSettings.skipLowRatedEnabled`, `skipRatingThreshold` (Task 2); `SkipPolicy` (Task 1); `MockPlaybackCoordinator` records `.rate` via `api`, `.skipForward` via coordinator.

`rate(_:)` reads the live policy from `configStore.settings` after a successful rate and, if the rating should skip, calls `coordinator.skipForward()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelSkipTests: XCTestCase {
    private func makeVM(settings: AppSettings, rating: Int)
        async -> (MiniPlayerViewModel, MockPlaybackCoordinator, StubKeychainAuth) {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let auth = StubKeychainAuth()
        auth.loggedIn = true
        let store = StubConfigStore(initial: settings)
        let vm = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: auth,
            configStore: store,
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: {}
        )
        let song = makeGaplessSong(songId: "42", eventId: 100, userRating: 0)
        let np = NowPlaying(channelId: 0, song: song, songDurationSeconds: 180, bitrateLabel: "flac")
        await coordinator.setNowPlaying(np)
        await vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.refreshAuthState()
        return (vm, coordinator, auth)
    }

    func testRateBelowThresholdSkips() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s, rating: 2)
        await vm.rate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertTrue(calls.contains(.skipForward), "rating 2 below threshold 5 should skip. calls=\(calls)")
        await vm.stop()
    }

    func testRateAtThresholdDoesNotSkip() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s, rating: 5)
        await vm.rate(5)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertFalse(calls.contains(.skipForward), "rating 5 (== threshold) must not skip. calls=\(calls)")
        await vm.stop()
    }

    func testRateBelowThresholdDisabledDoesNotSkip() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = false
        s.skipRatingThreshold = 5
        let (vm, coordinator, _) = await makeVM(settings: s, rating: 2)
        await vm.rate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await coordinator.recordedCalls()
        XCTAssertFalse(calls.contains(.skipForward), "feature disabled must not skip. calls=\(calls)")
        await vm.stop()
    }
}
```

`StubAlbumArtCache` already exists in the test target (`Tests/RPPlayerTests/Shell/StubAlbumArtCache.swift`, `@MainActor final class StubAlbumArtCache: AlbumArtCache`) — use it directly, no new stub needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MiniPlayerViewModelSkipTests`
Expected: FAIL (rating below threshold does not yet trigger `.skipForward`).

- [ ] **Step 3: Implement the immediate skip**

In `MiniPlayerViewModel.rate(_:)`, replace:

```swift
            _ = try await api.rate(songId: songId, rating: value)
            currentRating = value
```

with:

```swift
            _ = try await api.rate(songId: songId, rating: value)
            currentRating = value
            let s = await configStore.settings
            if SkipPolicy(enabled: s.skipLowRatedEnabled, threshold: s.skipRatingThreshold).shouldSkip(value) {
                try? await coordinator.skipForward()
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MiniPlayerViewModelSkipTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelSkipTests.swift
git commit -m "feat(skip): immediate skip on rating current song below threshold"
```

---

### Task 8: UpcomingProgramViewModel — isSkipped on rows

**Files:**
- Modify: `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`
- Test: `Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelSkipTests.swift`

**Interfaces:**
- Consumes: `SkipPolicy` (Task 1); `AppSettings.skipLowRatedEnabled`, `skipRatingThreshold` (Task 2).
- Produces: `UpcomingSongRow.isSkipped: Bool` (new stored field, last parameter, no default).

Because `UpcomingSongRow` gains a non-defaulted field, update its single construction site inside `load()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class UpcomingProgramViewModelSkipTests: XCTestCase {
    private func makeVM(_ settings: AppSettings, _ api: MockRpApiClient) -> UpcomingProgramViewModel {
        UpcomingProgramViewModel(
            api: api,
            albumArtCache: StubAlbumArtCache(),
            configStore: StubConfigStore(initial: settings),
            paletteExtractor: StubAmbientPaletteExtractor()
        )
    }

    func testRowsMarkedSkippedByPolicy() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 5
        let api = MockRpApiClient()
        await api.setListChannelsResponse([Channel(chan: "0", title: "Main", streamName: "main", bannerUrl: nil, slug: nil, image: nil)])
        await api.setGaplessByChannel([0: makeGaplessResponse(songs: [
            makeGaplessSong(songId: "good", eventId: 100, userRating: 8),
            makeGaplessSong(songId: "bad",  eventId: 101, userRating: 2),
            makeGaplessSong(songId: "new",  eventId: 102, userRating: 0),
        ])])
        let vm = makeVM(s, api)
        await vm.load()

        let rows = vm.columns.first?.songs ?? []
        XCTAssertEqual(rows.first(where: { $0.song.songId == "good" })?.isSkipped, false)
        XCTAssertEqual(rows.first(where: { $0.song.songId == "bad" })?.isSkipped, true)
        XCTAssertEqual(rows.first(where: { $0.song.songId == "new" })?.isSkipped, false)
    }

    func testNoRowsSkippedWhenDisabled() async throws {
        let s = AppSettings.default  // skipLowRatedEnabled defaults false
        let api = MockRpApiClient()
        await api.setListChannelsResponse([Channel(chan: "0", title: "Main", streamName: "main", bannerUrl: nil, slug: nil, image: nil)])
        await api.setGaplessByChannel([0: makeGaplessResponse(songs: [
            makeGaplessSong(songId: "bad", eventId: 101, userRating: 2),
        ])])
        let vm = makeVM(s, api)
        await vm.load()
        XCTAssertEqual(vm.columns.first?.songs.first?.isSkipped, false)
    }
}
```

`Channel` memberwise init is `(chan:title:streamName:bannerUrl:slug:image:)`. Use `StubAlbumArtCache` as in Task 7.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UpcomingProgramViewModelSkipTests`
Expected: FAIL (compile error — `UpcomingSongRow` has no `isSkipped`).

- [ ] **Step 3: Add the field**

In `UpcomingProgramViewModel.swift`, change the `UpcomingSongRow` struct:

```swift
struct UpcomingSongRow: Identifiable, Sendable {
    let id: String
    let song: GaplessSong
    let art: NSImage?
    let ambientColor: Color
    let isSkipped: Bool
}
```

- [ ] **Step 4: Compute isSkipped in load()**

In `load()`, the `settings` snapshot is already read near the top (`let settings = await configStore.settings`). After that line, add:

```swift
        let skipPolicy = SkipPolicy(enabled: settings.skipLowRatedEnabled, threshold: settings.skipRatingThreshold)
```

Then update the row construction inside the `columns = stubs.enumerated().map { ... }` block:

```swift
                return UpcomingSongRow(
                    id: "\(stub.chanId)-\(song.songId)",
                    song: song,
                    art: art,
                    ambientColor: color,
                    isSkipped: skipPolicy.shouldSkip(song.userRating)
                )
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter UpcomingProgramViewModelSkipTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Run the existing upcoming suite for regressions**

Run: `swift test --filter UpcomingProgramViewModelTests`
Expected: PASS (existing rows now carry `isSkipped: false` since defaults are unrated/disabled).

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelSkipTests.swift
git commit -m "feat(skip): mark upcoming rows as skip-bound by policy"
```

---

### Task 9: UpcomingSongCardView — Dim + SKIP pill

**Files:**
- Modify: `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift`

**Interfaces:**
- Consumes: `UpcomingSongRow.isSkipped` (Task 8).

No unit test (SwiftUI card rendering is not unit-tested here; the data flow is covered by Task 8). Verify via `swift build` + manual smoke (Step 3).

- [ ] **Step 1: Apply dim + pill in UpcomingSongCardView**

In `UpcomingSongCardView.body`, wrap the styled card so the whole card dims and gains a SKIP pill overlay when `row.isSkipped`. Replace the `body` with:

```swift
    var body: some View {
        HStack(spacing: 0) {
            artView
            textArea
        }
        .frame(height: 68)
        .frame(maxWidth: .infinity)
        .background(row.ambientColor.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
        )
        .shadow(color: isCurrent ? Color.accentColor.opacity(0.6) : .clear, radius: 6)
        .opacity(row.isSkipped ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            if row.isSkipped {
                Text("⏭ SKIP")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary))
                    .padding(4)
            }
        }
    }
```

(The pill sits at full opacity over the dimmed card because the `.overlay` is applied after `.opacity`.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Manual verify**

Run the app, open the Upcoming window with the skip feature enabled and a threshold above some previously low-rated song: that song's card appears at ~40% opacity with a "⏭ SKIP" pill in the top-right corner; the ★ rating badge still shows; other cards render normally.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Upcoming/UpcomingProgramView.swift
git commit -m "feat(skip): dim + SKIP pill marking on upcoming cards"
```

---

### Task 10: Wire skip policy into AppContainer + reactive updates

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

**Interfaces:**
- Consumes: `LivePlaybackCoordinator.updateSkipPolicy` (Task 5); `AppSettings.skipLowRatedEnabled`, `skipRatingThreshold` (Task 2); `SkipPolicy` (Task 1).

No unit test: this is integration glue (the coordinator behavior is covered by Tasks 5–6). Verify via `swift build` + the full suite.

- [ ] **Step 1: Push initial policy + subscribe to changes**

In `AppContainer`, right after `coordinatorBox.value = coordinator` (near line 293), add:

```swift
        Task { [coordinator, store, initial] in
            await coordinator.updateSkipPolicy(
                SkipPolicy(enabled: initial.skipLowRatedEnabled, threshold: initial.skipRatingThreshold)
            )
            guard let store else { return }
            let stream = await store.changes
            for await settings in stream {
                await coordinator.updateSkipPolicy(
                    SkipPolicy(enabled: settings.skipLowRatedEnabled, threshold: settings.skipRatingThreshold)
                )
            }
        }
```

(`coordinator` here is the concrete `LivePlaybackCoordinator` `let`, so `updateSkipPolicy` resolves. `initial` is the startup `AppSettings` already in scope.)

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: PASS (all existing + new tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(skip): wire skip policy from settings into coordinator"
```

---

### Task 11: Documentation

**Files:**
- Modify: `CHANGELOG.md`, `docs/pr-history.md`, `docs/test-counts.md`, `docs/architecture.md`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: CHANGELOG**

Under `## [Unreleased]` → `Added`, add:

```markdown
- Skip low-rated songs: a Settings toggle + threshold picker (★2–★10, default ★5) auto-skips songs rated below the threshold. Rating the current song low skips it immediately; already-low-rated upcoming songs are never downloaded and show a dimmed "⏭ SKIP" marking in the Upcoming list. When a whole block has no qualifying songs, playback stops with a message to raise the threshold.
```

- [ ] **Step 2: pr-history**

Add a PR 44 row to the status table in `docs/pr-history.md` summarizing the skip-low-rated feature.

- [ ] **Step 3: test-counts**

Append a line to `docs/test-counts.md` with the new total (run `swift test 2>&1 | tail -5` to read the executed count; previous total was 572).

- [ ] **Step 4: architecture.md**

Add a short entry documenting the non-obvious two-layer skip decision:

```markdown
### Skip low-rated songs — two-layer skip (PR 44)

Skip-bound songs (`SkipPolicy.shouldSkip`) are removed from the coordinator's
playback queue at every gapless-fetch ingestion point (Layer A) so their audio
is never downloaded, queued, or play-reported. A second check on the playing
head in `syncQueueHeadFromMpv` (Layer B) catches songs that entered the queue
before a mid-playback settings change and `skipForward`s past them. The Upcoming
list is a separate gapless fetch, so it still shows skip-bound songs (marked),
fetching only their album art. A fully-filtered block stops playback with a
user message rather than retrying.
```

- [ ] **Step 5: CLAUDE.md**

Refresh the *Current state* block: last merged → PR 44 (skip low-rated songs); next up → TBD.

- [ ] **Step 6: README**

Add the skip-low-rated feature to the user-facing feature list / Settings description.

- [ ] **Step 7: Commit**

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md docs/architecture.md CLAUDE.md README.md
git commit -m "docs(skip): document skip-low-rated feature (PR 44)"
```

---

## Self-Review

**Spec coverage:**
- Setting (toggle + dropdown, default 5) → Tasks 2, 3, 4. ✓
- Immediate skip on rating current song below threshold → Task 7. ✓
- Skip-bound upcoming songs marked in list → Tasks 8, 9. ✓
- Skipped songs not downloaded (audio); album art only via upcoming view → Task 5 (Layer A filter; upcoming view fetches art independently — Task 8/9). ✓
- Skip even on forward (never downloaded) → Task 5 (queue filter applies to skipForward shallow refetch; deep advance only ever traverses the already-filtered queue). ✓
- Mid-playback change: don't rip queued song, but skip at playback time → Task 6 (Layer B). ✓
- Empty block → stop + message, no retry → Task 5 (`stopWithNoMatchesMessage`). ✓
- 1–10 scale, strict less-than, default 5, promos/unrated never skip → Task 1 (`SkipPolicy`) + Global Constraints. ✓

**Placeholder scan:** No TBD/TODO in code steps; every code step shows full code. Two view tasks (4, 9) and one integration task (10) intentionally have no unit test with a stated reason + build/manual verification — consistent with the repo's lack of SwiftUI render tests.

**Type consistency:** `SkipPolicy(enabled:threshold:)`, `shouldSkip(_:)`, `updateSkipPolicy(_:)`, `UpcomingSongRow.isSkipped`, `setSkipLowRatedEnabled`, `setSkipRatingThreshold`, the empty-block message string, and the `2...10` picker range are used identically across all tasks.

**Risks to watch during execution:**
- `UpcomingSongRow` gaining a non-defaulted `isSkipped` may have construction sites beyond `load()`; grep `UpcomingSongRow(` in `Sources/` and `Tests/` and fix any others (e.g. previews).
- `NoopAlbumArtCache` / `Channel(...)` initializer shapes in Tasks 7–8 must be reconciled with the real types before the test compiles (notes included inline).
- Confirm no existing `LivePlaybackCoordinatorTests` case relies on a low `userRating` that the default-disabled policy would now (it won't — policy defaults disabled and tests don't call `updateSkipPolicy`).
