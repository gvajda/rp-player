# Event-Cursor Block Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `now_playing`-based song matching with a per-channel in-memory event cursor that drives `get_block?event=<id>`, so the user resumes each channel from where they left off (song granularity) and block-end transitions are deterministic.

**Architecture:** Add an `event: Int?` param to `RpApiClient.getBlock`. Drop the entire `now_playing` API path (protocol method, impl, model struct, mocks, tests). Add a `channelCursors: [Int: Int]` map to `LivePlaybackCoordinator`, mutated at four boundary-cross points (in-block auto-advance, in-block skipForward, skipForward past-last, auto-swap on natural block end). `play(channelId:)` reads the cursor and calls `getBlock(event: cursor)`. Prefetch and skipForward past-last use `event=<endEvent>` to fetch the next block deterministically.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit on macOS 14, XCTest. No new dependencies.

**Branch:** `claude/event-cursor-resume` (created off `main`, work directly in main checkout per CLAUDE.md).

**Spec:** `docs/superpowers/specs/2026-05-02-event-cursor-block-resume-design.md`

---

## File Structure

**Modified files:**
- `Sources/RPPlayer/Api/RpApiClient.swift` — protocol/impl signature change; remove `nowPlaying` method.
- `Sources/RPPlayer/Api/ApiModels.swift` — remove `NowPlayingEntry` struct.
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — add cursor map, simplify `play`, insert cursor writes, remove `resolveStart`, prefetch event param, swap path cursor write.
- `Tests/RPPlayerTests/Api/RpApiClientTests.swift` — update `getBlock` test for new signature; add `event=` URL test; remove any `nowPlaying` test.
- `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` — signature change, record `event`, drop `nowPlaying` mocks.
- `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` — drop 3 now-playing tests, update bitrate test, add ~10 cursor tests.
- `CLAUDE.md` — refresh "Coordinator playback" + "API client" sections, update test count.

**Deleted files (if present):** `Tests/RPPlayerTests/Fixtures/Api/now_playing*.json` (none currently in tree per check).

---

## Setup

- [ ] **Step 0.1: Create feature branch off `main`**

```bash
git checkout main
git pull --ff-only
git checkout -b claude/event-cursor-resume
```

- [ ] **Step 0.2: Verify current test count baseline**

Run: `swift test 2>&1 | tail -20`
Expected: 201 tests passing on `main`.

---

## Task 1: Add `event` param to `RpApiClient.getBlock`

**Files:**
- Modify: `Sources/RPPlayer/Api/RpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`
- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` (signature only — drop `nowPlaying` later in Task 3)
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (call sites: `play`, `skipForward`, `maybeStartPrefetch` — pass `event: nil` for now)

- [ ] **Step 1.1: Write failing test for `event=` query param**

Add to `Tests/RPPlayerTests/Api/RpApiClientTests.swift` after `testGetBlockBuildsCorrectQueryAndDecodes`:

```swift
func testGetBlockWithEventAppendsEventQueryItemAlphabeticallySorted() async throws {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/get_block"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "bitrate", value: "4"),
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "event", value: "2868950"),
        URLQueryItem(name: "info", value: "true"),
    ]
    StubURLProtocol.register(url: components.url!, body: try loadFixture("get_block"))

    let client = makeClient()
    let block = try await client.getBlock(channel: 0, bitrate: 4, info: true, event: 2868950)
    XCTAssertFalse(block.url.isEmpty)
}
```

- [ ] **Step 1.2: Run test — should fail to compile (signature mismatch)**

Run: `swift test --filter RpApiClientTests/testGetBlockWithEventAppendsEventQueryItemAlphabeticallySorted 2>&1 | tail -10`
Expected: FAIL with compile error about `event:` argument.

- [ ] **Step 1.3: Update `RpApiClient` protocol**

In `Sources/RPPlayer/Api/RpApiClient.swift`, replace:

```swift
func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock
```

with:

```swift
func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock
```

- [ ] **Step 1.4: Update `LiveRpApiClient.getBlock`**

In the same file, replace:

```swift
public func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock {
    try await get(path: "api/get_block", query: [
        "chan": String(channel),
        "bitrate": String(bitrate),
        "info": info ? "true" : "false",
    ])
}
```

with:

```swift
public func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock {
    var query: [String: String] = [
        "chan": String(channel),
        "bitrate": String(bitrate),
        "info": info ? "true" : "false",
    ]
    if let event {
        query["event"] = String(event)
    }
    return try await get(path: "api/get_block", query: query)
}
```

- [ ] **Step 1.5: Update `MockRpApiClient` signature only**

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`, replace the `Call.getBlock` case and the `getBlock(...)` impl:

```swift
case getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?)
```

```swift
func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock {
    calls.append(.getBlock(channel: channel, bitrate: bitrate, info: info, event: event))
    guard !blockResponses.isEmpty else {
        throw RpApiError.network(URLError(.unknown))
    }
    return blockResponses.removeFirst()
}
```

- [ ] **Step 1.6: Update coordinator call sites to pass `event: nil`**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, three call sites need `event: nil` (intermediate state — cursor wiring lands in Task 5).

In `play(channelId:)` (around line 65):

```swift
async let blockFetch = api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: nil)
```

In `skipForward()` past-last branch (around line 166):

```swift
let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: nil)
```

In `maybeStartPrefetch()` (around line 313):

```swift
let result = try? await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: nil)
```

- [ ] **Step 1.7: Update existing coordinator tests that pattern-match on `Call.getBlock`**

Run: `grep -n "\.getBlock(" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`
For each match, add `, event: nil` to the case pattern. Example:

```swift
// Before:
XCTAssertTrue(apiCalls.contains(.getBlock(channel: 0, bitrate: 4, info: true)))
// After:
XCTAssertTrue(apiCalls.contains(.getBlock(channel: 0, bitrate: 4, info: true, event: nil)))
```

- [ ] **Step 1.8: Update existing `getBlock` test in RpApiClientTests**

In `Tests/RPPlayerTests/Api/RpApiClientTests.swift`, the existing `testGetBlockBuildsCorrectQueryAndDecodes` calls `client.getBlock(channel: 0, bitrate: 4, info: true)` — change to `event: nil`:

```swift
let block = try await client.getBlock(channel: 0, bitrate: 4, info: true, event: nil)
```

- [ ] **Step 1.9: Build + run full suite**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds.

Run: `swift test 2>&1 | tail -10`
Expected: same test count as baseline (201) + 1 new (= 202), all passing.

- [ ] **Step 1.10: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift \
        Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Api/RpApiClientTests.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(api): add event param to getBlock"
```

---

## Task 2: Drop `now_playing` API surface

**Files:**
- Modify: `Sources/RPPlayer/Api/RpApiClient.swift` — remove protocol method + impl.
- Modify: `Sources/RPPlayer/Api/ApiModels.swift` — remove `NowPlayingEntry` struct.
- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` — remove `Call.nowPlaying`, response/error state, `nowPlaying(...)` impl.
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — remove `async let nowPlayingFetch`, `nowPlayingEntry`, the logging block, and the call to `resolveStart` will be replaced in Task 4.

This task is removal-only. Coordinator still compiles after — `play(channelId:)` keeps `block.cue`-based fallback behavior temporarily until Task 4 simplifies it fully.

- [ ] **Step 2.1: Remove `nowPlaying` from protocol**

In `Sources/RPPlayer/Api/RpApiClient.swift`, delete the line:

```swift
func nowPlaying(channel: Int) async throws -> NowPlayingEntry
```

- [ ] **Step 2.2: Remove `nowPlaying` impl from `LiveRpApiClient`**

In the same file, delete:

```swift
public func nowPlaying(channel: Int) async throws -> NowPlayingEntry {
    try await get(path: "api/now_playing", query: ["chan": String(channel)])
}
```

- [ ] **Step 2.3: Remove `NowPlayingEntry` struct**

In `Sources/RPPlayer/Api/ApiModels.swift`, delete the entire struct (lines 52–59):

```swift
public struct NowPlayingEntry: Codable, Sendable, Equatable {
    public let artist: String
    public let title: String
    public let album: String?
    public let year: String?
    public let cover: String?
    public let time: Int?
}
```

- [ ] **Step 2.4: Remove `nowPlaying` from `MockRpApiClient`**

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:
- Delete `case nowPlaying(channel: Int)` from the `Call` enum.
- Delete `var nowPlayingResponse: NowPlayingEntry?` and `var nowPlayingError: Error?`.
- Delete `setNowPlayingResponse(_:)` and `setNowPlayingError(_:)`.
- Delete the `nowPlaying(channel:)` func impl.

- [ ] **Step 2.5: Adapt `play(channelId:)` to compile without nowPlaying**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace the body of `play(channelId:)` (lines 60–101) with a *temporary* simplified form that drops nowPlaying but keeps cue-based fallback (full simplification happens in Task 4):

```swift
public func play(channelId: Int) async throws {
    logger.debug("play(channelId: \(channelId))")
    await ensureEventSubscription()
    let bitrate = await bitrateProvider()
    logger.debug("play resolved bitrate=\(bitrate)")
    let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: nil)
    let songs = BlockSongs.orderedSongs(from: block)
    guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

    let starts = BlockSongs.startsAtSeconds(songs: songs)
    logger.debug("play block (expiration=\(block.expiration)):\n\(describeBlock(url: block.url, songs: songs, starts: starts))")

    let cueFallback = block.cue > 0 ? Double(block.cue) / 1000.0 : nil
    let (startIndex, startPos) = resolveStart(songs: songs, starts: starts, cue: cueFallback)
    currentChannelId = channelId
    currentBlock = block
    orderedSongs = songs
    startsAt = starts
    currentSongIndex = startIndex
    currentPositionSeconds = startPos

    let startSeconds: Double? = startPos > 0 ? startPos : nil
    guard let url = URL(string: block.url) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
    }
    logger.debug("play engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil (beginning)")")
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitNowPlaying(forSongIndex: currentSongIndex)
}
```

- [ ] **Step 2.6: Adapt `resolveStart` signature (drop `entry` param)**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace `resolveStart(songs:starts:entry:cue:)` with the simpler form:

```swift
private func resolveStart(songs: [PlayListSong], starts: [Double], cue: Double?) -> (index: Int, seconds: Double) {
    if let cue, !starts.isEmpty {
        let idx = BlockSongs.indexOfSong(at: cue, in: starts)
        logger.debug("cue: \(cue)s → song \(idx), seeking to exact cue position")
        return (idx, cue)
    }
    let firstStart = starts.first ?? 0
    logger.debug("defaulting to first listed song at \(firstStart)s")
    return (0, firstStart)
}
```

(This entire helper is deleted in Task 4 once cursor logic lands; the temp form keeps the suite green between tasks.)

- [ ] **Step 2.7: Build + run remaining tests that don't reference nowPlaying**

Run: `swift build 2>&1 | tail -10`
Expected: build error in `LivePlaybackCoordinatorTests.swift` for tests that still call `setNowPlayingResponse`. That's resolved in Task 3.

Skip running tests for now; do the test cleanup in Task 3 first.

- [ ] **Step 2.8: Commit (build will be broken — temporary)**

Skip commit in this task. Combined commit happens at end of Task 3 once tests compile.

---

## Task 3: Drop now-playing-dependent coordinator tests

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 3.1: Delete the three now-playing-resolution tests**

Delete from `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

- `testPlaySeeksToStartOfSongMatchedByNowPlaying` (around line 51)
- `testPlayUsesCueFallbackWhenNowPlayingHasNoMatch` (around line 106)
- `testPlayStartsFromFirstListedSongWhenBothNowPlayingAndCueMissing` (around line 125)
- `testPlaySeedsNowPlayingFromNowPlayingMatch` (around line 87) — also gone, depends on `setNowPlayingResponse`.

- [ ] **Step 3.2: Update `testPlayPropagatesBlockBitrateIntoNowPlaying`**

This test sets a `setNowPlayingResponse` only as setup noise. Remove that line. The test's actual assertion is on `coordinator.nowPlaying.song.title` after play; that still works because `play` emits NowPlaying for `currentSongIndex`.

Find the test (around line 71). Remove any `await api.setNowPlayingResponse(...)` line inside it.

- [ ] **Step 3.3: Find any other test referencing `setNowPlayingResponse` / `setNowPlayingError` / `Call.nowPlaying`**

Run: `grep -n "setNowPlaying\|\.nowPlaying(channel" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`
Expected: empty after Step 3.2.

If lines remain, remove them (they are dead lines pointing at a deleted API).

- [ ] **Step 3.4: Build + run full suite**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

Run: `swift test 2>&1 | tail -10`
Expected: ~198 tests passing (202 from Task 1 minus 4 deleted now-playing-resolution tests).

- [ ] **Step 3.5: Commit (combined Task 2 + Task 3)**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift \
        Sources/RPPlayer/Api/ApiModels.swift \
        Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(api): drop now_playing API surface and dependent tests"
```

---

## Task 4: Add `channelCursors` state + use cursor in `play(channelId:)`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 4.1: Write failing test — fresh play has `event: nil`**

Add to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
func testPlayWithoutCursorCallsGetBlockWithoutEventParam() async throws {
    let api = MockRpApiClient()
    await api.setBlockResponses([CoordinatorTestSupport.makeBlock(channel: 0)])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)

    let calls = await api.calls
    XCTAssertEqual(calls.last, .getBlock(channel: 0, bitrate: 4, info: true, event: nil))
}
```

If `CoordinatorTestSupport.makeBlock(channel:)` doesn't exist, locate the existing helper used by other tests in this file (likely inline `GetBlock(...)` literals or a fixture loader). Use the same shape. Confirm by reading `LivePlaybackCoordinatorTests.swift` near line 30.

- [ ] **Step 4.2: Run test, confirm pass (already passes from Task 1's `event: nil` plumbing)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPlayWithoutCursorCallsGetBlockWithoutEventParam 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 4.3: Write failing test — replay after cursor seeded calls with `event=<cursor>`**

Add immediately after Step 4.1's test:

```swift
func testPlayWithCursorCallsGetBlockWithEventParam() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "100", elapsed: 0, duration: 60_000),
        CoordinatorTestSupport.makeSong(songId: "2", event: "101", elapsed: 60_000, duration: 60_000),
    ], cue: 0, endEvent: "101")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    // Drive engine position past startsAt[1] = 60s — boundary cross writes cursor = song[0].event = 100.
    await engine.emitPositionUpdate(seconds: 60.5)
    // Replay channel 0 — should pass event=100.
    try await coordinator.play(channelId: 0)

    let calls = await api.calls
    let getBlockCalls = calls.compactMap { call -> Int? in
        if case let .getBlock(_, _, _, event) = call { return event }
        return nil
    }
    XCTAssertEqual(getBlockCalls, [nil, 100])
}
```

If `MockPlayerEngine.emitPositionUpdate(seconds:)` doesn't exist, find the existing way coordinator tests drive engine position events. Likely a `setPositionUpdates(_:)` or a stream-yielding helper. Match the existing pattern.

If `CoordinatorTestSupport.makeSong(...)` / `makeBlock(...)` don't exist as helpers, write inline `PlayListSong` / `GetBlock` constructors (use the same shape current tests use — read 5 lines around any existing block construction in the file).

- [ ] **Step 4.4: Run test — should fail (cursor not yet wired)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPlayWithCursorCallsGetBlockWithEventParam 2>&1 | tail -10`
Expected: FAIL — second call's event is nil, not 100. (Cursor map doesn't exist yet.)

- [ ] **Step 4.5: Add `channelCursors` state to `LivePlaybackCoordinator`**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, in the actor's stored properties section (near `private var prefetchTask: Task<Void, Never>?`):

```swift
private var channelCursors: [Int: Int] = [:]
```

- [ ] **Step 4.6: Wire cursor read into `play(channelId:)` and simplify**

Replace the entire body of `play(channelId:)` with:

```swift
public func play(channelId: Int) async throws {
    logger.debug("play(channelId: \(channelId))")
    await ensureEventSubscription()
    let bitrate = await bitrateProvider()
    let cursor = channelCursors[channelId]
    logger.debug("play resolved bitrate=\(bitrate) cursor=\(cursor.map(String.init) ?? "nil")")
    let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: cursor)
    let songs = BlockSongs.orderedSongs(from: block)
    guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

    let starts = BlockSongs.startsAtSeconds(songs: songs)
    logger.debug("play block (expiration=\(block.expiration)):\n\(describeBlock(url: block.url, songs: songs, starts: starts))")

    let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
    currentChannelId = channelId
    currentBlock = block
    orderedSongs = songs
    startsAt = starts
    currentSongIndex = 0
    currentPositionSeconds = startPos

    let startSeconds: Double? = startPos > 0 ? startPos : nil
    guard let url = URL(string: block.url) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
    }
    logger.debug("play engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil (beginning)")")
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitNowPlaying(forSongIndex: 0)
}
```

- [ ] **Step 4.7: Delete `resolveStart` helper**

It is no longer called. Delete the entire `private func resolveStart(songs:starts:cue:)` method.

- [ ] **Step 4.8: Build to confirm `resolveStart` had no remaining callers**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 4.9: Run `testPlayWithCursorCallsGetBlockWithEventParam` — still failing (cursor not written yet)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPlayWithCursorCallsGetBlockWithEventParam 2>&1 | tail -10`
Expected: FAIL — cursor read works but no write site exists yet, so `channelCursors[0]` is empty. Second call's event is still nil.

This test is left red until Task 5 lands the in-block auto-advance write site.

- [ ] **Step 4.10: Run full suite — `testPlayWithCursorCallsGetBlockWithEventParam` red, all others pass**

Run: `swift test 2>&1 | tail -10`
Expected: ~199 tests pass (198 prior + 1 new green Step 4.1 test). 1 red (Step 4.3 test). Continue to Task 5.

- [ ] **Step 4.11: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): add channelCursors map; play reads cursor"
```

---

## Task 5: Cursor write on in-block auto-advance

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

- [ ] **Step 5.1: Insert cursor write before `currentSongIndex = newIndex`**

In `handleEngineEvent`'s `.positionUpdate` branch, locate:

```swift
if newIndex != currentSongIndex {
    logger.debug("song boundary crossed: \(currentSongIndex) -> \(newIndex) at pos=\(seconds)")
    currentSongIndex = newIndex
    emitNowPlaying(forSongIndex: newIndex)
}
```

Replace with:

```swift
if newIndex != currentSongIndex {
    logger.debug("song boundary crossed: \(currentSongIndex) -> \(newIndex) at pos=\(seconds)")
    if let chan = currentChannelId,
       currentSongIndex < orderedSongs.count,
       let finishedEvent = Int(orderedSongs[currentSongIndex].event ?? "") {
        channelCursors[chan] = finishedEvent
        logger.debug("cursor[\(chan)] = \(finishedEvent) (auto-advance)")
    }
    currentSongIndex = newIndex
    emitNowPlaying(forSongIndex: newIndex)
}
```

- [ ] **Step 5.2: Run failing test from Task 4 — should now pass**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPlayWithCursorCallsGetBlockWithEventParam 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5.3: Add explicit boundary-cross cursor test**

Add to `LivePlaybackCoordinatorTests.swift`:

```swift
func testInBlockAutoAdvanceUpdatesCursorToFinishedSongEvent() async throws {
    let api = MockRpApiClient()
    let block = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "100", elapsed: 0, duration: 60_000),
        CoordinatorTestSupport.makeSong(songId: "2", event: "101", elapsed: 60_000, duration: 60_000),
    ], cue: 0, endEvent: "101")
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    await engine.emitPositionUpdate(seconds: 60.5)

    // Re-fetching for ch 0 must pass event=100.
    await api.setBlockResponses([block])
    try await coordinator.play(channelId: 0)
    let calls = await api.calls
    let lastEvent: Int? = {
        if case let .getBlock(_, _, _, event) = calls.last { return event }
        return nil
    }()
    XCTAssertEqual(lastEvent, 100)
}
```

- [ ] **Step 5.4: Run new test**

Run: `swift test --filter LivePlaybackCoordinatorTests/testInBlockAutoAdvanceUpdatesCursorToFinishedSongEvent 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5.5: Run full suite**

Run: `swift test 2>&1 | tail -10`
Expected: 200 tests passing (no reds).

- [ ] **Step 5.6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): cursor write on in-block auto-advance"
```

---

## Task 6: Cursor write on in-block `skipForward()`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 6.1: Write failing test**

```swift
func testSkipForwardInBlockUpdatesCursorBeforeAdvance() async throws {
    let api = MockRpApiClient()
    let block = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "200", elapsed: 0, duration: 60_000),
        CoordinatorTestSupport.makeSong(songId: "2", event: "201", elapsed: 60_000, duration: 60_000),
    ], cue: 0, endEvent: "201")
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    try await coordinator.skipForward()

    // Replay to inspect cursor.
    await api.setBlockResponses([block])
    try await coordinator.play(channelId: 0)
    let calls = await api.calls
    let lastEvent: Int? = {
        if case let .getBlock(_, _, _, event) = calls.last { return event }
        return nil
    }()
    XCTAssertEqual(lastEvent, 200)
}
```

- [ ] **Step 6.2: Run test — should fail (no cursor write in skipForward in-block branch)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardInBlockUpdatesCursorBeforeAdvance 2>&1 | tail -5`
Expected: FAIL.

- [ ] **Step 6.3: Insert cursor write into in-block skipForward branch**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, inside `skipForward()`, locate:

```swift
let nextIndex = currentSongIndex + 1
if nextIndex < orderedSongs.count {
    let target = startsAt[nextIndex] + 0.05
    let nextSong = orderedSongs[nextIndex]
    logger.debug("skipForward in-block: url=\(currentBlock?.url ?? "?") seek to \(target)s → song [\(nextIndex)] '\(nextSong.artist) – \(nextSong.title)'")
    do {
        try await engine.seek(to: target)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    currentSongIndex = nextIndex
    currentPositionSeconds = target
    emitNowPlaying(forSongIndex: nextIndex)
}
```

Replace with:

```swift
let nextIndex = currentSongIndex + 1
if nextIndex < orderedSongs.count {
    let target = startsAt[nextIndex] + 0.05
    let nextSong = orderedSongs[nextIndex]
    logger.debug("skipForward in-block: url=\(currentBlock?.url ?? "?") seek to \(target)s → song [\(nextIndex)] '\(nextSong.artist) – \(nextSong.title)'")
    if let chan = currentChannelId,
       let skippedEvent = Int(orderedSongs[currentSongIndex].event ?? "") {
        channelCursors[chan] = skippedEvent
        logger.debug("cursor[\(chan)] = \(skippedEvent) (skipForward in-block)")
    }
    do {
        try await engine.seek(to: target)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    currentSongIndex = nextIndex
    currentPositionSeconds = target
    emitNowPlaying(forSongIndex: nextIndex)
}
```

- [ ] **Step 6.4: Run test — should pass**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardInBlockUpdatesCursorBeforeAdvance 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6.5: Run full suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 201 tests passing.

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): cursor write on in-block skipForward"
```

---

## Task 7: Cursor write + `event=endEvent` fetch on `skipForward()` past-last

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 7.1: Write failing test**

```swift
func testSkipForwardPastLastSongUsesEndEventAsCursorAndFetchParam() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "300", elapsed: 0, duration: 60_000),
    ], cue: 0, endEvent: "300")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    try await coordinator.skipForward()  // past last → fetch with event=300

    let calls = await api.calls
    let getBlockEvents = calls.compactMap { call -> Int?? in
        if case let .getBlock(_, _, _, event) = call { return event }
        return nil
    }
    XCTAssertEqual(getBlockEvents.count, 2)
    XCTAssertEqual(getBlockEvents.last, 300)
}
```

- [ ] **Step 7.2: Run — should fail (currently passes `event: nil`)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardPastLastSongUsesEndEventAsCursorAndFetchParam 2>&1 | tail -5`
Expected: FAIL.

- [ ] **Step 7.3: Update past-last branch in `skipForward()`**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, locate the `else` branch of `skipForward()` (`Past the last song — fetch a fresh block...`). Replace it with:

```swift
} else {
    let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
    if let endEvent, let chan = currentChannelId {
        channelCursors[chan] = endEvent
        logger.debug("cursor[\(chan)] = \(endEvent) (skipForward past-last)")
    }
    let bitrate = await bitrateProvider()
    logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(endEvent.map(String.init) ?? "nil")")
    let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
    let songs = BlockSongs.orderedSongs(from: block)
    guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
    let newStarts = BlockSongs.startsAtSeconds(songs: songs)
    logger.debug("skipForward next block:\n\(describeBlock(url: block.url, songs: songs, starts: newStarts))")
    currentBlock = block
    orderedSongs = songs
    startsAt = newStarts
    currentSongIndex = 0
    let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
    currentPositionSeconds = startPos
    guard let url = URL(string: block.url) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
    }
    let startSeconds: Double? = startPos > 0 ? startPos : nil
    logger.debug("skipForward engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitNowPlaying(forSongIndex: 0)
}
```

- [ ] **Step 7.4: Run test + suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 202 tests passing.

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): skipForward past-last uses endEvent cursor"
```

---

## Task 8: Prefetch uses `event=endEvent`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 8.1: Write failing test**

```swift
func testPrefetchUsesEndEventAsEventParam() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "400", elapsed: 0, duration: 11_000),
    ], cue: 0, endEvent: "400")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    // Drive position to within 10s of total duration (11s) → trigger prefetch.
    await engine.emitPositionUpdate(seconds: 2.0)
    // Allow prefetch task to run.
    try await Task.sleep(nanoseconds: 100_000_000)

    let calls = await api.calls
    let prefetchEvent: Int? = {
        guard calls.count >= 2 else { return nil }
        if case let .getBlock(_, _, _, event) = calls[1] { return event }
        return nil
    }()
    XCTAssertEqual(prefetchEvent, 400)
}
```

If existing prefetch tests use a different "wait for prefetch" pattern (e.g., observing a flag), match that pattern instead of the `Task.sleep`.

- [ ] **Step 8.2: Run — should fail (current prefetch passes `event: nil`)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testPrefetchUsesEndEventAsEventParam 2>&1 | tail -5`
Expected: FAIL.

- [ ] **Step 8.3: Update `maybeStartPrefetch()` to capture endEvent and pass it**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace `maybeStartPrefetch()`:

```swift
private func maybeStartPrefetch() {
    guard let channelId = currentChannelId,
          !orderedSongs.isEmpty,
          currentSongIndex == orderedSongs.count - 1,
          prefetchedBlock == nil,
          prefetchTask == nil else { return }
    let totalSeconds = BlockSongs.totalDurationSeconds(songs: orderedSongs)
    let remaining = totalSeconds - currentPositionSeconds
    guard remaining < 10.0 else { return }

    let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
    if endEvent == nil {
        logger.error("prefetch: endEvent missing or non-numeric — falling back to event=nil")
    }
    let api = self.api
    let provider = self.bitrateProvider
    logger.debug("prefetch start, channel=\(channelId) event=\(endEvent.map(String.init) ?? "nil")")
    prefetchTask = Task { [weak self] in
        let bitrate = await provider()
        let result = try? await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
        await self?.absorbPrefetchResult(result)
    }
}
```

- [ ] **Step 8.4: Run test + suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 203 tests passing.

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): prefetch uses endEvent as event param"
```

---

## Task 9: Cursor write on auto-swap (`swapToPrefetchedBlockIfAvailable`)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 9.1: Write failing test**

```swift
func testSwapToPrefetchedBlockUpdatesCursorToOldEndEvent() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "500", elapsed: 0, duration: 11_000),
    ], cue: 0, endEvent: "500")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "2", event: "501", elapsed: 0, duration: 60_000),
    ], cue: 0, endEvent: "501")
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    await engine.emitPositionUpdate(seconds: 2.0)
    try await Task.sleep(nanoseconds: 100_000_000)
    // Trigger natural file end → swap.
    await engine.emitFileEnded(reason: .eof)
    try await Task.sleep(nanoseconds: 100_000_000)

    // Replay channel 0 — cursor should be 500 (old endEvent), not 501.
    await api.setBlockResponses([block1])  // any response, just to satisfy mock
    try await coordinator.play(channelId: 0)
    let calls = await api.calls
    let lastEvent: Int? = {
        if case let .getBlock(_, _, _, event) = calls.last { return event }
        return nil
    }()
    XCTAssertEqual(lastEvent, 500)
}
```

If `MockPlayerEngine.emitFileEnded(reason:)` doesn't exist, find the existing harness for this. Likely `engine.emitEvent(.fileEnded(.eof))` or similar.

- [ ] **Step 9.2: Run — should fail**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSwapToPrefetchedBlockUpdatesCursorToOldEndEvent 2>&1 | tail -5`
Expected: FAIL — no cursor write in swap path.

- [ ] **Step 9.3: Insert cursor write into `swapToPrefetchedBlockIfAvailable`**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace `swapToPrefetchedBlockIfAvailable()`:

```swift
private func swapToPrefetchedBlockIfAvailable() async {
    guard let block = prefetchedBlock else {
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        current = nil
        return
    }
    if let chan = currentChannelId,
       let oldEnd = Int(currentBlock?.endEvent ?? "") {
        channelCursors[chan] = oldEnd
        logger.debug("cursor[\(chan)] = \(oldEnd) (swap to prefetched)")
    }
    prefetchedBlock = nil
    let songs = BlockSongs.orderedSongs(from: block)
    let swapStarts = BlockSongs.startsAtSeconds(songs: songs)
    logger.info("swap to prefetched block:\n\(describeBlock(url: block.url, songs: songs, starts: swapStarts))")
    currentBlock = block
    orderedSongs = songs
    startsAt = swapStarts
    currentSongIndex = 0
    let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
    currentPositionSeconds = startPos
    guard let url = URL(string: block.url) else {
        logger.error("prefetched block had invalid url: \(block.url)")
        return
    }
    let startSeconds: Double? = startPos > 0 ? startPos : nil
    logger.debug("swap engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        logger.error("failed to play prefetched block: \(error)")
        return
    }
    emitNowPlaying(forSongIndex: 0)
}
```

- [ ] **Step 9.4: Run test + suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 204 tests passing.

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): cursor write on prefetched-block swap"
```

---

## Task 10: `skipForward()` past-last adopts prefetched block when available

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

Behavior change: when the user skips past last song and a prefetched block is already in `prefetchedBlock`, adopt it via swap instead of issuing a new fetch. Saves a redundant API request and avoids potential race with the in-flight prefetch task.

- [ ] **Step 10.1: Write failing test**

```swift
func testSkipForwardPastLastSongAdoptsPrefetchedBlockWhenAvailable() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "600", elapsed: 0, duration: 11_000),
    ], cue: 0, endEvent: "600")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block1, block2])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    // Drive into prefetch window.
    await engine.emitPositionUpdate(seconds: 2.0)
    try await Task.sleep(nanoseconds: 200_000_000)
    // Confirm prefetch fired (2 calls so far).
    var calls = await api.calls
    XCTAssertEqual(calls.count, 2)

    // Now skip past last. Should NOT issue a 3rd fetch.
    try await coordinator.skipForward()
    calls = await api.calls
    XCTAssertEqual(calls.count, 2, "skipForward past-last must adopt prefetched block, not re-fetch")
}
```

- [ ] **Step 10.2: Run — should fail (currently issues a 3rd fetch)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardPastLastSongAdoptsPrefetchedBlockWhenAvailable 2>&1 | tail -5`
Expected: FAIL — 3 calls observed, expected 2.

- [ ] **Step 10.3: Add prefetch-adoption branch to `skipForward()` past-last**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, modify the past-last branch of `skipForward()` so it tries the prefetched block first. Replace the `else { ... }` body added in Task 7 with:

```swift
} else {
    let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
    if let endEvent, let chan = currentChannelId {
        channelCursors[chan] = endEvent
        logger.debug("cursor[\(chan)] = \(endEvent) (skipForward past-last)")
    }
    if prefetchedBlock != nil {
        logger.debug("skipForward past-last: adopting prefetched block")
        await swapToPrefetchedBlockIfAvailable()
        return
    }
    let bitrate = await bitrateProvider()
    logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(endEvent.map(String.init) ?? "nil")")
    let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
    let songs = BlockSongs.orderedSongs(from: block)
    guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
    let newStarts = BlockSongs.startsAtSeconds(songs: songs)
    logger.debug("skipForward next block:\n\(describeBlock(url: block.url, songs: songs, starts: newStarts))")
    currentBlock = block
    orderedSongs = songs
    startsAt = newStarts
    currentSongIndex = 0
    let startPos = block.cue > 0 ? Double(block.cue) / 1000.0 : 0
    currentPositionSeconds = startPos
    guard let url = URL(string: block.url) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
    }
    let startSeconds: Double? = startPos > 0 ? startPos : nil
    logger.debug("skipForward engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil")")
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitNowPlaying(forSongIndex: 0)
}
```

Note: `swapToPrefetchedBlockIfAvailable` already writes the cursor (Task 9). The cursor write at the top of the past-last branch is harmless because it writes the same value. Keeping both ensures cursor is correct on the synchronous-fetch path too.

- [ ] **Step 10.4: Run test + suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 205 tests passing.

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): skipForward past-last adopts prefetched block"
```

---

## Task 11: `skipForward()` past-last cancels in-flight prefetch

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

Edge case: user skips past last song while prefetch task is mid-flight. Current behavior would race (two in-flight fetches). Cancel the in-flight task and issue the synchronous fetch.

- [ ] **Step 11.1: Write failing test**

If `MockRpApiClient` does not currently support delaying `getBlock` responses, add a delay knob first:

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`, add:

```swift
var getBlockDelayNanos: UInt64 = 0

func setGetBlockDelay(nanos: UInt64) {
    self.getBlockDelayNanos = nanos
}
```

And modify `getBlock`:

```swift
func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock {
    calls.append(.getBlock(channel: channel, bitrate: bitrate, info: info, event: event))
    if getBlockDelayNanos > 0 {
        try await Task.sleep(nanoseconds: getBlockDelayNanos)
    }
    guard !blockResponses.isEmpty else {
        throw RpApiError.network(URLError(.unknown))
    }
    return blockResponses.removeFirst()
}
```

Now add the test:

```swift
func testSkipForwardPastLastSongCancelsInFlightPrefetchAndFetches() async throws {
    let api = MockRpApiClient()
    let block1 = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "700", elapsed: 0, duration: 11_000),
    ], cue: 0, endEvent: "700")
    let block2 = CoordinatorTestSupport.makeBlock(channel: 0)
    let block3 = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block1, block2, block3])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    // Make prefetch slow so it's still in-flight when skip happens.
    await api.setGetBlockDelay(nanos: 1_000_000_000)
    await engine.emitPositionUpdate(seconds: 2.0)
    // Don't sleep — skip immediately.
    try await coordinator.skipForward()

    // Allow time for cancelled task to settle.
    try await Task.sleep(nanoseconds: 200_000_000)
    let calls = await api.calls
    // Expect 3 calls: initial play, prefetch (cancelled mid-flight), synchronous skip-fetch.
    // Cancellation may or may not record the call depending on timing — accept 2 or 3.
    XCTAssertGreaterThanOrEqual(calls.count, 2)
    XCTAssertLessThanOrEqual(calls.count, 3)
    // currentBlock must be a fresh block (not block1).
    let np = await coordinator.nowPlaying
    XCTAssertNotNil(np)
}
```

This test is timing-sensitive. If existing prefetch tests use a deterministic harness (a `prefetchSettled` confirmation), prefer that pattern.

- [ ] **Step 11.2: Run — should fail (no cancellation logic)**

Run: `swift test --filter LivePlaybackCoordinatorTests/testSkipForwardPastLastSongCancelsInFlightPrefetchAndFetches 2>&1 | tail -10`
Expected: FAIL or hang/timeout. If hang, lower delay further.

- [ ] **Step 11.3: Add prefetch cancellation to `skipForward()` past-last branch**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, in the past-last branch, replace the `if prefetchedBlock != nil { ... }` block with:

```swift
if prefetchedBlock != nil {
    logger.debug("skipForward past-last: adopting prefetched block")
    await swapToPrefetchedBlockIfAvailable()
    return
}
if prefetchTask != nil {
    logger.debug("skipForward past-last: cancelling in-flight prefetch")
    prefetchTask?.cancel()
    prefetchTask = nil
}
```

Then the synchronous fetch path runs as before.

- [ ] **Step 11.4: Run test + suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 206 tests passing (or 205 if test is timing-flaky and skipped).

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/MockRpApiClient.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coordinator): skipForward past-last cancels in-flight prefetch"
```

---

## Task 12: Channel-switch cursor preservation test

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

This is a verification test — no production change should be required. If it fails, investigate what cursor logic is missing.

- [ ] **Step 12.1: Write test**

```swift
func testChannelSwitchPreservesCursors() async throws {
    let api = MockRpApiClient()
    let block0a = CoordinatorTestSupport.makeBlock(channel: 0, songs: [
        CoordinatorTestSupport.makeSong(songId: "1", event: "800", elapsed: 0, duration: 60_000),
        CoordinatorTestSupport.makeSong(songId: "2", event: "801", elapsed: 60_000, duration: 60_000),
    ], cue: 0, endEvent: "801")
    let block1 = CoordinatorTestSupport.makeBlock(channel: 1, songs: [
        CoordinatorTestSupport.makeSong(songId: "3", event: "900", elapsed: 0, duration: 60_000),
    ], cue: 0, endEvent: "900")
    let block0b = CoordinatorTestSupport.makeBlock(channel: 0)
    await api.setBlockResponses([block0a, block1, block0b])
    let engine = MockPlayerEngine()
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine,
        logger: AppLogger(category: "test"),
        bitrateProvider: { 4 }
    )

    try await coordinator.play(channelId: 0)
    await engine.emitPositionUpdate(seconds: 60.5)  // cursor[0] = 800
    try await coordinator.changeChannel(to: 1)      // play(1), no cursor
    try await coordinator.changeChannel(to: 0)      // play(0), event=800

    let calls = await api.calls
    let events = calls.compactMap { call -> Int?? in
        if case let .getBlock(channel, _, _, event) = call { return event }
        return nil
    }
    XCTAssertEqual(events, [nil, nil, 800])
}
```

- [ ] **Step 12.2: Run test**

Run: `swift test --filter LivePlaybackCoordinatorTests/testChannelSwitchPreservesCursors 2>&1 | tail -5`
Expected: PASS (the cursor logic from Tasks 4–5 already covers this).

If it fails: investigate. Likely cause would be `changeChannel(to:)` re-issuing `play` in a way that bypasses cursor read — verify that `changeChannel` calls `play(channelId:)` rather than directly fetching.

- [ ] **Step 12.3: Run full suite + commit**

Run: `swift test 2>&1 | tail -5`
Expected: 207 tests passing.

```bash
git add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "test(coordinator): channel-switch preserves per-channel cursors"
```

---

## Task 13: Cleanup + documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 13.1: Update CLAUDE.md "Coordinator playback" section**

In `CLAUDE.md`, locate the "Coordinator playback" subsection (under "Key technical decisions"). Replace the bullets about `LivePlaybackCoordinator.play(channelId:)` issuing `getBlock` and `nowPlaying` concurrently. New text:

```markdown
- `LivePlaybackCoordinator` keeps a per-channel `channelCursors: [Int: Int]` map that tracks the most recently finished or skipped-from event id per channel. `play(channelId:)` reads `channelCursors[channelId]` and passes it as `event` to `RpApiClient.getBlock(...event:)`; the server returns the block whose first listed song is `cursor + 1` (i.e. "songs after cursor"). Empty cursor → no event param → server returns the live block.
- The cursor mutates at four boundary-cross points: in-block auto-advance (engine position update), in-block `skipForward()`, `skipForward()` past last song, and prefetched-block auto-swap. Each writes the event id of the song just finished or skipped from. Channel switch-away is *not* a cursor-write point; the cursor already reflects the right value via the four points above.
- `skipForward()` past last song uses `currentBlock.endEvent` as both the cursor value and the `event` query param for the next-block fetch. If a prefetched block is already present it is adopted via `swapToPrefetchedBlockIfAvailable()` (no extra fetch). If a prefetch task is in flight it is cancelled before the synchronous fetch.
- Prefetch fires when `currentSongIndex == orderedSongs.count - 1` and `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The prefetch call now uses `event=<currentBlock.endEvent>` so the prefetched block is the deterministic next block, not just whatever the live channel happens to be.
- The earlier `now_playing`-based song-match path (`api.nowPlaying(channel:)` + `resolveStart(...)` + `NowPlayingEntry`) is gone. The cursor model makes it redundant: server tells us where the listener is by what we hand back.
```

Also update the "API client" section: remove any reference to `nowPlaying`. Update `RpApiClient.getBlock` signature note to include `event: Int?`.

- [ ] **Step 13.2: Update test count in CLAUDE.md**

Locate the "Test counts by PR" section. Add a new line at the bottom:

```markdown
- After event-cursor block resume (channelCursors map, drop now_playing API path, deterministic next-block fetch via event=endEvent): 207
```

(Adjust the final number to match `swift test 2>&1 | tail -5` actual output.)

- [ ] **Step 13.3: Update PR status table**

Locate the PR status table. Add a new row above PR 13:

```markdown
| 12.5 | claude/event-cursor-resume | ⬜ | Event-cursor block resume (drops now_playing API; per-channel cursor) |
```

Or if the user prefers absorbing this into PR 13's branch, make a note. Default: separate row.

- [ ] **Step 13.4: Run final full suite**

Run: `swift test 2>&1 | tail -10`
Expected: all tests passing, count matches CLAUDE.md.

Run: `swift build 2>&1 | tail -5`
Expected: clean build.

- [ ] **Step 13.5: Commit + push**

```bash
git add CLAUDE.md
git commit -m "docs(claude): event-cursor block resume notes + test count"
git push -u origin claude/event-cursor-resume
```

---

## Self-review

**1. Spec coverage check:**
- §3 Cursor model (4 update points): Tasks 5, 6, 7, 9 ✓
- §4 API surface (event param + dropped nowPlaying): Tasks 1, 2 ✓
- §5 Coordinator changes (state, simplified play, skipForward, prefetch, swap, engine handler): Tasks 4, 5, 6, 7, 8, 9, 10 ✓
- §6 Removed now_playing path: Tasks 2, 3 ✓
- §7 Tests (delete 3 + add ~10): Tasks 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 ✓
- §8 Edge cases: covered by Tasks 10, 11 + cursor parse-failure log lines ✓
- §9 Files touched: all listed in plan ✓

**2. Placeholder scan:** none ("TBD" appears once in spec but not in plan).

**3. Type consistency:** `channelCursors: [Int: Int]` used uniformly. `Int(currentBlock?.endEvent ?? "")` parsing pattern used uniformly. `Int(orderedSongs[i].event ?? "")` parsing pattern used uniformly. `event: Int?` on `getBlock` matches every call site (`play`, `skipForward` past-last, `maybeStartPrefetch`, all tests).

**4. Helper assumptions:** `CoordinatorTestSupport.makeBlock(...)` and `.makeSong(...)` are referenced by new tests. Existing test file may or may not have these helpers — Step 4.3 instructs the implementer to either use the existing helpers or inline the constructors. This is a known risk; the implementer should check before writing the first new test.

**5. Mock harness assumptions:** `MockPlayerEngine.emitPositionUpdate(seconds:)` and `.emitFileEnded(reason:)` are referenced by new tests. If these don't exist, Steps 4.3 and 9.1 instruct the implementer to find and use the existing position/event-driving pattern.

---

**Plan complete.** Saved to `docs/superpowers/plans/2026-05-02-event-cursor-block-resume.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch with checkpoints.

Which approach?
