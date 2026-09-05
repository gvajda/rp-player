# Cache-Aware Transport Buttons + Stop Action — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the popover transport reflect cache state honestly: loading icon moves to the skip slot when the next track isn't queued (so play/pause stays available); when paused, the second slot becomes a stop button that clears queue/now-playing/art and returns the popover to the just-launched look.

**Architecture:** Add a new `nextReady` signal on `PlaybackCoordinator` (independent from `PlaybackState`), derived from `queue.count >= 2 && queueNextEventId == queue[1].eventId`, broadcast via `nextReadyUpdates: AsyncStream<Bool>`. `MiniPlayerViewModel` subscribes + publishes `nextReady`. View picks slot-2 content from `(isPlaying, nextReady, isPaused)`. Mid-playback `.loading` emits (skipForward queue[1] defer, eof-recovery defer, tryQueueNextOrDefer) are removed because they now collapse onto `nextReady`. View model extends `.stopped` handler to clear now-playing/art/palette; channel selection untouched.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, XCTest. Project uses `swift test` and `swift build`.

**Spec:** `docs/superpowers/specs/2026-05-22-transport-buttons-cache-aware-design.md`.

## File map

**Modify:**
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — protocol additions (`nextReady`, `nextReadyUpdates`), `LivePlaybackCoordinator` impl (storage, `updateNextReady()`, hook into queue/queueNextEventId mutations, remove three `.loading` emits + the now-dead `.playing` lifts paired with them).
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — `@Published nextReady`, subscribe in `start()`, new `stopPlayback()` method, extended `.stopped` clear.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — slot-2 rendering branches on `(isPlaying, nextReady, isPaused)`.
- `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift` — add `nextReadyValue` storage, broadcast continuations, `nextReadyUpdates` stream, `fireNextReady(_:)` test helper.

**Create:**
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift` — new view-model tests for `nextReady` mirroring + `stopPlayback()` clearing.

**Tests added inline:**
- New tests appended to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` for `nextReady` emissions and the absence of mid-playback `.loading`.

**Docs:**
- `CHANGELOG.md` (`## [Unreleased]` → `Added` / `Changed` / `Fixed`).
- `docs/pr-history.md` — append row to status table.
- `docs/test-counts.md` — append new test count.
- `CLAUDE.md` — refresh *Current state* block.
- `README.md` — update screenshot/feature list if applicable (verify in final task).

---

## Task 1: Add `nextReady` to `PlaybackCoordinator` protocol + Mock impl

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (protocol block at lines 9-26)
- Modify: `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`
- Modify (compile-fix only): `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` LivePlaybackCoordinator class (add stored value + conformance)

- [ ] **Step 1: Write failing test for Mock initial `nextReady`**

Add to bottom of `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift` is not the right place — put the test in a new file:

`Tests/RPPlayerTests/Playback/MockPlaybackCoordinatorNextReadyTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class MockPlaybackCoordinatorNextReadyTests: XCTestCase {
    func testNextReadyInitialIsFalse() async {
        let mock = MockPlaybackCoordinator()
        let value = await mock.nextReady
        XCTAssertFalse(value)
    }

    func testFireNextReadyUpdatesValue() async {
        let mock = MockPlaybackCoordinator()
        await mock.fireNextReady(true)
        let value = await mock.nextReady
        XCTAssertTrue(value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MockPlaybackCoordinatorNextReadyTests`
Expected: compile error — `nextReady` and `fireNextReady` don't exist on `MockPlaybackCoordinator`.

- [ ] **Step 3: Add `nextReady` to the protocol**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, inside the protocol declaration (between `var currentPlaybackState` line 14 and `var errors` line 15):

```swift
public protocol PlaybackCoordinator: Sendable, Actor {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }
    var positionUpdates: AsyncStream<Double> { get async }
    var stateUpdates: AsyncStream<PlaybackState> { get async }
    var currentPlaybackState: PlaybackState { get async }
    var nextReady: Bool { get async }
    var nextReadyUpdates: AsyncStream<Bool> { get async }
    var errors: AsyncStream<String> { get async }
    // ...rest unchanged
}
```

- [ ] **Step 4: Add minimal `nextReady` storage + conformance to `LivePlaybackCoordinator`**

In the same file, find the `private var queueNextEventId: Int?` line (around line 51). Add directly after:

```swift
private var nextReadyValue: Bool = false
private var nextReadyContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
```

Then add public computed properties near the existing `stateUpdates` accessor (around line 128). After the `stateUpdates` getter, add:

```swift
public var nextReady: Bool { nextReadyValue }

public var nextReadyUpdates: AsyncStream<Bool> {
    let id = UUID()
    return AsyncStream { continuation in
        self.nextReadyContinuations[id] = continuation
        continuation.yield(self.nextReadyValue)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.unregisterNextReady(id: id) }
        }
    }
}

private func unregisterNextReady(id: UUID) {
    nextReadyContinuations.removeValue(forKey: id)
}
```

(No mutator call sites yet — that lands in Task 3.)

- [ ] **Step 5: Add `nextReady` + `fireNextReady` to `MockPlaybackCoordinator`**

In `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`, add a property block alongside the other continuations (near line 19):

```swift
private var nextReadyValue: Bool = false
private var nextReadyContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
```

Add the protocol-conformance accessors near the existing `stateUpdates` getter (after line 85):

```swift
var nextReady: Bool { nextReadyValue }

var nextReadyUpdates: AsyncStream<Bool> {
    let id = UUID()
    return AsyncStream { continuation in
        self.nextReadyContinuations[id] = continuation
        continuation.yield(self.nextReadyValue)
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.unregisterNextReady(id: id) }
        }
    }
}

private func unregisterNextReady(id: UUID) {
    nextReadyContinuations.removeValue(forKey: id)
}

func fireNextReady(_ value: Bool) {
    nextReadyValue = value
    for c in nextReadyContinuations.values { c.yield(value) }
}
```

Also add stream cleanup in `shutdown()` (line 126-134) — add before `errorsContinuation.finish()`:

```swift
for c in nextReadyContinuations.values { c.finish() }
nextReadyContinuations.removeAll()
```

- [ ] **Step 6: Run test, expect PASS**

Run: `swift test --filter MockPlaybackCoordinatorNextReadyTests`
Expected: 2 tests PASS.

- [ ] **Step 7: Run full test suite to confirm no regressions**

Run: `swift test`
Expected: existing 548 tests still pass + 2 new = 550 total.

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/MockPlaybackCoordinatorNextReadyTests.swift
git commit -m "feat(playback): add nextReady signal to PlaybackCoordinator protocol"
```

---

## Task 2: Wire `nextReady` mutations in `LivePlaybackCoordinator`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (multiple mutator sites)
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append tests)

- [ ] **Step 1: Write failing tests for `nextReady` emissions**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (use existing helpers `makeGaplessSong`, `makeGaplessResponse`, `MockRpApiClient`, `MockPlayerEngine`, `MockSongFileCache`, `silentLogger`):

```swift
    // MARK: - nextReady signal

    func testNextReadyStartsFalse() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        let value = await coordinator.nextReady
        XCTAssertFalse(value)
    }

    func testNextReadyTrueAfterPlayWithCachedQueueOne() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        await cache.markDownloaded([head, next])
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let value = await coordinator.nextReady
        XCTAssertTrue(value, "nextReady should be true once queue[1] is queueNext'd in mpv")
    }

    func testNextReadyFalseWhenQueueOneDeferred() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache() // empty cache → queue[1] defers
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        await cache.markDownloaded([head]) // only head cached; next defers
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let value = await coordinator.nextReady
        XCTAssertFalse(value, "nextReady should remain false while queue[1] download is deferred")
    }

    func testNextReadyFalseAfterStop() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        await cache.markDownloaded([head, next])
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await coordinator.stop()
        let value = await coordinator.nextReady
        XCTAssertFalse(value)
    }

    func testNextReadyStreamReplaysCurrentValue() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        await cache.markDownloaded([head, next])
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )
        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        var iter = await coordinator.nextReadyUpdates.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, true, "new subscriber should immediately receive current nextReady value")
    }
```

- [ ] **Step 2: Run, expect FAIL**

Run: `swift test --filter LivePlaybackCoordinatorTests/testNextReady`
Expected: 5 FAIL — `nextReady` stays false across all scenarios (no mutator hooks yet).

- [ ] **Step 3: Add `updateNextReady()` helper to `LivePlaybackCoordinator`**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, add inside the `LivePlaybackCoordinator` class (place near other private helpers, e.g. directly after `private func emitState`):

```swift
private func updateNextReady() {
    let value = queue.count >= 2 && queueNextEventId == queue[1].eventId
    guard value != nextReadyValue else { return }
    nextReadyValue = value
    for c in nextReadyContinuations.values { c.yield(value) }
}
```

- [ ] **Step 4: Call `updateNextReady()` at every `queue` or `queueNextEventId` mutation**

Audit each assignment site in `LivePlaybackCoordinator`. For each one below, add `updateNextReady()` on the very next line. Use exact text search to locate; line numbers will drift as edits accumulate.

Sites where `queueNextEventId` is assigned (search for `queueNextEventId = `):
- After `queueNextEventId = nil` inside `LivePlaybackCoordinator.stop()` (currently lines 304 and 318 — both copies).
- After `queueNextEventId = next.eventId` inside `skipForward()` queue[1] defer branch (line 373).
- After `queueNextEventId = nil` inside `skipForward()` shallow-refetch path (line 409).
- After `queueNextEventId = nil` inside `applyBitrateChange()` (line 446 and 492 — both copies if present).
- After `queueNextEventId = nil` and `queueNextEventId = next.eventId` inside the recovery branch (lines 586, 603 area).
- After `queueNextEventId = nil` inside `syncQueueHeadFromMpv` advance branch (line 659 area).
- After `queueNextEventId = nil` inside `changeChannel()` (line 733 area).
- After `queueNextEventId = next.eventId` inside `tryQueueNextOrDefer` success branch (line 921).
- After `queueNextEventId = next.eventId` inside `tryQueueNextIfPending(landed:)` (line 943).

Sites where `queue =` is assigned (search for `self.queue = ` and `queue = `):
- `queue = []` in `stop()` (after the new `queueNextEventId = nil`).
- `queue = response.songs` in `skipForward` shallow refetch (line 407).
- `self.queue = [head] + newSongs` in `applyBitrateChange()` (around line 487 — verify exact line).
- `queue =` assignment in recovery (line 580 area).
- `queue =` assignment in `runRefetch` (search for it inside that method).
- Any other `queue.append`, `queue.insert`, `queue.removeFirst`, etc. — search for `queue.` mutating ops and audit each.

**Pattern (apply at every site):**

```swift
queueNextEventId = next.eventId   // existing
updateNextReady()                  // ADDED
```

```swift
queue = response.songs             // existing
updateNextReady()                  // ADDED
```

**Important:** if a method mutates both `queue` and `queueNextEventId` in the same isolated stretch, call `updateNextReady()` **after the last of the two**, not between them. Two intermediate calls are harmless (the early-out in `updateNextReady` suppresses duplicate emissions) but one final call is cheaper.

- [ ] **Step 5: Run the new tests, expect PASS**

Run: `swift test --filter LivePlaybackCoordinatorTests/testNextReady`
Expected: 5 PASS.

- [ ] **Step 6: Run full suite**

Run: `swift test`
Expected: all tests pass. Test count: 550 + 5 = 555.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(playback): compute nextReady from queue + queueNextEventId"
```

---

## Task 3: Remove mid-playback `.loading` emits

The new `nextReady` signal replaces `.loading` as the UI indicator for "next track not preloaded". `.loading` reverts to its session-startup meaning ("no audio coming out").

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write failing test asserting no `.loading` during mid-playback skipForward**

Append to `LivePlaybackCoordinatorTests.swift`:

```swift
    func testSkipForwardWithUncachedQueueNextDoesNotEmitLoading() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        let third = makeGaplessSong(songId: "s2", eventId: 102, gaplessUrl: "https://s.example.com/102.flac")
        await cache.markDownloaded([head]) // only head cached → next defers on play
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next, third]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        // Collect every state emission for the duration of the test.
        actor StateRecorder { var states: [PlaybackState] = []; func record(_ s: PlaybackState) { states.append(s) } }
        let recorder = StateRecorder()
        let stream = await coordinator.stateUpdates
        let task = Task {
            for await s in stream { await recorder.record(s) }
        }
        defer { task.cancel() }

        try await coordinator.play(channelId: 0)
        // Once mpv reports the head started, we're "playing" from the user's POV
        // even though queue[1] is still downloading.
        await engine.setSimulatedCurrentPath(URL(string: head.gaplessUrl))
        await engine.fire(.fileStarted)
        try await Task.sleep(nanoseconds: 80_000_000)

        // Pre-cache `next` so the skipForward-induced cache probe in
        // syncQueueHeadFromMpv has a chance to queueNext if needed, but ensure
        // the queue[1].cached check at skipForward time finds it MISSING — clear
        // again to force the defer branch.
        // Actually we want to test the defer branch directly: ensure queue[1]
        // is uncached at skipForward call time.
        try await coordinator.skipForward()
        try await Task.sleep(nanoseconds: 80_000_000)

        let states = await recorder.states
        // After the initial transition from .stopped → .loading → .playing,
        // no further .loading emission should occur during the skip while audio
        // is playing. Filter out the initial .loading (the startup one is
        // legitimate).
        // Find index of first .playing — anything after it must not be .loading.
        guard let firstPlayingIdx = states.firstIndex(of: .playing) else {
            XCTFail("never reached .playing"); return
        }
        let postPlaying = states[(firstPlayingIdx + 1)...]
        XCTAssertFalse(postPlaying.contains(.loading),
                       "no .loading should be emitted after audio starts; got post-playing states: \(Array(postPlaying))")
    }
```

- [ ] **Step 2: Run, expect FAIL**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardWithUncachedQueueNextDoesNotEmitLoading`
Expected: FAIL — `.loading` currently emitted by skipForward queue[1] defer branch (line 357) and/or `tryQueueNextOrDefer` (line 930).

- [ ] **Step 3: Remove `.loading` emit from `skipForward` queue[1]-not-queued branch**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, delete the line at the queue[1]-not-queued branch (currently line 357):

```swift
emitState(.loading)
```

Also delete the three paired `.playing` emits that only existed to lift the now-deleted `.loading` (currently lines 365, 375, 379):

```swift
emitState(.playing)
```

(All three are inside the `if queueNextEventId != queue[1].eventId { ... }` block. Audio never stopped, so neither emit is needed. Leave the `try await engine.queueNext` and error handling intact.)

- [ ] **Step 4: Remove `.loading` emit from `tryQueueNextOrDefer`**

Delete the line at the bottom of the defer branch (currently line 930):

```swift
emitState(.loading)
```

The `deferredQueueNextAt = clock()` line above it stays — telemetry needs it.

- [ ] **Step 5: Remove `.loading` emit from EOF-recovery defer branch**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, find the eof-recovery branch around line 610. Delete:

```swift
emitState(.loading)
```

(the one inside the `else { ... logger.debug("recovery: deferring queueNext (not cached) ...) }` block).

Also remove the now-dead lift block (currently lines 615-618):

```swift
// Lift any stale .loading once recovery successfully played the head. ...
if currentState == .loading && deferredQueueNextAt == nil {
    emitState(.playing)
}
```

- [ ] **Step 6: Remove now-dead `.playing` lift from `tryQueueNextIfPending(landed:)`**

In `tryQueueNextIfPending(landed:)` (currently around lines 934-955), delete the inner `if currentState == .loading { emitState(.playing) }` (lines 948-950). The `.loading` state is no longer reachable via the defer path, so this lift is dead.

Keep the surrounding `if let deferredAt = deferredQueueNextAt { ... deferredQueueNextAt = nil }` for telemetry.

- [ ] **Step 7: Run new test, expect PASS**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardWithUncachedQueueNextDoesNotEmitLoading`
Expected: PASS.

- [ ] **Step 8: Run full suite**

Run: `swift test`
Expected: some existing tests may now fail if they asserted `.loading` was emitted from any of the removed sites. Inspect failures; for each:
  - If the test was specifically verifying the loading flicker (e.g., `"skipForward emits loading then playing during defer"`), update or remove it — the behavior is now intentionally absent.
  - If the test was a broader integration scenario, replace any `.loading` assertion with the equivalent `nextReady == false` assertion against the new signal.

Expected outcome after fixes: all tests pass. Test count: 555 + 1 - N (where N is the number of obsolete-flicker tests removed; record actual delta in PR description).

- [ ] **Step 9: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor(playback): drop mid-playback .loading emits, defer to nextReady"
```

---

## Task 4: View-model `nextReady` subscription

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Create: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift`

- [ ] **Step 1: Write failing test**

`Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelStopAndNextReadyTests: XCTestCase {
    private func makeViewModel(coordinator: MockPlaybackCoordinator) -> MiniPlayerViewModel {
        // Reuse the helper pattern from MiniPlayerViewModelTests if present;
        // otherwise inline the same factory shape used there.
        let api = MockRpApiClient()
        let albumArt = StubAlbumArtCache()
        let auth = StubKeychainAuth()
        let config = InMemoryConfigStore(initial: AppSettings.defaults)
        let palette = StubPaletteExtractor()
        return MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: albumArt,
            auth: auth,
            configStore: config,
            paletteExtractor: palette,
            openSettings: {},
            persistChannelId: { _ in },
            updateChecker: NoopUpdateChecker()
        )
    }

    func testNextReadyMirrorsCoordinatorStream() async {
        let coord = MockPlaybackCoordinator()
        let vm = makeViewModel(coordinator: coord)
        await vm.start()
        XCTAssertFalse(vm.nextReady)
        await coord.fireNextReady(true)
        // Yield until the subscription task pumps the value.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.nextReady)
        await coord.fireNextReady(false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(vm.nextReady)
    }
}
```

If `StubKeychainAuth`, `InMemoryConfigStore`, `StubPaletteExtractor`, `NoopUpdateChecker` don't exist verbatim, look in `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift` (around setup helpers) for the actual factory and copy that pattern.

- [ ] **Step 2: Run, expect FAIL**

Run: `swift test --filter MiniPlayerViewModelStopAndNextReadyTests/testNextReadyMirrorsCoordinatorStream`
Expected: compile error — `nextReady` does not exist on `MiniPlayerViewModel`.

- [ ] **Step 3: Add `nextReady` to view model**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`, add near the other `@Published` properties (after `isLoading` at line 10):

```swift
@Published private(set) var nextReady: Bool = false
```

Add a task field near the other subscription tasks (around line 38-44):

```swift
private var nextReadySubscriptionTask: Task<Void, Never>?
```

In `start()` (after line 91 and before line 220), cancel the new task at the top and subscribe to the stream. Place this with the other subscription setups, e.g. directly after the `stateSubscriptionTask` setup at line 192:

```swift
self.nextReady = await coordinator.nextReady
let nextReadyStream = await coordinator.nextReadyUpdates
nextReadySubscriptionTask = Task { [weak self] in
    for await value in nextReadyStream {
        guard let self else { return }
        await MainActor.run { self.nextReady = value }
    }
}
```

Add cancellation in `stop()` (line 229-238) alongside the other `?.cancel(); = nil` pairs:

```swift
nextReadySubscriptionTask?.cancel(); nextReadySubscriptionTask = nil
```

Also add an initial-cancel at the top of `start()` (matching the pattern at lines 92-101):

```swift
nextReadySubscriptionTask?.cancel()
nextReadySubscriptionTask = nil
```

- [ ] **Step 4: Run, expect PASS**

Run: `swift test --filter MiniPlayerViewModelStopAndNextReadyTests/testNextReadyMirrorsCoordinatorStream`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift
git commit -m "feat(shell): subscribe MiniPlayerViewModel to coordinator.nextReady"
```

---

## Task 5: View-model `stopPlayback()` + clear-on-stopped

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift`

- [ ] **Step 1: Write failing test**

Append to `MiniPlayerViewModelStopAndNextReadyTests.swift`:

```swift
    func testStopPlaybackCallsCoordinatorStopAndClearsArtAndNowPlaying() async throws {
        let coord = MockPlaybackCoordinator()
        let vm = makeViewModel(coordinator: coord)
        await vm.start()

        // Simulate active playback state.
        await coord.setNowPlaying(NowPlayingFixture.makeNowPlaying(songId: "s1"))
        await coord.fireState(.playing)
        // Pump the stream
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(vm.nowPlaying)

        // Channel selection before stop
        let channelBefore = vm.selectedChannelId

        await vm.stopPlayback()
        await coord.fireState(.stopped)
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(await coord.recordedCalls().contains(.stop),
                      "stopPlayback should invoke coordinator.stop()")
        XCTAssertNil(vm.nowPlaying)
        XCTAssertNil(vm.currentArt)
        XCTAssertNil(vm.ambientTopColor)
        XCTAssertNil(vm.currentRating)
        XCTAssertNil(vm.currentBitrateLabel)
        XCTAssertEqual(vm.songElapsedSeconds, 0)
        XCTAssertEqual(vm.songDurationSeconds, 0)
        XCTAssertEqual(vm.selectedChannelId, channelBefore,
                       "channel selection must persist across stop")
    }
```

Adapt `NowPlayingFixture.makeNowPlaying` to whatever signature the existing `NowPlayingFixture.swift` exposes (check `Tests/RPPlayerTests/Playback/NowPlayingFixture.swift` first).

- [ ] **Step 2: Run, expect FAIL**

Run: `swift test --filter MiniPlayerViewModelStopAndNextReadyTests/testStopPlaybackCallsCoordinatorStopAndClearsArtAndNowPlaying`
Expected: compile error — `stopPlayback` does not exist; or assertion failures on the cleared properties.

- [ ] **Step 3: Add `stopPlayback()` to view model**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`, add after `skipForward()` (around line 276):

```swift
func stopPlayback() async {
    errorMessage = nil
    do {
        try await coordinator.stop()
    } catch {
        errorMessage = "Stop failed: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 4: Extend `.stopped` handler to clear visual state**

Find the `.stopped` arm of the `stateUpdates` switch (currently in lines 180-190, inside the `stateSubscriptionTask` setup):

```swift
case .paused, .stopped:
    isLoading = false
    isPlaying = false
```

Split into two cases:

```swift
case .paused:
    isLoading = false
    isPlaying = false
case .stopped:
    isLoading = false
    isPlaying = false
    nowPlaying = nil
    currentArt = nil
    lastLoadedCoverPath = nil
    ambientTopColor = nil
    currentRating = nil
    currentBitrateLabel = nil
    songElapsedSeconds = 0
    songDurationSeconds = 0
    lastNotifiedSongId = ""
```

- [ ] **Step 5: Run, expect PASS**

Run: `swift test --filter MiniPlayerViewModelStopAndNextReadyTests/testStopPlaybackCallsCoordinatorStopAndClearsArtAndNowPlaying`
Expected: PASS.

- [ ] **Step 6: Run full suite**

Run: `swift test`
Expected: all green. Some existing tests may have implicitly relied on `nowPlaying` persisting after `.stopped`. Inspect failures and update assertions; the documented behavior change is now-playing/art clears on `.stopped`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelStopAndNextReadyTests.swift
git commit -m "feat(shell): add stopPlayback() and clear visuals on .stopped"
```

---

## Task 6: View slot-2 rendering

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift` (lines 150-184, the `transport` body)

- [ ] **Step 1: Replace slot-2 button construction**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`, replace the entire `transport` computed property (lines 150-184) with:

```swift
private var transport: some View {
    HStack(spacing: 18) {
        Button {
            Task { await viewModel.togglePlayPause() }
        } label: {
            ZStack {
                if viewModel.isLoading {
                    Image(systemName: "circle")
                        .font(.system(size: 44))
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: viewModel.isPlaying ? "pause.circle" : "play.circle")
                        .font(.system(size: 44))
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PressOpacityButtonStyle())
        .disabled(viewModel.isLoading)
        .accessibilityLabel(viewModel.isLoading ? "Loading" : (viewModel.isPlaying ? "Pause" : "Play"))

        secondarySlot
    }
}

@ViewBuilder
private var secondarySlot: some View {
    let isPaused = viewModel.nowPlaying != nil && !viewModel.isPlaying && !viewModel.isLoading
    let showLoadingInSkipSlot = viewModel.isPlaying && !viewModel.nextReady

    if isPaused {
        Button {
            Task { await viewModel.stopPlayback() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 22))
        }
        .buttonStyle(PressOpacityButtonStyle())
        .frame(width: 38, height: 38)
        .accessibilityLabel("Stop")
    } else if showLoadingInSkipSlot {
        ZStack {
            Image(systemName: "circle")
                .font(.system(size: 22))
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel("Loading next track")
    } else {
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
```

- [ ] **Step 2: Run build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Run full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 4: Manual verification (per repo convention, no SwiftUI snapshot harness)**

Build + launch the app (`run` skill, or `swift run` if app target supports it). Walk through each row of the state table from the spec:

| Scenario | Setup | Expected |
|---|---|---|
| fresh launch | open popover | play.circle + skip disabled |
| play with cached next | press play | pause.circle + skip enabled |
| play with uncached next | toggle a network throttle, press play | pause.circle + loading spinner in slot 2 |
| pause | press pause once playing | play.circle + stop.fill |
| stop from paused | press stop | back to fresh-launch view; channel persists |

Document any visual issues; fix inline before commit if trivial, otherwise file a deferred-item note.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat(shell): cache-aware secondary transport slot (loading/skip/stop)"
```

---

## Task 7: Final regression sweep + audit any remaining `.loading` emits

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (audit only)
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (regression test)

- [ ] **Step 1: Audit remaining `.loading` emit sites**

Run: `grep -n 'emitState(.loading)' Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

Expected remaining sites:
- `play()` initial path (around line 148) — KEEP. Session startup, mpv is idle.
- `skipForward()` shallow-refetch path (around line 391) — KEEP. Track ends, fresh `engine.play(...)` follows. There IS a known minor flicker because the refetch await runs while mpv still plays the old head, and we emit `.loading` before the actual interruption. Document as known issue in CHANGELOG (not blocking).
- `handleSongPlaybackError(...)` recovery (search for it) — audit. If the engine has actually stopped (line `try? await engine.stop()` precedes the emit), KEEP. Otherwise drop.

Any other `.loading` site should either fall into the above three or be removed.

- [ ] **Step 2: Add regression test for "loading lifts properly after stop+play cycle"**

Append to `LivePlaybackCoordinatorTests.swift`:

```swift
    func testPlayAfterStopReturnsLoadingThenPlaying() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let head = makeGaplessSong(songId: "s0", eventId: 100, gaplessUrl: "https://s.example.com/100.flac")
        let next = makeGaplessSong(songId: "s1", eventId: 101, gaplessUrl: "https://s.example.com/101.flac")
        await cache.markDownloaded([head, next])
        await api.setGaplessResponse(makeGaplessResponse(songs: [head, next]))
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 80_000_000)
        try await coordinator.stop()
        let stoppedState = await coordinator.currentPlaybackState
        XCTAssertEqual(stoppedState, .stopped)
        let nextReadyAfterStop = await coordinator.nextReady
        XCTAssertFalse(nextReadyAfterStop)

        try await coordinator.play(channelId: 0)
        try await Task.sleep(nanoseconds: 80_000_000)
        let playingState = await coordinator.currentPlaybackState
        XCTAssertEqual(playingState, .playing)
    }
```

- [ ] **Step 3: Run, expect PASS**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPlayAfterStopReturnsLoadingThenPlaying`
Expected: PASS.

- [ ] **Step 4: Run full suite + count tests**

Run: `swift test 2>&1 | tail -20`
Expected: all green. Record actual count.

- [ ] **Step 5: Commit**

```bash
git add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "test(playback): regression for stop→play state machine"
```

---

## Task 8: Documentation updates

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md`
- Modify: `README.md` (only if user-facing description changes; verify first)

- [ ] **Step 1: Update `CHANGELOG.md`**

Add entries under `## [Unreleased]`:

```markdown
### Added
- Popover transport now shows a Stop button (filled square) in the second slot when playback is paused. Pressing Stop clears the play queue and the displayed track info / album art, returning the popover to the fresh-launch state. Channel selection is preserved.

### Changed
- The loading indicator now appears in the **skip** slot whenever the next track has not yet been preloaded into mpv, rather than replacing the play/pause icon. The play/pause button stays available throughout active playback. Skip is disabled while loading.

### Fixed
- Fixed an inconsistency where the play/pause button could flip to the loading spinner during normal playback (notably mid-track skips and end-of-block transitions), leaving the user unable to pause an actively-playing song. Loading is now reserved for session start.
```

- [ ] **Step 2: Update `docs/pr-history.md`**

Append a row to the status table (match existing column order). Add deferred item if Task 7 surfaced one (e.g. "skipForward shallow-refetch shows pre-emptive .loading flicker").

- [ ] **Step 3: Update `docs/test-counts.md`**

Append the new total from Task 7 Step 4.

- [ ] **Step 4: Update `CLAUDE.md` *Current state* block**

Replace the *Last merged* + *Next up* lines with the new PR summary (cache-aware transport buttons + stop action). Include test count delta.

- [ ] **Step 5: Verify `README.md`**

Run: `grep -n -i 'skip\|button\|stop' README.md | head`
If README documents the transport buttons, update those sections to reflect the new state table; otherwise skip.

- [ ] **Step 6: Run full suite one more time**

Run: `swift test`
Expected: all green, count matches `docs/test-counts.md` entry.

- [ ] **Step 7: Commit docs**

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md CLAUDE.md README.md
git commit -m "docs: cache-aware transport buttons + stop action"
```

---

## Self-review notes

Coverage check against spec:
- ✅ Spec § State table → Task 6 (view) + Task 4/5 (view model)
- ✅ Spec § `nextReady` signal → Task 1/2
- ✅ Spec § Stop action wiring → Task 5
- ✅ Spec § Test mocks → Task 1 step 5
- ✅ Spec § Open issue (`.loading` mid-playback) → Task 3 + Task 7
- ✅ Spec § Docs → Task 8

No placeholders detected. Type/method names consistent (`nextReady`, `nextReadyUpdates`, `fireNextReady`, `stopPlayback`, `updateNextReady`) across tasks.
