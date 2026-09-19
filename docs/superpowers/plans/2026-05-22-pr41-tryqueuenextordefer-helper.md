# PR 41 — `tryQueueNextOrDefer` helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a `tryQueueNextOrDefer(_:)` private helper on `PlaybackCoordinator` and convert 5 risk-bearing `await songFileCache.localFile(...)` call sites to use it. Each site stops blocking the coordinator actor on in-flight downloads; on cache miss, queueNext is deferred via the existing PR 40 mechanism (`deferredQueueNextAt` + `tryQueueNextIfPending`).

**Architecture:** Helper does a synchronous `cachedFile(for:)` probe. Hit → `engine.queueNext` + set `queueNextEventId`. Miss → set `deferredQueueNextAt = clock()` + `emitState(.loading)`. The existing `tryQueueNextIfPending(landed:)` post-download hook (called from `kickSequentialDownload`'s downloader Task) fires queueNext + lifts state when bytes land. Race-guards on `queue[1].eventId` post-await become dead code because the probe is synchronous.

**Tech Stack:** Swift 6.2 actors, XCTest, libmpv (engine adapter mocked in tests).

**Spec:** `docs/superpowers/specs/2026-05-22-pr41-tryqueuenextordefer-helper-design.md`

**Branch:** `claude/pr41-tryqueuenextordefer-helper`

**Test count budget:** 543 → 549 (+6)

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Modify | Add helper; convert 5 next-resolve call sites |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` | Modify | Add 6 new tests (5 per-site defer + 1 cross-cutting lift) |
| `CHANGELOG.md` | Modify | Append under `## [Unreleased]` § Changed |
| `docs/pr-history.md` | Modify | Add PR 41 row; remove the "PR 40 — remaining await sites" entry from § Deferred |
| `docs/test-counts.md` | Modify | Append new line `543 → 549` |
| `CLAUDE.md` | Modify | Refresh *Current state* block |

No new files.

---

## Task 0: Branch setup

**Files:** none (git only)

- [ ] **Step 1: Create + switch to feature branch**

Run:
```bash
git -C /Users/gergely/git/rp-player checkout -b claude/pr41-tryqueuenextordefer-helper
```
Expected: `Switched to a new branch 'claude/pr41-tryqueuenextordefer-helper'`

- [ ] **Step 2: Verify clean working tree**

Run:
```bash
git -C /Users/gergely/git/rp-player status --short
```
Expected: no output (clean).

---

## Task 1: Failing test — `syncQueueHeadFromMpv` defers queueNext on cache miss

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append before the `private actor StateBox` marker at L1643)

- [ ] **Step 1: Append the failing test**

Add this method to the test class (insert just above `private actor StateBox` on line ~1643; the closing `}` of the class is immediately above that marker):

```swift
    /// PR 41: syncQueueHeadFromMpv (.fileStarted advance branch) must defer queueNext
    /// via the synchronous cachedFile(for:) probe when queue[1] is not yet downloaded.
    /// Pre-fix: blocking await songFileCache.localFile(for: queue[1]) parks the actor
    /// and risks the same cascade PR 40 fixed in the .fileEnded(.eof) recovery branch.
    func testSyncQueueHeadFromMpvDefersQueueNextOnAdvanceWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 300, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 301, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 302, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A + B downloaded so bootstrap completes; C in-flight (uncached).
        await cache.markDownloaded([300, 301])
        await cache.setInFlight([302])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        // Simulate B starting (mpv advanced from A → B naturally). syncQueueHeadFromMpv
        // runs, advances queue head, then tries to queueNext C. C is in-flight.
        await engine.setSimulatedCurrentPath(bUrl)
        await engine.fire(.fileStarted)

        // queueNext(C) must NOT fire — C is uncached, must defer.
        try await Task.sleep(nanoseconds: 200_000_000)
        let callsAfterAdvance = await engine.recordedCalls()
        let queuedC = callsAfterAdvance.contains(.queueNext(url: cUrl, startSeconds: nil))
        XCTAssertFalse(queuedC,
                       "syncQueueHeadFromMpv must defer queueNext(C) when C is uncached; calls=\(callsAfterAdvance)")

        // State must transition to .loading: defer signals to UI that we're waiting on a download.
        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "syncQueueHeadFromMpv must emit .loading when deferring queueNext")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run the test to verify it FAILS**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testSyncQueueHeadFromMpvDefersQueueNextOnAdvanceWhenNextUncached 2>&1 | tail -30
```
Expected: `XCTAssertFalse` failure on `queuedC` — pre-fix the await on `localFile(C)` parks until C releases, but in this test we never release, so it actually parks forever then times out on `waitUntil`. Either failure mode confirms the bug. Acceptable failure messages:
- `"syncQueueHeadFromMpv must defer queueNext(C)..."` (assertion fires)
- `waitUntil timed out after 1.0s` on the `.loading` check

If the test PASSES — STOP. The bug is not as described; investigate before proceeding.

- [ ] **Step 3: Commit the failing test**

Run:
```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): failing test for syncQueueHeadFromMpv queueNext defer

Pins the same blocking-actor bug PR 40 fixed for .fileEnded(.eof) — this
time on the .fileStarted advance path. Test releases B as the head song,
fires .fileStarted, and asserts queueNext(C) is deferred + .loading
emitted when C is uncached.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: commit succeeds.

---

## Task 2: Implement helper + convert `syncQueueHeadFromMpv` (L867)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:865-877` (the `if queue.count >= 2` next-resolve block inside `syncQueueHeadFromMpv`)
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (insert helper just above `tryQueueNextIfPending` at L967)

- [ ] **Step 1: Insert the helper above `tryQueueNextIfPending`**

Find this line (~L967):
```swift
    private func tryQueueNextIfPending(landed: GaplessSong) async {
```

Insert this method immediately before it:

```swift
    // Resolves queue[1] (or any candidate "next" song) for engine.queueNext using
    // a synchronous cache probe. Returns true on cache hit + successful queueNext.
    // Returns false on cache miss (deferred — kickSequentialDownload's post-download
    // hook tryQueueNextIfPending(landed:) will fire queueNext + lift state once
    // the download lands) or on queueNext error.
    private func tryQueueNextOrDefer(_ next: GaplessSong) async -> Bool {
        if let url = songFileCache.cachedFile(for: next) {
            do {
                try await engine.queueNext(url: url, startSeconds: nil)
                queueNextEventId = next.eventId
                return true
            } catch {
                logger.warn("queueNext failed event=\(next.eventId): \(error)")
                return false
            }
        }
        logger.debug("deferring queueNext (not cached) event=\(next.eventId)")
        deferredQueueNextAt = clock()
        emitState(.loading)
        return false
    }

```

- [ ] **Step 2: Convert the `syncQueueHeadFromMpv` advance block**

Find this block (~L865-877):
```swift
            if queue.count >= 2 {
                let next = queue[1]
                let nextUrl = await songFileCache.localFile(for: next)
                    ?? URL(string: next.gaplessUrl)
                if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                    do {
                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                        queueNextEventId = next.eventId
                    } catch {
                        logger.warn("syncQueueHead: queueNext failed: \(error)")
                    }
                }
            }
```

Replace with:
```swift
            if queue.count >= 2 {
                _ = await tryQueueNextOrDefer(queue[1])
            }
```

- [ ] **Step 3: Run the new test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testSyncQueueHeadFromMpvDefersQueueNextOnAdvanceWhenNextUncached 2>&1 | tail -10
```
Expected: `Test Suite '...' passed.` / `Executed 1 test, with 0 failures`.

- [ ] **Step 4: Run the existing PR 40 cascade test to verify no regression**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testEofRecoveryDoesNotBlockWhenNextDownloadInFlight 2>&1 | tail -10
```
Expected: passes.

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testEofRecoveryCascadeOnShortPromoDoesNotDesyncQueue 2>&1 | tail -10
```
Expected: passes.

- [ ] **Step 5: Commit**

Run:
```bash
git -C /Users/gergely/git/rp-player add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
feat(playback): tryQueueNextOrDefer helper + convert syncQueueHeadFromMpv

Extracts the sync-probe-or-defer pattern from PR 40's .fileEnded(.eof)
recovery branch into a reusable private method. Converts the
.fileStarted advance branch (highest-risk site) to use it. The
post-await race-guard on queue[1].eventId becomes dead code because the
cachedFile probe is synchronous — no actor suspension, no mid-await
queue mutation possible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: commit succeeds.

---

## Task 3: Failing test — `handleSongPlaybackError` defers queueNext

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append above `private actor StateBox`)

- [ ] **Step 1: Append the failing test**

```swift
    /// PR 41: handleSongPlaybackError's recovery-play branch must defer queueNext
    /// when the new queue[1] (after dropping the unplayable head) is uncached.
    func testHandleSongPlaybackErrorDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 400, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 401, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 402, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A downloaded (so bootstrap plays it), B downloaded (so initial queueNext fires),
        // C in-flight. Then A fires .fileEnded(.error) — recovery drops A, plays B, tries
        // queueNext(C). C is uncached → must defer.
        await cache.markDownloaded([400, 401])
        await cache.setInFlight([402])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        // Unplayable-song error code: -13 (LOADING_FAILED). Drops A, plays B, tries C.
        await engine.fire(.fileEnded(reason: .error(code: -13)))

        let playedB = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(playedB, "recovery must play B after unplayable-A drop")

        try await Task.sleep(nanoseconds: 200_000_000)
        let callsAfter = await engine.recordedCalls()
        let queuedC = callsAfter.contains(.queueNext(url: cUrl, startSeconds: nil))
        XCTAssertFalse(queuedC,
                       "handleSongPlaybackError must defer queueNext(C) when uncached; calls=\(callsAfter)")

        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "handleSongPlaybackError must emit .loading when deferring queueNext")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run test — verify it FAILS**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testHandleSongPlaybackErrorDefersQueueNextWhenNextUncached 2>&1 | tail -30
```
Expected: fails on `queuedC` assertion (pre-conversion, the await on `localFile(C)` parks; the test's 200ms sleep + 1s `waitUntil` on `.loading` will time out).

- [ ] **Step 3: Commit the failing test**

```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): failing test for handleSongPlaybackError queueNext defer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Convert `handleSongPlaybackError` (L772-784)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:772-784`

- [ ] **Step 1: Replace the next-resolve block**

Find this block (~L772-784) inside `handleSongPlaybackError`:
```swift
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("handleSongPlaybackError: queueNext failed: \(error)")
                }
            }
        }
```

Replace with:
```swift
        if queue.count >= 2 {
            _ = await tryQueueNextOrDefer(queue[1])
        }
```

- [ ] **Step 2: Run new test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testHandleSongPlaybackErrorDefersQueueNextWhenNextUncached 2>&1 | tail -10
```
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
feat(playback): convert handleSongPlaybackError to tryQueueNextOrDefer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Failing test — `applyBitrateChange` defers queueNext

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append above `private actor StateBox`)

- [ ] **Step 1: Append the failing test**

```swift
    /// PR 41: applyBitrateChange's post-refresh queueNext must defer when the new
    /// queue[1] (refreshed at the new bitrate) is uncached.
    func testApplyBitrateChangeDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 500, gaplessUrl: "https://example.com/A-320.mp3"),
            makeGaplessSong(songId: "B", eventId: 501, gaplessUrl: "https://example.com/B-320.mp3"),
        ])
        let refresh = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 500, gaplessUrl: "https://example.com/A-flac.flac"),
            makeGaplessSong(songId: "B", eventId: 501, gaplessUrl: "https://example.com/B-flac.flac"),
        ])
        await api.setGaplessResponses([initial, refresh])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // Bootstrap at the old bitrate with A + B downloaded.
        await cache.markDownloaded([500, 501])

        try await coord.play(channelId: 0)

        let aOld = URL(string: "https://example.com/A-320.mp3")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aOld, startSeconds: nil))
        }, timeout: 2.0)

        // Bitrate change refreshes the queue with the flac URLs. Mark B-flac as in-flight
        // so cachedFile(B-flac) returns nil at the post-refresh queueNext.
        // NOTE: setInFlight does NOT remove the [500, 501] downloaded entries, but the
        // refreshed B song carries a different gaplessUrl. cachedFile uses eventId only —
        // but the mock's releasedMirror stores by eventId, so B (event 501) IS cached.
        // To force cache miss, override cachedFile to return nil for event 501.
        cache.cachedFileOverride = { song in
            song.eventId == 501 ? nil : URL(string: song.gaplessUrl)
        }
        await statesBox.reset()

        await coord.applyBitrateChange()

        try await Task.sleep(nanoseconds: 200_000_000)
        let bNew = URL(string: "https://example.com/B-flac.flac")!
        let callsAfter = await engine.recordedCalls()
        let queuedB = callsAfter.contains(.queueNext(url: bNew, startSeconds: nil))
        XCTAssertFalse(queuedB,
                       "applyBitrateChange must defer queueNext(B-flac) when uncached; calls=\(callsAfter)")

        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "applyBitrateChange must emit .loading when deferring queueNext")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run test — verify it FAILS**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testApplyBitrateChangeDefersQueueNextWhenNextUncached 2>&1 | tail -30
```
Expected: pre-fix, the test will either fail on `queuedB` (await returned passthrough URL, queueNext fired) or on the `.loading` waitUntil timeout. Either confirms the bug.

- [ ] **Step 3: Commit the failing test**

```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): failing test for applyBitrateChange queueNext defer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Convert `applyBitrateChange` (L526-538)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:526-538`

- [ ] **Step 1: Replace the next-resolve block**

Find this block (~L526-538) inside `applyBitrateChange`:
```swift
        if self.queue.count >= 2 {
            let next = self.queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, self.queue.count >= 2, self.queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("applyBitrateChange: queueNext failed: \(error)")
                }
            }
        }
```

Replace with:
```swift
        if self.queue.count >= 2 {
            _ = await tryQueueNextOrDefer(self.queue[1])
        }
```

- [ ] **Step 2: Run new test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testApplyBitrateChangeDefersQueueNextWhenNextUncached 2>&1 | tail -10
```
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
feat(playback): convert applyBitrateChange to tryQueueNextOrDefer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Failing test — `skipForward` shallow-refetch defers queueNext

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append above `private actor StateBox`)

- [ ] **Step 1: Append the failing test**

```swift
    /// PR 41: skipForward's shallow-refetch branch (queue depleted → API refetch →
    /// engine.play(new head) → queueNext(new[1])) must defer queueNext when new[1] is uncached.
    func testSkipForwardShallowRefetchDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        // First gapless: only 1 song (forces the depleted-queue path on skip).
        let initial = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 600, gaplessUrl: "https://example.com/A.flac"),
        ])
        // Skip-triggered refetch: 2 songs. Skip drops A, plays first of refresh, queueNext second.
        let refresh = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "X", eventId: 700, gaplessUrl: "https://example.com/X.flac"),
            makeGaplessSong(songId: "Y", eventId: 701, gaplessUrl: "https://example.com/Y.flac"),
        ])
        await api.setGaplessResponses([initial, refresh])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A + X downloaded so play(A) and post-refetch play(X) succeed; Y in-flight.
        await cache.markDownloaded([600, 700])
        await cache.setInFlight([701])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let xUrl = URL(string: "https://example.com/X.flac")!
        let yUrl = URL(string: "https://example.com/Y.flac")!
        _ = try await waitUntil({
            await engine.recordedCalls().contains(.play(url: aUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        try await coord.skipForward()

        // After skip: engine.play(X) fires, then tryQueueNextOrDefer(Y) must defer.
        let playedX = try await waitUntil({
            await engine.recordedCalls().contains(.play(url: xUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(playedX, "shallow-refetch skip must play X")

        try await Task.sleep(nanoseconds: 200_000_000)
        let queuedY = await engine.recordedCalls().contains(.queueNext(url: yUrl, startSeconds: nil))
        XCTAssertFalse(queuedY,
                       "skipForward shallow-refetch must defer queueNext(Y) when uncached")

        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "skipForward shallow-refetch must emit .loading when deferring queueNext")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run test — verify it FAILS**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testSkipForwardShallowRefetchDefersQueueNextWhenNextUncached 2>&1 | tail -30
```
Expected: failure.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): failing test for skipForward shallow-refetch defer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Convert `skipForward` shallow-refetch (L447-459)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:447-459`

- [ ] **Step 1: Replace the post-engine.play next-resolve block**

Find this block (~L447-459) at the tail of `skipForward`'s shallow-refetch path (after `engine.play(url:)`, before `kickSequentialDownload()`):
```swift
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl, queue.count >= 2, queue[1].eventId == next.eventId {
                do {
                    try await engine.queueNext(url: nextUrl, startSeconds: nil)
                    queueNextEventId = next.eventId
                } catch {
                    logger.warn("skipForward shallow-refetch: queueNext failed: \(error)")
                }
            }
        }
```

Replace with:
```swift
        if queue.count >= 2 {
            _ = await tryQueueNextOrDefer(queue[1])
        }
```

- [ ] **Step 2: Run new test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testSkipForwardShallowRefetchDefersQueueNextWhenNextUncached 2>&1 | tail -10
```
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
feat(playback): convert skipForward shallow-refetch to tryQueueNextOrDefer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Failing test — `play(channelId:)` defers queueNext

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append above `private actor StateBox`)

- [ ] **Step 1: Append the failing test**

```swift
    /// PR 41: play(channelId:) must defer queueNext when queue[1] is uncached at
    /// the post-engine.play queueNext step.
    func testPlayDefersQueueNextWhenNextUncached() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 800, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 801, gaplessUrl: "https://example.com/B.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        // A downloaded so play(A) succeeds; B in-flight.
        await cache.markDownloaded([800])
        await cache.setInFlight([801])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        _ = try await waitUntil({
            await engine.recordedCalls().contains(.play(url: aUrl, startSeconds: nil))
        }, timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)
        let queuedB = await engine.recordedCalls().contains(.queueNext(url: bUrl, startSeconds: nil))
        XCTAssertFalse(queuedB, "play() must defer queueNext(B) when uncached")

        let sawLoading = try await waitUntil({
            await statesBox.contains(.loading)
        }, timeout: 1.0)
        XCTAssertTrue(sawLoading,
                      "play() must emit .loading when deferring queueNext")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run test — verify it FAILS**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testPlayDefersQueueNextWhenNextUncached 2>&1 | tail -30
```
Expected: failure.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): failing test for play() queueNext defer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Convert `play(channelId:)` (L202-219)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:202-219`

- [ ] **Step 1: Replace the next-resolve block**

Find this block (~L202-219) inside `playInternal`:
```swift
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl {
                // Race-guard: another action (skip / channel-change) may have run
                // on this actor during the localFile await. queue[1] may no
                // longer match `next`. Only queueNext if it still does.
                if queue.count >= 2, queue[1].eventId == next.eventId {
                    do {
                        try await engine.queueNext(url: nextUrl, startSeconds: nil)
                        queueNextEventId = next.eventId
                    } catch {
                        logger.warn("play: queueNext failed: \(error)")
                    }
                }
            }
        }
```

Replace with:
```swift
        if queue.count >= 2 {
            _ = await tryQueueNextOrDefer(queue[1])
        }
```

- [ ] **Step 2: Run new test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testPlayDefersQueueNextWhenNextUncached 2>&1 | tail -10
```
Expected: passes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
feat(playback): convert play() to tryQueueNextOrDefer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Cross-cutting lift test — deferred queueNext lifts state when downloader lands

**Files:**
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (append above `private actor StateBox`)

- [ ] **Step 1: Append the lift test**

```swift
    /// PR 41 cross-cutting: when a tryQueueNextOrDefer call defers (via the
    /// .fileStarted advance path), kickSequentialDownload's post-download hook
    /// must fire queueNext + lift state .loading → .playing once the bytes land.
    /// One exemplar test covers the lift behaviour across all converted sites
    /// (helper extraction means the lift path is shared).
    func testDeferredQueueNextLiftsStateWhenDownloaderLands() async throws {
        let api = MockRpApiClient()
        let response = makeGaplessResponse(songs: [
            makeGaplessSong(songId: "A", eventId: 900, gaplessUrl: "https://example.com/A.flac"),
            makeGaplessSong(songId: "B", eventId: 901, gaplessUrl: "https://example.com/B.flac"),
            makeGaplessSong(songId: "C", eventId: 902, gaplessUrl: "https://example.com/C.flac"),
        ])
        await api.setGaplessResponses([response])
        let engine = MockPlayerEngine()
        let cache = MockSongFileCache()
        let coord = LivePlaybackCoordinator(
            api: api, engine: engine, songFileCache: cache, logger: silentLogger(), bitrateProvider: { 4 }
        )

        let stateStream = await coord.stateUpdates
        let statesBox = StateBox()
        let stateCollector = Task {
            for await s in stateStream { await statesBox.append(s) }
        }

        await cache.markDownloaded([900, 901])
        await cache.setInFlight([902])

        try await coord.play(channelId: 0)

        let aUrl = URL(string: "https://example.com/A.flac")!
        let bUrl = URL(string: "https://example.com/B.flac")!
        let cUrl = URL(string: "https://example.com/C.flac")!
        _ = try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains(.play(url: aUrl, startSeconds: nil))
                && calls.contains(.queueNext(url: bUrl, startSeconds: nil))
        }, timeout: 2.0)

        await statesBox.reset()

        // Advance to B → defer on C.
        await engine.setSimulatedCurrentPath(bUrl)
        await engine.fire(.fileStarted)

        // Confirm we deferred (state went to .loading, queueNext(C) not yet called).
        _ = try await waitUntil({ await statesBox.contains(.loading) }, timeout: 1.0)

        // Release C's download → tryQueueNextIfPending fires queueNext(C) + lifts state.
        await cache.releaseInFlight(eventId: 902, url: cUrl)

        let queuedC = try await waitUntil({
            await engine.recordedCalls().contains(.queueNext(url: cUrl, startSeconds: nil))
        }, timeout: 2.0)
        XCTAssertTrue(queuedC, "tryQueueNextIfPending must fire queueNext(C) after C lands")

        let backToPlaying = try await waitUntil({
            await coord.currentPlaybackState == .playing
        }, timeout: 1.0)
        XCTAssertTrue(backToPlaying,
                      "state must lift .loading → .playing after deferred queueNext lands")

        stateCollector.cancel()
    }
```

- [ ] **Step 2: Run the lift test — verify it PASSES**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test --filter LivePlaybackCoordinatorTests/testDeferredQueueNextLiftsStateWhenDownloaderLands 2>&1 | tail -10
```
Expected: passes (no implementation change needed — the lift mechanism is PR 40's existing `tryQueueNextIfPending`).

If it FAILS: investigate. Most likely cause is that the `.fileStarted` path doesn't reach the lift because some intermediate state changed. Cross-check against `testSyncQueueHeadFromMpvDefersQueueNextOnAdvanceWhenNextUncached` (Task 1) which already confirms the defer half works.

- [ ] **Step 3: Commit**

```bash
git -C /Users/gergely/git/rp-player add Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
test(playback): cross-cutting lift test for tryQueueNextOrDefer

One exemplar test verifies the .loading → .playing lift fires after a
deferred queueNext lands. Helper extraction means lift behaviour is
shared across all 5 converted sites — per-site lift tests would be
redundant.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Full regression run

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test 2>&1 | tail -50
```
Expected: `Executed 549 tests, with 0 failures`. (543 baseline + 6 new tests added across Tasks 1, 3, 5, 7, 9, 11.)

If any other test fails: investigate. Likely causes:
- Removed race-guard exposes a pre-existing race elsewhere → restore the guard at that specific site and update plan
- Helper's `.loading` emit fires somewhere it shouldn't → re-read the site's caller path; emit may need to be conditional

If everything passes: proceed to Task 13.

- [ ] **Step 2: Run `swift build` (release config sanity)**

Run:
```bash
cd /Users/gergely/git/rp-player && swift build 2>&1 | tail -10
```
Expected: `Build complete!` with no warnings introduced by the change.

---

## Task 13: Documentation updates

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append entry to `CHANGELOG.md`**

Open `CHANGELOG.md`. Find the `## [Unreleased]` heading. Under its `### Changed` subsection (create if missing), add:

```markdown
- Extract `tryQueueNextOrDefer(_:)` helper on `PlaybackCoordinator` and convert 5 next-resolve call sites (`play`, `skipForward` shallow-refetch, `applyBitrateChange`, `handleSongPlaybackError`, `syncQueueHeadFromMpv`) to use it. Generalises PR 40's pattern: synchronous `cachedFile(for:)` probe replaces blocking `await songFileCache.localFile(...)`; on cache miss, queueNext is deferred and `.loading` is emitted; `tryQueueNextIfPending(landed:)` lifts state when the download lands. Closes the deferred tech-debt item from PR 40.
```

- [ ] **Step 2: Update `docs/pr-history.md`**

Add a new row at the bottom of the PR status table (mirroring the PR 40 row format — check the existing row at L53 for the exact column layout):

```markdown
| 41   | claude/pr41-tryqueuenextordefer-helper | ⏳ | tryQueueNextOrDefer helper (2026-05-22): generalises PR 40's sync-probe-or-defer pattern. Extracts a private helper on PlaybackCoordinator that does a synchronous cachedFile(for:) probe; on hit calls engine.queueNext, on miss sets deferredQueueNextAt + emits .loading. Converts 5 call sites: play(), skipForward shallow-refetch, applyBitrateChange, handleSongPlaybackError, syncQueueHeadFromMpv. The skipForward mid-skip site (queue[1] not yet queued in mpv) is intentionally NOT converted — mpv is idle waiting for our advanceToQueued, no events can queue behind the await, and converting would force the user's skip to bail out on cache miss. Head-resolve sites (L175, L429, L624, L754) also excluded — they precede engine.play(url:) which needs the URL; converting would mean handing mpv the remote URL on miss (behaviour change, not just risk fix). 6 new tests (5 per-site defer + 1 cross-cutting lift). 543 → 549 (+6). |
```

Then in the `## Deferred / tech debt` section, **remove** the entire `### PR 40 — remaining `await songFileCache.localFile(...)` call sites` block (it's now resolved). The `### PR 27 — CPU / RAM footprint deep scan (optional)` entry stays.

- [ ] **Step 3: Update `docs/test-counts.md`**

Append a new line at the bottom (match the file's existing format — check the last line first):

```markdown
- 2026-05-22: 543 → 549 (+6) — PR 41 tryQueueNextOrDefer helper (5 per-site defer + 1 lift)
```

- [ ] **Step 4: Update `CLAUDE.md` *Current state* block**

In `CLAUDE.md`, find the `## Current state` section. Replace its content with:

```markdown
- Last merged (pending): **PR 41** — `tryQueueNextOrDefer` helper. Extracts the sync-probe-or-defer pattern from PR 40's `.fileEnded(.eof)` recovery branch into a private method on `PlaybackCoordinator` and converts 5 risk-bearing `await songFileCache.localFile(...)` call sites (`play`, `skipForward` shallow-refetch, `applyBitrateChange`, `handleSongPlaybackError`, `syncQueueHeadFromMpv`). Each converted site stops blocking the coordinator actor on in-flight downloads; on cache miss, queueNext defers + emits `.loading`; existing `tryQueueNextIfPending(landed:)` lifts state when bytes land. Intentionally NOT converted: `skipForward` mid-skip (mpv idle, no risk) + 4 head-resolve sites (precede `engine.play(url:)`, would change cache-or-stream behaviour). Closes the PR 40 deferred tech-debt item. 549 tests.
- **Next up:** TBD — pick from the deferred list (`docs/pr-history.md` § Deferred) or brainstorm the next subsystem.
```

- [ ] **Step 5: Verify the doc edits**

Run:
```bash
git -C /Users/gergely/git/rp-player diff --stat CHANGELOG.md docs/pr-history.md docs/test-counts.md CLAUDE.md
```
Expected: 4 files changed, all with positive line counts (and `pr-history.md` having both `-` and `+` lines from the deferred-section removal).

- [ ] **Step 6: Commit the docs**

```bash
git -C /Users/gergely/git/rp-player add CHANGELOG.md docs/pr-history.md docs/test-counts.md CLAUDE.md
git -C /Users/gergely/git/rp-player commit -m "$(cat <<'EOF'
docs(pr41): changelog + pr-history + test-counts + CLAUDE.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: Final regression sanity check**

Run:
```bash
cd /Users/gergely/git/rp-player && swift test 2>&1 | tail -5
```
Expected: `Executed 549 tests, with 0 failures`.

- [ ] **Step 8: View branch summary**

Run:
```bash
git -C /Users/gergely/git/rp-player log --oneline main..HEAD
```
Expected: ~12 commits — 5 test commits + 5 impl commits + 1 lift-test commit + 1 docs commit. Branch is ready for review/merge.

---

## Done

PR 41 is implementation-complete. Next step: review (ultrareview / manual) → fast-forward merge to `main` per CLAUDE.md workflow conventions.
