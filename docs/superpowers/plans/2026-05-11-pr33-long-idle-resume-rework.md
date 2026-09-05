# PR 33 — Long-Idle Resume Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LivePlaybackCoordinator.resume()` continue the cached, paused song after a multi-hour pause instead of abruptly cancelling it; remove PR 30's network-stall watchdog, which is now unreachable.

**Architecture:** Drop `engine.clearPlaylist` + queue wipe + `play(channelId:)` from the long-idle branch of `resume()`. Just `engine.resume()` (mpv unpauses queue[0]; queueNext'd queue[1] still in mpv playlist), then truncate `queue` to `[queue[0], queue[1]]` and kick a background refetch. Generalize `kickRefetch` to filter `eventId > queue.last!.eventId` so the merged tail appends after the preserved prefix instead of rebuilding from queue[0]. Delete the stall watchdog (sole arm site is the long-idle resume branch we're rewriting).

**Tech Stack:** Swift 6.2, swift-package-manager, XCTest. Coordinator is a Swift actor; tests use `MockPlayerEngine`, `MockRpApiClient`, `MockSongFileCache` from `Tests/RPPlayerTests/Helpers/` and `Tests/RPPlayerTests/Playback/`.

**Reference:** [docs/superpowers/specs/2026-05-11-long-idle-resume-rework-design.md](docs/superpowers/specs/2026-05-11-long-idle-resume-rework-design.md)

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Modify | Rewrite `resume()` long-idle branch; generalize `kickRefetch` filter to `queue.last`; drop `sleep:` init param; delete watchdog functions + field. |
| `Sources/RPPlayer/App/AppContainer.swift` | Modify | Drop `sleep:` from `LivePlaybackCoordinator(...)` call. |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` | Modify | Add 6 new resume + kickRefetch tests; delete `testStallWatchdogStillArmsAfterLongIdleResume`; drop `sleep:` arg from helper. |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift` | Delete | Whole file gone with PR 30's watchdog. `ControllableSleep` lives here too. |
| `CHANGELOG.md` | Modify | Unreleased > Fixed (long-idle resume) + Removed (stall watchdog). |
| `CLAUDE.md` | Modify | Add PR 33 row, update Coordinator playback long-idle bullet, append Test counts row. |

---

## Task 0: Branch + Baseline

**Files:** none (git only).

- [ ] **Step 1: Verify clean working tree on main**

```bash
git status
git log --oneline -5
```

Expected: clean tree on `main`; head at `38cfeb4 fix: re-check for updates before opening update panel from popover button` (or later).

- [ ] **Step 2: Cut feature branch**

```bash
git checkout -b claude/pr33-long-idle-resume-rework
```

Expected: `Switched to a new branch 'claude/pr33-long-idle-resume-rework'`.

- [ ] **Step 3: Verify baseline tests pass**

```bash
swift test 2>&1 | tail -20
```

Expected: `Test Suite 'All tests' passed at ...`. Test count: 399.

---

## Task 1: Generalize `kickRefetch` filter to `queue.last.eventId`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:813-872` (`kickRefetch`, `runRefetch`)
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

The current `kickRefetch` snapshots `queue.first?.eventId` and rebuilds `queue = [firstHead] + newSongs` filtered by `eventId > firstHead.eventId`. This drops anything between queue[0] and queue.last, which is wrong when the long-idle resume preserves a 2-entry queue. Generalize: snapshot `queue.last?.eventId` too, race-check both, filter by `> tailEvent`, merge as `queue + filtered`. In steady state this preserves existing entries (the previous rebuild happened to be identical because backend always returned head onward and the in-memory queue was just a prefix; the new logic preserves the prefix explicitly).

- [ ] **Step 1: Write the failing test for queue.last filtering**

Add this test to `LivePlaybackCoordinatorTests.swift`. Pick a location near other refetch tests; if unsure, append before the closing `}` of the `LivePlaybackCoordinatorTests` class.

```swift
func testKickRefetchFiltersByQueueLastEventIdAndAppendsTail() async throws {
    // queue=[a(1), b(2), c(3)]; mock response includes b(2) (overlap) + d(4) + e(5).
    // After refetch: queue should be [a, b, c, d, e] — preserves prefix, appends new tail.
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let songA = makeGaplessSong(eventId: 1, title: "A")
    let songB = makeGaplessSong(eventId: 2, title: "B")
    let songC = makeGaplessSong(eventId: 3, title: "C")
    let songD = makeGaplessSong(eventId: 4, title: "D")
    let songE = makeGaplessSong(eventId: 5, title: "E")
    api.gaplessByChannel[0] = makeGaplessResponse(songs: [songB, songD, songE])
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    api.gaplessByChannel[0] = makeGaplessResponse(songs: [songA, songB, songC])
    try await coordinator.play(channelId: 0)
    // Now reset the response to the merge scenario before the next refetch fires.
    api.gaplessByChannel[0] = makeGaplessResponse(songs: [songB, songD, songE])
    // Force a refetch by simulating queue.count<3 trigger via a head advance is heavy;
    // simpler: drive one through a public seam. Instead, advance the head directly using
    // the test-only helper added below in step 7 (`testForceKickRefetch`).
    // For now, await the refetch the bootstrap kicked.
    try await waitUntil({ await coordinator.snapshotQueueIds() == [1, 2, 3, 4, 5] }, timeout: 2.0)
}
```

This test uses `await coordinator.snapshotQueueIds()` and `waitUntil(_:timeout:)`. If a `snapshotQueueIds` accessor doesn't exist on the coordinator, add it as a `#if DEBUG` test-only public method that returns `queue.map { $0.eventId }`. If `waitUntil` doesn't exist in the test helpers, add one in this same step:

```swift
@discardableResult
func waitUntil(_ condition: @Sendable () async -> Bool, timeout: TimeInterval) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("waitUntil timed out after \(timeout)s")
    return false
}
```

Place `waitUntil` at file scope in `LivePlaybackCoordinatorTests.swift` if no shared helpers file exists; otherwise add to `Tests/RPPlayerTests/Helpers/` as `WaitUntil.swift`.

Add the `snapshotQueueIds` accessor to `LivePlaybackCoordinator`:

```swift
#if DEBUG
public func snapshotQueueIds() -> [Int] { queue.map { $0.eventId } }
#endif
```

Place it just below `currentPlaybackState` (around line 96).

- [ ] **Step 2: Run the test to confirm it fails**

```bash
swift test --filter testKickRefetchFiltersByQueueLastEventIdAndAppendsTail 2>&1 | tail -20
```

Expected: FAIL. Today's `kickRefetch` rebuilds as `[firstHead] + filteredByFirstHead`, so queue ends up `[1, 2, 4, 5]` (loses `3`). XCTAssertEqual mismatch on the snapshotQueueIds output.

- [ ] **Step 3: Apply the kickRefetch generalization**

Replace `kickRefetch` and `runRefetch` ([PlaybackCoordinator.swift:813-872](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L813-L872)):

```swift
private func kickRefetch() {
    guard refetchTask == nil, let channelId = currentChannelId else { return }
    let headEvent = queue.first?.eventId ?? 0
    let tailEvent = queue.last?.eventId ?? 0
    refetchTask = Task { [weak self] in
        guard let self else { return }
        await self.runRefetch(channelId: channelId, headEvent: headEvent, tailEvent: tailEvent)
    }
}

private func runRefetch(channelId: Int, headEvent: Int, tailEvent: Int) async {
    let bitrate = await bitrateProvider()
    let response: GaplessResponse
    do {
        response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
    } catch {
        logger.warn("kickRefetch failed: \(error)")
        self.refetchTask = nil
        return
    }
    // Race-guard: discard if channel changed or queue head/tail moved during await.
    guard self.currentChannelId == channelId,
          self.queue.first?.eventId == headEvent,
          self.queue.last?.eventId == tailEvent else {
        logger.debug("kickRefetch result discarded: channel/head/tail moved during fetch")
        self.refetchTask = nil
        return
    }
    let newSongs = response.songs.filter { $0.eventId > tailEvent }
    let hadShortQueue = self.queue.count < 2
    self.queue = self.queue + newSongs
    self.currentResponse = response
    if hadShortQueue, self.queue.count >= 2 {
        let next = self.queue[1]
        let nextUrl = await songFileCache.localFile(for: next)
            ?? URL(string: next.gaplessUrl)
        if let nextUrl {
            try? await self.engine.queueNext(url: nextUrl, startSeconds: nil)
        }
    }
    kickSequentialDownload()
    self.refetchTask = nil
}
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
swift test --filter testKickRefetchFiltersByQueueLastEventIdAndAppendsTail 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Run the whole suite to catch regressions**

```bash
swift test 2>&1 | tail -25
```

Expected: PASS. Test count rises by 1 (399 → 400). If any existing test fails, it likely asserted on the post-refetch queue shape that the rebuild produced — fix the assertion to match the generalized merge (the new shape is a superset; for tests that fed responses including queue[0], the post-merge queue gains one entry at index 0 because the old rebuild's filter `> queue[0].eventId` stripped queue[0] from the response and then re-prefixed it, while the new filter `> queue.last.eventId` also strips it but doesn't re-prefix — but queue[0] was already in `self.queue`, so the new merge `self.queue + filtered` keeps it). Concretely: a test that pre-refetch had queue=[a] and response=[a,b,c,d] previously yielded `[a,b,c,d]` and still yields `[a,b,c,d]` (filter `> a.eventId` strips `a`, merge `[a]+[b,c,d]`). No change. The only behavioral diff is when queue.count >= 2 going in — that's new ground covered by the new test.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift \
        Tests/RPPlayerTests/Helpers/WaitUntil.swift 2>/dev/null
git commit -m "refactor: kickRefetch filters by queue.last.eventId so merged tail appends after preserved prefix"
```

If `WaitUntil.swift` was inlined into the test file instead, omit it from the `git add` line.

---

## Task 2: Rewrite `resume()` long-idle branch

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:225-274` (`resume`)
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

`resume()`'s long-idle branch today calls `engine.clearPlaylist`, wipes coordinator state, and re-runs `play(channelId:)` — abruptly cancelling the paused song. Replace it: probe `songFileCache.cachedFile(for: queue[0])`; if missing, fall through to legacy refetch+restart; otherwise `engine.resume()` (mpv unpauses queue[0]; queueNext'd queue[1] survives), fire pause-telemetry as today, then if long-idle truncate `queue` to `prefix(2)`, cancel the in-flight downloader (so it stops fetching old tail), and `kickRefetch()` to merge backend-current.

- [ ] **Step 1: Write failing test 1 — preserves current song + queue[1]**

Add to `LivePlaybackCoordinatorTests.swift`:

```swift
func testLongIdleResumePreservesCachedSongAndQueueOne() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let songs = (1...20).map { i in makeGaplessSong(eventId: 1000 + i, title: "Song\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: songs)
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coordinator.play(channelId: 0)
    // Pause and let 60 minutes elapse (> 59-min threshold).
    try await coordinator.pause()
    clockState.advance(seconds: 60 * 60)
    // Pre-resume baseline.
    let preResumePlayCalls = await engine.playCalls.count
    let preResumeClearCalls = await engine.clearPlaylistCalls
    // Refetch response with brand-new eventIds to simulate backend cursor advance.
    let freshSongs = (1...10).map { i in makeGaplessSong(eventId: 2000 + i, title: "Fresh\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: freshSongs)
    try await coordinator.resume()
    // engine.resume() called; engine.play and engine.clearPlaylist NOT called.
    XCTAssertEqual(await engine.resumeCalls, 1)
    XCTAssertEqual(await engine.playCalls.count, preResumePlayCalls)
    XCTAssertEqual(await engine.clearPlaylistCalls, preResumeClearCalls)
    // Queue truncated to [oldQ0, oldQ1] immediately after resume returns,
    // before the background refetch resolves.
    let postResumeIds = await coordinator.snapshotQueueIds()
    XCTAssertEqual(postResumeIds.prefix(2).map { $0 }, [1001, 1002])
    XCTAssertGreaterThanOrEqual(postResumeIds.count, 2)
}
```

This test references `engine.resumeCalls`, `engine.playCalls`, `engine.clearPlaylistCalls`. If `MockPlayerEngine` doesn't already track them, add the counters in this step:

```swift
// In Tests/RPPlayerTests/Playback/MockPlayerEngine.swift (or wherever MockPlayerEngine lives).
// If they exist already, no change.
private(set) var resumeCalls = 0
private(set) var clearPlaylistCalls = 0
// playCalls likely already exists as [URL] or [PlayCall]; if not, add it analogously.
```

- [ ] **Step 2: Run failing test**

```bash
swift test --filter testLongIdleResumePreservesCachedSongAndQueueOne 2>&1 | tail -20
```

Expected: FAIL. Today's resume calls clearPlaylist + play; XCTAssertEqual fails on resumeCalls (or on clearPlaylistCalls being incremented).

- [ ] **Step 3: Rewrite `resume()`**

Replace [PlaybackCoordinator.swift:225-274](Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L225-L274) with:

```swift
public func resume() async throws {
    logger.debug("resume()")
    guard !queue.isEmpty, let channelId = currentChannelId else { throw PlaybackCoordinatorError.notPlaying }
    let now = clock()
    let pausedFor: TimeInterval? = pausedAt.map { now.timeIntervalSince($0) }
    let longIdle = (pausedFor ?? 0) >= Self.longIdleResumeThresholdSeconds

    // If queue[0]'s cached file was evicted during pause, mpv will fail re-opening
    // the file:// URL. Fall back to the legacy refetch+restart path.
    if songFileCache.cachedFile(for: queue[0]) == nil {
        logger.warn("resume: cache miss for queue[0]; falling back to refetch+restart")
        try? await engine.clearPlaylist()
        queue = []
        currentResponse = nil
        lastStartedEventId = nil
        pausedAt = nil
        pausePositionMs = 0
        try await play(channelId: channelId)
        return
    }

    await prePlayHook()
    do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    emitState(.playing)

    // update_pause telemetry — same logic as before (lifted from old short-idle branch).
    let song = queue[0]
    if pausedAt != nil, song.updateHistory {
        let ppm = pausePositionMs
        let ts = Int(clock().timeIntervalSince1970)
        let songId = song.songId
        let event = String(song.eventId)
        let audioType = song.type
        let sliceNum = String(song.sliceNum)
        let api = self.api
        Task.detached {
            try? await api.updateHistory(
                songId: songId, chan: channelId, event: event, audioType: audioType,
                sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts,
                pauseFlag: true
            )
        }
    }
    pausedAt = nil
    pausePositionMs = 0

    // Long-idle catch-up: drop stale tail beyond queue[1]; refetch in background.
    if longIdle {
        logger.info("resume: long idle (\(Int(pausedFor ?? 0))s), kicking background catch-up")
        if queue.count > 2 {
            queue = Array(queue.prefix(2))
        }
        // Stop downloading the old tail. New tail starts after refetch resolves.
        downloaderTask?.cancel()
        downloaderTask = nil
        let cacheRef = songFileCache
        Task { await cacheRef.cancelInFlightDownloads() }
        kickRefetch()
    }
}
```

Note: `currentSongInQueueAvailable()` helper is still referenced elsewhere — leave it. Also, the old `armLongIdleStallWatchdog()` call inside the long-idle branch is now gone. We remove the function entirely in Task 3.

- [ ] **Step 4: Run failing test to confirm pass**

```bash
swift test --filter testLongIdleResumePreservesCachedSongAndQueueOne 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Write failing test 2 — fresh tail merges**

Append to `LivePlaybackCoordinatorTests.swift`:

```swift
func testLongIdleResumeMergesFreshTailAfterRefetch() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let initial = (1...20).map { i in makeGaplessSong(eventId: 1000 + i, title: "Song\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: initial)
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coordinator.play(channelId: 0)
    try await coordinator.pause()
    clockState.advance(seconds: 60 * 60)
    let freshSongs = (1...10).map { i in makeGaplessSong(eventId: 2000 + i, title: "Fresh\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: freshSongs)
    try await coordinator.resume()
    try await waitUntil({
        let ids = await coordinator.snapshotQueueIds()
        return ids == [1001, 1002, 2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008, 2009, 2010]
    }, timeout: 2.0)
}
```

- [ ] **Step 6: Run failing test**

```bash
swift test --filter testLongIdleResumeMergesFreshTailAfterRefetch 2>&1 | tail -20
```

Expected: PASS already if Task 1's filter shift is correct (the merge happens naturally). If it fails, it's because Task 1's filter didn't actually take effect for this code path — recheck Task 1's diff.

- [ ] **Step 7: Write failing test 3 — cache miss for queue[0] falls back**

Append:

```swift
func testLongIdleResumeWithCacheMissForQueueZeroFallsBack() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let songs = (1...20).map { i in makeGaplessSong(eventId: 1000 + i, title: "Song\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: songs)
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coordinator.play(channelId: 0)
    try await coordinator.pause()
    clockState.advance(seconds: 60 * 60)
    // Simulate eviction of queue[0]'s cache entry.
    await cache.removeCachedEntry(eventId: 1001)
    // Fresh response so the legacy refetch+restart path fetches new content.
    let freshSongs = (1...10).map { i in makeGaplessSong(eventId: 2000 + i, title: "Fresh\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: freshSongs)
    let preResumeClearCalls = await engine.clearPlaylistCalls
    let preResumePlayCalls = await engine.playCalls.count
    try await coordinator.resume()
    XCTAssertGreaterThan(await engine.clearPlaylistCalls, preResumeClearCalls)
    XCTAssertGreaterThan(await engine.playCalls.count, preResumePlayCalls)
    let postResumeIds = await coordinator.snapshotQueueIds()
    XCTAssertEqual(postResumeIds.first, 2001)
}
```

If `MockSongFileCache` doesn't expose `removeCachedEntry(eventId:)`, add it. The mock's cache state is whatever it tracks for `cachedFile(for:)` to return non-nil. Concretely (sketching):

```swift
// In MockSongFileCache.swift — add:
private var evicted: Set<Int> = []
func removeCachedEntry(eventId: Int) { evicted.insert(eventId) }

nonisolated func cachedFile(for song: GaplessSong) -> URL? {
    // existing logic, but return nil if song.eventId is in the evicted set.
    // The actor-isolated read of `evicted` from a nonisolated method requires reworking — use a lock or move the evicted check via an awaitable cache method. If reworking the mock is heavy, fall back to a different strategy: provide a `cachedFileOverride: @Sendable (GaplessSong) -> URL?` closure on the mock that the test sets to `{ song in song.eventId == 1001 ? nil : URL(string: song.gaplessUrl) }`.
}
```

The closure-override approach is simpler; prefer it if the existing mock isn't already tracking per-song state in a nonisolated-friendly way. Concretely:

```swift
// In MockSongFileCache.swift, add a stored property:
nonisolated(unsafe) var cachedFileOverride: (@Sendable (GaplessSong) -> URL?)?

// In cachedFile(for:), check the override first:
nonisolated func cachedFile(for song: GaplessSong) -> URL? {
    if let override = cachedFileOverride { return override(song) }
    return /* existing logic */
}
```

Then in the test, instead of `removeCachedEntry`, write:

```swift
cache.cachedFileOverride = { song in
    song.eventId == 1001 ? nil : URL(string: song.gaplessUrl)
}
```

Use whichever fits the existing mock shape better. Read `Tests/RPPlayerTests/Helpers/MockSongFileCache.swift` first to decide.

- [ ] **Step 8: Run failing test**

```bash
swift test --filter testLongIdleResumeWithCacheMissForQueueZeroFallsBack 2>&1 | tail -20
```

Expected: PASS (the implementation in Step 3 already handles this).

- [ ] **Step 9: Write failing test 4 — queue.count == 1 skips truncate**

Append:

```swift
func testLongIdleResumeQueueCountOneSkipsTruncate() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let single = [makeGaplessSong(eventId: 1001, title: "Solo")]
    api.gaplessByChannel[0] = makeGaplessResponse(songs: single)
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coordinator.play(channelId: 0)
    try await coordinator.pause()
    clockState.advance(seconds: 60 * 60)
    let freshSongs = (1...3).map { i in makeGaplessSong(eventId: 2000 + i, title: "Fresh\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: freshSongs)
    try await coordinator.resume()
    XCTAssertEqual(await engine.resumeCalls, 1)
    try await waitUntil({
        let ids = await coordinator.snapshotQueueIds()
        return ids == [1001, 2001, 2002, 2003]
    }, timeout: 2.0)
}
```

- [ ] **Step 10: Run failing test**

```bash
swift test --filter testLongIdleResumeQueueCountOneSkipsTruncate 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 11: Write failing test 5 — second resume during in-flight refetch is idempotent**

Append:

```swift
func testSecondResumeDuringInFlightRefetchIsIdempotent() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let clockState = ClockHolder()
    let songs = (1...20).map { i in makeGaplessSong(eventId: 1000 + i, title: "Song\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: songs)
    api.gaplessDelayNanoseconds = 200_000_000  // 200ms — long enough to overlap a 2nd resume
    let coordinator = LivePlaybackCoordinator(
        api: api, engine: engine, songFileCache: cache,
        logger: AppLogger(category: "Test"),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coordinator.play(channelId: 0)
    try await coordinator.pause()
    clockState.advance(seconds: 60 * 60)
    let freshSongs = (1...5).map { i in makeGaplessSong(eventId: 2000 + i, title: "Fresh\(i)") }
    api.gaplessByChannel[0] = makeGaplessResponse(songs: freshSongs)
    try await coordinator.resume()
    // Immediate 2nd resume (before refetch completes).
    try await coordinator.resume()
    // engine.resume() called exactly once on the long-idle branch (2nd is a no-op since pausedAt is nil now).
    XCTAssertEqual(await engine.resumeCalls, 1)
    try await waitUntil({
        let ids = await coordinator.snapshotQueueIds()
        return ids.suffix(5) == [2001, 2002, 2003, 2004, 2005]
    }, timeout: 2.0)
}
```

This relies on `MockRpApiClient.gaplessDelayNanoseconds` (per CLAUDE.md PR 31, the mock has a delay knob). If the actual property name is different, grep `MockRpApiClient.swift` and adjust.

The 2nd `resume()` call hits `pausedAt == nil` path. With the new code, the guard at the top still passes (`!queue.isEmpty && currentChannelId != nil`), and execution flows: `longIdle = false` (pausedFor is nil); cache probe passes; `engine.resume()` called again. So actually we'd see 2 engine.resume calls. That's fine for mpv (resume on already-playing is a no-op there). The test must accept that. Adjust:

```swift
XCTAssertGreaterThanOrEqual(await engine.resumeCalls, 1)
XCTAssertLessThanOrEqual(await engine.resumeCalls, 2)
```

The important assertion is the queue ends up correct (no duplicate refetch corrupts it; `kickRefetch`'s `refetchTask == nil` guard prevents a 2nd in-flight refetch).

- [ ] **Step 12: Run failing test**

```bash
swift test --filter testSecondResumeDuringInFlightRefetchIsIdempotent 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 13: Run the full suite to catch regressions**

```bash
swift test 2>&1 | tail -25
```

Expected: PASS. Test count: 400 → 405 (5 added in this task). The pre-existing `testStallWatchdogStillArmsAfterLongIdleResume` at [LivePlaybackCoordinatorTests.swift:448](Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift#L448) and any other test that asserted `engine.clearPlaylist` was called on long-idle resume will now fail. Catalog them and either:
- (a) Delete them if their behavioral assumption is invalidated by this PR (preferred for `testStallWatchdogStillArmsAfterLongIdleResume` — it's about the watchdog, which Task 3 deletes wholesale).
- (b) Update assertions to match the new behavior.

If `testStallWatchdogStillArmsAfterLongIdleResume` fails: leave it failing for now (Task 3 deletes it). Skip it temporarily by renaming `func testStall...` → `func skip_testStall...` so the suite goes green for this commit; revert in Task 3.

- [ ] **Step 14: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift \
        Tests/RPPlayerTests/Playback/MockPlayerEngine.swift \
        Tests/RPPlayerTests/Helpers/MockSongFileCache.swift
git commit -m "fix: long-idle resume keeps cached song and queue[1]; refetch merges backend-current as tail"
```

---

## Task 3: Delete stall watchdog

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (delete watchdog functions, field, sleep init param, 8 cancelStallWatchdog call sites)
- Modify: `Sources/RPPlayer/App/AppContainer.swift` (drop `sleep:` arg from `LivePlaybackCoordinator(...)` call)
- Delete: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift` (whole file; takes `ControllableSleep` with it)
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (delete `testStallWatchdogStillArmsAfterLongIdleResume`; drop `sleep:` arg from any helper that passed it)

- [ ] **Step 1: Delete the watchdog test file**

```bash
git rm Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift
```

- [ ] **Step 2: Delete `testStallWatchdogStillArmsAfterLongIdleResume` from main coordinator tests**

In `LivePlaybackCoordinatorTests.swift`, find the test (around line 448). Delete it entirely. Also check for any other reference to `ControllableSleep` or `sleep: sleeper.sleep` in this file (one usage at line 464-467 per grep). Drop the `sleep:` argument from the `LivePlaybackCoordinator(...)` call there. If `sleeper` becomes unused, delete it too.

If Step 13 of Task 2 used the `skip_test...` rename workaround, undo it now (the test is being deleted anyway).

- [ ] **Step 3: Delete watchdog functions + field + init param + call sites in coordinator**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, make these edits:

1. **Delete fields** (lines 54, 61):

```swift
private var stallWatchdog: Task<Void, Never>?
private static let stallWatchdogTimeoutSeconds: TimeInterval = 10
```

2. **Delete `sleep:` from init signature + storage + assignment** (lines 34, 75, 86):

```swift
private let sleep: @Sendable (UInt64) async -> Void   // delete
sleep: @escaping @Sendable (UInt64) async -> Void = { ns in try? await Task.sleep(nanoseconds: ns) }, // delete
self.sleep = sleep   // delete
```

3. **Delete watchdog functions** (lines 878-951):

```swift
private func cancelStallWatchdog() { ... }
private func armLongIdleStallWatchdog() { ... }
private func waitForFirstPositionUpdate(...) { ... }
private func logStallWatchdogTimeout(...) { ... }
private func surfaceStallError() { ... }
```

4. **Delete the 8 `cancelStallWatchdog()` call sites** at lines 142, 201, 290, 307, 387, 461, 586, plus the one inside `surfaceStallError` (gone with the function). Use grep to find them:

```bash
grep -n "cancelStallWatchdog\|armLongIdleStallWatchdog\|stallWatchdog" Sources/RPPlayer/Playback/PlaybackCoordinator.swift
```

After deletion, all 16 hits should be gone. (The 240 line `armLongIdleStallWatchdog()` call inside the long-idle resume branch was already removed in Task 2's `resume()` rewrite.)

- [ ] **Step 4: Drop `sleep:` arg from AppContainer.live()**

Find it:

```bash
grep -n "sleep:" Sources/RPPlayer/App/AppContainer.swift
```

If it appears in a `LivePlaybackCoordinator(...)` call, delete that one argument. If `AppContainer` doesn't pass `sleep:` (the default in the old init handled it), no change needed.

- [ ] **Step 5: Build to verify deletions are clean**

```bash
swift build 2>&1 | tail -20
```

Expected: build succeeds. If any reference to the deleted symbols remains, fix it. Common culprits: any test helper that passed `sleep:` will need the argument dropped.

- [ ] **Step 6: Run full test suite**

```bash
swift test 2>&1 | tail -25
```

Expected: PASS. Test count: 405 - 6 (StallWatchdogTests file) - 1 (testStallWatchdogStillArmsAfterLongIdleResume) = 398. Wait — Task 2 added 5 tests bringing 399 → 400 (Task 1) → 405 (Task 2). Task 3 deletes 7. Net: 398.

If a test fails because it still passes `sleep:` to `LivePlaybackCoordinator(...)`, drop that argument.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Sources/RPPlayer/App/AppContainer.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor: remove PR 30 long-idle stall watchdog (now-unreachable network-stall defense)"
```

The `git rm` from Step 1 was already staged; if not, add it now: `git add -u Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift`.

---

## Task 4: Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add CHANGELOG entries**

Open `CHANGELOG.md`. Under `## [Unreleased]`, add (creating sections if absent):

```markdown
### Fixed
- Long-idle resume preserves the currently paused song. Resume after a multi-hour pause now `engine.resume()`s the cached, paused queue head (mpv's playlist still holds the queueNext'd queue[1]), then truncates the in-memory queue to `[queue[0], queue[1]]` and kicks a background `api/gapless` refetch. The merged response appends as the new tail (filter `eventId > queue.last!.eventId`), so playback catches up to the backend's current cursor at the queue[1]→queue[2] boundary instead of abruptly cancelling the user's song.

### Removed
- PR 30's long-idle stall watchdog (`armLongIdleStallWatchdog`, `cancelStallWatchdog`, `surfaceStallError`, `waitForFirstPositionUpdate`, `LivePlaybackCoordinator.sleep` init param). The defense protected against mpv getting stuck on an HTTP `ffurl_read` after a long pause; with PR 32's local cache the resumed song is a `file://` URL, so the failure mode is unreachable. Historical rationale stays documented in the CLAUDE.md PR 30 entry for revival reference.
```

- [ ] **Step 2: Add PR 33 row to CLAUDE.md PR status table**

In `CLAUDE.md`, find the PR status table (`| PR | Branch | Status | Contents |`). Append:

```markdown
| 33   | claude/pr33-long-idle-resume-rework | ✅      | Long-idle resume rework: `LivePlaybackCoordinator.resume()` no longer cancels the paused, locally-cached song after a multi-hour pause. New flow: probe `songFileCache.cachedFile(for: queue[0])` (cache-miss → legacy refetch+restart fallback); `engine.resume()` (mpv unpauses queue[0], queue[1] still queueNext'd in mpv playlist); fire `update_pause` telemetry; if pausedFor ≥ 59 min then truncate `queue` to `prefix(2)`, cancel `downloaderTask` + `cache.cancelInFlightDownloads()`, `kickRefetch()` for background catch-up. `kickRefetch` filter generalized: snapshots both `queue.first?.eventId` AND `queue.last?.eventId`, race-checks both, filters response by `eventId > tailEvent`, merges as `self.queue + filtered` (preserves prefix; appends new tail). Boundary advance from queue[1]→queue[2] is the silent catch-up to backend-current. Deletes PR 30 stall watchdog (`armLongIdleStallWatchdog`, `cancelStallWatchdog`, `waitForFirstPositionUpdate`, `surfaceStallError`, `stallWatchdog` field, 8 `cancelStallWatchdog()` call sites, `sleep:` init param + `defaultSleep`, `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift` file with inline `ControllableSleep` helper, `testStallWatchdogStillArmsAfterLongIdleResume`) — sole arm site was the long-idle resume branch we replaced; with cached file:// playback the network-stall failure mode is unreachable. |
```

- [ ] **Step 3: Update Coordinator playback long-idle bullet in CLAUDE.md**

Find the bullet starting `**Long-idle resume.**` under "Coordinator playback (gapless model, PR 31)". Replace with:

```markdown
- **Long-idle resume.** `resume()` after `pausedFor ≥ 59 * 60` no longer cancels the paused song. New flow: cache-probe `queue[0]` (miss → legacy refetch+restart fallback); `engine.resume()` (mpv unpauses queue[0]; queueNext'd queue[1] still in mpv playlist); fire `update_pause` telemetry; truncate `queue` to `prefix(2)`; cancel `downloaderTask` + `cache.cancelInFlightDownloads()`; `kickRefetch()` for background catch-up. `kickRefetch` snapshots both head and tail eventIds, filters response by `> tailEvent`, merges as `queue + filtered` so the preserved prefix stays and backend-current songs append as the new tail. Boundary advance from queue[1]→queue[2] is the silent catch-up jump. Short-idle (`< 59 min`) branch is identical minus the truncate/refetch/downloader-cancel triplet. PR 30 stall watchdog deleted (sole arm site removed; unreachable failure mode with local file:// playback).
```

- [ ] **Step 4: Append Test counts row to CLAUDE.md**

Find the "Test counts by PR" section. Append the latest row (the PR 32 post-smoke-test fixes row currently ends at 399). Add:

```markdown
- After PR 33 long-idle resume rework — `kickRefetch` filter generalized to `queue.last.eventId` (snapshot pair race-guard, merge as `self.queue + filtered`); `resume()` long-idle branch rewritten (cache-miss fallback to legacy refetch+restart; otherwise `engine.resume()` + `update_pause` telemetry + truncate queue to `prefix(2)` + cancel downloader + `cancelInFlightDownloads()` + `kickRefetch()`); PR 30 stall watchdog wholly deleted (`armLongIdleStallWatchdog`, `cancelStallWatchdog`, `waitForFirstPositionUpdate`, `surfaceStallError`, `stallWatchdog` field, `sleep:` init param + `defaultSleep`, all 8 `cancelStallWatchdog()` call sites, `LivePlaybackCoordinatorStallWatchdogTests.swift` file with inline `ControllableSleep`, `testStallWatchdogStillArmsAfterLongIdleResume`). New tests: `testKickRefetchFiltersByQueueLastEventIdAndAppendsTail`, `testLongIdleResumePreservesCachedSongAndQueueOne`, `testLongIdleResumeMergesFreshTailAfterRefetch`, `testLongIdleResumeWithCacheMissForQueueZeroFallsBack`, `testLongIdleResumeQueueCountOneSkipsTruncate`, `testSecondResumeDuringInFlightRefetchIsIdempotent`. Test seam: `#if DEBUG` `snapshotQueueIds()` accessor; `MockSongFileCache.cachedFileOverride` (or equivalent eviction hook); `waitUntil(_:timeout:)` helper. Net: 399 → 398 (+6 added, -7 deleted).
```

- [ ] **Step 5: Commit doc updates**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: PR 33 changelog + status table + coordinator long-idle bullet + test count"
```

- [ ] **Step 6: Final verification**

```bash
swift test 2>&1 | tail -25
git log --oneline main..HEAD
```

Expected: 4 new commits on `claude/pr33-long-idle-resume-rework` (kickRefetch refactor, long-idle resume fix, watchdog removal, docs). Test suite green at 398.

---

## Self-Review

**Spec coverage check:**
- ✅ `resume()` rewrite — Task 2.
- ✅ `kickRefetch` filter shift (B1) — Task 1.
- ✅ Stall watchdog deletion + sleep init param drop + ControllableSleep delete — Task 3.
- ✅ Cache-miss defense for queue[0] — Task 2 Step 3 (probe + fallback).
- ✅ Cache-miss for queue[1] — relies on existing `fileEnded(.eof)` recovery (no new code per spec); not a new test required, but if desired add as a stretch test in Task 2.
- ✅ E2 (queue.count == 1 skip) — Task 2 test 4.
- ✅ E3 (refetch fails) — covered by `kickRefetch`'s existing error swallowing; relies on existing eof recovery; no new test required per spec.
- ✅ E4 (second resume during refetch) — Task 2 test 5.
- ✅ E5/E6 — implicit (existing logic handles them; no new code).
- ✅ Doc updates (CHANGELOG, CLAUDE.md) — Task 4.

**Placeholder scan:** No "TBD", "TODO", "implement later", "similar to" placeholders. All test code shown in full. Bash commands are exact. Code blocks contain real Swift, not pseudocode.

**Type consistency:** `LivePlaybackCoordinator.snapshotQueueIds()` consistent across all referencing tests. `MockPlayerEngine.resumeCalls` / `playCalls` / `clearPlaylistCalls` consistent. `cachedFileOverride` callable signature stable.

**Known fuzziness to resolve at implementation time:**
- Exact location/structure of `MockSongFileCache.cachedFileOverride` — depends on the existing mock's actor-isolation shape. Read the file first; pick whichever pattern (override closure vs evicted-set) doesn't fight the existing concurrency.
- Exact `MockRpApiClient` delay-knob property name (`gaplessDelayNanoseconds` is a guess from CLAUDE.md PR 31 wording). Grep first.
- Whether `ClockHolder` is the existing test double name or something else. Grep `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` for the existing pause+advance idiom.
- Whether `MockPlayerEngine` already exposes `resumeCalls` / `clearPlaylistCalls`. If yes, skip the additions in Task 2 Step 1.

These are local lookups (single grep + read), not design decisions. Resolve at implementation, no plan re-write needed.
