# PR 13 — `api/play` Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `api/get_block` with `api/play` as the universal block-fetch endpoint so the desktop app supports every Radio Paradise channel — including the favorites/"My Paradise" channel (chan=99) that returns one song per fetch instead of multi-song blocks.

**Architecture:** Browser-derived discovery: the RP web player uses `api/play` for every channel. Music channels return the same multi-song `GetBlock` shape; favorites returns a single-song `GetBlock`. Cursor management moves to the backend (keyed on `(player_id, chan)`); the client always bootstraps with `event=0&action=start`. Within-session advance and skip use `event=<lastEvent>&action=play&audio_type=<M|P>&episode_id=0&slice_num=<n|null>`. The client's per-channel `channelCursors` map is removed; `lastEvent` for the next call is read from the song dict on each advance. `PlayListSong` gains two new optional string fields (`type`, `sliceNum`) needed for the advance-call query params. Telemetry endpoints (`update_history`, `update_pause`) are deferred to PR 14.

**Tech Stack:** Swift 6.2, swift-test (XCTest), URLSession, StubURLProtocol for API stubbing.

**Branch:** `claude/pr13-api-play-migration` (off `main`).

---

## File Structure

| File                                                              | Action | Responsibility                                                                                                                                                            |
| ----------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/RPPlayer/Api/ApiModels.swift`                            | Modify | Add `type: String?` and `sliceNum: String?` to `PlayListSong`.                                                                                                            |
| `Sources/RPPlayer/Api/RpApiClient.swift`                          | Modify | Add `PlayAction` enum + `play(...)` method. Remove `getBlock(...)` at the end.                                                                                            |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`             | Modify | Replace 3 `api.getBlock(...)` call sites with `api.play(...)`. Drop `channelCursors` map.                                                                                 |
| `Tests/RPPlayerTests/Api/ApiModelsTests.swift`                    | Modify | Cover `type` + `sliceNum` decoding from existing fixture.                                                                                                                 |
| `Tests/RPPlayerTests/Api/RpApiClientTests.swift`                  | Modify | Replace `get_block` URL tests with `play` URL tests for both bootstrap (`action=start`) and advance (`action=play`).                                                      |
| `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`              | Modify | Replace `getBlock` mock with `play` mock + new `Call.play(...)` enum case.                                                                                                |
| `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` | Modify | Update all `apiCalls` assertions from `.getBlock(...)` to `.play(...)`. Drop `testChannelSwitchPreservesCursors`. Add `testFavoritesChannelBootstrapUsesPlayActionStart`. |
| `Tests/RPPlayerTests/Fixtures/Api/play_favorites.json`            | Create | Single-song favorites response fixture (derived from `.temp/play_response.json`).                                                                                         |
| `CLAUDE.md`                                                       | Modify | Replace event-cursor-resume notes with `api/play` migration notes. Update test count.                                                                                     |

Files NOT touched (despite reading from them): `BlockSongs.swift`, `NowPlaying.swift`, `MpvPlayerEngine.swift`, view models, shell. The `GetBlock` model itself is unchanged because the response shape is identical to `api/get_block`.

---

## Task 1: Add `type` and `sliceNum` to `PlayListSong`

**Files:**

- Modify: `Sources/RPPlayer/Api/ApiModels.swift`
- Test: `Tests/RPPlayerTests/Api/ApiModelsTests.swift`

The fixture `Tests/RPPlayerTests/Fixtures/Api/get_block.json` already has `"slice_num": "5"` and `"type": "M"` per song; we just need to expose them in the model. Both are strings in the live API. `slice_num` is `null` for favorites.

- [ ] **Step 1.1: Write failing tests**

Append to `Tests/RPPlayerTests/Api/ApiModelsTests.swift` (inside the existing `ApiModelsTests` final class):

```swift
func testPlayListSongDecodesSliceNumAndType() throws {
    let url = Bundle.module.url(forResource: "get_block", withExtension: "json", subdirectory: "Fixtures/Api")!
    let data = try Data(contentsOf: url)
    let block = try JSONDecoder.rpDecoder.decode(GetBlock.self, from: data)
    let song0 = try XCTUnwrap(block.song["0"])
    XCTAssertEqual(song0.type, "M")
    XCTAssertEqual(song0.sliceNum, "5")
}

func testPlayListSongDecodesNullSliceNum() throws {
    let json = """
    {
      "song_id": "12345",
      "artist": "X",
      "title": "Y",
      "album": "Z",
      "duration": 100000,
      "slice_num": null,
      "type": "M"
    }
    """.data(using: .utf8)!
    let song = try JSONDecoder.rpDecoder.decode(PlayListSong.self, from: json)
    XCTAssertNil(song.sliceNum)
    XCTAssertEqual(song.type, "M")
}
```

- [ ] **Step 1.2: Run tests, verify they fail**

```bash
swift test --filter ApiModelsTests/testPlayListSongDecodesSliceNumAndType
swift test --filter ApiModelsTests/testPlayListSongDecodesNullSliceNum
```

Expected: both fail with "value of type 'PlayListSong' has no member 'sliceNum'" (compile error) or similar.

- [ ] **Step 1.3: Add fields to**`PlayListSong`

In `Sources/RPPlayer/Api/ApiModels.swift`, in `struct PlayListSong`, add two new stored properties just after `slideshow`:

```swift
public let slideshow: String?
/// RP block type: "M" = music, "P" = promo. Null for favorites bootstrap.
public let type: String?
/// Slice index within the audio file. Live API encodes as String for music ("5"),
/// JSON null for favorites. Sent verbatim back as `slice_num` URL param on the
/// next `api/play` call.
public let sliceNum: String?
```

Add the same two parameters to the existing `init(...)` (preserve order: `slideshow` last in old init, then `type`, then `sliceNum`). Update the existing call site in `init(from info: SongInfo)`:

```swift
public extension PlayListSong {
    init(from info: SongInfo) {
        self.init(
            songId: String(info.songId),
            artist: info.artist,
            title: info.title,
            album: info.album,
            duration: (info.length.flatMap(Int.init) ?? 0) * 1000,
            event: nil,
            schedTime: nil,
            chan: nil,
            year: nil,
            asin: info.asin,
            rating: info.avgRating.map { String($0) },
            userRating: info.userRating.map { String($0) },
            cover: info.largeCover ?? info.medCover,
            elapsed: nil,
            slideshow: info.slideshow,
            type: nil,
            sliceNum: nil
        )
    }
}
```

- [ ] **Step 1.4: Run all tests, verify pass**

```bash
swift test
```

Expected: 246 passing → 248 passing (2 new). No existing tests should break: `Codable` synthesis handles missing keys for optionals, and the explicit `init` callers all live in the test target — find them and update:

```bash
grep -rn "PlayListSong(" Tests/RPPlayerTests
```

For each match that uses the positional init, append `, type: nil, sliceNum: nil` before the closing `)`.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/RPPlayer/Api/ApiModels.swift Tests/RPPlayerTests/Api/ApiModelsTests.swift Tests/RPPlayerTests
git commit -m "feat(api): add type + slice_num to PlayListSong for api/play migration"
```

---

## Task 2: Add `play(...)` method to `RpApiClient`

**Files:**

- Modify: `Sources/RPPlayer/Api/RpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`
- Create: `Tests/RPPlayerTests/Fixtures/Api/play_favorites.json`

This task adds `play(...)` *alongside* `getBlock(...)`. Removing `getBlock` happens in Task 8 once all callers are migrated.

- [ ] **Step 2.1: Add favorites fixture**

Save the favorites bootstrap response to `Tests/RPPlayerTests/Fixtures/Api/play_favorites.json`. Use the captured response from `.temp/play_response.json` (or, if that file is gone, regenerate via `scripts/probe-favorites.sh` after a fresh session bootstrap). The contents:

```json
{
    "event": "1777741838988",
    "type": "M",
    "end_event": "1777741838988",
    "sched_time_millis": 1777741838000000,
    "image_base": "//img.radioparadise.com/",
    "url": "https://audio-geo.radioparadise.com/audio/m4a/128/35952.m4a",
    "length": "304.2",
    "song": {
        "0": {
            "song_id": "35952",
            "artist": "John Scofield",
            "title": "Green Tea",
            "album": "A Go Go",
            "duration": 304245,
            "type": "M",
            "event": "1777741838988",
            "slice_num": null,
            "elapsed": 0,
            "cover": "covers/l/9577.jpg"
        }
    },
    "chan": "99",
    "channel": {
        "chan": "99",
        "title": "My Favorites",
        "stream_name": "favorites",
        "isER": false
    },
    "bitrate": "128k aac",
    "ext": "m4a",
    "cue": 13758,
    "expiration": 1777828238
}
```

- [ ] **Step 2.2: Write failing tests**

Append to `Tests/RPPlayerTests/Api/RpApiClientTests.swift` inside the existing test class. Three tests:

```swift
func testPlayBootstrapBuildsCorrectURL() async throws {
    let baseURL = URL(string: "https://api.example.com/")!
    var components = URLComponents(url: baseURL.appendingPathComponent("api/play"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "action", value: "start"),
        URLQueryItem(name: "bitrate", value: "2"),
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "elapsed", value: "1"),
        URLQueryItem(name: "event", value: "0"),
        URLQueryItem(name: "info", value: "true"),
        URLQueryItem(name: "source", value: "24"),
    ]
    let expectedURL = components.url!
    let fixtureData = try fixtureData(named: "get_block")
    StubURLProtocol.register(handler: { request in
        XCTAssertEqual(request.url, expectedURL)
        return (HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, fixtureData)
    })
    let client = LiveRpApiClient(baseURL: baseURL, session: stubSession(), cookieProvider: NoopCookieProvider(), logger: NoopLogger())

    let block = try await client.play(channel: 0, bitrate: 2, event: 0, action: .start, audioType: nil, episodeId: nil, sliceNum: nil)
    XCTAssertFalse(block.song.isEmpty)
}

func testPlayAdvanceIncludesAudioTypeEpisodeIdSliceNum() async throws {
    let baseURL = URL(string: "https://api.example.com/")!
    var components = URLComponents(url: baseURL.appendingPathComponent("api/play"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "action", value: "play"),
        URLQueryItem(name: "audio_type", value: "M"),
        URLQueryItem(name: "bitrate", value: "2"),
        URLQueryItem(name: "chan", value: "0"),
        URLQueryItem(name: "elapsed", value: "1"),
        URLQueryItem(name: "episode_id", value: "0"),
        URLQueryItem(name: "event", value: "2869394"),
        URLQueryItem(name: "info", value: "true"),
        URLQueryItem(name: "slice_num", value: "5"),
        URLQueryItem(name: "source", value: "24"),
    ]
    let expectedURL = components.url!
    let fixtureData = try fixtureData(named: "get_block")
    StubURLProtocol.register(handler: { request in
        XCTAssertEqual(request.url, expectedURL)
        return (HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, fixtureData)
    })
    let client = LiveRpApiClient(baseURL: baseURL, session: stubSession(), cookieProvider: NoopCookieProvider(), logger: NoopLogger())

    _ = try await client.play(channel: 0, bitrate: 2, event: 2869394, action: .play, audioType: "M", episodeId: 0, sliceNum: "5")
}

func testPlayAdvanceFavoritesSendsLiteralNullSliceNum() async throws {
    let baseURL = URL(string: "https://api.example.com/")!
    var components = URLComponents(url: baseURL.appendingPathComponent("api/play"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
        URLQueryItem(name: "action", value: "play"),
        URLQueryItem(name: "audio_type", value: "M"),
        URLQueryItem(name: "bitrate", value: "2"),
        URLQueryItem(name: "chan", value: "99"),
        URLQueryItem(name: "elapsed", value: "1"),
        URLQueryItem(name: "episode_id", value: "0"),
        URLQueryItem(name: "event", value: "1777746918882"),
        URLQueryItem(name: "info", value: "true"),
        URLQueryItem(name: "slice_num", value: "null"),
        URLQueryItem(name: "source", value: "24"),
    ]
    let expectedURL = components.url!
    let fixtureData = try fixtureData(named: "play_favorites")
    StubURLProtocol.register(handler: { request in
        XCTAssertEqual(request.url, expectedURL)
        return (HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!, fixtureData)
    })
    let client = LiveRpApiClient(baseURL: baseURL, session: stubSession(), cookieProvider: NoopCookieProvider(), logger: NoopLogger())

    let block = try await client.play(channel: 99, bitrate: 2, event: 1_777_746_918_882, action: .play, audioType: "M", episodeId: 0, sliceNum: nil)
    XCTAssertEqual(block.song.count, 1)
}
```

If the existing test file does not yet have a `fixtureData(named:)` helper, add it as a private method on the class:

```swift
private func fixtureData(named name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Api")!
    return try Data(contentsOf: url)
}
```

- [ ] **Step 2.3: Run tests, verify they fail**

```bash
swift test --filter RpApiClientTests
```

Expected: three new tests fail with "value of type 'LiveRpApiClient' has no member 'play'".

- [ ] **Step 2.4: Implement `PlayAction` +**`play(...)`

In `Sources/RPPlayer/Api/RpApiClient.swift`, add the enum at top of file (after `import Foundation`):

```swift
public enum PlayAction: String, Sendable {
    case start
    case play
}
```

In the `RpApiClient` protocol, add the new method:

```swift
public protocol RpApiClient: Sendable {
    func listChannels() async throws -> [Channel]
    func getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?) async throws -> GetBlock
    func play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
              audioType: String?, episodeId: Int?, sliceNum: String?) async throws -> GetBlock
    func info(songId: Int) async throws -> SongInfo
    func rate(songId: Int, rating: Int) async throws -> Rating
    func authState() async throws -> Auth
}
```

In `LiveRpApiClient`, add the implementation just after `getBlock(...)`:

```swift
public func play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
                 audioType: String?, episodeId: Int?, sliceNum: String?) async throws -> GetBlock {
    var query: [String: String] = [
        "chan": String(channel),
        "bitrate": String(bitrate),
        "event": String(event),
        "action": action.rawValue,
        "info": "true",
        "elapsed": "1",
        "source": "24",
    ]
    if action == .play {
        query["audio_type"] = audioType ?? ""
        query["episode_id"] = String(episodeId ?? 0)
        query["slice_num"] = sliceNum ?? "null"
    }
    return try await get(path: "api/play", query: query)
}
```

- [ ] **Step 2.5: Run tests, verify they pass**

```bash
swift test --filter RpApiClientTests
swift test
```

Expected: all RpApiClientTests pass; full suite still green (248 → 251).

- [ ] **Step 2.6: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift Tests/RPPlayerTests/Api/RpApiClientTests.swift Tests/RPPlayerTests/Fixtures/Api/play_favorites.json
git commit -m "feat(api): add play(channel:bitrate:event:action:...) method"
```

---

## Task 3: Mirror `play(...)` on `MockRpApiClient`

**Files:**

- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`

`MockRpApiClient` is the test seam used by every coordinator test. We need it to record `.play(...)` calls and return the same canned blocks.

- [ ] **Step 3.1: Read current mock**

```bash
cat Tests/RPPlayerTests/Playback/MockRpApiClient.swift
```

Confirm shape: it has a `Call` enum, an `enqueue` mechanism, and a `getBlock(...)` method that pops from a queue.

- [ ] **Step 3.2: Add `Call.play` case + `play(...)` method**

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:

1. In the `Call` enum, add a new case below `getBlock`:

```swift
case play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
          audioType: String?, episodeId: Int?, sliceNum: String?)
```

1. Add a new method on the class:

```swift
func play(channel: Int, bitrate: Int, event: Int, action: PlayAction,
          audioType: String?, episodeId: Int?, sliceNum: String?) async throws -> GetBlock {
    calls.append(.play(channel: channel, bitrate: bitrate, event: event, action: action,
                       audioType: audioType, episodeId: episodeId, sliceNum: sliceNum))
    if getBlockDelayNanos > 0 {
        do {
            try await Task.sleep(nanoseconds: getBlockDelayNanos)
        } catch {
            getBlockCancellations += 1
            throw error
        }
    }
    return try popBlock()
}
```

(Reuse the existing `popBlock()` helper that `getBlock(...)` already calls — it pops the next queued response. If the helper is private to `getBlock` inline, extract it.)

- [ ] **Step 3.3: Build mock target only**

```bash
swift build --target RPPlayerTests
```

Expected: build succeeds. The `Call` enum's new `.play` case forces all `switch` statements over `Call` in test files to be updated — those updates happen in Task 7 once they bind to coordinator behavior. For now, any switch is `default`-protected or exhaustive over `.getBlock` only, which still compiles.

If the build fails due to non-exhaustive switches, add `case .play: break` arms to keep the build green; Task 7 replaces them with real assertions.

- [ ] **Step 3.4: Commit**

```bash
git add Tests/RPPlayerTests/Playback/MockRpApiClient.swift
git commit -m "test: mirror play(...) on MockRpApiClient"
```

---

## Task 4: Migrate coordinator bootstrap to `api.play(action: .start)`

**Files:**

- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

The bootstrap path is `LivePlaybackCoordinator.play(channelId:)` at lines 76–108. Replace its single `api.getBlock(...)` call with `api.play(... event: 0, action: .start, ...)`. Drop the `cursor` lookup (backend authoritative on bootstrap).

- [ ] **Step 4.1: Write a failing test**

Add to `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

```swift
func testPlayChannelBootstrapsWithEventZeroAndActionStart() async throws {
    let api = MockRpApiClient()
    api.enqueue(block: makeMultiSongBlock(songs: [
        .stub(songId: "1", event: "100", durationSeconds: 60),
        .stub(songId: "2", event: "200", durationSeconds: 60),
    ], cue: 0))
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(api: api, engine: engine, logger: NoopLogger(), bitrateProvider: { 4 })

    try await coord.play(channelId: 0)

    let calls = await api.calls
    XCTAssertEqual(calls.count, 1)
    guard case let .play(channel, bitrate, event, action, audioType, episodeId, sliceNum) = calls[0] else {
        return XCTFail("expected .play call, got \(calls[0])")
    }
    XCTAssertEqual(channel, 0)
    XCTAssertEqual(bitrate, 4)
    XCTAssertEqual(event, 0)
    XCTAssertEqual(action, .start)
    XCTAssertNil(audioType)
    XCTAssertNil(episodeId)
    XCTAssertNil(sliceNum)
}
```

If `makeMultiSongBlock(...)` and `PlayListSong.stub(...)` helpers don't exist with these exact signatures, look at the existing tests (e.g., `testPlayLoadsBlockAndStartsEngine`) and reuse whatever block-building helper is in scope.

- [ ] **Step 4.2: Run test, verify it fails**

```bash
swift test --filter LivePlaybackCoordinatorTests/testPlayChannelBootstrapsWithEventZeroAndActionStart
```

Expected: fails because the recorded call is `.getBlock(...)`, not `.play(...)`.

- [ ] **Step 4.3: Replace the bootstrap call**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, in `play(channelId:)`, replace lines roughly 80–82:

```swift
        let cursor = channelCursors[channelId]
        logger.debug("play resolved bitrate=\(bitrate) cursor=\(cursor.map(String.init) ?? "nil")")
        let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: cursor)
```

With:

```swift
        logger.debug("play resolved bitrate=\(bitrate)")
        let block = try await api.play(
            channel: channelId, bitrate: bitrate, event: 0, action: .start,
            audioType: nil, episodeId: nil, sliceNum: nil
        )
```

Leave `channelCursors` reads/writes elsewhere intact for now — Task 7 removes the map.

- [ ] **Step 4.4: Run test, verify it passes**

```bash
swift test --filter LivePlaybackCoordinatorTests/testPlayChannelBootstrapsWithEventZeroAndActionStart
```

Expected: pass.

- [ ] **Step 4.5: Run full coordinator test suite — note expected breakages**

```bash
swift test --filter LivePlaybackCoordinatorTests
```

Tests that asserted `.getBlock(channel:..., event: nil)` for the bootstrap path will now fail because the recorded call is `.play(...)`. Identified failing tests (from grep at plan time):

- `testPlayLoadsBlockAndStartsEngine` (line ~64) — asserts `.getBlock(channel: 0, bitrate: 4, info: true, event: nil)`
- `testPlayUsesCurrentSettingsBitrate` (line ~206) — asserts `.getBlock(channel: 0, bitrate: 0, info: true, event: nil)`
- `testChangeChannelStopsThenPlays` (line ~560) — `.getBlock(channel: 0, bitrate: 4, info: true, event: nil)`

Fix each: replace `.getBlock(channel: X, bitrate: Y, info: true, event: nil)` with the equivalent `.play(channel: X, bitrate: Y, event: 0, action: .start, audioType: nil, episodeId: nil, sliceNum: nil)`. Use grep to find every site:

```bash
grep -n ".getBlock(.*event: nil)" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
```

For each match, replace inline. Re-run after fixing.

- [ ] **Step 4.6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor(coord): bootstrap via api.play(event:0, action:.start) instead of getBlock"
```

---

## Task 5: Migrate coordinator skipForward-past-last to `api.play(action: .play)`

**Files:**

- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

The skipForward past-last path is at lines 173–214. The current code reads `endEvent` from `currentBlock.endEvent`, then calls `api.getBlock(... event: endEvent)`. Migrate to `api.play(... event: lastSongEvent, action: .play, audioType: lastSong.type, episodeId: 0, sliceNum: lastSong.sliceNum)`.

- [ ] **Step 5.1: Write a failing test**

Add to `LivePlaybackCoordinatorTests.swift`:

```swift
func testSkipForwardPastLastSongUsesPlayActionWithSongMetadata() async throws {
    let api = MockRpApiClient()
    let firstBlock = makeMultiSongBlock(songs: [
        .stub(songId: "1", event: "100", durationSeconds: 60, type: "M", sliceNum: "5"),
    ], cue: 0, endEvent: "100")
    let secondBlock = makeMultiSongBlock(songs: [
        .stub(songId: "2", event: "101", durationSeconds: 60),
    ], cue: 0)
    api.enqueue(block: firstBlock)
    api.enqueue(block: secondBlock)
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(api: api, engine: engine, logger: NoopLogger(), bitrateProvider: { 2 })
    try await coord.play(channelId: 0)

    try await coord.skipForward()

    let calls = await api.calls
    XCTAssertEqual(calls.count, 2)
    guard case let .play(channel, bitrate, event, action, audioType, episodeId, sliceNum) = calls[1] else {
        return XCTFail("expected second call to be .play, got \(calls[1])")
    }
    XCTAssertEqual(channel, 0)
    XCTAssertEqual(bitrate, 2)
    XCTAssertEqual(event, 100)
    XCTAssertEqual(action, .play)
    XCTAssertEqual(audioType, "M")
    XCTAssertEqual(episodeId, 0)
    XCTAssertEqual(sliceNum, "5")
}
```

You will need to extend `PlayListSong.stub(...)` (or whatever helper exists) to accept `type` and `sliceNum` parameters with `nil` defaults. If no helper exists, write one near the test:

```swift
private extension PlayListSong {
    static func stub(songId: String, event: String, durationSeconds: Double,
                     type: String? = nil, sliceNum: String? = nil) -> PlayListSong {
        PlayListSong(
            songId: songId, artist: "A", title: "T", album: "Al",
            duration: Int(durationSeconds * 1000),
            event: event, schedTime: nil, chan: "0",
            year: nil, asin: nil, rating: nil, userRating: nil,
            cover: nil, elapsed: nil, slideshow: nil,
            type: type, sliceNum: sliceNum
        )
    }
}
```

- [ ] **Step 5.2: Run test, verify it fails**

```bash
swift test --filter LivePlaybackCoordinatorTests/testSkipForwardPastLastSongUsesPlayActionWithSongMetadata
```

Expected: fails because the second call is still `.getBlock(...)`.

- [ ] **Step 5.3: Replace the skipForward past-last call**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, in `skipForward()`, the past-last branch (the `else` at line ~173). Replace the `api.getBlock(...)` call (line ~191) and surrounding event read:

Current (lines 173–192 paraphrased):

```swift
        } else {
            let endEvent: Int? = Int(currentBlock?.endEvent ?? "")
            if let endEvent, let chan = currentChannelId {
                channelCursors[chan] = endEvent
                logger.debug("cursor[\(chan)] = \(endEvent) (skipForward past-last)")
            }
            if prefetchedBlock != nil {
                ...
            }
            ...
            let bitrate = await bitrateProvider()
            logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(endEvent.map(String.init) ?? "nil")")
            let block = try await api.getBlock(channel: channelId, bitrate: bitrate, info: true, event: endEvent)
```

Replace with (keep `channelCursors` writes for now — Task 7 removes them):

```swift
        } else {
            let lastSong = orderedSongs.last
            let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(currentBlock?.endEvent ?? "") ?? 0
            if lastEvent != 0, let chan = currentChannelId {
                channelCursors[chan] = lastEvent
                logger.debug("cursor[\(chan)] = \(lastEvent) (skipForward past-last)")
            }
            if prefetchedBlock != nil {
                ...
            }
            ...
            let bitrate = await bitrateProvider()
            let audioType = lastSong?.type ?? "M"
            let sliceNum = lastSong?.sliceNum
            logger.debug("skipForward past last song, fetching next block channel=\(channelId) bitrate=\(bitrate) event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
            let block = try await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
```

The rest of the past-last branch is unchanged.

- [ ] **Step 5.4: Run test, verify it passes**

```bash
swift test --filter LivePlaybackCoordinatorTests/testSkipForwardPastLastSongUsesPlayActionWithSongMetadata
```

Expected: pass.

- [ ] **Step 5.5: Fix related-tests breakages**

Find every `.getBlock(... event: <non-nil>)` assertion in coordinator tests:

```bash
grep -n ".getBlock(channel:" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
```

For tests that exercise skipForward-past-last (e.g., `testSkipForwardPastLastSongUsesEndEventAsCursorAndFetchParam`), change the assertion from `.getBlock(channel: X, bitrate: Y, info: true, event: Z)` to the equivalent `.play(channel: X, bitrate: Y, event: Z, action: .play, audioType: ..., episodeId: 0, sliceNum: ...)`. Use whatever song metadata the test set up.

For tests that exercise channel-cursor preservation across channel switches (`testChannelSwitchPreservesCursors`): leave them failing for Task 7. Add `// FIXME(task-7): rewrite or drop` comment so they're easy to find.

Re-run:

```bash
swift test --filter LivePlaybackCoordinatorTests
```

Aim for: all tests pass except the ones marked for Task 7.

- [ ] **Step 5.6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor(coord): skipForward-past-last via api.play(action:.play) with song metadata"
```

---

## Task 6: Migrate coordinator prefetch to `api.play(action: .play)`

**Files:**

- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

Prefetch lives at `maybeStartPrefetch()` lines 312–334. Same shape as the past-last call — uses `currentBlock.endEvent`. Replace identically.

- [ ] **Step 6.1: Write a failing test**

Add to `LivePlaybackCoordinatorTests.swift`:

```swift
func testPrefetchUsesPlayActionWithLastSongMetadata() async throws {
    let api = MockRpApiClient()
    let firstBlock = makeMultiSongBlock(songs: [
        .stub(songId: "1", event: "100", durationSeconds: 5, type: "M", sliceNum: "5"),
    ], cue: 0, endEvent: "100")
    let secondBlock = makeMultiSongBlock(songs: [
        .stub(songId: "2", event: "101", durationSeconds: 60),
    ], cue: 0)
    api.enqueue(block: firstBlock)
    api.enqueue(block: secondBlock)
    let engine = MockPlayerEngine()
    let coord = LivePlaybackCoordinator(api: api, engine: engine, logger: NoopLogger(), bitrateProvider: { 3 })
    try await coord.play(channelId: 0)

    // Drive position into the prefetch window (last song, < 10s remaining).
    await engine.fire(event: .positionUpdate(seconds: 1.0))
    // Yield enough times for the prefetch task to start and complete.
    for _ in 0..<50 { await Task.yield() }

    let calls = await api.calls
    XCTAssertEqual(calls.count, 2)
    guard case let .play(_, _, event, action, audioType, episodeId, sliceNum) = calls[1] else {
        return XCTFail("expected prefetch call to be .play, got \(calls[1])")
    }
    XCTAssertEqual(event, 100)
    XCTAssertEqual(action, .play)
    XCTAssertEqual(audioType, "M")
    XCTAssertEqual(episodeId, 0)
    XCTAssertEqual(sliceNum, "5")
}
```

The exact mechanism for "wait for prefetch to complete" (`await Task.yield()` loop) follows the pattern used in existing prefetch tests — copy from `testPrefetchTriggeredAndPickedUp` or whichever test currently exercises prefetch.

- [ ] **Step 6.2: Run test, verify it fails**

```bash
swift test --filter LivePlaybackCoordinatorTests/testPrefetchUsesPlayActionWithLastSongMetadata
```

Expected: fails because prefetch still calls `.getBlock(...)`.

- [ ] **Step 6.3: Replace the prefetch call**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, in `maybeStartPrefetch()` at lines ~322–333:

Current:

```swift
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
```

Replace with:

```swift
        let lastSong = orderedSongs.last
        let lastEvent: Int = Int(lastSong?.event ?? "") ?? Int(currentBlock?.endEvent ?? "") ?? 0
        let audioType = lastSong?.type ?? "M"
        let sliceNum = lastSong?.sliceNum
        let api = self.api
        let provider = self.bitrateProvider
        logger.debug("prefetch start, channel=\(channelId) event=\(lastEvent) audioType=\(audioType) sliceNum=\(sliceNum ?? "null")")
        prefetchTask = Task { [weak self] in
            let bitrate = await provider()
            let result = try? await api.play(
                channel: channelId, bitrate: bitrate, event: lastEvent, action: .play,
                audioType: audioType, episodeId: 0, sliceNum: sliceNum
            )
            await self?.absorbPrefetchResult(result)
        }
```

- [ ] **Step 6.4: Run test, verify it passes**

```bash
swift test --filter LivePlaybackCoordinatorTests/testPrefetchUsesPlayActionWithLastSongMetadata
```

Expected: pass.

- [ ] **Step 6.5: Fix existing prefetch-related test breakages**

```bash
grep -n "prefetch" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
```

Tests that asserted prefetch's recorded call was `.getBlock(...)` need updating to `.play(...)`. Pattern is identical to Task 5's fix-up. Run the suite, audit failures, fix each.

```bash
swift test --filter LivePlaybackCoordinatorTests
```

Aim: all tests pass except the FIXME(task-7) ones.

- [ ] **Step 6.6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor(coord): prefetch via api.play(action:.play) with song metadata"
```

---

## Task 7: Drop `channelCursors` map and obsolete tests

**Files:**

- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`

The `channelCursors: [Int: Int]` map is now dead state — bootstrap always sends `event=0`, advance reads from `lastSong.event`. Removing it also removes the in-block-skip-cursor-write at lines 160–164 and the auto-advance cursor-write at lines 262–267.

- [ ] **Step 7.1: Confirm remaining cursor reads are dead**

```bash
grep -n "channelCursors" Sources/RPPlayer/Playback/PlaybackCoordinator.swift
```

Expected hits (post Tasks 4–6):

- The map declaration (line ~35).
- A write at in-block skipForward (line ~160).
- A write at past-last skipForward (line ~175 — added in Task 5 transition).
- A write at auto-advance song-boundary cross (line ~262).
- A write at swap-to-prefetched (line ~357).

No reads remain (the bootstrap read was removed in Task 4). All remaining writes are dead code.

- [ ] **Step 7.2: Delete the map + all writes + obsolete test**

In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:

1. Delete the property declaration:

```swift
    private var channelCursors: [Int: Int] = [:]
```

1. Delete each `channelCursors[...] = ...` write site (5 places). Also delete the `if let chan = currentChannelId, ... { ... }` wrappers around them. The surrounding logic (seek, fetch, etc.) stays.

In `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`:

1. Delete `testChannelSwitchPreservesCursors` (line ~755) entirely — the behavior it asserted (cursors persist across channel switches) is the explicit semantics we're abandoning. Backend handles per-channel cursors now.
2. Audit other tests that reason about cursor state. Tests that assert "second call to chan X uses event Y from cursor" become invalid — channel switches always go through `event=0&action=start`. Either delete them or rewrite to assert "channel switch always sends event=0\&action=start". Likely candidates (from grep):

```bash
grep -n "cursor" Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
```

For each match: read the test, decide if its intent is still valid with backend-managed cursors. If yes, rewrite the assertion. If no (e.g., it's specifically about client-side cursor persistence), delete it.

- [ ] **Step 7.3: Run full test suite**

```bash
swift test
```

Expected: all tests pass. Test count: ~244 ± dropped tests + new ones added in Tasks 1–6.

- [ ] **Step 7.4: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift
git commit -m "refactor(coord): drop channelCursors map (backend authoritative on bootstrap)"
```

---

## Task 8: Remove `getBlock` from protocol, impl, mock, and tests

**Files:**

- Modify: `Sources/RPPlayer/Api/RpApiClient.swift`
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`
- Modify: `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`

All callers are now on `play(...)`. Remove the dead `getBlock` API.

- [ ] **Step 8.1: Confirm no production callers remain**

```bash
grep -rn "getBlock" Sources
```

Expected: no matches in `Sources/`. (If any remain, abort and migrate them first.)

- [ ] **Step 8.2: Remove from protocol + LiveRpApiClient**

In `Sources/RPPlayer/Api/RpApiClient.swift`:

---

- - Delete the `getBlock(...)` line from the protocol.
- Delete the `getBlock(...)` implementation in `LiveRpApiClient`.
- [ ] **Step 8.3: Remove from MockRpApiClient**

In `Tests/RPPlayerTests/Playback/MockRpApiClient.swift`:

- Delete `case getBlock(channel: Int, bitrate: Int, info: Bool, event: Int?)` from the `Call` enum.
- Delete `func getBlock(...)`.
- Audit `getBlockDelayNanos`, `getBlockCancellations`, `setGetBlockDelayNanos`: rename to `playDelayNanos`, `playCancellations`, `setPlayDelayNanos` (or just leave as-is — they're internal to the mock). Recommend renaming for clarity:

```swift
private(set) var playCancellations: Int = 0
var playDelayNanos: UInt64 = 0
func setPlayDelayNanos(_ nanos: UInt64) { self.playDelayNanos = nanos }
```

Update the body of `play(...)` to use the renamed properties.

- [ ] **Step 8.4: Remove the `get_block` URL tests from RpApiClientTests**

In `Tests/RPPlayerTests/Api/RpApiClientTests.swift`, locate and delete the two tests that hit `api/get_block` URLs (the original tests at lines 41–51 and 98–108 area). The new `play` tests added in Task 2 cover the equivalent functionality.

```bash
grep -n "api/get_block" Tests/RPPlayerTests/Api/RpApiClientTests.swift
```

Delete the matching test functions in their entirety.

- [ ] **Step 8.5: Audit tests for renamed mock properties**

```bash
grep -rn "getBlockDelayNanos\|getBlockCancellations\|setGetBlockDelayNanos" Tests/RPPlayerTests
```

Replace each with `play*` equivalents from Step 8.3.

- [ ] **Step 8.6: Build + run full test suite**

```bash
swift build
swift test
```

Expected: clean build, all tests pass.

- [ ] **Step 8.7: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift Tests/RPPlayerTests/Api/RpApiClientTests.swift Tests/RPPlayerTests/Playback/MockRpApiClient.swift Tests/RPPlayerTests
git commit -m "refactor(api): remove getBlock — fully replaced by play"
```

---

## Task 9: Update `CLAUDE.md`

**Files:**

- Modify: `CLAUDE.md`

Document the migration so future sessions don't re-discover the same browser-derived insights.

- [ ] **Step 9.1: Append to CLAUDE.md**

In `CLAUDE.md`:

1. Add a new entry to the PR status table:

```
| 13  | merged to main | ✅   | api/play migration (replaces get_block; supports favorites chan=99) |
```

1. Update "Last merged" / "Next" notes at the top of "Current state".
2. Replace the "Coordinator playback" section's bullets about `channelCursors` and `api/now_playing` with the new model:

```markdown
- **Universal block-fetch endpoint is `api/play`.** All channels (including favorites chan=99) use it. Same response shape as the legacy `api/get_block`: a multi-song `GetBlock` for music channels, a single-song `GetBlock` for favorites. Browser-derived discovery (HAR captures from the RP web player). The previous `api/get_block` endpoint and its tests are gone.
- **Backend tracks cursors per `(player_id, chan)`.** Bootstrap from any channel switch is `api/play?event=0&action=start&chan=N&bitrate=X&info=true&elapsed=1&source=24` — the server returns the block where the listener last left off (per its records). The client-side `channelCursors: [Int: Int]` map is removed.
- **Within-session advance/skip uses `api/play?event=<lastEvent>&action=play&audio_type=<M|P>&episode_id=0&slice_num=<n|null>&chan=N&bitrate=X&info=true&elapsed=1&source=24`.** `lastEvent`, `audio_type`, and `slice_num` come from the song that just finished (`orderedSongs.last`). Favorites: `slice_num` is JSON `null` in the response → `String?` decodes as `nil` → URL builder writes literal `slice_num=null`.
- **`PlayListSong.type`** is `"M"` for music, `"P"` for promo. Used both for `audio_type` query param construction and for UI gating (e.g., disable rating UI on promo blocks — pending follow-up).
- **`PlayListSong.sliceNum`** is the song's slice index within the channel's event sequence. String for music ("5"), nil for favorites. Sent verbatim back as `slice_num` URL param on the next `play` call.
- **Cross-session resume is server-driven.** With the telemetry endpoints (`update_history`, `update_pause`) deferred to PR 14, the server's record of where a desktop user is may lag — so on app restart, the bootstrap `event=0&action=start` may return a recently-played slice rather than the next-after-last-played. PR 14 closes this gap.
```

1. Update the test count (whatever the suite reports after Task 8 — record the post-merge number).

- [ ] **Step 9.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document api/play migration + drop channelCursors notes"
```

---

## Final verification

- [ ] **Run full test suite from a clean state:**

```bash
swift test
```

Expected: all tests pass (count documented in CLAUDE.md update).

- [ ] **Manual smoke from the app:**

```bash
swift build
swift run RPPlayer
```

In the running app:

1. Sign in if not already.
2. Verify default music channel (chan=0) plays — confirms `event=0&action=start` bootstrap works for music.
3. Skip forward several times — confirms `event=<n>&action=play` advance works.
4. Switch to "My Favorites" (chan=99) — confirms favorites channel plays end-to-end (the original goal).
5. Skip forward on favorites — confirms single-song block advance.
6. Switch back to chan=0 — confirms cross-channel switch works.
7. Pause + resume — confirms engine pause/resume still works (telemetry deferred to PR 14, but local pause/resume must keep working).

- [ ] **Fast-forward merge to `main`:**

Per CLAUDE.md merge convention: ff-only into main once all reviews pass.

```bash
git checkout main
git merge --ff-only claude/pr13-api-play-migration
git branch -d claude/pr13-api-play-migration
```

---

## Out of scope (deferred to subsequent PRs)

- **PR 14 — Telemetry.** `update_history` (song-start + resume), `update_pause`. Fire-and-forget, optionally toggleable via Settings.
- **Promo UI gating.** Disable `RatingMenu` when `currentSong.type == "P"`.
- **Recently played panel** in popover via `nowplaying_list_v2022`.
- **Distribution CI workflow + `.app` bundling** (originally PR 13; now PR 15).
