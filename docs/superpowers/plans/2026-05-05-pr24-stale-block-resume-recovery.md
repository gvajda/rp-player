# PR 24: Stale-Block Detection + Long-Idle Resume Recovery

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "displays paused song but plays something else" bug after long-idle resume by (a) detecting stale `api/play?action=start` responses with all-non-positive `elapsed` and advancing past them via `action=play`, and (b) refetching block on resume when paused-duration exceeds 59 minutes.

**Architecture:** Two narrowly-scoped changes inside `LivePlaybackCoordinator`. First, a pure helper `BlockSongs.isStale(songs:cue:)` that classifies a block as stale when `cue == 0 && songs.allSatisfy { (elapsed ?? 0) <= 0 }`. Second, `play(channelId:)` checks the helper after the bootstrap fetch and, if stale, issues a single `action=play` advance call using the last song's `event`/`type`/`sliceNum` (same shape used by `skipForward` past-last and `advancePastUnplayableBlock`). Third, `resume()` checks `clock() - pausedAt > 59 * 60` and routes to `play(channelId:)` instead of `engine.resume()` — the freshly-fetched block then runs through the stale-detector if needed. No new public API surface, no new state.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest. Files limited to `Sources/RPPlayer/Playback/` and corresponding tests.

---

## Background

Log-extracted reproduction: at `2026-05-04T22:39:48Z` `play(channelId: 0)` issued `api/play?action=start&event=0&chan=0...`. Server returned block `2077-0.flac` (the one previously playing 24 minutes earlier) with three songs whose `elapsed` values were `-1069700`, `-794400`, `-289400` ms — i.e. negative, summing to zero with last song's duration so `last.elapsed + last.duration == 0`. `block.cue == 0`. Coordinator played the file from offset 0 (file content there: "Orbital – The Box"). `BlockSongs.indexOfSong(at:in:)` picked song[2] = "Bill Miller – River Of Time" (the last index where `startsAt <= 0.02`). Result: UI showed Bill Miller, audio played Orbital. User then paused at 22:40:21 and resumed 8.5h later at 07:09:56; `engine.resume()` ran on a stale CDN connection and hit `Stream ends prematurely at 152387234, should be 201328748`.

The web player (`.temp/main.js`) has the same negative-elapsed code path with no detection. Server-side cursor staleness is real but rare; this PR makes the client self-heal.

Existing `advancePastUnplayableBlock(failureCode:)` is engine-error-driven and uses `consecutivePlaybackFailures`. We do NOT reuse it directly because (a) stale-block isn't a playback failure and (b) we want a single retry capped independent of engine-level failure counters. We do mirror its API-call shape.

---

## File Structure

- **Modify** `Sources/RPPlayer/Playback/BlockSongs.swift` — add `isStale(songs:cue:)`.
- **Modify** `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — `play(channelId:)` post-bootstrap stale check + advance; `resume()` long-idle refetch.
- **Modify** `Tests/RPPlayerTests/Playback/BlockSongsTests.swift` — unit tests for `isStale`.
- **Modify** `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` — integration tests for stale-block advance + long-idle resume refetch.
- **Modify** `CLAUDE.md` — document PR 24 row, new test count, key technical decisions.

---

## Task 1: Add `BlockSongs.isStale(songs:cue:)` helper (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Playback/BlockSongs.swift`
- Test: `Tests/RPPlayerTests/Playback/BlockSongsTests.swift`

- [ ] **Step 1: Write failing tests in `BlockSongsTests.swift`**

Append the following test cases to the existing `BlockSongsTests` class (locate the closing `}` of the class and insert before it). The helper `makeSong` already exists in this file — reuse it.

```swift
func testIsStaleReturnsTrueWhenCueZeroAndAllElapsedNonPositive() {
    let songs = [
        makeSong(elapsed: -1_069_700, duration: 275_300),
        makeSong(elapsed: -794_400, duration: 505_000),
        makeSong(elapsed: -289_400, duration: 289_400),
    ]
    XCTAssertTrue(BlockSongs.isStale(songs: songs, cue: 0))
}

func testIsStaleReturnsTrueWhenAllElapsedZeroAndCueZero() {
    let songs = [
        makeSong(elapsed: 0, duration: 60_000),
        makeSong(elapsed: 0, duration: 60_000),
    ]
    XCTAssertTrue(BlockSongs.isStale(songs: songs, cue: 0))
}

func testIsStaleReturnsFalseWhenAnyElapsedPositive() {
    let songs = [
        makeSong(elapsed: -1_000, duration: 60_000),
        makeSong(elapsed: 60_000, duration: 60_000),
    ]
    XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 0))
}

func testIsStaleReturnsFalseWhenCueNonZero() {
    let songs = [
        makeSong(elapsed: -1_000, duration: 60_000),
        makeSong(elapsed: -500, duration: 60_000),
    ]
    XCTAssertFalse(BlockSongs.isStale(songs: songs, cue: 357_800))
}

func testIsStaleReturnsFalseForEmptySongs() {
    XCTAssertFalse(BlockSongs.isStale(songs: [], cue: 0))
}
```

If `BlockSongsTests.swift` does not already define a `fileprivate func makeSong(elapsed:duration:)` helper, add this at the top of the class:

```swift
fileprivate func makeSong(elapsed: Int, duration: Int) -> PlayListSong {
    PlayListSong(
        songId: "x", artist: "A", title: "T", album: "Al", duration: duration,
        event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: elapsed, slideshow: nil,
        type: nil, sliceNum: nil
    )
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
swift test --filter BlockSongsTests/testIsStale 2>&1 | tail -20
```

Expected: compile error referencing `BlockSongs.isStale` not defined.

- [ ] **Step 3: Implement `isStale` in `BlockSongs.swift`**

Append to `enum BlockSongs` after `indexOfSong(at:in:)`:

```swift
    // True when the bootstrap response is for a block whose audio file has
    // already played past its end (server cursor lagged real-time). Detected
    // by cue == 0 AND every song's elapsed offset being <= 0. In that case
    // playing the file from the start would resurrect already-aired content;
    // callers should advance to the next block via api/play action=play.
    static func isStale(songs: [PlayListSong], cue: Int) -> Bool {
        guard !songs.isEmpty, cue == 0 else { return false }
        return songs.allSatisfy { ($0.elapsed ?? 0) <= 0 }
    }
```

- [ ] **Step 4: Run tests, verify pass**

```bash
swift test --filter BlockSongsTests 2>&1 | tail -10
```

Expected: all `BlockSongsTests` tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Playback/BlockSongs.swift Tests/RPPlayerTests/Playback/BlockSongsTests.swift
git commit -m "feat(playback): add BlockSongs.isStale stale-block detector

Detects bootstrap api/play responses with cue=0 and all non-positive
elapsed offsets — symptom of server-side per-(player_id, chan) cursor
having advanced past the block's audio file end."
```

---

## Task 2: Stale-block advance in `play(channelId:)` (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:124-160`
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write failing test for stale-block advance**

Append to `LivePlaybackCoordinatorTests` (in the main class body, before its closing `}`):

```swift
func testPlayDetectsStaleBlockAndAdvancesViaActionPlay() async throws {
    // Server returned a "stale" bootstrap block: cue=0, all elapsed <= 0.
    // Coordinator must follow up with a single action=play advance call,
    // using the last song's event/type/sliceNum, and play the resulting block.
    let staleSong = PlayListSong(
        songId: "old", artist: "A", title: "T", album: "Al", duration: 289_400,
        event: "2870247", schedTime: nil, chan: "0", year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: -289_400, slideshow: nil,
        type: "M", sliceNum: "5"
    )
    let staleBlock = makeBlock(
        url: "https://example.com/stale.flac",
        cue: 0, endEvent: "2870247", prebuiltSongs: [staleSong]
    )
    let freshBlock = makeBlock(
        url: "https://example.com/fresh.flac",
        songs: [("s1", 60_000), ("s2", 60_000)]
    )

    let api = MockRpApiClient()
    await api.setBlockResponses([staleBlock, freshBlock])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
    )
    try await coord.play(channelId: 0)

    let calls = await api.calls
    XCTAssertEqual(calls.count, 2, "expected bootstrap + 1 advance")
    XCTAssertEqual(calls[0], .play(channel: 0, bitrate: 4, event: 0, action: .start,
                                   audioType: nil, episodeId: nil, sliceNum: nil))
    guard case let .play(_, _, event2, action2, audioType2, episodeId2, sliceNum2) = calls[1] else {
        return XCTFail("expected second call to be .play")
    }
    XCTAssertEqual(action2, .play)
    XCTAssertEqual(event2, 2_870_247)
    XCTAssertEqual(audioType2, "M")
    XCTAssertEqual(episodeId2, 0)
    XCTAssertEqual(sliceNum2, "5")

    let engineCalls = await engine.recordedCalls()
    XCTAssertEqual(engineCalls.last,
                   .play(url: URL(string: "https://example.com/fresh.flac")!, startSeconds: nil),
                   "engine should play the fresh (post-advance) block, not the stale one")
}

func testPlayDoesNotAdvanceTwiceIfAdvanceAlsoReturnsStale() async throws {
    // Defense-in-depth: if both the bootstrap AND the action=play advance
    // return stale, we accept the second response rather than recursing.
    let staleA = PlayListSong(
        songId: "a", artist: "A", title: "T", album: "Al", duration: 100_000,
        event: "100", schedTime: nil, chan: "0", year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: -100_000, slideshow: nil,
        type: "M", sliceNum: "1"
    )
    let staleB = PlayListSong(
        songId: "b", artist: "A", title: "T", album: "Al", duration: 100_000,
        event: "200", schedTime: nil, chan: "0", year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: -100_000, slideshow: nil,
        type: "M", sliceNum: "1"
    )
    let staleBlockA = makeBlock(url: "https://example.com/staleA.flac", cue: 0,
                                endEvent: "100", prebuiltSongs: [staleA])
    let staleBlockB = makeBlock(url: "https://example.com/staleB.flac", cue: 0,
                                endEvent: "200", prebuiltSongs: [staleB])
    let api = MockRpApiClient()
    await api.setBlockResponses([staleBlockA, staleBlockB])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 4 }
    )
    try await coord.play(channelId: 0)

    let calls = await api.calls
    XCTAssertEqual(calls.count, 2, "expected exactly one advance retry, not infinite recursion")
    let engineCalls = await engine.recordedCalls()
    XCTAssertEqual(engineCalls.last,
                   .play(url: URL(string: "https://example.com/staleB.flac")!, startSeconds: nil))
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
swift test --filter "LivePlaybackCoordinatorTests/testPlayDetectsStaleBlockAndAdvancesViaActionPlay" 2>&1 | tail -30
```

Expected: `expected bootstrap + 1 advance` failure (only 1 call recorded) and engine plays `stale.flac`.

- [ ] **Step 3: Replace body of `play(channelId:)` in `PlaybackCoordinator.swift`**

Locate `public func play(channelId: Int) async throws` at line 124. Replace the entire method (lines 124-160) with:

```swift
public func play(channelId: Int) async throws {
    logger.debug("play(channelId: \(channelId))")
    await ensureEventSubscription()
    let bitrate = await bitrateProvider()
    logger.debug("play resolved bitrate=\(bitrate)")
    var block = try await api.play(
        channel: channelId, bitrate: bitrate, event: 0, action: .start,
        audioType: nil, episodeId: nil, sliceNum: nil
    )
    var songs = BlockSongs.orderedSongs(from: block)
    guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

    if BlockSongs.isStale(songs: songs, cue: block.cue) {
        let lastSong = songs.last
        let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(block.endEvent ?? "") ?? 0
        let audioType = lastSong?.type ?? "M"
        let sliceNum = lastSong?.sliceNum
        logger.info("bootstrap returned stale block (cue=0, all elapsed<=0); advancing via action=play event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
        block = try await api.play(
            channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
            audioType: audioType, episodeId: 0, sliceNum: sliceNum
        )
        songs = BlockSongs.orderedSongs(from: block)
        guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
    }

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
    emitState(.playing)
    fireSongStartTelemetry(song: orderedSongs[0], channelId: channelId)
}
```

The diff vs original: `let block` → `var block`, `let songs` → `var songs`, plus the new stale-detect block immediately after `guard !songs.isEmpty`.

- [ ] **Step 4: Run tests, verify pass**

```bash
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -15
```

Expected: both new tests pass; all pre-existing tests still pass.

- [ ] **Step 5: Run full suite to catch regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: total tests pass = previous (334) + 5 (Task 1) + 2 (Task 2) = 341. If a different number, investigate before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "fix(playback): detect stale bootstrap block and advance via action=play

Server occasionally returns a per-(player_id, chan) bootstrap response
where the audio file's scheduled play time has already elapsed in real
time, encoded as cue=0 with all song.elapsed<=0. Previously the
coordinator played the file from offset 0 (resurrecting already-aired
content) while the boundary detector latched onto the last song
(picking the largest startsAt<=0). Fix: detect via BlockSongs.isStale
and follow up with a single action=play advance using the last song's
event/type/sliceNum. Cap to one retry — if the advance also returns
stale, accept it and let the user skip manually."
```

---

## Task 3: Long-idle resume refetch (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:190-229`
- Test: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write failing test**

Append to `LivePlaybackCoordinatorTests`:

```swift
func testResumeAfterLongIdleRefetchesBlockInsteadOfEngineResume() async throws {
    // After paused for >= 59 minutes, mpv's HTTP connection to the CDN is
    // commonly stale (server-side connection eviction, even if block.expiration
    // is still in the future per RP's API). resume() must refetch via play()
    // rather than calling engine.resume() blindly.
    final class MutableClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }
    let clockState = MutableClock()
    let api = MockRpApiClient()
    let firstBlock = makeBlock(
        url: "https://example.com/before.flac",
        expiration: 99_999_999_999,
        songs: [("s1", 60_000), ("s2", 60_000)]
    )
    let refetched = makeBlock(
        url: "https://example.com/after.flac",
        songs: [("s3", 60_000)]
    )
    await api.setBlockResponses([firstBlock, refetched])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coord.play(channelId: 0)
    try await coord.pause()
    // 59 minutes + 1 second after pause
    clockState.date = Date(timeIntervalSince1970: 1_000 + 59 * 60 + 1)
    try await coord.resume()

    let engineCalls = await engine.recordedCalls()
    let resumeCount = engineCalls.filter { if case .resume = $0 { return true } else { return false } }.count
    XCTAssertEqual(resumeCount, 0, "expected no engine.resume after long idle")
    XCTAssertEqual(engineCalls.last,
                   .play(url: URL(string: "https://example.com/after.flac")!, startSeconds: nil),
                   "expected engine.play with refetched block")
    let apiCalls = await api.calls
    XCTAssertEqual(apiCalls.count, 2, "expected bootstrap + refetch (no extra advance)")
    guard case let .play(_, _, _, action2, _, _, _) = apiCalls[1] else {
        return XCTFail("expected second call to be .play")
    }
    XCTAssertEqual(action2, .start, "long-idle refetch goes through play(channelId:) which uses action=start")
}

func testResumeWithinIdleThresholdStillCallsEngineResume() async throws {
    // 30 minutes after pause: still within 59m threshold, normal engine.resume() path.
    final class MutableClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }
    let clockState = MutableClock()
    let api = MockRpApiClient()
    let block = makeBlock(
        url: "https://example.com/0-1.flac",
        expiration: 99_999_999_999,
        songs: [("s1", 60_000), ("s2", 60_000)]
    )
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(),
        bitrateProvider: { 4 }, clock: { clockState.date }
    )
    try await coord.play(channelId: 0)
    try await coord.pause()
    clockState.date = Date(timeIntervalSince1970: 1_000 + 30 * 60)
    try await coord.resume()

    let engineCalls = await engine.recordedCalls()
    let resumeCount = engineCalls.filter { if case .resume = $0 { return true } else { return false } }.count
    XCTAssertEqual(resumeCount, 1, "expected exactly one engine.resume within idle threshold")
    let apiCalls = await api.calls
    XCTAssertEqual(apiCalls.count, 1, "no refetch within threshold")
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
swift test --filter "LivePlaybackCoordinatorTests/testResumeAfterLongIdle" 2>&1 | tail -25
```

Expected: `resumeCount == 0` assertion fails (engine.resume was called).

- [ ] **Step 3: Modify `resume()` to add long-idle refetch branch**

Locate `public func resume() async throws` at line 190. Replace the existing block-expiration check with this combined check. The new long-idle branch goes BEFORE the existing block-expiration branch so a block with `expiration > 0` but stale connection is still refetched.

Replace lines 192-201 (from `guard let block = currentBlock` through the existing `try await play(channelId: channelId); return }` plus the closing brace of the if):

```swift
guard let block = currentBlock else { throw PlaybackCoordinatorError.notPlaying }
let now = clock()
let pausedFor: TimeInterval? = pausedAt.map { now.timeIntervalSince($0) }
let longIdle = (pausedFor ?? 0) >= Self.longIdleResumeThresholdSeconds
let blockExpired = block.expiration > 0 && now.timeIntervalSince1970 > Double(block.expiration)
if (longIdle || blockExpired), let channelId = currentChannelId {
    if longIdle {
        logger.info("resume: long idle (\(Int(pausedFor ?? 0))s >= \(Int(Self.longIdleResumeThresholdSeconds))s), refetching block")
    } else {
        logger.info("resume: block expired (now=\(Int(now.timeIntervalSince1970)) > expiration=\(block.expiration)), refetching")
    }
    pausedAt = nil
    pausePositionMs = 0
    try await play(channelId: channelId)
    return
}
```

Also add a static constant near the top of `LivePlaybackCoordinator` (find the `private static let maxConsecutivePlaybackFailures` line, around line 52, and add directly after it):

```swift
    private static let longIdleResumeThresholdSeconds: TimeInterval = 59 * 60
```

- [ ] **Step 4: Run tests, verify pass**

```bash
swift test --filter "LivePlaybackCoordinatorTests/testResume" 2>&1 | tail -15
```

Expected: all `testResume*` tests pass.

- [ ] **Step 5: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 341 + 2 = 343 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "fix(playback): refetch block on resume when paused >= 59 minutes

After a long idle, mpv's cached HTTP connection to the CDN is commonly
dead even when block.expiration is still in the future — observed
'Stream ends prematurely' on resume after 8.5h pause. Threshold set
just under 1h (59 min) on the assumption that any stricter server-side
TCP idle timeout is at least 1h. Refetch routes through play(channelId:)
so the new stale-block detector also fires for the bootstrap response."
```

---

## Task 4: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add PR 24 entry to PR status table**

Find the markdown table headed `| PR   | Branch         | Status | Contents                                                                    |`. The last row is PR 23. Add directly below it:

```markdown
| 24   | merged to main | ✅      | Stale-block detection + long-idle resume refetch: BlockSongs.isStale (cue=0, all elapsed<=0); play(channelId:) advances via action=play with last song's event/type/sliceNum (single retry); resume() refetches via play() when paused >=59 min |
```

(Only flip status to ✅ after the merge — until then leave as `🚧` and `claude/pr24-stale-block-recovery`. The plan template uses ✅ for the post-merge state.)

- [ ] **Step 2: Add to "Last merged" line at top of "Current state"**

Replace the existing `Last merged: **PR 23** ...` line with:

```markdown
- Last merged: **PR 24** — stale-block detection (api/play action=start with cue=0 + all elapsed<=0 advances via action=play) + long-idle resume refetch (>=59 min). 343 tests passing on `main`.
```

(Adjust `343` to the actual final count from `swift test` output.)

- [ ] **Step 3: Add "Test counts by PR" entry**

Find `## Test counts by PR` section and append after the PR 23 line:

```markdown
- After PR 24 stale-block + long-idle resume recovery (`BlockSongs.isStale(songs:cue:)`; `play(channelId:)` post-bootstrap stale check + 1 advance retry via `action=play` with last song's event/type/sliceNum; `resume()` refetches via `play()` when `pausedAt` >= 59 min): 343
```

- [ ] **Step 4: Add to "Coordinator playback" key technical decisions**

Find the `### Coordinator playback` section. Append a new bullet at the end:

```markdown
- **Stale bootstrap block recovery.** `api/play?action=start` can return a block where `cue=0` and every song's `elapsed` is `<= 0` — the server's per-(player_id, chan) cursor lagged real-time and the encoded offsets are relative to "block end" rather than "file start". Naive playback would seek to file offset 0 (already-aired content) while `BlockSongs.indexOfSong` latches onto the last song. `BlockSongs.isStale(songs:cue:)` detects this; `play(channelId:)` follows up with a single `api/play?action=play&event=<lastSong.event ?? block.endEvent>&audio_type=<lastSong.type>&slice_num=<lastSong.sliceNum>` advance and uses the response. One retry max — a second stale response is accepted and the user can skip manually. Web player (main.js) has the same negative-elapsed code path with no detection; client-side recovery is correct.
- **Long-idle resume refetch.** `resume()` checks `clock() - pausedAt >= 59 * 60` (`longIdleResumeThresholdSeconds`) and routes to `play(channelId:)` when over threshold. Reason: mpv's cached HTTP connection to the CDN dies on long idle (observed `Stream ends prematurely at <bytes>` after 8.5h pause) even when `block.expiration` is still in the future per RP's API. 59 min picked deliberately under 1h to stay inside any common 1-hour server-side TCP idle timeout. The refetched block runs through the stale-detector above.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: PR 24 stale-block + long-idle resume recovery"
```

---

## Task 5: Push, open PR, merge

- [ ] **Step 1: Push branch**

```bash
git push -u origin claude/pr24-stale-block-recovery
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "fix(playback): stale-block + long-idle resume recovery" --body "$(cat <<'EOF'
## Summary
- Detect stale bootstrap responses (`api/play?action=start` returning cue=0 + all `elapsed<=0`) and advance via single `action=play` retry using last song's `event`/`type`/`sliceNum`.
- Refetch block on `resume()` when paused >= 59 min (mpv HTTP connection to CDN dies on long idle even when `block.expiration` is in the future).
- Adds `BlockSongs.isStale(songs:cue:)` plus 9 new tests (5 unit, 4 integration). Total 343.

## Repro before fix
Log line `play block (expiration=...): url=.../2077-0.flac [0] -1069.7s Verve [1] -794.4s FJM [2] -289.4s Bill Miller` followed by `play engine.play startSeconds=nil (beginning)` then `song boundary crossed: 0 -> 2 at pos=0.02` — UI displays Bill Miller while audio plays Orbital from file offset 0.

## Test plan
- [x] `swift test` passes (343)
- [ ] Manual: pause for >1h, resume — verify fresh block fetched, no "stream ends prematurely"
- [ ] Manual: in conditions that previously triggered stale bootstrap (long-idle + restart), verify advance fires (look for `bootstrap returned stale block` log line)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI green, then merge ff-only**

```bash
gh pr checks --watch
git checkout main
git merge --ff-only claude/pr24-stale-block-recovery
git push origin main
```

- [ ] **Step 4: Update CLAUDE.md "Last merged" line + flip PR row to merged status**

```bash
# Open CLAUDE.md, change "🚧" → "✅" on PR 24 row, set "merged to main".
git add CLAUDE.md
git commit -m "docs: mark PR 24 merged"
git push origin main
```

---

## Acceptance criteria

- `BlockSongs.isStale(songs:cue:)` returns true exactly when `cue == 0 && !songs.isEmpty && songs.allSatisfy { ($0.elapsed ?? 0) <= 0 }`.
- `play(channelId:)` makes at most 2 API calls per invocation (bootstrap + at most one advance).
- `resume()` makes 0 engine calls when long-idle (only `play()` flow runs).
- Within-threshold resume (e.g. 30 min pause) still calls `engine.resume()` exactly once and emits no extra API calls.
- Total test count: 343 (was 334 + 5 BlockSongs + 2 stale-advance + 2 long-idle).
- No new public API on `PlaybackCoordinator` protocol.
