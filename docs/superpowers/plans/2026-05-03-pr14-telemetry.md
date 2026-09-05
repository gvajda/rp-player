# PR 14 — Telemetry Endpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fire `api/update_history` on every music-song start and `api/update_pause` on pause resume so the RP backend tracks listening position and cross-session resume works correctly.

**Architecture:** Two new fire-and-forget methods on `RpApiClient` use a shared `fire(path:query:)` helper in `LiveRpApiClient` that skips JSON decode. `LivePlaybackCoordinator` gains a `clock` injection, two pause-tracking fields, and a private `fireSongStartTelemetry` helper wired at five trigger points. All telemetry dispatches are `Task.detached { try? await ... }` — errors are dropped silently. `MockRpApiClient` captures calls in typed arrays so coordinator tests can verify fire counts and params.

**Tech Stack:** Swift 6.2, Swift Testing (`XCTest`-style), `StubURLProtocol` for client URL tests, `MockRpApiClient` + `MockPlayerEngine` for coordinator tests.

---

## File Map

| File | Change |
|---|---|
| `Sources/RPPlayer/Api/RpApiClient.swift` | Add `updateHistory` + `updatePause` to protocol; add `fire(path:query:)` + impls to `LiveRpApiClient` |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Add `clock`, `pausedAt`, `pausePositionMs`; add `fireSongStartTelemetry(song:channelId:ppm:)`; wire five trigger sites + pause/resume |
| `Tests/RPPlayerTests/Playback/MockRpApiClient.swift` | Add `UpdateHistoryArgs`, `UpdatePauseArgs`, `updateHistoryCalls`, `updatePauseCalls` capture |
| `Tests/RPPlayerTests/Api/RpApiClientTests.swift` | Add 3 URL-construction tests |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` | Add ~12 telemetry coordinator tests |

---

## Task 1: Add protocol methods + update mock (compile gate)

**Files:**
- Modify: `Sources/RPPlayer/Api/RpApiClient.swift:7-14`
- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`

- [ ] **Step 1: Extend `RpApiClient` protocol**

In `Sources/RPPlayer/Api/RpApiClient.swift`, extend the protocol:

```swift
public protocol RpApiClient: Sendable {
    func listChannels() async throws -> [Channel]
    func play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
              audioType: String?, episodeId: Int?, sliceNum: String?) async throws -> GetBlock
    func info(songId: Int) async throws -> SongInfo
    func rate(songId: Int, rating: Int) async throws -> Rating
    func authState() async throws -> Auth
    func updateHistory(
        songId: String, chan: Int, event: String, audioType: String,
        sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int,
        pauseFlag: Bool
    ) async throws
    func updatePause(
        songId: String, chan: Int, event: String, audioType: String,
        sliceNum: String?, pauseDurationMillis: Int, playtimeSecs: Int
    ) async throws
}
```

- [ ] **Step 2: Add capture types and conformance to `MockRpApiClient`**

At the top of `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`, add the arg structs and two capture arrays to the `MockRpApiClient` actor:

```swift
struct UpdateHistoryArgs: Sendable, Equatable {
    let songId: String
    let chan: Int
    let event: String
    let audioType: String
    let sliceNum: String?
    let playPositionMillis: Int
    let playtimeSecs: Int
    let pauseFlag: Bool
}

struct UpdatePauseArgs: Sendable, Equatable {
    let songId: String
    let chan: Int
    let event: String
    let audioType: String
    let sliceNum: String?
    let pauseDurationMillis: Int
    let playtimeSecs: Int
}
```

Inside `MockRpApiClient`, add after the existing `private(set) var playCancellations`:

```swift
private(set) var updateHistoryCalls: [UpdateHistoryArgs] = []
private(set) var updatePauseCalls: [UpdatePauseArgs] = []
```

Add the two conformance methods inside `MockRpApiClient`:

```swift
func updateHistory(
    songId: String, chan: Int, event: String, audioType: String,
    sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int,
    pauseFlag: Bool
) async throws {
    updateHistoryCalls.append(UpdateHistoryArgs(
        songId: songId, chan: chan, event: event, audioType: audioType,
        sliceNum: sliceNum, playPositionMillis: playPositionMillis,
        playtimeSecs: playtimeSecs, pauseFlag: pauseFlag
    ))
}

func updatePause(
    songId: String, chan: Int, event: String, audioType: String,
    sliceNum: String?, pauseDurationMillis: Int, playtimeSecs: Int
) async throws {
    updatePauseCalls.append(UpdatePauseArgs(
        songId: songId, chan: chan, event: event, audioType: audioType,
        sliceNum: sliceNum, pauseDurationMillis: pauseDurationMillis,
        playtimeSecs: playtimeSecs
    ))
}
```

- [ ] **Step 3: Verify it compiles**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!` (or errors about `NoopRpApiClient` / other conformances — fix those by adding stub methods that `throw RpApiError.network(URLError(.unknown))`)

- [ ] **Step 4: Run existing tests to confirm no regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed N tests, with 0 failures` (251 tests pass).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift Tests/RPPlayerTests/Playback/MockRpApiClient.swift
git commit -m "feat(api): add updateHistory + updatePause to RpApiClient protocol + mock"
```

---

## Task 2: API client `fire()` helper + `updateHistory` / `updatePause` implementations + URL tests

**Files:**
- Modify: `Sources/RPPlayer/Api/RpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`

- [ ] **Step 1: Write the three failing URL tests**

Add to `RpApiClientTests` in `Tests/RPPlayerTests/Api/RpApiClientTests.swift`:

```swift
func testUpdateHistoryBuildsCorrectURL() async throws {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/update_history"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "episode_id", value: "0"),
        URLQueryItem(name: "event", value: "2869397"),
        URLQueryItem(name: "event_num", value: "undefined"),
        URLQueryItem(name: "play_position_millis", value: "3194"),
        URLQueryItem(name: "player_id", value: "rp3_test-player"),
        URLQueryItem(name: "playtime_secs", value: "1777746855"),
        URLQueryItem(name: "slice_num", value: "5"),
        URLQueryItem(name: "song_id", value: "20093"),
        URLQueryItem(name: "source", value: "24"),
        URLQueryItem(name: "time_relative", value: "-3"),
        URLQueryItem(name: "type", value: "M"),
    ]
    StubURLProtocol.register(url: components.url!, body: Data())
    let client = makeClient(playerId: "rp3_test-player")
    try await client.updateHistory(
        songId: "20093", chan: 0, event: "2869397", audioType: "M",
        sliceNum: "5", playPositionMillis: 3194, playtimeSecs: 1777746855,
        pauseFlag: false
    )
    // If the URL doesn't match, StubURLProtocol throws network error — test fails.
}

func testUpdateHistoryWithPauseFlagAddsParam() async throws {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/update_history"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "episode_id", value: "0"),
        URLQueryItem(name: "event", value: "2869397"),
        URLQueryItem(name: "event_num", value: "undefined"),
        URLQueryItem(name: "pause", value: "1"),
        URLQueryItem(name: "play_position_millis", value: "21233"),
        URLQueryItem(name: "player_id", value: "rp3_test-player"),
        URLQueryItem(name: "playtime_secs", value: "1777746905"),
        URLQueryItem(name: "slice_num", value: "6"),
        URLQueryItem(name: "song_id", value: "55464"),
        URLQueryItem(name: "source", value: "24"),
        URLQueryItem(name: "time_relative", value: "-21"),
        URLQueryItem(name: "type", value: "M"),
    ]
    StubURLProtocol.register(url: components.url!, body: Data())
    let client = makeClient(playerId: "rp3_test-player")
    try await client.updateHistory(
        songId: "55464", chan: 0, event: "2869397", audioType: "M",
        sliceNum: "6", playPositionMillis: 21233, playtimeSecs: 1777746905,
        pauseFlag: true
    )
}

func testUpdatePauseBuildsCorrectURL() async throws {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/update_pause"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "episode_id", value: "0"),
        URLQueryItem(name: "event", value: "2869397"),
        URLQueryItem(name: "event_num", value: "undefined"),
        URLQueryItem(name: "pause", value: "21233"),
        URLQueryItem(name: "player_id", value: "rp3_test-player"),
        URLQueryItem(name: "playtime_secs", value: "1777746899"),
        URLQueryItem(name: "slice_num", value: "6"),
        URLQueryItem(name: "song_id", value: "55464"),
        URLQueryItem(name: "source", value: "24"),
        URLQueryItem(name: "type", value: "M"),
    ]
    StubURLProtocol.register(url: components.url!, body: Data())
    let client = makeClient(playerId: "rp3_test-player")
    try await client.updatePause(
        songId: "55464", chan: 0, event: "2869397", audioType: "M",
        sliceNum: "6", pauseDurationMillis: 21233, playtimeSecs: 1777746899
    )
}
```

- [ ] **Step 2: Run the three new tests to confirm they fail**

```bash
swift test --filter "testUpdateHistory|testUpdatePause" 2>&1 | tail -10
```

Expected: 3 failures — `URLError` or test not found (since method not implemented yet).

- [ ] **Step 3: Add `fire(path:query:)` helper to `LiveRpApiClient`**

Add after the existing `get<T:Decodable>` method in `Sources/RPPlayer/Api/RpApiClient.swift`:

```swift
private func fire(path: String, query: [String: String]) async throws {
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
        throw RpApiError.network(URLError(.badURL))
    }
    if !query.isEmpty {
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else {
        throw RpApiError.network(URLError(.badURL))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    let cookie = await cookieProvider.currentCookie()
    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    let cookieNames = cookie.map { Self.cookieNameSummary($0) } ?? "none"
    logger.debug("GET \(url.absoluteString) cookies=[\(cookieNames)]")
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch let error as URLError {
        logger.error("Network failure for \(url.absoluteString): \(error)")
        throw RpApiError.network(error)
    } catch {
        logger.error("Unknown network error for \(url.absoluteString): \(error)")
        throw RpApiError.underlying(error)
    }
    guard let http = response as? HTTPURLResponse else {
        throw RpApiError.invalidResponse(statusCode: -1, body: data)
    }
    guard (200..<300).contains(http.statusCode) else {
        let bodyPreview = Self.bodyPreview(data)
        logger.error("HTTP \(http.statusCode) for \(url.absoluteString) cookies=[\(cookieNames)] — body: \(bodyPreview)")
        throw RpApiError.invalidResponse(statusCode: http.statusCode, body: data)
    }
}
```

- [ ] **Step 4: Add `updateHistory` and `updatePause` to `LiveRpApiClient`**

Add before `fire(path:query:)` in `Sources/RPPlayer/Api/RpApiClient.swift`:

```swift
public func updateHistory(
    songId: String, chan: Int, event: String, audioType: String,
    sliceNum: String?, playPositionMillis: Int, playtimeSecs: Int,
    pauseFlag: Bool
) async throws {
    let seconds = Int((Double(playPositionMillis) / 1000.0).rounded())
    var query: [String: String] = [
        "chan": String(chan),
        "episode_id": "0",
        "event": event,
        "event_num": "undefined",
        "play_position_millis": String(playPositionMillis),
        "playtime_secs": String(playtimeSecs),
        "slice_num": sliceNum ?? "null",
        "song_id": songId,
        "source": "24",
        "time_relative": "-\(seconds)",
        "type": audioType,
    ]
    if pauseFlag { query["pause"] = "1" }
    if let playerId { query["player_id"] = playerId }
    try await fire(path: "api/update_history", query: query)
}

public func updatePause(
    songId: String, chan: Int, event: String, audioType: String,
    sliceNum: String?, pauseDurationMillis: Int, playtimeSecs: Int
) async throws {
    var query: [String: String] = [
        "chan": String(chan),
        "episode_id": "0",
        "event": event,
        "event_num": "undefined",
        "pause": String(pauseDurationMillis),
        "playtime_secs": String(playtimeSecs),
        "slice_num": sliceNum ?? "null",
        "song_id": songId,
        "source": "24",
        "type": audioType,
    ]
    if let playerId { query["player_id"] = playerId }
    try await fire(path: "api/update_pause", query: query)
}
```

- [ ] **Step 5: Run the three URL tests — confirm they pass**

```bash
swift test --filter "testUpdateHistory|testUpdatePause" 2>&1 | tail -10
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Run all tests to confirm no regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 254 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift Tests/RPPlayerTests/Api/RpApiClientTests.swift
git commit -m "feat(api): implement updateHistory + updatePause via fire() helper"
```

---

## Task 3: Coordinator — add clock + pause state + `fireSongStartTelemetry` (compile gate)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

- [ ] **Step 1: Add `clock` injection and pause state to `LivePlaybackCoordinator`**

After `private let bitrateProvider` (line 20), add:

```swift
private let clock: @Sendable () -> Date
private var pausedAt: Date? = nil
private var pausePositionMs: Int = 0
```

Update `init` to accept `clock` with a default:

```swift
public init(
    api: any RpApiClient,
    engine: any PlayerEngine,
    logger: any Logging,
    bitrateProvider: @escaping @Sendable () async -> Int,
    clock: @escaping @Sendable () -> Date = { Date() }
) {
    self.api = api
    self.engine = engine
    self.logger = logger
    self.bitrateProvider = bitrateProvider
    self.clock = clock
}
```

- [ ] **Step 2: Add `fireSongStartTelemetry(song:channelId:ppm:)` helper**

Add after `emitNowPlaying(forSongIndex:)` in `PlaybackCoordinator.swift`:

```swift
private func fireSongStartTelemetry(song: PlayListSong, channelId: Int, ppm: Int? = nil) {
    guard song.type != "P" else { return }
    guard currentSongIndex < startsAt.count else { return }
    let resolvedPpm = ppm ?? max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
    let ts = Int(clock().timeIntervalSince1970)
    let songId = song.songId
    let event = song.event ?? ""
    let audioType = song.type ?? "M"
    let sliceNum = song.sliceNum
    let api = self.api
    Task.detached {
        try? await api.updateHistory(
            songId: songId, chan: channelId, event: event, audioType: audioType,
            sliceNum: sliceNum, playPositionMillis: resolvedPpm, playtimeSecs: ts,
            pauseFlag: false
        )
    }
}
```

- [ ] **Step 3: Verify it compiles and tests still pass**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
swift test 2>&1 | tail -5
```

Expected: `Build complete!`, `Executed 254 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git commit -m "feat(coord): add clock injection, pause state, fireSongStartTelemetry helper"
```

---

## Task 4: Song-start telemetry on bootstrap and channel switch

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing bootstrap telemetry test**

Add a new `extension LivePlaybackCoordinatorTests` block in `LivePlaybackCoordinatorTests.swift`:

```swift
// MARK: — Telemetry: song-start on bootstrap
extension LivePlaybackCoordinatorTests {
    func testBootstrapFiresUpdateHistoryForFirstSong() async throws {
        let api = MockRpApiClient()
        // Block with cue=3194ms, first song at elapsed=0 → ppm=3194
        let song = makeSong(id: "20093", duration: 60_000, elapsed: 0, event: "2869396")
        let block = makeBlock(
            channel: "0", cue: 3194, endEvent: "2869396",
            prebuiltSongs: [
                PlayListSong(songId: "20093", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "2869396", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "5")
            ]
        )
        await api.setBlockResponses([block])
        let fixedDate = Date(timeIntervalSince1970: 1_777_746_855)
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(),
            bitrateProvider: { 0 }, clock: { fixedDate }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 1)
        let call = try XCTUnwrap(historyCalls.first)
        XCTAssertEqual(call.songId, "20093")
        XCTAssertEqual(call.chan, 0)
        XCTAssertEqual(call.event, "2869396")
        XCTAssertEqual(call.audioType, "M")
        XCTAssertEqual(call.sliceNum, "5")
        XCTAssertEqual(call.playPositionMillis, 3194)
        XCTAssertEqual(call.playtimeSecs, 1_777_746_855)
        XCTAssertFalse(call.pauseFlag)
    }

    func testChannelSwitchFiresUpdateHistoryForFirstSong() async throws {
        let api = MockRpApiClient()
        let block1 = makeBlock(songs: [("s1", 60_000)])
        let block2 = makeBlock(
            channel: "1",
            prebuiltSongs: [
                PlayListSong(songId: "99", artist: "A", title: "T", album: "Al",
                             duration: 60_000, event: "9999", schedTime: nil,
                             chan: nil, year: nil, asin: nil, rating: nil,
                             userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                             type: "M", sliceNum: "1")
            ]
        )
        await api.setBlockResponses([block1, block2])
        let coord = LivePlaybackCoordinator(
            api: api, engine: MockPlayerEngine(), logger: silentLogger(),
            bitrateProvider: { 0 }
        )
        try await coord.play(channelId: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await coord.changeChannel(to: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let historyCalls = await api.updateHistoryCalls
        XCTAssertEqual(historyCalls.count, 2)
        XCTAssertEqual(historyCalls.last?.songId, "99")
        XCTAssertEqual(historyCalls.last?.chan, 1)
    }
}
```

- [ ] **Step 2: Run the two new tests to confirm they fail**

```bash
swift test --filter "testBootstrapFiresUpdateHistory|testChannelSwitchFiresUpdateHistory" 2>&1 | tail -10
```

Expected: 2 failures (count == 0).

- [ ] **Step 3: Wire telemetry in `play(channelId:)`**

In `LivePlaybackCoordinator.play(channelId:)`, add one line after `emitNowPlaying(forSongIndex: 0)`:

```swift
emitNowPlaying(forSongIndex: 0)
fireSongStartTelemetry(song: orderedSongs[0], channelId: channelId)
```

- [ ] **Step 4: Run the two tests to confirm they pass**

```bash
swift test --filter "testBootstrapFiresUpdateHistory|testChannelSwitchFiresUpdateHistory" 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 256 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coord): fire update_history on song-start (bootstrap + channel switch)"
```

---

## Task 5: Song-start telemetry on natural advance

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing natural-advance telemetry test**

Add to the telemetry extension in `LivePlaybackCoordinatorTests.swift`:

```swift
func testNaturalSongAdvanceFiresUpdateHistory() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "s1", artist: "A", title: "T", album: "Al",
                         duration: 60_000, event: "ev1", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "1"),
            PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                         duration: 60_000, event: "ev2", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 60_000, slideshow: nil,
                         type: "M", sliceNum: "2"),
        ]
    )
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    // Simulate engine crossing into song 2 (elapsed=60_000ms → 60.0s start)
    await engine.fire(.positionUpdate(seconds: 60.01))
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 2)  // bootstrap + boundary
    XCTAssertEqual(historyCalls.last?.songId, "s2")
    XCTAssertEqual(historyCalls.last?.event, "ev2")
    XCTAssertFalse(historyCalls.last?.pauseFlag ?? true)
}
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
swift test --filter "testNaturalSongAdvanceFiresUpdateHistory" 2>&1 | tail -10
```

Expected: 1 failure (count == 1 not 2, or boundary call missing).

- [ ] **Step 3: Wire telemetry in `handleEngineEvent(.positionUpdate)`**

In `LivePlaybackCoordinator.handleEngineEvent`, after `currentSongIndex = newIndex` and `emitNowPlaying(forSongIndex: newIndex)`:

```swift
if newIndex != currentSongIndex {
    logger.debug("song boundary crossed: \(currentSongIndex) -> \(newIndex) at pos=\(seconds)")
    currentSongIndex = newIndex
    emitNowPlaying(forSongIndex: newIndex)
    if let channelId = currentChannelId {
        fireSongStartTelemetry(song: orderedSongs[newIndex], channelId: channelId)
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
swift test --filter "testNaturalSongAdvanceFiresUpdateHistory" 2>&1 | tail -5
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 257 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coord): fire update_history on natural song-boundary advance"
```

---

## Task 6: Song-start telemetry on skip + promo skip + favorites params

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing skip telemetry tests**

Add to the telemetry extension:

```swift
func testInBlockSkipFiresUpdateHistory() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "s1", artist: "A", title: "T1", album: "Al",
                         duration: 60_000, event: "ev1", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "1"),
            PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                         duration: 60_000, event: "ev2", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 60_000, slideshow: nil,
                         type: "M", sliceNum: "2"),
        ]
    )
    await api.setBlockResponses([block])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    try await coord.skipForward()
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 2)  // bootstrap + skip
    XCTAssertEqual(historyCalls.last?.songId, "s2")
    XCTAssertEqual(historyCalls.last?.playPositionMillis, 1)  // hardcoded 1 for skip
}

func testPromoSongDoesNotFireUpdateHistory() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "0", artist: "Commercial-free", title: "Listener-supported",
                         album: nil, duration: 5_000, event: "ev1", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "P", sliceNum: nil),
        ]
    )
    await api.setBlockResponses([block])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 0)  // promo skipped
}

func testFavoritesChannelSendsNullSliceNum() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(
        channel: "99",
        prebuiltSongs: [
            PlayListSong(songId: "42839", artist: "A", title: "T", album: "Al",
                         duration: 300_000, event: "1777746918882", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: nil),
        ]
    )
    await api.setBlockResponses([block])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 99)
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 1)
    XCTAssertNil(historyCalls.first?.sliceNum)  // nil → "null" in URL; stored as nil in args
    XCTAssertEqual(historyCalls.first?.event, "1777746918882")
    XCTAssertEqual(historyCalls.first?.chan, 99)
}
```

Note: `sliceNum` is `nil` in `UpdateHistoryArgs` when `song.sliceNum == nil`; `LiveRpApiClient.updateHistory` writes `"null"` to the URL. The mock captures it as-is.

- [ ] **Step 2: Run the three tests to confirm they fail**

```bash
swift test --filter "testInBlockSkip|testPromoSong|testFavoritesChannel" 2>&1 | tail -10
```

Expected: failures.

- [ ] **Step 3: Wire telemetry in `skipForward()` — in-block case**

In `skipForward()`, after `emitNowPlaying(forSongIndex: nextIndex)`:

```swift
currentSongIndex = nextIndex
currentPositionSeconds = target
emitNowPlaying(forSongIndex: nextIndex)
fireSongStartTelemetry(song: nextSong, channelId: channelId, ppm: 1)
```

- [ ] **Step 4: Run the three tests to confirm they pass**

```bash
swift test --filter "testInBlockSkip|testPromoSong|testFavoritesChannel" 2>&1 | tail -5
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 260 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coord): fire update_history on in-block skip; skip promos; favorites null slice"
```

---

## Task 7: Song-start telemetry on skip past-last + prefetch swap

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to the telemetry extension:

```swift
func testSkipPastLastSongFiresUpdateHistoryForNewBlock() async throws {
    let api = MockRpApiClient()
    let firstBlock = makeBlock(songs: [("s1", 60_000)])
    let secondBlock = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "s2", artist: "A", title: "T", album: "Al",
                         duration: 60_000, event: "ev2", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "1"),
        ]
    )
    await api.setBlockResponses([firstBlock, secondBlock])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    try await coord.skipForward()  // past last song of first block
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 2)  // bootstrap + new block first song
    XCTAssertEqual(historyCalls.last?.songId, "s2")
    XCTAssertEqual(historyCalls.last?.playPositionMillis, 1)
}

func testPrefetchSwapFiresUpdateHistoryForNewBlock() async throws {
    let api = MockRpApiClient()
    let firstBlock = makeBlock(
        endEvent: "100",
        prebuiltSongs: [
            PlayListSong(songId: "s1", artist: "A", title: "T", album: "Al",
                         duration: 60_000, event: "100", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "5"),
        ]
    )
    let prefetchBlock = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "s2", artist: "A", title: "T2", album: "Al",
                         duration: 60_000, event: "101", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "6"),
        ]
    )
    await api.setBlockResponses([firstBlock, prefetchBlock])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    // Trigger prefetch: simulate being in last song with <10s remaining
    // Song duration=60000ms=60s, trigger prefetch at 51s (totalDuration-9)
    await engine.fire(.positionUpdate(seconds: 51.0))
    try await Task.sleep(nanoseconds: 100_000_000)  // let prefetch complete
    // Now simulate EOF to trigger swap
    await engine.fire(.fileEnded(.eof))
    try await Task.sleep(nanoseconds: 50_000_000)
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(historyCalls.count, 2)  // bootstrap + swap
    XCTAssertEqual(historyCalls.last?.songId, "s2")
}
```

- [ ] **Step 2: Run the two tests to confirm they fail**

```bash
swift test --filter "testSkipPastLastSong|testPrefetchSwap" 2>&1 | tail -10
```

Expected: failures.

- [ ] **Step 3: Wire telemetry in `skipForward()` past-last case**

In the `else` branch of `skipForward()` (past-last), add after `emitNowPlaying(forSongIndex: 0)`:

```swift
emitNowPlaying(forSongIndex: 0)
fireSongStartTelemetry(song: songs[0], channelId: channelId, ppm: 1)
```

Also add the same after the `swapToPrefetchedBlockIfAvailable()` call path (the `if prefetchedBlock != nil` branch calls `await swapToPrefetchedBlockIfAvailable(); return` — the telemetry will be fired inside `swapToPrefetchedBlockIfAvailable()` itself, see step 4).

- [ ] **Step 4: Wire telemetry in `swapToPrefetchedBlockIfAvailable()`**

After `emitNowPlaying(forSongIndex: 0)` in `swapToPrefetchedBlockIfAvailable()`:

```swift
emitNowPlaying(forSongIndex: 0)
if let channelId = currentChannelId {
    fireSongStartTelemetry(song: orderedSongs[0], channelId: channelId)
}
```

- [ ] **Step 5: Run the two tests to confirm they pass**

```bash
swift test --filter "testSkipPastLastSong|testPrefetchSwap" 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 262 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coord): fire update_history on skip-past-last and prefetch swap"
```

---

## Task 8: Pause/resume telemetry

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing pause/resume tests**

Add to the telemetry extension:

```swift
func testPauseResumeFiresUpdatePauseAndUpdateHistory() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(
        prebuiltSongs: [
            PlayListSong(songId: "55464", artist: "A", title: "T", album: "Al",
                         duration: 120_000, event: "2869397", schedTime: nil,
                         chan: nil, year: nil, asin: nil, rating: nil,
                         userRating: nil, cover: nil, elapsed: 0, slideshow: nil,
                         type: "M", sliceNum: "6"),
        ]
    )
    await api.setBlockResponses([block])
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(
        api: api, engine: engine, logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    await engine.fire(.positionUpdate(seconds: 10.0))
    try await Task.sleep(nanoseconds: 20_000_000)
    try await coord.pause()
    try await coord.resume()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pauseCalls = await api.updatePauseCalls
    let historyCalls = await api.updateHistoryCalls
    XCTAssertEqual(pauseCalls.count, 1)
    XCTAssertEqual(pauseCalls.first?.songId, "55464")
    XCTAssertGreaterThanOrEqual(pauseCalls.first?.pauseDurationMillis ?? -1, 0)
    XCTAssertEqual(pauseCalls.first?.chan, 0)
    let resumeHistory = historyCalls.last(where: { $0.pauseFlag })
    XCTAssertNotNil(resumeHistory)
    XCTAssertEqual(resumeHistory?.songId, "55464")
    XCTAssertEqual(resumeHistory?.pauseFlag, true)
}

// Tests exact pause duration via a mutable clock wrapped in @unchecked Sendable.
func testPauseDurationMillisIsCorrect() async throws {
    final class MutableClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000)
    }
    let clockState = MutableClock()
    let api = MockRpApiClient()
    let block = makeBlock(songs: [("s1", 120_000)])
    await api.setBlockResponses([block])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(),
        bitrateProvider: { 0 }, clock: { clockState.date }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 20_000_000)
    try await coord.pause()                                    // pausedAt = t=1000
    clockState.date = Date(timeIntervalSince1970: 1_005)       // advance clock 5s
    try await coord.resume()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pauseCalls = await api.updatePauseCalls
    XCTAssertEqual(pauseCalls.first?.pauseDurationMillis, 5_000)
}

func testResumeWithoutPriorPauseDoesNotFireTelemetry() async throws {
    let api = MockRpApiClient()
    let block = makeBlock(songs: [("s1", 60_000)])
    await api.setBlockResponses([block])
    let coord = LivePlaybackCoordinator(
        api: api, engine: MockPlayerEngine(), logger: silentLogger(), bitrateProvider: { 0 }
    )
    try await coord.play(channelId: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    try? await coord.resume()
    try await Task.sleep(nanoseconds: 50_000_000)
    let pauseCalls = await api.updatePauseCalls
    XCTAssertEqual(pauseCalls.count, 0)
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
swift test --filter "testPauseResumeFires|testResumeWithoutPrior" 2>&1 | tail -10
```

Expected: failures.

- [ ] **Step 3: Capture pause state in `pause()`**

Modify `pause()` in `PlaybackCoordinator.swift` — after `engine.pause()` succeeds:

```swift
public func pause() async throws {
    logger.debug("pause()")
    guard currentBlock != nil else { throw PlaybackCoordinatorError.notPlaying }
    do { try await engine.pause() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    pausedAt = clock()
    if currentSongIndex < startsAt.count {
        pausePositionMs = max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))
    }
}
```

- [ ] **Step 4: Fire telemetry in `resume()` after successful engine resume**

Modify `resume()` in `PlaybackCoordinator.swift`. Add after `try await engine.resume()` succeeds, before the method returns:

```swift
public func resume() async throws {
    logger.debug("resume()")
    guard let block = currentBlock else { throw PlaybackCoordinatorError.notPlaying }
    if block.expiration > 0,
       Date().timeIntervalSince1970 > Double(block.expiration),
       let channelId = currentChannelId {
        logger.info("resume: block expired (now=\(Int(Date().timeIntervalSince1970)) > expiration=\(block.expiration)), refetching")
        pausedAt = nil
        pausePositionMs = 0
        try await play(channelId: channelId)
        return
    }
    logger.debug("resume: block fresh, engine.resume()")
    do { try await engine.resume() } catch { throw PlaybackCoordinatorError.engineError(message: String(describing: error)) }
    guard let at = pausedAt, let channelId = currentChannelId,
          currentSongIndex < orderedSongs.count else { return }
    let song = orderedSongs[currentSongIndex]
    guard song.type != "P" else {
        pausedAt = nil
        pausePositionMs = 0
        return
    }
    let durationMs = Int(clock().timeIntervalSince(at) * 1000)
    let ppm = pausePositionMs
    let ts = Int(clock().timeIntervalSince1970)
    let songId = song.songId
    let event = song.event ?? ""
    let audioType = song.type ?? "M"
    let sliceNum = song.sliceNum
    let api = self.api
    pausedAt = nil
    pausePositionMs = 0
    Task.detached {
        try? await api.updatePause(
            songId: songId, chan: channelId, event: event, audioType: audioType,
            sliceNum: sliceNum, pauseDurationMillis: durationMs, playtimeSecs: ts
        )
        try? await api.updateHistory(
            songId: songId, chan: channelId, event: event, audioType: audioType,
            sliceNum: sliceNum, playPositionMillis: ppm, playtimeSecs: ts,
            pauseFlag: true
        )
    }
}
```

- [ ] **Step 5: Run the pause/resume tests to confirm they pass**

```bash
swift test --filter "testPauseResumeFires|testResumeWithoutPrior" 2>&1 | tail -5
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 264 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "feat(coord): fire update_pause + update_history(pause=1) on pause→resume"
```

---

## Task 9: Final verification and CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full test suite**

```bash
swift test 2>&1 | tail -5
```

Expected: `Executed 265 tests, with 0 failures` (251 baseline + 3 API URL + 2 bootstrap/channel-switch + 1 natural-advance + 3 skip/promo/favorites + 2 skip-past-last/prefetch + 3 pause/resume = 265).

- [ ] **Step 2: Check `swift build` also succeeds cleanly**

```bash
swift build 2>&1 | grep -E "error:|warning:|Build complete"
```

Expected: `Build complete!` with no errors.

- [ ] **Step 3: Update CLAUDE.md PR status and test count**

In `CLAUDE.md`, update the PR 14 row:

```
| 14   | merged to main                 | ✅      | Telemetry endpoints (update_history, update_pause) for cross-session resume |
```

And update the test count entry at the bottom:

```
- After PR 14 telemetry (update_history + update_pause; 5 trigger sites; clock injection; promo/favorites guards): 265
```

Also update "Last merged: **PR 14**" and "Upcoming: **PR 15**".

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): mark PR 14 merged + update test count"
```

---

## Key implementation notes

- `fireSongStartTelemetry` is `private` on the actor and accesses `currentPositionSeconds`, `startsAt`, `currentSongIndex` directly (all actor-isolated). No `await` needed.
- For in-block skip and skip-past-last, `ppm: 1` is hardcoded to match observed HAR behavior (user skipped to song start — position-within-song is effectively 0).
- For bootstrap and natural advance, the formula `max(1, Int((currentPositionSeconds - startsAt[currentSongIndex]) * 1000))` naturally handles cue offsets.
- `time_relative` is always `"-\(seconds)"` — even when `seconds == 0` it writes `"-0"` matching the web player's literal JS `"-" + Math.round(ppm/1000)` pattern.
- `event_num=undefined` is hardcoded — the web player sends this literally because it references an undefined JS variable; hardcode the string.
- `Task.detached` captures values by copy before dispatch (all captured as `let` local vars inside the actor before the Task). The `api` stored property is `Sendable` (it's a `struct`), so it crosses the isolation boundary safely.
- Tests use `try await Task.sleep(nanoseconds: 50_000_000)` (50ms) after triggering actions to give `Task.detached` work time to complete before asserting.
- The `clock` param default `{ Date() }` means no existing tests need updating — they all construct `LivePlaybackCoordinator` without `clock:`.
