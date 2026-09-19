# PR 6: PlaybackCoordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `PlaybackCoordinator` Swift actor that orchestrates the playback session — fetches blocks via `RpApiClient`, drives `PlayerEngine`, tracks the current song within the block, emits `NowPlaying` updates via `AsyncStream`, and supports skip-forward, channel switch, and gapless block-to-block transitions per DESIGN.md §5.

**Architecture:** The coordinator owns the active session: current channel, current `GetBlock`, current song index, prefetched next block. It subscribes to `PlayerEngine.events` and translates `positionUpdate` events into song-boundary detection (using the per-song `duration` field). On `fileEnded(reason: .eof)` it swaps to the prefetched block to deliver gapless continuation. `play(channelId:)`, `skipForward()`, `changeChannel(to:)`, `pause()`, `resume()`, `stop()` are the public commands. Out-of-scope (deferred to a polish PR): network retry-with-backoff, hog-mode fallback, auth-expiry detection, block-expiration recovery after long pause.

**Tech Stack:** Swift 6.2 actors, `AsyncStream`, existing `RpApiClient` + `PlayerEngine` + `AppSettings` infrastructure.

---

## File map

**New source files:**
- `Sources/RPPlayer/Playback/NowPlaying.swift` — `NowPlaying` struct, `PlaybackCoordinatorError` enum
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — `PlaybackCoordinator` protocol + `LivePlaybackCoordinator` actor
- `Sources/RPPlayer/Playback/BlockSongs.swift` — pure helpers that turn `GetBlock` into an ordered `[PlayListSong]` and an array of cumulative `startsAtSeconds` boundaries

**New test files:**
- `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift` — programmable test double for PR 8 (`MiniPlayerView`)
- `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` — programmable `RpApiClient` test double
- `Tests/RPPlayerTests/Playback/BlockSongsTests.swift` — pure-function tests for ordering + boundary math
- `Tests/RPPlayerTests/Playback/NowPlayingTests.swift` — value-type semantics
- `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` — actor behavior using `MockPlayerEngine` and `MockRpApiClient`

**Modified:**
- (none)

---

## Public API surface

```swift
public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }

    func play(channelId: Int) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func skipForward() async throws
    func changeChannel(to channelId: Int) async throws
    func shutdown() async
}

public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: PlayListSong
    public let songIndexInBlock: Int
    public let blockDurationSeconds: Double
    public let songStartSeconds: Double
    public let songEndSeconds: Double
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case notPlaying
    case channelNotFound(channelId: Int)
    case blockHasNoSongs
    case engineError(message: String)
    case underlying(message: String)
}
```

`PlayListSong.duration` is in milliseconds (per `ApiModels.swift`). Boundary math converts to seconds throughout.

---

## Block / song model (DESIGN.md §5 mapping)

Per the live API fixture (`Tests/RPPlayerTests/Fixtures/Api/get_block.json`):
- `GetBlock.song` is `[String: PlayListSong]` keyed by integer-string indices ("0", "1", "2", "3").
- `GetBlock.cue` is the live-stream playhead offset in **milliseconds** — the coordinator seeks here after a fresh block load so the player tunes in to where everyone else is listening.
- Each `PlayListSong.duration` is **milliseconds**.
- The block URL is a single FLAC file containing all four songs concatenated.

The pure helpers in `BlockSongs.swift`:
- `BlockSongs.orderedSongs(from: GetBlock) -> [PlayListSong]` — sort entries by `Int(key)`, return values in order.
- `BlockSongs.startsAtSeconds(songs: [PlayListSong]) -> [Double]` — cumulative starts. For 4 songs of 60/120/90/100 s, returns `[0, 60, 180, 270]`.
- `BlockSongs.totalDurationSeconds(songs: [PlayListSong]) -> Double` — sum of all durations / 1000.
- `BlockSongs.indexOfSong(at positionSeconds: Double, in startsAtSeconds: [Double]) -> Int` — largest `i` such that `startsAtSeconds[i] <= positionSeconds`. Clamped to `[0, count - 1]`.

---

## Out-of-scope (deferred)

These are intentionally omitted from PR 6 to keep the PR shippable. They land in a follow-up "PR 6 polish" or as part of error-handling work alongside the UI:
- **Network retry-with-backoff on `get_block` / `info`.** The plan calls `apiClient.getBlock(...)` once; failures propagate as thrown errors.
- **Hog-mode fallback to shared mode.** When `setHogMode(true)` is called and libmpv reports an error, the coordinator currently re-throws.
- **Auth-expiry detection.** A `200 OK` with anonymous payload is treated as success; the keychain banner work happens later.
- **Block-expiration recovery after long pause.** If the user pauses past `block.expiration`, resume re-uses the stale block. Fix lands when we wire pause-duration tracking.

These are tracked as DESIGN.md §7 work in a future PR.

---

## Task 1: NowPlaying + PlaybackCoordinatorError + protocol

**Files:**
- Create: `Tests/RPPlayerTests/Playback/NowPlayingTests.swift`
- Create: `Sources/RPPlayer/Playback/NowPlaying.swift`
- Create: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (protocol only — actor lands in Task 4)

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Playback/NowPlayingTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class NowPlayingTests: XCTestCase {
    private func makeSong(id: String = "1", duration: Int = 180000) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "A", title: "T", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    func testEqualityRequiresAllFieldsMatch() {
        let song = makeSong()
        let np1 = NowPlaying(channelId: 0, song: song, songIndexInBlock: 1,
                             blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        let np2 = NowPlaying(channelId: 0, song: song, songIndexInBlock: 1,
                             blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        XCTAssertEqual(np1, np2)

        let differentChannel = NowPlaying(channelId: 1, song: song, songIndexInBlock: 1,
                                           blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
        XCTAssertNotEqual(np1, differentChannel)
    }

    func testCoordinatorErrorEquality() {
        XCTAssertEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 5)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.channelNotFound(channelId: 5),
            PlaybackCoordinatorError.channelNotFound(channelId: 6)
        )
        XCTAssertNotEqual(
            PlaybackCoordinatorError.notPlaying,
            PlaybackCoordinatorError.blockHasNoSongs
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter NowPlayingTests 2>&1 | head -10
```

Expected: compile error containing `cannot find type 'NowPlaying'`.

- [ ] **Step 3: Implement NowPlaying.swift**

Create `Sources/RPPlayer/Playback/NowPlaying.swift`:

```swift
import Foundation

public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: PlayListSong
    public let songIndexInBlock: Int
    public let blockDurationSeconds: Double
    public let songStartSeconds: Double
    public let songEndSeconds: Double

    public init(
        channelId: Int,
        song: PlayListSong,
        songIndexInBlock: Int,
        blockDurationSeconds: Double,
        songStartSeconds: Double,
        songEndSeconds: Double
    ) {
        self.channelId = channelId
        self.song = song
        self.songIndexInBlock = songIndexInBlock
        self.blockDurationSeconds = blockDurationSeconds
        self.songStartSeconds = songStartSeconds
        self.songEndSeconds = songEndSeconds
    }
}

public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    case notPlaying
    case channelNotFound(channelId: Int)
    case blockHasNoSongs
    case engineError(message: String)
    case underlying(message: String)
}
```

- [ ] **Step 4: Implement PlaybackCoordinator.swift (protocol only)**

Create `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:

```swift
import Foundation

public protocol PlaybackCoordinator: Sendable {
    var nowPlaying: NowPlaying? { get async }
    var nowPlayingUpdates: AsyncStream<NowPlaying> { get async }

    func play(channelId: Int) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
    func skipForward() async throws
    func changeChannel(to channelId: Int) async throws
    func shutdown() async
}
```

- [ ] **Step 5: Run tests to verify they pass**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter NowPlayingTests 2>&1 | tail -10
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/NowPlaying.swift \
        Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/NowPlayingTests.swift
git commit -m "feat(pr06): add NowPlaying value type and PlaybackCoordinator protocol"
```

---

## Task 2: BlockSongs pure helpers

**Files:**
- Create: `Tests/RPPlayerTests/Playback/BlockSongsTests.swift`
- Create: `Sources/RPPlayer/Playback/BlockSongs.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Playback/BlockSongsTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class BlockSongsTests: XCTestCase {
    private func song(id: String, duration: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "A", title: id, album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    private func block(songs: [(String, Int)], cue: Int = 0) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = song(id: pair.0, duration: pair.1)
        }
        return GetBlock(
            url: "https://example.com/x.flac",
            chan: "0", bitrate: nil, cue: cue, expiration: 0,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil, filename: nil
        )
    }

    func testOrderedSongsSortsByIntKey() {
        let b = GetBlock(
            url: "u", chan: "0", bitrate: nil, cue: 0, expiration: 0,
            length: nil, imageBase: "",
            song: [
                "2": song(id: "c", duration: 10000),
                "0": song(id: "a", duration: 30000),
                "1": song(id: "b", duration: 20000),
            ],
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil, filename: nil
        )
        let ordered = BlockSongs.orderedSongs(from: b)
        XCTAssertEqual(ordered.map(\.songId), ["a", "b", "c"])
    }

    func testStartsAtSecondsCumulativeFromZero() {
        let b = block(songs: [("a", 60_000), ("b", 120_000), ("c", 90_000), ("d", 100_000)])
        let starts = BlockSongs.startsAtSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(starts, [0, 60, 180, 270])
    }

    func testStartsAtSecondsForEmptyBlockIsEmpty() {
        let b = block(songs: [])
        let starts = BlockSongs.startsAtSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(starts, [])
    }

    func testTotalDurationSecondsSumsAllSongs() {
        let b = block(songs: [("a", 60_000), ("b", 120_000), ("c", 90_000), ("d", 100_000)])
        let total = BlockSongs.totalDurationSeconds(songs: BlockSongs.orderedSongs(from: b))
        XCTAssertEqual(total, 370.0, accuracy: 0.001)
    }

    func testIndexOfSongWithinFirstSong() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 0.0, in: starts), 0)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 30.0, in: starts), 0)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 59.999, in: starts), 0)
    }

    func testIndexOfSongCrossesBoundary() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 60.0, in: starts), 1)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 100.0, in: starts), 1)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 180.0, in: starts), 2)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 269.999, in: starts), 2)
        XCTAssertEqual(BlockSongs.indexOfSong(at: 270.0, in: starts), 3)
    }

    func testIndexOfSongNegativePositionClampsToZero() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: -5.0, in: starts), 0)
    }

    func testIndexOfSongPastEndClampsToLast() {
        let starts: [Double] = [0, 60, 180, 270]
        XCTAssertEqual(BlockSongs.indexOfSong(at: 99999.0, in: starts), 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter BlockSongsTests 2>&1 | head -10
```

Expected: compile error containing `cannot find 'BlockSongs'`.

- [ ] **Step 3: Implement BlockSongs.swift**

Create `Sources/RPPlayer/Playback/BlockSongs.swift`:

```swift
import Foundation

enum BlockSongs {
    static func orderedSongs(from block: GetBlock) -> [PlayListSong] {
        block.song
            .compactMap { (key, value) -> (Int, PlayListSong)? in
                guard let idx = Int(key) else { return nil }
                return (idx, value)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    static func startsAtSeconds(songs: [PlayListSong]) -> [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(songs.count)
        var running: Double = 0
        for song in songs {
            starts.append(running)
            running += Double(song.duration) / 1000.0
        }
        return starts
    }

    static func totalDurationSeconds(songs: [PlayListSong]) -> Double {
        songs.reduce(0.0) { $0 + Double($1.duration) / 1000.0 }
    }

    /// Largest `i` such that `startsAtSeconds[i] <= positionSeconds`. Returns `0`
    /// for negative positions and `count - 1` for positions past the last
    /// boundary; returns `0` for an empty array (caller must guard separately).
    static func indexOfSong(at positionSeconds: Double, in startsAtSeconds: [Double]) -> Int {
        guard !startsAtSeconds.isEmpty else { return 0 }
        if positionSeconds <= 0 { return 0 }
        var result = 0
        for (i, start) in startsAtSeconds.enumerated() where start <= positionSeconds {
            result = i
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter BlockSongsTests 2>&1 | tail -10
```

Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Playback/BlockSongs.swift \
        Tests/RPPlayerTests/Playback/BlockSongsTests.swift
git commit -m "feat(pr06): add BlockSongs helpers for song ordering and boundary math"
```

---

## Task 3: MockRpApiClient + MockPlaybackCoordinator test doubles

**Files:**
- Create: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`
- Create: `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`

`MockRpApiClient` is a programmable `RpApiClient` test double consumed by `LivePlaybackCoordinatorTests` (Task 4+). `MockPlaybackCoordinator` is consumed by future PR 8 (`MiniPlayerView`) — it's the coordinator-side analogue of `MockPlayerEngine`.

- [ ] **Step 1: Create MockRpApiClient**

Create `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:

```swift
import Foundation
@testable import RPPlayer

actor MockRpApiClient: RpApiClient {
    enum Call: Sendable, Equatable {
        case listChannels
        case getBlock(channel: Int, bitrate: Int, info: Bool)
        case info(songId: Int)
        case rate(songId: Int, rating: Int)
        case authState
    }

    private(set) var calls: [Call] = []

    /// Each call to `getBlock` consumes the next entry from this queue. If the
    /// queue is empty when `getBlock` is invoked, the call throws
    /// `RpApiError.network(URLError(.unknown))`.
    var blockResponses: [GetBlock] = []
    var listChannelsResponse: [Channel] = []
    var infoResponse: SongInfo?
    var ratingResponse: Rating = Rating(status: "ok", songId: nil, userId: nil, userRating: nil)
    var authStateResponse: Auth = Auth(userId: nil, postOk: nil, username: nil, level: nil,
                                        countryCode: nil, avatar: nil, privmsgNew: nil, status: nil)

    func setBlockResponses(_ responses: [GetBlock]) {
        self.blockResponses = responses
    }

    func setInfoResponse(_ response: SongInfo) {
        self.infoResponse = response
    }

    func listChannels() async throws -> [Channel] {
        calls.append(.listChannels)
        return listChannelsResponse
    }

    func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock {
        calls.append(.getBlock(channel: channel, bitrate: bitrate, info: info))
        guard !blockResponses.isEmpty else {
            throw RpApiError.network(URLError(.unknown))
        }
        return blockResponses.removeFirst()
    }

    func info(songId: Int) async throws -> SongInfo {
        calls.append(.info(songId: songId))
        if let r = infoResponse { return r }
        throw RpApiError.network(URLError(.unknown))
    }

    func rate(songId: Int, rating: Int) async throws -> Rating {
        calls.append(.rate(songId: songId, rating: rating))
        return ratingResponse
    }

    func authState() async throws -> Auth {
        calls.append(.authState)
        return authStateResponse
    }
}
```

- [ ] **Step 2: Create MockPlaybackCoordinator**

Create `Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift`:

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
    private var nextError: Error?

    func setNextError(_ error: Error) { nextError = error }
    func setNowPlaying(_ value: NowPlaying?) {
        current = value
        if let value = value {
            for c in continuations.values { c.yield(value) }
        }
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

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

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
    }
}
```

- [ ] **Step 3: Verify build is clean**

```
cd /Users/gergely/git/rp-player-pr06
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
```

Expected: `Build complete!`. Test count unchanged (no test for the mocks themselves).

- [ ] **Step 4: Commit**

```bash
git add Tests/RPPlayerTests/Playback/MockRpApiClient.swift \
        Tests/RPPlayerTests/Playback/MockPlaybackCoordinator.swift
git commit -m "test(pr06): add MockRpApiClient and MockPlaybackCoordinator test doubles"
```

---

## Task 4: LivePlaybackCoordinator scaffold + play(channelId:)

**Files:**
- Create: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (append the actor; protocol from Task 1 stays)

The actor takes constructor-injected dependencies: `RpApiClient`, `PlayerEngine`, `AppLogger`, plus a fixed bitrate (taken from `AppSettings.bitrate` at the call site). It does NOT subscribe to `ConfigStore.changes` in this PR — the bitrate is captured at coordinator creation time. Settings-driven hog/device updates lands later when `AppContainer` (PR 11) wires everything together.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class LivePlaybackCoordinatorTests: XCTestCase {
    private func makeSong(id: String, duration: Int) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "Artist-\(id)", title: "Title-\(id)", album: "Al", duration: duration,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    private func makeBlock(channel: String = "0", url: String = "https://example.com/0-0.flac",
                           cue: Int = 0,
                           songs: [(String, Int)]) -> GetBlock {
        var dict: [String: PlayListSong] = [:]
        for (idx, pair) in songs.enumerated() {
            dict[String(idx)] = makeSong(id: pair.0, duration: pair.1)
        }
        return GetBlock(
            url: url, chan: channel, bitrate: nil, cue: cue, expiration: 0,
            length: nil, imageBase: "img/", song: dict,
            channel: nil, event: nil, endEvent: nil, type: nil, ext: nil, filename: nil
        )
    }

    private func silentLogger() -> AppLogger {
        AppLogger(category: "PlaybackCoordinatorTests")
    }

    func testPlayCallsGetBlockAndEnginePlay() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls, [.getBlock(channel: 0, bitrate: 4, info: false)])
        XCTAssertEqual(engineCalls, [.play(url: URL(string: "https://example.com/0-0.flac")!)])
    }

    func testPlaySeeksToCueOffsetAfterFileLoad() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(cue: 90_000,
                              songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        try await coordinator.play(channelId: 0)
        // The coordinator subscribes to engine.events; simulate the engine
        // confirming the file has loaded so the coordinator can issue its seek.
        await engine.fire(.fileLoaded)
        // Hand the actor a chance to process the event.
        try await Task.sleep(nanoseconds: 50_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls, [
            .play(url: URL(string: "https://example.com/0-0.flac")!),
            .seek(seconds: 90.0),
        ])
    }

    func testPlayThrowsWhenBlockHasNoSongs() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        do {
            try await coordinator.play(channelId: 0)
            XCTFail("expected blockHasNoSongs")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .blockHasNoSongs)
        }
    }

    func testNowPlayingIsNilBeforePlay() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 4
        )
        let np = await coordinator.nowPlaying
        XCTAssertNil(np)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | head -10
```

Expected: compile error containing `cannot find 'LivePlaybackCoordinator'`.

- [ ] **Step 3: Implement LivePlaybackCoordinator scaffold**

Append to `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (keep the existing protocol):

```swift
public actor LivePlaybackCoordinator: PlaybackCoordinator {
    private let api: any RpApiClient
    private let engine: any PlayerEngine
    private let logger: any Logging
    private let bitrate: Int

    private var currentChannelId: Int?
    private var currentBlock: GetBlock?
    private var orderedSongs: [PlayListSong] = []
    private var startsAt: [Double] = []
    private var currentSongIndex: Int = 0
    private var currentPositionSeconds: Double = 0
    private var current: NowPlaying?
    private var continuations: [UUID: AsyncStream<NowPlaying>.Continuation] = [:]
    private var eventTask: Task<Void, Never>?
    private var pendingCueSeekSeconds: Double?
    private var isShutdown = false

    public init(
        api: any RpApiClient,
        engine: any PlayerEngine,
        logger: any Logging,
        bitrate: Int
    ) {
        self.api = api
        self.engine = engine
        self.logger = logger
        self.bitrate = bitrate
        Task { await self.startEventSubscription() }
    }

    public var nowPlaying: NowPlaying? { current }

    public var nowPlayingUpdates: AsyncStream<NowPlaying> {
        let id = UUID()
        return AsyncStream { continuation in
            if self.isShutdown { continuation.finish(); return }
            self.continuations[id] = continuation
            if let current = self.current { continuation.yield(current) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func play(channelId: Int) async throws {
        let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
        let songs = BlockSongs.orderedSongs(from: block)
        guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

        currentChannelId = channelId
        currentBlock = block
        orderedSongs = songs
        startsAt = BlockSongs.startsAtSeconds(songs: songs)
        currentSongIndex = 0
        currentPositionSeconds = 0
        pendingCueSeekSeconds = block.cue > 0 ? Double(block.cue) / 1000.0 : nil

        guard let url = URL(string: block.url) else {
            throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
        }
        do {
            try await engine.play(url: url)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }
        emitNowPlaying(forSongIndex: 0)
    }

    public func pause() async throws {
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func resume() async throws {
        guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
        do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    }

    public func stop() async throws {
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        current = nil
    }

    public func skipForward() async throws {
        // Stub — Task 6 fills this in.
        throw PlaybackCoordinatorError.notPlaying
    }

    public func changeChannel(to channelId: Int) async throws {
        // Stub — Task 7 fills this in.
        try await stop()
        try await play(channelId: channelId)
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        eventTask?.cancel()
        await eventTask?.value
        eventTask = nil
        try? await engine.stop()
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func startEventSubscription() async {
        let stream = await engine.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleEngineEvent(event)
            }
        }
    }

    private func handleEngineEvent(_ event: PlayerEvent) async {
        switch event {
        case .fileLoaded:
            if let cueSeconds = pendingCueSeekSeconds {
                pendingCueSeekSeconds = nil
                do {
                    try await engine.seek(to: cueSeconds)
                } catch {
                    logger.warn("post-load cue seek failed: \(error)")
                }
            }
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            // Task 5 will use this to advance the song index.
            _ = seconds
        case .fileEnded:
            // Task 7 (gapless prefetch) hooks here.
            break
        case .error(let message):
            logger.error("player engine reported error: \(message)")
        case .hogModeChanged, .outputDeviceChanged, .shutdown:
            break
        }
    }

    private func emitNowPlaying(forSongIndex idx: Int) {
        guard let channelId = currentChannelId, idx < orderedSongs.count else { return }
        let song = orderedSongs[idx]
        let songStart = startsAt[idx]
        let songEnd = songStart + Double(song.duration) / 1000.0
        let np = NowPlaying(
            channelId: channelId,
            song: song,
            songIndexInBlock: idx,
            blockDurationSeconds: BlockSongs.totalDurationSeconds(songs: orderedSongs),
            songStartSeconds: songStart,
            songEndSeconds: songEnd
        )
        current = np
        for c in continuations.values { c.yield(np) }
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Run full suite**

```
cd /Users/gergely/git/rp-player-pr06
swift test 2>&1 | tail -5
```

Expected: `Executed 81 tests, with 0 failures` (67 prior + 2 NowPlaying + 8 BlockSongs + 4 LivePlaybackCoordinator).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(pr06): LivePlaybackCoordinator scaffold with play/pause/resume/stop"
```

---

## Task 5: Song boundary advancement + NowPlaying emit on positionUpdate

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

When a `positionUpdate` event arrives, recompute the song index. If it changed, emit a fresh `NowPlaying`.

- [ ] **Step 1: Append the failing tests**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
extension LivePlaybackCoordinatorTests {
    func testPositionUpdateEmitsNowPlayingWhenSongBoundaryCrossed() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )

        let stream = await coordinator.nowPlayingUpdates
        let collector = Task { () -> [Int] in
            var seenIndexes: [Int] = []
            for await np in stream {
                seenIndexes.append(np.songIndexInBlock)
                if seenIndexes.count == 3 { return seenIndexes }
            }
            return seenIndexes
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 30.0))   // still song 0
        await engine.fire(.positionUpdate(seconds: 75.0))   // now song 1
        await engine.fire(.positionUpdate(seconds: 200.0))  // now song 2
        let result = await collector.value
        XCTAssertEqual(result, [0, 1, 2])
    }

    func testPositionUpdatesWithinSameSongDoNotReEmit() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )

        let stream = await coordinator.nowPlayingUpdates
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
                if count == 2 { return count }
            }
            return count
        }

        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 5.0))    // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 10.0))   // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 15.0))   // song 0 — no re-emit
        await engine.fire(.positionUpdate(seconds: 100.0))  // song 1 — emits
        let result = await collector.value
        // First emission is the initial play() emit (song 0); second is the song 1 boundary cross.
        XCTAssertEqual(result, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter "LivePlaybackCoordinatorTests/testPositionUpdateEmitsNowPlayingWhenSongBoundaryCrossed|LivePlaybackCoordinatorTests/testPositionUpdatesWithinSameSongDoNotReEmit" 2>&1 | tail -15
```

Expected: tests run but fail (the `positionUpdate` arm in `handleEngineEvent` is currently a no-op).

- [ ] **Step 3: Wire boundary detection in the engine-event handler**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace the `.positionUpdate` arm of `handleEngineEvent`:

```swift
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            guard !startsAt.isEmpty else { return }
            let newIndex = BlockSongs.indexOfSong(at: seconds, in: startsAt)
            if newIndex != currentSongIndex && newIndex < orderedSongs.count {
                currentSongIndex = newIndex
                emitNowPlaying(forSongIndex: newIndex)
            }
```

- [ ] **Step 4: Run all coordinator tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Run full suite**

```
cd /Users/gergely/git/rp-player-pr06
swift test 2>&1 | tail -5
```

Expected: `Executed 83 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(pr06): emit NowPlaying on song boundary via positionUpdate"
```

---

## Task 6: skipForward (within block + cross-block)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

`skipForward()` semantics:
- If there is a next song in the current block, seek the engine to `startsAt[currentSongIndex + 1] + 0.05` (50 ms epsilon to ensure the boundary is unambiguously crossed).
- If we are on the last song in the block, fetch the next block on the same channel and `play(url:)` it. This is effectively a fresh `play(channelId:)` flow but bypasses the cue seek (start from offset 0).
- Throw `notPlaying` if no current block.

- [ ] **Step 1: Append failing tests**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
extension LivePlaybackCoordinatorTests {
    func testSkipForwardWithinBlockSeeksToNextSongStart() async throws {
        let api = MockRpApiClient()
        let block = makeBlock(songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)])
        await api.setBlockResponses([block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        try await coordinator.skipForward()
        let calls = await engine.recordedCalls()
        // Expect: play, then seek to 60.05 (start of song 1 + epsilon).
        XCTAssertEqual(calls.last, .seek(seconds: 60.05))
    }

    func testSkipForwardOnLastSongFetchesNextBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-1.flac",
            songs: [("s1", 60_000), ("s2", 120_000), ("s3", 90_000), ("s4", 100_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-2.flac",
            songs: [("s5", 60_000), ("s6", 60_000), ("s7", 60_000), ("s8", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        // Move to last song.
        await engine.fire(.positionUpdate(seconds: 280.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coordinator.skipForward()
        let apiCalls = await api.calls
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(apiCalls.count, 2)
        XCTAssertEqual(apiCalls.last, .getBlock(channel: 0, bitrate: 0, info: false))
        // Last engine call should be a play() of the new URL.
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-2.flac")!))
    }

    func testSkipForwardWithoutCurrentBlockThrows() async throws {
        let api = MockRpApiClient()
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        do {
            try await coordinator.skipForward()
            XCTFail("expected notPlaying")
        } catch let error as PlaybackCoordinatorError {
            XCTAssertEqual(error, .notPlaying)
        }
    }
}
```

- [ ] **Step 2: Run failing tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter "LivePlaybackCoordinatorTests/testSkipForwardWithinBlockSeeksToNextSongStart|LivePlaybackCoordinatorTests/testSkipForwardOnLastSongFetchesNextBlock|LivePlaybackCoordinatorTests/testSkipForwardWithoutCurrentBlockThrows" 2>&1 | tail -15
```

Expected: 3 failures (current `skipForward()` is the stub from Task 4 that always throws `notPlaying` — only the third test passes).

- [ ] **Step 3: Replace `skipForward` body**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, replace the stub:

```swift
    public func skipForward() async throws {
        guard currentBlock != nil, !orderedSongs.isEmpty,
              let channelId = currentChannelId else {
            throw PlaybackCoordinatorError.notPlaying
        }
        let nextIndex = currentSongIndex + 1
        if nextIndex < orderedSongs.count {
            // Seek slightly past the boundary so positionUpdate trips into the new song.
            let target = startsAt[nextIndex] + 0.05
            do {
                try await engine.seek(to: target)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            currentSongIndex = nextIndex
            currentPositionSeconds = target
            emitNowPlaying(forSongIndex: nextIndex)
        } else {
            // Past the last song — fetch a fresh block from the same channel
            // and play from offset 0 (no cue tune-in: user's intent is "next block").
            let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
            let songs = BlockSongs.orderedSongs(from: block)
            guard !songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }
            currentBlock = block
            orderedSongs = songs
            startsAt = BlockSongs.startsAtSeconds(songs: songs)
            currentSongIndex = 0
            currentPositionSeconds = 0
            pendingCueSeekSeconds = nil
            guard let url = URL(string: block.url) else {
                throw PlaybackCoordinatorError.engineError(message: "invalid block url: \(block.url)")
            }
            do {
                try await engine.play(url: url)
            } catch {
                throw PlaybackCoordinatorError.engineError(message: String(describing: error))
            }
            emitNowPlaying(forSongIndex: 0)
        }
    }
```

- [ ] **Step 4: Run all coordinator tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Run full suite**

```
cd /Users/gergely/git/rp-player-pr06
swift test 2>&1 | tail -5
```

Expected: `Executed 86 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(pr06): skipForward within and across block boundaries"
```

---

## Task 7: Block prefetch + gapless transition on EOF

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

DESIGN.md §5.6: "When `currentSongIndex == 3` and time-to-end < 10 s, coordinator prefetches the next block." On `MPV_EVENT_END_FILE` with reason `.eof`, swap to the prefetched block by calling `engine.play(url:)` with the new block's URL.

Concretely:
1. On every `positionUpdate`, check whether `currentSongIndex == orderedSongs.count - 1` AND `(blockTotalSeconds - position) < 10` AND `prefetchedBlock == nil` AND `prefetchTask == nil`. If yes, kick off `Task { try? await api.getBlock(...) }` that stores the result in `prefetchedBlock`.
2. On `fileEnded(reason: .eof)`: if `prefetchedBlock != nil`, swap to it (no cue seek, fresh start). Otherwise, just clear current state.
3. On `stop` or `changeChannel`, cancel any in-flight prefetch and discard `prefetchedBlock`.

- [ ] **Step 1: Append failing tests**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
extension LivePlaybackCoordinatorTests {
    func testPrefetchTriggeredInLastSongFinalSeconds() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        // Move to last song with < 10s remaining (block total = 240s).
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "second getBlock call should have been triggered as prefetch")
    }

    func testPrefetchOnlyHappensOncePerBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.fire(.positionUpdate(seconds: 235.0))
        await engine.fire(.positionUpdate(seconds: 238.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        let apiCalls = await api.calls
        XCTAssertEqual(apiCalls.count, 2, "prefetch should happen at most once per block")
    }

    func testEndOfFileSwapsToPrefetchedBlock() async throws {
        let api = MockRpApiClient()
        let firstBlock = makeBlock(
            url: "https://example.com/0-A.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let secondBlock = makeBlock(
            url: "https://example.com/0-B.flac",
            songs: [("b1", 60_000), ("b2", 60_000), ("b3", 60_000), ("b4", 60_000)]
        )
        await api.setBlockResponses([firstBlock, secondBlock])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        // Trigger prefetch.
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        // File ends with EOF.
        await engine.fire(.fileEnded(reason: .eof))
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/0-B.flac")!))
    }
}
```

- [ ] **Step 2: Run failing tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter "LivePlaybackCoordinatorTests/testPrefetchTriggeredInLastSongFinalSeconds|LivePlaybackCoordinatorTests/testPrefetchOnlyHappensOncePerBlock|LivePlaybackCoordinatorTests/testEndOfFileSwapsToPrefetchedBlock" 2>&1 | tail -15
```

Expected: 3 failures (no prefetch logic exists yet).

- [ ] **Step 3: Add prefetch + EOF swap**

Add two private stored properties to `LivePlaybackCoordinator`:

```swift
    private var prefetchedBlock: GetBlock?
    private var prefetchTask: Task<Void, Never>?
```

Replace the `.positionUpdate` arm in `handleEngineEvent` to also call a `maybeStartPrefetch()` helper:

```swift
        case .positionUpdate(let seconds):
            currentPositionSeconds = seconds
            guard !startsAt.isEmpty else { return }
            let newIndex = BlockSongs.indexOfSong(at: seconds, in: startsAt)
            if newIndex != currentSongIndex && newIndex < orderedSongs.count {
                currentSongIndex = newIndex
                emitNowPlaying(forSongIndex: newIndex)
            }
            maybeStartPrefetch()
```

Replace the `.fileEnded` arm:

```swift
        case .fileEnded(let reason):
            if case .eof = reason {
                await swapToPrefetchedBlockIfAvailable()
            }
```

Add the three private helpers near the other private methods:

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

        let api = self.api
        let bitrate = self.bitrate
        prefetchTask = Task { [weak self] in
            let result = try? await api.getBlock(channel: channelId, bitrate: bitrate, info: false)
            await self?.absorbPrefetchResult(result)
        }
    }

    private func absorbPrefetchResult(_ block: GetBlock?) {
        prefetchTask = nil
        if let block = block, BlockSongs.orderedSongs(from: block).isEmpty == false {
            prefetchedBlock = block
        }
    }

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
        prefetchedBlock = nil
        let songs = BlockSongs.orderedSongs(from: block)
        currentBlock = block
        orderedSongs = songs
        startsAt = BlockSongs.startsAtSeconds(songs: songs)
        currentSongIndex = 0
        currentPositionSeconds = 0
        pendingCueSeekSeconds = nil
        guard let url = URL(string: block.url) else {
            logger.error("prefetched block had invalid url: \(block.url)")
            return
        }
        do {
            try await engine.play(url: url)
        } catch {
            logger.error("failed to play prefetched block: \(error)")
            return
        }
        emitNowPlaying(forSongIndex: 0)
    }
```

Update `stop()` to also clear prefetch state:

```swift
    public func stop() async throws {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        do { try await engine.stop() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
        currentBlock = nil
        orderedSongs = []
        startsAt = []
        currentSongIndex = 0
        currentPositionSeconds = 0
        current = nil
    }
```

- [ ] **Step 4: Run all coordinator tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10
```

Expected: 12 tests, 0 failures.

- [ ] **Step 5: Run full suite**

```
cd /Users/gergely/git/rp-player-pr06
swift test 2>&1 | tail -5
```

Expected: `Executed 89 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(pr06): block prefetch and gapless EOF transition"
```

---

## Task 8: changeChannel hardening + CLAUDE.md updates

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`
- Modify: `CLAUDE.md`

The Task 4 stub `changeChannel(to:)` does `stop` + `play`, which works but doesn't cancel an in-flight prefetch from the previous channel. Tighten it. Also: add CLAUDE.md updates for the PR table, post-PR6 test count, and the prefetch / 10s threshold technical decision.

- [ ] **Step 1: Append failing test**

Append to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
extension LivePlaybackCoordinatorTests {
    func testChangeChannelCancelsPrefetchFromPreviousChannel() async throws {
        let api = MockRpApiClient()
        let chan0Block = makeBlock(
            url: "https://example.com/chan0.flac",
            songs: [("a1", 60_000), ("a2", 60_000), ("a3", 60_000), ("a4", 60_000)]
        )
        let chan1Block = makeBlock(
            channel: "1",
            url: "https://example.com/chan1.flac",
            songs: [("c1", 60_000), ("c2", 60_000), ("c3", 60_000), ("c4", 60_000)]
        )
        await api.setBlockResponses([chan0Block, chan1Block])
        let engine = MockPlayerEngine()
        let coordinator = LivePlaybackCoordinator(
            api: api, engine: engine, logger: silentLogger(), bitrate: 0
        )
        try await coordinator.play(channelId: 0)
        // Trigger prefetch on channel 0 last song.
        await engine.fire(.positionUpdate(seconds: 232.0))
        try await Task.sleep(nanoseconds: 50_000_000)
        // Switch channels.
        try await coordinator.changeChannel(to: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let engineCalls = await engine.recordedCalls()
        // Expect: play(chan0), stop, play(chan1).
        XCTAssertEqual(engineCalls.last, .play(url: URL(string: "https://example.com/chan1.flac")!))
        // The prefetch task either finished and was discarded, or never wrote
        // its result. Either way: no extra play() of chan0's hypothetical
        // prefetched block should appear after the chan1 play.
        let chan1PlayIndex = engineCalls.lastIndex(of: .play(url: URL(string: "https://example.com/chan1.flac")!))
        XCTAssertEqual(chan1PlayIndex, engineCalls.count - 1, "chan1 play must be the final engine call")
    }
}
```

- [ ] **Step 2: Replace `changeChannel(to:)` body**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:

```swift
    public func changeChannel(to channelId: Int) async throws {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedBlock = nil
        try await stop()
        try await play(channelId: channelId)
    }
```

(Note: `stop()` already clears prefetch state, but doing it here too is defensive against a future where `stop()` semantics change.)

- [ ] **Step 3: Run all coordinator tests**

```
cd /Users/gergely/git/rp-player-pr06
swift test --filter LivePlaybackCoordinatorTests 2>&1 | tail -10
```

Expected: 13 tests, 0 failures.

- [ ] **Step 4: Update CLAUDE.md**

Replace the PR table rows for 5b and 6:

```markdown
| 5b  | merged to main | ✅      | PlayerEngine (libmpv Swift actor)                                 |
| 6   | **next**       | ⬜      | PlaybackCoordinator                                               |
```

(The "next" pointer moves to PR 7 after this PR merges.)

Replace the "PR 5b scope" paragraph with:

```markdown
PR 6 scope: orchestrate playback via `LivePlaybackCoordinator` actor — fetches blocks, drives `PlayerEngine`, tracks song boundary, prefetches the next block when `currentSongIndex == lastIndex` and remaining time < 10 s, and swaps gaplessly on EOF. Out of scope (deferred to a follow-up PR): network retry-with-backoff, hog-mode fallback, auth-expiry detection, block-expiration recovery after long pause.
```

Append to "Key technical decisions":

```markdown
- `LivePlaybackCoordinator` triggers the next-block prefetch when `currentSongIndex == orderedSongs.count - 1` AND `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The 10-second window matches DESIGN.md §5.6 and gives the network round-trip plenty of margin before EOF. Only one prefetch per block (guarded by `prefetchedBlock == nil && prefetchTask == nil`).
- `LivePlaybackCoordinator.play(channelId:)` issues the cue tune-in by waiting for `PlayerEvent.fileLoaded`, then calling `engine.seek(to: cueSeconds)`. The cue seek is bypassed for prefetch-driven block swaps and for skip-forward-past-last-song — both intentionally start the new block from offset 0.
```

Append to "Test counts by PR":

```markdown
- After PR 6: 90 tests
```

- [ ] **Step 5: Run full suite**

```
cd /Users/gergely/git/rp-player-pr06
swift test 2>&1 | tail -5
```

Expected: `Executed 90 tests, with 0 failures`.

- [ ] **Step 6: Commit code change**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(pr06): cancel prefetch on changeChannel"
```

- [ ] **Step 7: Commit CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs(pr06): record PlaybackCoordinator notes and post-PR6 test count"
```

---

## Self-review

**Spec coverage check (DESIGN.md §4 + §5):**

| Requirement | Covered by |
|---|---|
| Owns active session: channel, block, song index | Task 4 stored properties |
| `play(channelId:)` fetches block, drives engine | Task 4 |
| Tune in to live (cue offset) | Task 4 (`pendingCueSeekSeconds`, `.fileLoaded` handler) |
| Track song boundary using `block.songs[i].duration` + libmpv position | Task 5 |
| Emit `NowPlaying` on song-start | Task 4 (initial play) + Task 5 (boundary cross) |
| `skipForward` within block | Task 6 |
| `skipForward` past last song fetches new block | Task 6 |
| `changeChannel` stops + fetches new block | Task 4 stub + Task 8 hardening |
| Prefetch next block when in last song with < 10 s remaining | Task 7 |
| Gapless transition on EOF | Task 7 |
| `pause`, `resume`, `stop` | Task 4 |
| Test double for PR 8 (`MiniPlayerView`) | Task 3 (`MockPlaybackCoordinator`) |
| Out-of-scope items (retry, hog fallback, auth, block expiration) | Documented in plan header |

**Placeholder scan:** searched for "TBD", "implement later", "appropriate", "similar to". No planning placeholders found. The Task 4 stub bodies for `skipForward` and `changeChannel` are sentinel-throwing; Tasks 6 and 8 replace them — same TDD pattern that worked in PR 5b.

**Type/signature consistency:**
- `PlaybackCoordinator` protocol: defined Task 1, implemented in Tasks 4–8. Method signatures match. ✓
- `NowPlaying` constructor: 6 named arguments `(channelId, song, songIndexInBlock, blockDurationSeconds, songStartSeconds, songEndSeconds)`, used identically across tests + impl. ✓
- `BlockSongs.orderedSongs(from:)`, `startsAtSeconds(songs:)`, `totalDurationSeconds(songs:)`, `indexOfSong(at:in:)` all referenced consistently in Tasks 2, 4, 5, 6, 7. ✓
- `MockPlayerEngine.fire(_:)` used to inject events in Tasks 4–8. ✓
- `MockRpApiClient.setBlockResponses(_:)` queues responses; `getBlock` consumes them in FIFO order. ✓

**Test-count math:**

| After | Tests | Delta |
|---|---|---|
| PR 5b | 67 | — |
| Task 1 | 69 | +2 (NowPlaying) |
| Task 2 | 77 | +8 (BlockSongs) |
| Task 3 | 77 | — |
| Task 4 | 81 | +4 (LivePlaybackCoordinator scaffold) |
| Task 5 | 83 | +2 (boundary) |
| Task 6 | 86 | +3 (skipForward) |
| Task 7 | 89 | +3 (prefetch + EOF) |
| Task 8 | 90 | +1 (changeChannel) |

Total after PR 6: **90 tests**. Hmm — I wrote 89 in the plan body. Let me reconcile: 67 + 2 + 8 + 4 + 2 + 3 + 3 + 1 = 90. The Task 5 + 7 + 8 step counts in the plan body said "Executed 83 / 89 / 89" — Task 8's "Executed 89" is wrong. **Fix:** update Task 8 Step 5 expected output to `Executed 90 tests`, and Task 8's CLAUDE.md update to `After PR 6: 90 tests`.

(Inline fix applied below.)

**Risk register:**
- The boundary detection relies on libmpv reporting accurate `time-pos` events. mpv normally fires these at ~1 Hz; song boundary detection has up to ~1 s of delay. Acceptable for a UI that updates "what's playing now".
- The prefetch test waits 100 ms for the prefetch task to complete. On a slow CI runner this could flake. Tolerated for now (DESIGN.md §11.4 milestone 12 will figure out CI strategy).
- `swapToPrefetchedBlockIfAvailable` swallows `engine.play` errors (logs and returns). A future polish PR should surface these via the `nowPlayingUpdates` stream so the UI can show an error banner.
