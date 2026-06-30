# PR 31 — `api/gapless` Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `api/play` (and `api/get_block`) with `api/gapless`. Refactor `LivePlaybackCoordinator` from block-centric (`currentBlock` + `orderedSongs[]` + `startsAt[]` + `currentSongIndex`) to queue-centric (`queue: [GaplessSong]`). Simplify `UpcomingProgramViewModel` to one call per channel. Drop `GetBlock`, `BlockSongs`, `PlayAction`, all `api/play` + `api/get_block` fixtures.

**Architecture:** Each `GaplessSong` is a self-contained file URL with its own `cue` / `duration` / `event_id` / `type` / `slice_num`. Coordinator maintains `queue: [GaplessSong]` where `queue[0]` is currently playing and `queue[1]` is queued in mpv via `loadfile <url> append-play` (1-ahead pattern from PR 28). Boundary advance via `MPV_EVENT_START_FILE` → `queue.removeFirst()` → emit `NowPlaying` → fire telemetry → queue next. Refetch lazily on bootstrap, channel change, long-idle resume, and queue depth < 3.

**Tech Stack:** Swift 6.2, async/await, `RpApiClient` protocol, `MpvPlayerEngine` actor, `LivePlaybackCoordinator` actor, `XCTest` with `StubURLProtocol`.

**Spec:** `docs/superpowers/specs/2026-05-10-pr31-gapless-migration-design.md`

**Branch:** `claude/pr31-gapless-migration` (off `main`)

**Test command:** `swift test`
**Build command:** `swift build`

---

## Task 1: Add `GaplessSong` + `GaplessResponse` types + fixture

**Files:**

- Modify: `Sources/RPPlayer/Api/ApiModels.swift` (append after `SongInfo`)
- Create: `Tests/RPPlayerTests/Fixtures/Api/gapless_main.json`
- Create: `Tests/RPPlayerTests/Api/GaplessResponseTests.swift`

### Step 1.1: Create the fixture file

- [ ] Create `Tests/RPPlayerTests/Fixtures/Api/gapless_main.json`. Copy the contents of `.temp/gapless.json`. **Sanitise**: scan for any `player_id` / cookie occurrences and remove if present (the example response has none, but verify before committing).

### Step 1.2: Write a failing decoder test

- [ ] Create `Tests/RPPlayerTests/Api/GaplessResponseTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class GaplessResponseTests: XCTestCase {
    func testDecodesMainMixFixture() throws {
        let url = Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let response = try JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)

        XCTAssertEqual(response.channel.chan, "0")
        XCTAssertEqual(response.bitrateTitle, "flac")
        XCTAssertEqual(response.ext, "flac")
        XCTAssertEqual(response.imageBase, "//img.radioparadise.com/")
        XCTAssertEqual(response.currentEventId, 2872450)
        XCTAssertEqual(response.maxGaplessEventId, 2872500)
        XCTAssertEqual(response.slideshowPath, "slideshow/720/")
        XCTAssertGreaterThan(response.songs.count, 5)

        let first = response.songs[0]
        XCTAssertEqual(first.songId, "34608")
        XCTAssertEqual(first.artist, "Stan Getz")
        XCTAssertEqual(first.duration, 251840)
        XCTAssertEqual(first.cue, 163000)
        XCTAssertEqual(first.eventId, 2872450)
        XCTAssertEqual(first.type, "M")
        XCTAssertEqual(first.gaplessUrl, "https://audio-geo.radioparadise.com/chan/0/x/1129/4/g/1129-3.flac")
        XCTAssertEqual(first.sliceNum, 0)
        XCTAssertTrue(first.updateHistory)
        XCTAssertEqual(first.slideshow.count, 27)
    }

    func testDecodesPromoSongInline() throws {
        let url = Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api")
        let data = try Data(contentsOf: XCTUnwrap(url))
        let response = try JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)

        let promo = try XCTUnwrap(response.songs.first(where: { $0.type == "P" }))
        XCTAssertEqual(promo.songId, "0")
        XCTAssertEqual(promo.artist, "Commercial-free")
        XCTAssertFalse(promo.updateHistory)
        XCTAssertFalse(promo.isRateable)
    }
}
```

### Step 1.3: Run the tests to verify they fail

- [ ] `swift test --filter GaplessResponseTests`. Expected: FAIL — `GaplessResponse` undefined.

### Step 1.4: Add the types to ApiModels.swift

- [ ] Append at the end of `Sources/RPPlayer/Api/ApiModels.swift`:

```swift
public struct GaplessSong: Decodable, Sendable, Equatable {
    public let songId: String
    public let artist: String
    public let title: String
    public let album: String?
    public let year: String?
    public let duration: Int
    public let cue: Int
    public let coverArt: String?
    public let coverLarge: String?
    public let coverMedium: String?
    public let coverSmall: String?
    public let eventId: Int
    public let gaplessUrl: String
    public let slideshow: [String]
    public let type: String
    public let schedTimeMillis: Int64
    public let userRating: Int
    public let rating: Double
    public let ratingsNum: Int
    public let episodeId: Int
    public let sliceNum: Int
    public let isRateable: Bool
    public let isPlayableAfterSkip: Bool
    public let isPlayableOnStart: Bool
    public let updateHistory: Bool
    public let skipAllowedMillis: Int64

    enum CodingKeys: String, CodingKey {
        case songId, artist, title, album, year, duration, cue
        case coverArt, coverLarge, coverMedium, coverSmall
        case eventId, gaplessUrl, slideshow, type
        case schedTimeMillis, userRating, rating, ratingsNum
        case episodeId, sliceNum, isRateable, isPlayableAfterSkip, isPlayableOnStart
        case updateHistory, skipAllowedMillis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // song_id may be Int or String per legacy AllowReadingFromString contract.
        if let i = try? c.decode(Int.self, forKey: .songId) {
            songId = String(i)
        } else {
            songId = try c.decode(String.self, forKey: .songId)
        }
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album).flatMap { $0.isEmpty ? nil : $0 }
        year = try c.decodeIfPresent(String.self, forKey: .year)
        duration = try c.decode(Int.self, forKey: .duration)
        cue = try c.decodeIfPresent(Int.self, forKey: .cue) ?? 0
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        coverLarge = try c.decodeIfPresent(String.self, forKey: .coverLarge)
        coverMedium = try c.decodeIfPresent(String.self, forKey: .coverMedium)
        coverSmall = try c.decodeIfPresent(String.self, forKey: .coverSmall)
        eventId = try c.decode(Int.self, forKey: .eventId)
        gaplessUrl = try c.decode(String.self, forKey: .gaplessUrl)
        slideshow = try c.decodeIfPresent([String].self, forKey: .slideshow) ?? []
        type = try c.decode(String.self, forKey: .type)
        schedTimeMillis = try c.decodeIfPresent(Int64.self, forKey: .schedTimeMillis) ?? 0
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating) ?? 0
        rating = try c.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        ratingsNum = try c.decodeIfPresent(Int.self, forKey: .ratingsNum) ?? 0
        episodeId = try c.decodeIfPresent(Int.self, forKey: .episodeId) ?? 0
        sliceNum = try c.decodeIfPresent(Int.self, forKey: .sliceNum) ?? 0
        isRateable = try c.decodeIfPresent(Bool.self, forKey: .isRateable) ?? false
        isPlayableAfterSkip = try c.decodeIfPresent(Bool.self, forKey: .isPlayableAfterSkip) ?? true
        isPlayableOnStart = try c.decodeIfPresent(Bool.self, forKey: .isPlayableOnStart) ?? true
        updateHistory = try c.decodeIfPresent(Bool.self, forKey: .updateHistory) ?? false
        skipAllowedMillis = try c.decodeIfPresent(Int64.self, forKey: .skipAllowedMillis) ?? 0
    }
}

public struct GaplessResponse: Decodable, Sendable, Equatable {
    public let channel: Channel
    public let bitrateTitle: String?
    public let ext: String?
    public let imageBase: String
    public let currentEventId: Int
    public let maxGaplessEventId: Int
    public let slideshowPath: String
    public let timeoutMillis: Int
    public let songs: [GaplessSong]

    enum CodingKeys: String, CodingKey {
        case channel
        case bitrateTitle = "bitrate_title"
        case ext = "extension"
        case imageBase = "image_base"
        case currentEventId, maxGaplessEventId, slideshowPath, timeoutMillis, songs
    }
}
```

Notes:
- `JSONDecoder.rpDecoder` uses `convertFromSnakeCase`. The CodingKeys above lean on that for most fields. Custom raw values are required only where snake-case conversion produces the wrong key — `bitrate_title` / `extension` / `image_base` (the existing pattern in `GetBlock` keeps explicit string keys for everything; this struct mostly relies on the converter).
- `extension` is a Swift reserved word, hence the `ext` Swift name with an explicit raw value.
- `album` is normalised to `nil` when empty (promo songs return `""`).

### Step 1.5: Run the tests to verify they pass

- [ ] `swift test --filter GaplessResponseTests`. Expected: 2 tests PASS.

### Step 1.6: Commit

- [ ] ```bash
git checkout -b claude/pr31-gapless-migration
git add Sources/RPPlayer/Api/ApiModels.swift Tests/RPPlayerTests/Api/GaplessResponseTests.swift Tests/RPPlayerTests/Fixtures/Api/gapless_main.json
git commit -m "$(cat <<'EOF'
feat: add GaplessResponse + GaplessSong API types

Decodes the api/gapless endpoint that replaces api/play. Each song is
self-contained (own URL, own cue, own duration, own event_id) so the
coordinator can drop block-centric state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `RpApiClient.gapless` method

**Files:**

- Modify: `Sources/RPPlayer/Api/RpApiClient.swift` (protocol + `LiveRpApiClient`)
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift` (or wherever `LiveRpApiClient` URL/cookie tests live — discover during impl)
- Modify: `Tests/RPPlayerTests/Stubs/StubRpApiClient.swift` (or equivalent — discover during impl)

### Step 2.1: Discover the existing test surface

- [ ] `grep -rn "func play\|func getBlock" Tests/` to find the test file(s) and any stub clients. Note the file paths for editing.
- [ ] `grep -rn "class StubRpApiClient\|struct StubRpApiClient\|class FakeRpApiClient" Tests/` to find stub clients used by coordinator tests. They will need a `gapless` impl too (returning a stored `GaplessResponse`).

### Step 2.2: Write a failing test for the URL shape

- [ ] In the discovered `LiveRpApiClient` test file, add:

```swift
func testGaplessSendsExpectedQueryAndDecodesResponse() async throws {
    let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api"))
    let fixtureData = try Data(contentsOf: fixtureURL)
    let expectedURL = URL(string: "https://api.radioparadise.com/api/gapless?bitrate=4&chan=0&numSongs=20&player_id=test-player")!
    StubURLProtocol.register(url: expectedURL, status: 200, body: fixtureData, contentType: "application/json")
    defer { StubURLProtocol.reset() }

    let client = LiveRpApiClient(
        baseURL: URL(string: "https://api.radioparadise.com")!,
        session: StubURLProtocol.makeSession(),
        cookieProvider: FixedCookieProvider(cookie: nil),
        playerId: "test-player"
    )
    let response = try await client.gapless(channel: 0, bitrate: 4, numSongs: 20)
    XCTAssertEqual(response.songs.count, 20) // adjust to fixture's actual count
    XCTAssertEqual(response.currentEventId, 2872450)
}

func testGaplessAttachesCookies() async throws {
    let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "gapless_main", withExtension: "json", subdirectory: "Fixtures/Api"))
    let fixtureData = try Data(contentsOf: fixtureURL)
    let expectedURL = URL(string: "https://api.radioparadise.com/api/gapless?bitrate=4&chan=99&numSongs=10&player_id=p")!
    StubURLProtocol.register(url: expectedURL, status: 200, body: fixtureData, contentType: "application/json")
    defer { StubURLProtocol.reset() }

    let client = LiveRpApiClient(
        baseURL: URL(string: "https://api.radioparadise.com")!,
        session: StubURLProtocol.makeSession(),
        cookieProvider: FixedCookieProvider(cookie: "C_username=foo; C_passwd=bar"),
        playerId: "p"
    )
    _ = try await client.gapless(channel: 99, bitrate: 4, numSongs: 10)
    let request = try XCTUnwrap(StubURLProtocol.lastRequest)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "C_username=foo; C_passwd=bar")
}
```

Verify the existing tests use `FixedCookieProvider` / `StubURLProtocol.register(...)` with these exact APIs; if they differ (e.g. `StubURLProtocol.registerSuccess`), align the new tests to the existing pattern.

### Step 2.3: Run tests to verify they fail

- [ ] `swift test --filter testGaplessSendsExpectedQueryAndDecodesResponse`. Expected: FAIL — `gapless` method undefined.

### Step 2.4: Add the protocol method + LiveRpApiClient impl

- [ ] In `Sources/RPPlayer/Api/RpApiClient.swift`, add to the protocol after `getBlock`:

```swift
    func gapless(channel: Int, bitrate: Int, numSongs: Int) async throws -> GaplessResponse
```

- [ ] In `LiveRpApiClient`, add (placement: right after `getBlock`):

```swift
public func gapless(channel: Int, bitrate: Int, numSongs: Int) async throws -> GaplessResponse {
    var query: [String: String] = [
        "chan": String(channel),
        "bitrate": String(bitrate),
        "numSongs": String(numSongs),
    ]
    if let playerId {
        query["player_id"] = playerId
    }
    return try await get(path: "api/gapless", query: query)
}
```

### Step 2.5: Update stub clients to compile

- [ ] In each stub (`StubRpApiClient` etc.) found in step 2.1, add a stored `var gaplessResponse: GaplessResponse?` and a method:

```swift
func gapless(channel: Int, bitrate: Int, numSongs: Int) async throws -> GaplessResponse {
    if let response = gaplessResponse { return response }
    throw RpApiError.network(URLError(.badServerResponse))
}
```

(Match the existing stub style — actor / struct / class.)

### Step 2.6: Run tests to verify they pass

- [ ] `swift test --filter RpApiClientTests`. Expected: PASS for new tests; existing tests still green.

### Step 2.7: Commit

- [ ] ```bash
git add Sources/RPPlayer/Api/RpApiClient.swift Tests/RPPlayerTests
git commit -m "$(cat <<'EOF'
feat: add RpApiClient.gapless method

GET /api/gapless?bitrate=N&chan=N&numSongs=N&player_id=ID. Cookies
attached for favorites support (chan=99). Stub clients gain a
gaplessResponse seed for upcoming coordinator-test rewrites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate `NowPlaying` field names

**Files:**

- Modify: `Sources/RPPlayer/Playback/NowPlaying.swift`
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (just the `NowPlaying(...)` constructor call in `emitNowPlaying`)
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` (3 callsites)
- Modify: `Sources/RPPlayer/Shell/NowPlayingCenterController.swift` (2 callsites)
- Modify: `Tests/RPPlayerTests/Playback/NowPlayingTests.swift`
- Modify: `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift`
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (2 callsites referencing `songIndexInBlock`, 1 referencing `blockBitrate`)

**Strategy: keep `song: PlayListSong` in this task — only rename the position-related fields.** The `PlayListSong` → `GaplessSong` type swap happens in Task 5 with view-model cleanup. This way every task ends with `swift build` green.

### Step 3.1: Rewrite `NowPlaying`

- [ ] Replace the entire body of `Sources/RPPlayer/Playback/NowPlaying.swift` with:

```swift
public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: PlayListSong
    public let songDurationSeconds: Double
    public var bitrateLabel: String?

    public init(
        channelId: Int,
        song: PlayListSong,
        songDurationSeconds: Double,
        bitrateLabel: String? = nil
    ) {
        self.channelId = channelId
        self.song = song
        self.songDurationSeconds = songDurationSeconds
        self.bitrateLabel = bitrateLabel
    }
}
```

### Step 3.2: Update `LivePlaybackCoordinator.emitNowPlaying`

- [ ] In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` find `emitNowPlaying(forSongIndex:)`. Change the `NowPlaying(...)` constructor call:

  Replace this block:
  ```swift
  let np = NowPlaying(
      channelId: channelId,
      song: song,
      songIndexInBlock: idx,
      blockDurationSeconds: BlockSongs.totalDurationSeconds(songs: orderedSongs),
      songStartSeconds: songStart,
      songEndSeconds: songEnd,
      blockBitrate: currentBlock?.bitrate
  )
  ```
  With:
  ```swift
  let np = NowPlaying(
      channelId: channelId,
      song: song,
      songDurationSeconds: Double(song.duration) / 1000.0,
      bitrateLabel: currentBlock?.bitrate
  )
  ```

  (`songStart` / `songEnd` local lets above this line become unused; delete them.)

### Step 3.3: Update view-model field references

- [ ] `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`:
  - Line ~121: `BlockBitrateLabel.display(np.blockBitrate)` → `BlockBitrateLabel.display(np.bitrateLabel)`.
  - Line ~122: `let newDuration = max(0, np.songEndSeconds - np.songStartSeconds)` → `let newDuration = np.songDurationSeconds`.
  - Line ~123–124: replace the `if np.songStartSeconds != self.lastSongStartSeconds { … }` boundary-detection block with a song-id check:
    ```swift
    if np.song.songId != self.lastNotifiedSongId {
        self.lastNotifiedSongId = np.song.songId
        self.songElapsedSeconds = 0
    }
    self.songDurationSeconds = newDuration
    ```
    Rename the property declaration `lastSongStartSeconds: Double` → `lastNotifiedSongId: String` (default `""`).
  - Line ~152: `let duration = max(0, np.songEndSeconds - np.songStartSeconds)` → `let duration = np.songDurationSeconds`.
  - Line ~153: `let elapsed = max(0, pos - np.songStartSeconds)` → `let elapsed = max(0, pos)`.

- [ ] `Sources/RPPlayer/Shell/NowPlayingCenterController.swift`:
  - Line ~101: `lastSongDuration = max(0, np.songEndSeconds - np.songStartSeconds)` → `lastSongDuration = np.songDurationSeconds`.
  - Line ~163: `let elapsed = max(0, blockPosition - np.songStartSeconds)` → `let elapsed = max(0, blockPosition)`.

  In this task `np.song` is still `PlayListSong`, so cover/userRating accesses don't need changes here.

### Step 3.4: Update tests

- [ ] `Tests/RPPlayerTests/Playback/NowPlayingTests.swift`: replace constructor calls. Old:
  ```swift
  let np1 = NowPlaying(channelId: 0, song: song, songIndexInBlock: 1,
                       blockDurationSeconds: 600, songStartSeconds: 60, songEndSeconds: 240)
  ```
  New:
  ```swift
  let np1 = NowPlaying(channelId: 0, song: song, songDurationSeconds: 180)
  ```
  Drop tests asserting on removed fields. Update `Equatable` round-trip tests to match the new shape.

- [ ] `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift`: update the `NowPlaying(...)` constructor call (line ~18–19). Old:
  ```swift
  channelId: 0, song: makeSong(id: songId), songIndexInBlock: 0,
  blockDurationSeconds: 0, songStartSeconds: 0, songEndSeconds: 0
  ```
  New:
  ```swift
  channelId: 0, song: makeSong(id: songId), songDurationSeconds: 0
  ```

- [ ] `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`: update lines that read `np.songIndexInBlock` and `np.blockBitrate`:
  - Line ~83: `np?.blockBitrate` → `np?.bitrateLabel`.
  - Lines ~216 + ~294: `np.songIndexInBlock` → for now, drop these assertions or replace with `np.song.songId` comparisons. (Task 4 will rewrite this file end-to-end; minimal change here just to keep the build green.)

### Step 3.5: Build + test

- [ ] `swift build`. Expected: green.
- [ ] `swift test`. Expected: all green.

### Step 3.6: Commit

- [ ] ```bash
git add Sources/RPPlayer/Playback/NowPlaying.swift Sources/RPPlayer/Playback/PlaybackCoordinator.swift Sources/RPPlayer/Shell Tests/RPPlayerTests
git commit -m "$(cat <<'EOF'
refactor: simplify NowPlaying to per-song shape

Replaces songIndexInBlock + blockDurationSeconds + songStartSeconds +
songEndSeconds + blockBitrate with songDurationSeconds + bitrateLabel.
song field type stays PlayListSong (Task 5 swaps to GaplessSong).
View-model song-boundary detection switches from songStartSeconds delta
to songId comparison.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Refactor `LivePlaybackCoordinator` to queue model

**Files:**

- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (~800 lines, near-total rewrite of the live class)
- Modify: `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift` (re-author against gapless model)
- Create: `Tests/RPPlayerTests/Fixtures/Api/gapless_promo_first.json` (a tiny ≤3-song fixture with a promo at queue[0] for edge-case tests)
- No file deletions yet — `BlockSongs.swift` removal happens in Task 7. This task stops calling `BlockSongs.isStale` and `BlockSongs.orderedSongs` but leaves the file present until Task 7.

### Step 4.1: Read the existing coordinator end-to-end

- [ ] Open `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` and read it fully. Note: this task has to preserve PR 30's stall watchdog (`armLongIdleStallWatchdog`, `cancelStallWatchdog`, `surfaceStallError`, `waitForFirstPositionUpdate`, `logStallWatchdogTimeout`, the `sleep` injection, all of `stallWatchdog` state) untouched in semantics — only the fetch path beneath the long-idle resume branch changes.

### Step 4.2: Read the existing test file

- [ ] Open `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`. Inventory which tests survive (stall watchdog tests, channel-change tests, error tests if they don't mention block-internals, position-stream tests) and which need rewriting (block-shaped tests: stale-block, prefetch-swap, song-boundary-cross via `elapsed` arithmetic, last-song-prefetch trigger). The latter group is the bulk.

### Step 4.3: Rewrite the coordinator state model

- [ ] In `LivePlaybackCoordinator` (the actor body), replace this property block:

```swift
    private var currentChannelId: Int?
    private var currentBlock: GetBlock?
    private var orderedSongs: [PlayListSong] = []
    private var startsAt: [Double] = []
    private var currentSongIndex: Int = 0
```

with:

```swift
    private var currentChannelId: Int?
    private var queue: [GaplessSong] = []
    private var currentResponse: GaplessResponse?
```

- [ ] Replace this property block:

```swift
    private var prefetchedBlock: GetBlock?
    private var prefetchTask: Task<GetBlock?, Never>?
    private var queuedToEngine: Bool = false
```

with:

```swift
    private var refetchTask: Task<Void, Never>?
```

Keep all PR 30 stall-watchdog state unchanged (`stallWatchdog`, `stallWatchdogTimeoutSeconds`, `longIdleResumeThresholdSeconds`).

### Step 4.4: Rewrite `play(channelId:)`

- [ ] Replace the entire `play(channelId:)` method body with:

```swift
public func play(channelId: Int) async throws {
    logger.debug("play(channelId: \(channelId))")
    cancelStallWatchdog()
    await ensureEventSubscription()
    let bitrate = await bitrateProvider()
    logger.debug("play resolved bitrate=\(bitrate)")
    let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
    guard !response.songs.isEmpty else { throw PlaybackCoordinatorError.blockHasNoSongs }

    queue = response.songs
    currentResponse = response
    currentChannelId = channelId
    refetchTask?.cancel()
    refetchTask = nil

    let head = queue[0]
    let startSeconds: Double? = head.cue > 0 ? Double(head.cue) / 1000.0 : nil
    currentPositionSeconds = startSeconds ?? 0

    guard let url = URL(string: head.gaplessUrl) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid gapless url: \(head.gaplessUrl)")
    }

    logger.debug("play queue:\n\(describeQueue(songs: queue))")
    logger.debug("play engine.play url=\(url.absoluteString) startSeconds=\(startSeconds.map { "\($0)s" } ?? "nil (beginning)")")

    await prePlayHook()
    do {
        try await engine.play(url: url, startSeconds: startSeconds)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }

    if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
        try? await engine.queueNext(url: nextUrl, startSeconds: nil)
    }

    emitNowPlaying(forSongAt: 0)
    emitState(.playing)
    fireSongStartTelemetry(song: queue[0], channelId: channelId)
}
```

- [ ] Replace `describeBlock(url:songs:starts:)` with `describeQueue(songs:)`:

```swift
private func describeQueue(songs: [GaplessSong]) -> String {
    let preview = songs.prefix(5).enumerated().map { i, s in
        "  [\(i)] event=\(s.eventId) cue=\(s.cue)ms duration=\(s.duration)ms type=\(s.type) \(s.artist) — \(s.title)"
    }.joined(separator: "\n")
    let more = songs.count > 5 ? "\n  … (+\(songs.count - 5) more)" : ""
    return "queue (count=\(songs.count)):\n\(preview)\(more)"
}
```

### Step 4.5: Rewrite `emitNowPlaying`

**Note:** at this task `NowPlaying.song` is still `PlayListSong` (per Task 3's shim approach). Convert `GaplessSong` → `PlayListSong` at emit time. Task 5 will swap the type and drop the converter.

- [ ] Add a private converter:

```swift
private func playListSong(from g: GaplessSong) -> PlayListSong {
    PlayListSong(
        songId: g.songId,
        artist: g.artist,
        title: g.title,
        album: g.album,
        duration: g.duration,
        event: String(g.eventId),
        schedTime: nil,
        chan: nil,
        year: g.year,
        asin: nil,
        rating: g.rating > 0 ? String(g.rating) : nil,
        userRating: g.userRating > 0 ? String(g.userRating) : nil,
        cover: g.coverLarge ?? g.coverMedium,
        elapsed: nil,
        slideshow: nil,
        type: g.type,
        sliceNum: String(g.sliceNum)
    )
}
```

- [ ] Replace the existing `emitNowPlaying(forSongIndex:)` with:

```swift
private func emitNowPlaying(forSongAt index: Int) {
    guard index >= 0, index < queue.count, let channelId = currentChannelId else { return }
    let song = queue[index]
    let np = NowPlaying(
        channelId: channelId,
        song: playListSong(from: song),
        songDurationSeconds: Double(song.duration) / 1000.0,
        bitrateLabel: currentResponse?.bitrateTitle
    )
    current = np
    for cont in continuations.values {
        cont.yield(np)
    }
    if currentResponse != nil {
        Task { [weak self] in await self?.prefetchUpcomingSongArt() }
    }
}
```

(The old `maybeStartPrefetch()` callsite at the bottom is gone — refetch is driven from `kickRefetch` via boundary cross instead.)

- [ ] Update `prefetchUpcomingSongArt`:

```swift
private func prefetchUpcomingSongArt() {
    guard queue.count >= 2 else { return }
    let nextSong = queue[1]
    let cover = nextSong.coverLarge ?? nextSong.coverMedium
    guard let cover, !cover.isEmpty else { return }
    Task { [weak self] in
        guard let self else { return }
        await self.prefetchArt(cover)
    }
}
```

### Step 4.6: Rewrite the engine event handler

- [ ] Replace `handleEngineEvent(_:)` with:

```swift
private func handleEngineEvent(_ event: PlayerEvent) async {
    switch event {
    case .fileLoaded:
        consecutivePlaybackFailures = 0

    case .fileStarted:
        guard !queue.isEmpty else { return }
        // queue[0] just ended (mpv auto-advanced to the queued entry).
        // Fire telemetry for the song that just finished.
        let finished = queue[0]
        let finishedPlaytime = Int(currentPositionSeconds.rounded())
        if finished.updateHistory, let channelId = currentChannelId {
            Task { [weak self] in
                try? await self?.api.updateHistory(
                    songId: finished.songId,
                    chan: channelId,
                    event: String(finished.eventId),
                    audioType: finished.type,
                    sliceNum: String(finished.sliceNum),
                    playPositionMillis: finished.duration,
                    playtimeSecs: finishedPlaytime,
                    pauseFlag: false
                )
            }
        }
        // Advance queue.
        queue.removeFirst()
        currentPositionSeconds = 0
        guard !queue.isEmpty else {
            logger.warning("fileStarted but queue is empty post-removeFirst — refetching")
            kickRefetch()
            return
        }
        emitNowPlaying(forSongAt: 0)
        fireSongStartTelemetry(song: queue[0], channelId: currentChannelId ?? 0)
        if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
            try? await engine.queueNext(url: nextUrl, startSeconds: nil)
        }
        if queue.count < 3 {
            kickRefetch()
        }

    case .positionUpdate(let seconds):
        currentPositionSeconds = seconds
        for cont in positionContinuations.values {
            cont.yield(seconds)
        }

    case .fileEnded(.eof):
        // mpv reached EOF without auto-advancing — refetch lagged. Recover.
        logger.warning("fileEnded(.eof) without queued entry; recovering")
        if queue.count >= 2 {
            queue.removeFirst()
            if let url = URL(string: queue[0].gaplessUrl) {
                do {
                    try await engine.play(url: url, startSeconds: nil)
                    currentPositionSeconds = 0
                    emitNowPlaying(forSongAt: 0)
                    fireSongStartTelemetry(song: queue[0], channelId: currentChannelId ?? 0)
                    if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
                        try? await engine.queueNext(url: nextUrl, startSeconds: nil)
                    }
                    if queue.count < 3 { kickRefetch() }
                    return
                } catch {
                    handlePlaybackError(code: -99)
                    return
                }
            }
        }
        // Queue depleted entirely. Refetch + retry.
        guard let channelId = currentChannelId else {
            handlePlaybackError(code: -99)
            return
        }
        do {
            try await play(channelId: channelId)
        } catch {
            handlePlaybackError(code: -99)
        }

    case .fileEnded(.error(let code)):
        if isUnplayableSongCode(code) && queue.count >= 2 {
            handleSongPlaybackError(code: code)
        } else {
            handlePlaybackError(code: code)
        }

    case .error(let message):
        logger.warning("engine error: \(message)")

    case .shutdown:
        break
    }
}
```

### Step 4.7: Rewrite `skipForward`

- [ ] Replace `skipForward()` with:

```swift
public func skipForward() async throws {
    cancelStallWatchdog()
    guard !queue.isEmpty, let channelId = currentChannelId else { return }
    let skipped = queue[0]
    let playtime = Int(currentPositionSeconds.rounded())
    if skipped.updateHistory {
        Task { [weak self] in
            try? await self?.api.updateHistory(
                songId: skipped.songId,
                chan: channelId,
                event: String(skipped.eventId),
                audioType: skipped.type,
                sliceNum: String(skipped.sliceNum),
                playPositionMillis: playtime * 1000,
                playtimeSecs: playtime,
                pauseFlag: false
            )
        }
    }
    if queue.count >= 2 {
        do {
            try await engine.advanceToQueued()
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }
        // The .fileStarted handler will run queue.removeFirst() + state advance.
    } else {
        // Synchronous refetch + restart.
        let bitrate = await bitrateProvider()
        do {
            let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
            guard !response.songs.isEmpty else {
                errorsContinuation.yield("Cannot skip — no upcoming songs.")
                return
            }
            queue = response.songs
            currentResponse = response
            let head = queue[0]
            currentPositionSeconds = head.cue > 0 ? Double(head.cue) / 1000.0 : 0
            guard let url = URL(string: head.gaplessUrl) else {
                errorsContinuation.yield("Cannot skip — invalid url.")
                return
            }
            try await engine.play(url: url, startSeconds: head.cue > 0 ? Double(head.cue) / 1000.0 : nil)
            if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
                try? await engine.queueNext(url: nextUrl, startSeconds: nil)
            }
            emitNowPlaying(forSongAt: 0)
            fireSongStartTelemetry(song: queue[0], channelId: channelId)
        } catch {
            errorsContinuation.yield("Cannot skip — try again.")
        }
    }
}
```

### Step 4.8: Rewrite `pause()`

- [ ] `pause()` is largely unchanged. The `update_pause` telemetry call references `orderedSongs[currentSongIndex]` — replace with `queue[0]`. Audit + update accordingly:

```swift
public func pause() async throws {
    cancelStallWatchdog()
    guard isPlaying, let channelId = currentChannelId, !queue.isEmpty else { return }
    pausedAt = clock()
    pausePositionMs = Int(currentPositionSeconds * 1000)
    let song = queue[0]
    do {
        try await engine.pause()
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    emitState(.paused)
    if song.updateHistory {
        Task { [weak self, pausePositionMs, channelId] in
            try? await self?.api.updatePause(
                songId: song.songId,
                chan: channelId,
                event: String(song.eventId),
                audioType: song.type,
                sliceNum: String(song.sliceNum),
                playPositionMillis: pausePositionMs ?? 0,
                playtimeSecs: (pausePositionMs ?? 0) / 1000
            )
        }
    }
}
```

(Note: read the existing `pause()` carefully — it has `isPlaying` check via the engine, gates on `pausePositionMs` being non-nil, etc. Preserve those. Above is the structural shape; align with current control flow.)

### Step 4.9: Rewrite `resume()`

- [ ] Long-idle branch: drop queue + refetch via `play(channelId:)`. Short-idle branch: simply `engine.play` the current `queue[0]` from `currentPositionSeconds`. Replace `resume()` with:

```swift
public func resume() async throws {
    guard let channelId = currentChannelId, !queue.isEmpty else { return }
    let now = clock()
    let pausedAtSeconds = pausedAt ?? now
    let idleSeconds = max(0, now - pausedAtSeconds)
    let block = currentResponse  // snapshot for expiration check (unused in gapless model — see below)

    let isLongIdle = idleSeconds >= longIdleResumeThresholdSeconds
    if isLongIdle {
        logger.info("long-idle resume (\(Int(idleSeconds))s) — refetching gapless")
        queue = []
        currentResponse = nil
        try? await engine.clearPlaylist()
        try await play(channelId: channelId)
        armLongIdleStallWatchdog(channelId: channelId)
        return
    }

    let head = queue[0]
    guard let url = URL(string: head.gaplessUrl) else {
        throw PlaybackCoordinatorError.engineError(message: "invalid gapless url: \(head.gaplessUrl)")
    }
    do {
        try await engine.play(url: url, startSeconds: currentPositionSeconds > 0 ? currentPositionSeconds : nil)
    } catch {
        throw PlaybackCoordinatorError.engineError(message: String(describing: error))
    }
    if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
        try? await engine.queueNext(url: nextUrl, startSeconds: nil)
    }
    emitState(.playing)
    pausedAt = nil
    pausePositionMs = nil
    _ = block // silence unused warning if the old expiration check is dropped
}
```

Notes:
- Drop the old `block.expiration` check entirely. Gapless responses don't carry a block expiration; long-idle threshold (≥ 59 min) is the sole refetch trigger.
- `armLongIdleStallWatchdog(channelId:)` is the existing PR 30 method. Confirm its signature accepts `channelId` (it currently does — the existing `resume()` has the call site).

### Step 4.10: Rewrite cleanup methods

- [ ] `changeChannel(to:)`:

```swift
public func changeChannel(to channelId: Int) async throws {
    cancelStallWatchdog()
    refetchTask?.cancel()
    refetchTask = nil
    queue = []
    currentResponse = nil
    try? await engine.clearPlaylist()
    try await play(channelId: channelId)
}
```

- [ ] `stop()`:

```swift
public func stop() async {
    cancelStallWatchdog()
    refetchTask?.cancel()
    refetchTask = nil
    queue = []
    currentResponse = nil
    currentChannelId = nil
    currentPositionSeconds = 0
    pausedAt = nil
    pausePositionMs = nil
    try? await engine.clearPlaylist()
    do { try await engine.stop() } catch { /* swallow */ }
    emitState(.stopped)
    current = nil
    for cont in continuations.values {
        // Don't finish — the stream stays open for future plays.
    }
}
```

(Read the existing `stop()`; preserve any subtlety around the continuations or device release. The above is the queue-state portion only.)

- [ ] `handlePlaybackError(code:)`: replace block-state cleanup with queue cleanup. Existing structure (cancel prefetch + clear state + emit error) stays — only the field assignments change:

```swift
private func handlePlaybackError(code: Int32) {
    cancelStallWatchdog()
    refetchTask?.cancel()
    refetchTask = nil
    queue = []
    currentResponse = nil
    currentChannelId = nil
    currentPositionSeconds = 0
    pausedAt = nil
    pausePositionMs = nil
    Task { [weak self] in try? await self?.engine.clearPlaylist() }
    let message: String
    switch code {
    case -14:
        message = "Audio device unavailable. Check System Settings → Sound → Output."
        onDeviceUnavailable?()
    default:
        message = "Playback stopped unexpectedly (error \(code))."
    }
    errorsContinuation.yield(message)
    emitState(.stopped)
}
```

- [ ] `shutdown()`: clear queue + cancel refetch + cancel watchdog. Otherwise unchanged. Audit existing body and update field assignments.

### Step 4.11: Add `kickRefetch()` and `handleSongPlaybackError(code:)`

- [ ] Drop `maybeStartPrefetch`, `absorbPrefetchResult`, `swapToPrefetchedBlockState`, `swapToPrefetchedBlockIfAvailable`, `advancePastUnplayableBlock`. Replace with:

```swift
private func kickRefetch() {
    guard refetchTask == nil, let channelId = currentChannelId else { return }
    let headEvent = queue.first?.eventId ?? 0
    refetchTask = Task { [weak self] in
        guard let self else { return }
        await self.runRefetch(channelId: channelId, headEvent: headEvent)
    }
}

private func runRefetch(channelId: Int, headEvent: Int) async {
    let bitrate = await bitrateProvider()
    do {
        let response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)
        // Race-guard: discard if channel changed or head moved during await.
        guard self.currentChannelId == channelId,
              self.queue.first?.eventId == headEvent else {
            self.refetchTask = nil
            return
        }
        guard let firstHead = self.queue.first else {
            self.refetchTask = nil
            return
        }
        let newSongs = response.songs.filter { $0.eventId > firstHead.eventId }
        let hadShortQueue = self.queue.count < 2
        self.queue = [firstHead] + newSongs
        self.currentResponse = response
        if hadShortQueue, self.queue.count >= 2, let nextUrl = URL(string: self.queue[1].gaplessUrl) {
            try? await self.engine.queueNext(url: nextUrl, startSeconds: nil)
        }
        self.refetchTask = nil
    } catch {
        self.logger.warning("kickRefetch failed: \(error)")
        self.refetchTask = nil
    }
}

private func isUnplayableSongCode(_ code: Int32) -> Bool {
    // mpv error -16 = MPV_ERROR_LOADING_FAILED. Any code that is per-song-fatal
    // but not catastrophic (audio device, network down) goes here.
    return code == -16
}

private func handleSongPlaybackError(code: Int32) {
    guard !queue.isEmpty else {
        handlePlaybackError(code: code)
        return
    }
    let dropped = queue.removeFirst()
    logger.warning("dropping unplayable song event=\(dropped.eventId) url=\(dropped.gaplessUrl) code=\(code)")
    if queue.isEmpty {
        guard let channelId = currentChannelId else {
            handlePlaybackError(code: code)
            return
        }
        Task { [weak self] in
            do { try await self?.play(channelId: channelId) } catch { self?.handlePlaybackError(code: code) }
        }
        return
    }
    let head = queue[0]
    guard let url = URL(string: head.gaplessUrl) else {
        handlePlaybackError(code: code)
        return
    }
    Task { [weak self] in
        guard let self else { return }
        do {
            try await self.engine.play(url: url, startSeconds: nil)
            await MainActor.run { _ = () } // no-op; guarantees scheduling order
            await self.afterSongErrorAdvance()
        } catch {
            self.handlePlaybackError(code: code)
        }
    }
}

private func afterSongErrorAdvance() async {
    currentPositionSeconds = 0
    emitNowPlaying(forSongAt: 0)
    fireSongStartTelemetry(song: queue[0], channelId: currentChannelId ?? 0)
    if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
        try? await engine.queueNext(url: nextUrl, startSeconds: nil)
    }
    if queue.count < 3 {
        kickRefetch()
    }
}
```

### Step 4.12: Update `fireSongStartTelemetry`

- [ ] Replace the body's `PlayListSong` parameter with `GaplessSong` and adjust field references:

```swift
private func fireSongStartTelemetry(song: GaplessSong, channelId: Int) {
    guard song.updateHistory else { return }
    Task { [weak self] in
        try? await self?.api.updateHistory(
            songId: song.songId,
            chan: channelId,
            event: String(song.eventId),
            audioType: song.type,
            sliceNum: String(song.sliceNum),
            playPositionMillis: 0,
            playtimeSecs: 0,
            pauseFlag: false
        )
    }
}
```

### Step 4.13: Audit other coordinator helpers + drop `BlockSongs.isStale` use

- [ ] No `BlockSongs.*` calls should remain in this file. Search and confirm.
- [ ] All `currentBlock`, `orderedSongs`, `startsAt`, `currentSongIndex`, `prefetchedBlock`, `prefetchTask`, `queuedToEngine` references gone.
- [ ] Build: `swift build`. Expected: this file compiles. Other files (view models) still error — Task 5 fixes them.

### Step 4.14: Re-author the coordinator tests

- [ ] Open `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift`. Survey:
  - Tests that touch `block.url`, `block.cue`, `block.song`, `BlockSongs.*`, `songIndexInBlock`, `startsAt`, `currentBlock` etc. → rewrite.
  - Tests for stall watchdog (PR 30) → keep, but stub `gapless` instead of `play`/`getBlock`.
  - Tests for stale-block detection → delete entirely.
  - Tests for prefetch+swap → rewrite as queue-append tests.

- [ ] Replace block-shaped fixtures with `GaplessResponse` builders. Add a helper at the top of the test file:

```swift
private func makeGaplessSong(
    songId: String = "1",
    eventId: Int = 100,
    cue: Int = 0,
    duration: Int = 180_000,
    type: String = "M",
    gaplessUrl: String = "https://example.com/song.flac",
    updateHistory: Bool = true,
    isRateable: Bool = true,
    isPlayableAfterSkip: Bool = true,
    artist: String = "Artist",
    title: String = "Title",
    album: String? = "Album",
    sliceNum: Int = 0
) -> GaplessSong {
    let json: [String: Any] = [
        "song_id": songId,
        "artist": artist,
        "title": title,
        "album": album as Any,
        "duration": duration,
        "cue": cue,
        "event_id": eventId,
        "gapless_url": gaplessUrl,
        "type": type,
        "update_history": updateHistory,
        "is_rateable": isRateable,
        "is_playable_after_skip": isPlayableAfterSkip,
        "is_playable_on_start": true,
        "slice_num": sliceNum,
        "rating": 0,
        "user_rating": 0,
        "ratings_num": 0,
        "episode_id": 0,
        "sched_time_millis": 0,
        "skip_allowed_millis": 0,
        "slideshow": []
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder.rpDecoder.decode(GaplessSong.self, from: data)
}

private func makeGaplessResponse(songs: [GaplessSong], chan: String = "0", bitrateTitle: String = "flac") -> GaplessResponse {
    let songsJSON: [[String: Any]] = songs.map { s in
        // Re-serialise each song. Easier: encode via JSONEncoder. But GaplessSong
        // is Decodable-only. Build a tiny dictionary from its fields:
        return [
            "song_id": s.songId,
            "artist": s.artist,
            "title": s.title,
            "album": s.album as Any,
            "duration": s.duration,
            "cue": s.cue,
            "event_id": s.eventId,
            "gapless_url": s.gaplessUrl,
            "type": s.type,
            "update_history": s.updateHistory,
            "is_rateable": s.isRateable,
            "is_playable_after_skip": s.isPlayableAfterSkip,
            "is_playable_on_start": s.isPlayableOnStart,
            "slice_num": s.sliceNum,
            "rating": s.rating,
            "user_rating": s.userRating,
            "ratings_num": s.ratingsNum,
            "episode_id": s.episodeId,
            "sched_time_millis": s.schedTimeMillis,
            "skip_allowed_millis": s.skipAllowedMillis,
            "slideshow": s.slideshow
        ]
    }
    let json: [String: Any] = [
        "channel": ["chan": chan, "title": "Test", "stream_name": "test", "isER": false],
        "bitrate_title": bitrateTitle,
        "extension": "flac",
        "image_base": "//img.test/",
        "current_event_id": songs.first?.eventId ?? 0,
        "max_gapless_event_id": (songs.first?.eventId ?? 0) + 50,
        "slideshow_path": "slideshow/720/",
        "timeout_millis": 2_700_000,
        "songs": songsJSON
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)
}
```

- [ ] Author tests covering:

  1. `testPlayFetchesGaplessAndStartsFirstSong` — bootstrap fetch, engine.play called with first song's URL + cue, queueNext called with second song's URL.
  2. `testPlayWithSingleSongResponseDoesNotQueueNext` — only 1 song in response.
  3. `testFileStartedAdvancesQueueAndQueuesNext` — emit `.fileStarted`, expect `queue.removeFirst`, `emitNowPlaying` for new head, `queueNext` for new index 1, telemetry for finished song.
  4. `testFileStartedRefetchesWhenQueueShallow` — when queue has 2 songs and `.fileStarted` fires, `kickRefetch` is invoked (assert via stub `gapless` call counter).
  5. `testSkipForwardWithDeepQueueCallsAdvanceToQueued` — skip advances via mpv, telemetry for skipped song.
  6. `testSkipForwardWithSingleSongRefetches` — skip with `queue.count == 1` triggers gapless refetch + engine.play.
  7. `testChangeChannelClearsQueueAndRefetches` — channel change clears + clearPlaylist + new gapless call.
  8. `testLongIdleResumeRefetchesViaGapless` — pause for ≥ 59 min, resume, expect new gapless call + engine.play.
  9. `testEngineErrorCode16DropsSongAndAdvances` — emit `.fileEnded(.error(-16))`, queue head dropped, engine.play called for new head.
  10. `testEngineErrorCode14ClearsAllStateAndYieldsDeviceMessage` — code -14 routes through `handlePlaybackError`, errors stream yields the device-unavailable message.
  11. `testKickRefetchAppendsNewSongs` — set up queue with head event 100, gapless returns events [100,101,102,...]; expect queue[1] = event 101.
  12. `testKickRefetchRaceGuardDiscardsResultOnChannelChange` — change channel mid-fetch; result discarded.
  13. `testStallWatchdogStillTimeoutAfterLongIdleResume` — preserves PR 30 behavior.
  14. `testPromoSongAtQueueZeroSkipsTelemetry` — `updateHistory == false` → no `update_history` call.
  15. `testEmptyGaplessResponseThrowsBlockHasNoSongs`.

- [ ] Delete tests that don't apply to the new model: stale-block detection (entirely gone), prefetch+swap (replaced by queue-append), `songIndexInBlock` assertions.

### Step 4.15: Run the coordinator tests

- [ ] `swift test --filter LivePlaybackCoordinatorTests`. Expected: all green.

### Step 4.16: Commit

- [ ] ```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Sources/RPPlayer/Playback/NowPlaying.swift Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorTests.swift Tests/RPPlayerTests/Fixtures/Api/gapless_promo_first.json
git commit -m "$(cat <<'EOF'
refactor: migrate LivePlaybackCoordinator to gapless queue model

Replaces block-centric state (currentBlock + orderedSongs[] + startsAt[]
+ currentSongIndex + prefetchedBlock + prefetchTask + queuedToEngine)
with queue: [GaplessSong] + currentResponse + refetchTask. Boundary
crossing is driven by .fileStarted (queue.removeFirst + telemetry +
queueNext); skip uses advanceToQueued or sync refetch when queue thin;
long-idle resume drops queue and refetches via gapless. Stale-block
detection removed (per-song self-contained URLs make the recovery
redundant). PR 30 stall watchdog preserved.

Tests re-authored against gapless fixtures.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Do NOT add `BlockSongs.swift` or `ApiModels.swift` GetBlock to the deletion in this commit — Task 7 handles those.)

(Note: build is still red after this commit — view models reference old `NowPlaying` field names. Task 5 fixes that.)

---

## Task 5: Swap `NowPlaying.song` to `GaplessSong` + drop converter

**Files:**

- Modify: `Sources/RPPlayer/Playback/NowPlaying.swift`
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (drop the `playListSong(from:)` converter, change `emitNowPlaying` to pass `GaplessSong` directly)
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` (cover access path)
- Modify: `Sources/RPPlayer/Shell/NowPlayingCenterController.swift` (cover access path)
- Modify: `Sources/RPPlayer/Shell/PastSongViewModel.swift` (if it touches `song.cover`)
- Modify: `Tests/RPPlayerTests/Playback/NowPlayingTests.swift`
- Modify: `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift`

### Step 5.1: Swap the `NowPlaying.song` type

- [ ] In `Sources/RPPlayer/Playback/NowPlaying.swift`, change `song: PlayListSong` → `song: GaplessSong` in both the property and the initializer.

### Step 5.2: Drop the converter

- [ ] In `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`:
  - Remove `playListSong(from:)` (added in Task 4.5).
  - In `emitNowPlaying(forSongAt:)` change `song: playListSong(from: song)` → `song: song`.

### Step 5.3: Update view models for `GaplessSong` field shapes

`GaplessSong` field shapes vs `PlayListSong`:

| `PlayListSong`   | `GaplessSong`                             | Notes |
|---|---|---|
| `cover: String?` | `coverLarge: String?` / `coverMedium: String?` | Use `coverLarge ?? coverMedium` |
| `userRating: String?` | `userRating: Int` | `0` means unrated |
| `rating: String?` | `rating: Double`  | `0` means no rating |
| `songId: String` | `songId: String` | same |
| `artist`, `title` | same | same |
| `album: String?` | `album: String?` | same |
| `year: String?` | `year: String?` | same |
| `duration: Int` | `duration: Int` | same |
| `sliceNum: String?` | `sliceNum: Int` | telemetry sites convert via `String(...)` |
| `event: String?` | (use `eventId: Int` then `String(eventId)` if needed) | converter dropped |
| `type: String?` | `type: String` | always present in gapless |

- [ ] `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`: any `np.song.cover` → `np.song.coverLarge ?? np.song.coverMedium`. Any `parseRating(np.song.userRating)` → direct `Int` use (drop the `String?` parsing helper if no other callers remain). `np.song.rating` (if used for the rating-row display label) → format the `Double` value.

- [ ] `Sources/RPPlayer/Shell/NowPlayingCenterController.swift`: any `np.song.cover` → `coverLarge ?? coverMedium`. Album-art `MPMediaItemArtwork` builder reads cover URL from this same path.

- [ ] `Sources/RPPlayer/Shell/PastSongViewModel.swift`: `grep -n "song.cover\|song.userRating\|song.rating" Sources/RPPlayer/Shell/PastSongViewModel.swift`. Update accordingly. (Past-song popover still uses `PlayListSong` directly — only update if the file consumes a `NowPlaying` value.)

### Step 5.4: Test fixtures

- [ ] Hoist the `makeGaplessSong(...)` helper (added in Task 4.14) to a shared file: `Tests/RPPlayerTests/Helpers/GaplessFactories.swift`. Make `makeGaplessSong` and `makeGaplessResponse` `internal` and accessible across test targets.

### Step 5.5: `NowPlayingTests`

- [ ] Replace `NowPlaying(channelId: 0, song: song, songDurationSeconds: 180)` with `song: makeGaplessSong(...)`. The Equatable round-trip tests should still hold.

### Step 5.6: `NotificationClickRouterTests`

- [ ] Replace `NowPlaying(channelId: 0, song: makeSong(id: songId), songDurationSeconds: 0)` with `song: makeGaplessSong(songId: songId)`. The `NotificationClickRouter` itself uses `np.song.songId` — same string field on both types — so the router code likely doesn't need changes. Verify by inspection.

### Step 5.7: Build + test

- [ ] `swift build`. Green.
- [ ] `swift test`. All green.

### Step 5.8: Commit

- [ ] ```bash
git add Sources/RPPlayer Tests/RPPlayerTests
git commit -m "$(cat <<'EOF'
refactor: NowPlaying.song is now GaplessSong

Drops the PlayListSong shim from emitNowPlaying. View models read
covers via coverLarge / coverMedium (was: PlayListSong.cover) and
userRating as Int (was: String?). PlayListSong stays in the codebase
for the notification-click info → PlayListSong path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate `UpcomingProgramViewModel.load`

**Files:**

- Modify: `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`
- Modify: `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift` (if any field references on the row's `song` need updating)
- Modify: `Tests/RPPlayerTests/Upcoming/UpcomingProgramViewModelTests.swift`

### Step 6.1: Update the row + column types

- [ ] In `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`, change:

  ```swift
  struct UpcomingSongRow: Identifiable, Sendable {
      let id: String
      let song: PlayListSong   // → GaplessSong
      let art: NSImage?
      let ambientColor: Color
  }
  ```

### Step 6.2: Rewrite `load()`

- [ ] Replace the entire body of `load()` with the version below. Preserve all the channel-listing + ambient-extraction logic; only the per-channel fetch loop changes.

```swift
func load() async {
    await ensureNowPlayingSubscription()
    isLoading = true
    errorMessage = nil

    let settings = await configStore.settings
    let rowCount = settings.upcomingRowCount
    let hiddenIds = Set(settings.upcomingHiddenChannelIds)
    let bitrate = settings.bitrate

    let allChannels: [Channel]
    do {
        allChannels = try await api.listChannels()
    } catch {
        errorMessage = "Failed to load channels."
        isLoading = false
        return
    }
    cachedChannels = allChannels

    let enabledChannels = allChannels.filter {
        guard let id = Int($0.chan) else { return false }
        return id != 42 && id != 99 && !hiddenIds.contains(id)
    }
    skeletonColumnCount = enabledChannels.count

    // Single api/gapless call per channel. Filter promos inline.
    let api = self.api
    let fetchCount = max(rowCount * 2, rowCount + 5)  // overshoot to absorb promo filtering
    var rowResults: [(Int, Channel, [GaplessSong])] = []
    await withTaskGroup(of: (Int, Channel, [GaplessSong]).self) { group in
        for (i, channel) in enabledChannels.enumerated() {
            guard let chanId = Int(channel.chan) else { continue }
            group.addTask {
                let response = try? await api.gapless(channel: chanId, bitrate: bitrate, numSongs: fetchCount)
                let visible = (response?.songs ?? []).filter { $0.type != "P" && $0.songId != "0" }
                return (i, channel, Array(visible.prefix(rowCount)))
            }
        }
        for await result in group {
            rowResults.append(result)
        }
    }
    rowResults.sort { $0.0 < $1.0 }

    if rowResults.contains(where: { $0.2.isEmpty }) {
        errorMessage = "Some channels could not be loaded."
    }

    struct ColStub {
        let channel: Channel
        let chanId: Int
        let songs: [GaplessSong]
    }

    let stubs: [ColStub] = rowResults.compactMap { _, channel, songs in
        guard let chanId = Int(channel.chan) else { return nil }
        return ColStub(channel: channel, chanId: chanId, songs: songs)
    }

    // Collect art + palette results keyed by (colIndex, rowIndex).
    let albumArtCache = self.albumArtCache
    let paletteExtractor = self.paletteExtractor
    var artResults: [String: (NSImage?, Color)] = [:]
    await withTaskGroup(of: (String, NSImage?, Color).self) { group in
        for (ci, stub) in stubs.enumerated() {
            for (ri, song) in stub.songs.enumerated() {
                let cover = song.coverLarge ?? song.coverMedium
                guard let cover, !cover.isEmpty else { continue }
                let key = "\(ci)-\(ri)"
                group.addTask {
                    let image = await albumArtCache.image(for: cover)
                    var color = Color(nsColor: .windowBackgroundColor)
                    if let img = image,
                       let extracted = await paletteExtractor.extractBottomEdgeColor(from: img) {
                        color = extracted.swiftUIColor
                    }
                    return (key, image, color)
                }
            }
        }
        for await (key, image, color) in group {
            artResults[key] = (image, color)
        }
    }

    columns = stubs.enumerated().map { ci, stub in
        let rows = stub.songs.enumerated().map { ri, song in
            let (art, color) = artResults["\(ci)-\(ri)"] ?? (nil, Color(nsColor: .windowBackgroundColor))
            return UpcomingSongRow(id: "\(stub.chanId)-\(song.songId)", song: song, art: art, ambientColor: color)
        }
        return UpcomingColumn(id: stub.chanId, channel: stub.channel, songs: rows)
    }
    isLoading = false
    lastUpdated = Date()
}
```

### Step 6.3: Update `UpcomingProgramView` row rendering

- [ ] `grep -n "song.cover\|song.userRating\|song.year\|song.album" Sources/RPPlayer/Upcoming/*.swift`. Adjust:
  - `song.cover` → `song.coverLarge ?? song.coverMedium` (where used directly — though the row's `art: NSImage?` is pre-resolved; might not need this)
  - `song.userRating` (was `String?`) → `String(song.userRating)` for label rendering (`Int` now)
  - `song.year` (still `String?` — same)
  - `song.album` (still `String?` — same)
  - `song.duration` (still `Int` — same)
  - `song.songId` (still `String` — same)

### Step 6.4: Update `UpcomingProgramViewModelTests`

- [ ] Replace block-shaped fixtures with `GaplessResponse` builders. Reuse the shared `makeGaplessResponse(songs:chan:)` helper from Task 4.
- [ ] Tests to update:
  - `testLoadFetchesOneCallPerVisibleChannel` — assert exactly N gapless calls for N enabled channels (not the multi-block stitching pattern).
  - `testPromoSongsAreFiltered` — gapless response with mixed M/P songs; expect only M in `columns[0].songs`.
  - `testRowCountTrimsToConfiguredValue` — settings.upcomingRowCount=5; gapless returns 20 music songs; expect 5 rows.
  - `testHiddenChannelsAreSkipped` — preserve existing assertion shape.
  - `testFavoritesChannelIsExcluded` (chan=99 / 42 also).

- [ ] Delete tests that cover multi-block stitching (no longer applicable).

### Step 6.5: Build + test

- [ ] `swift test --filter UpcomingProgramViewModelTests`. Expected: green.
- [ ] `swift test`. Expected: all green.

### Step 6.6: Commit

- [ ] ```bash
git add Sources/RPPlayer/Upcoming Tests/RPPlayerTests/Upcoming
git commit -m "$(cat <<'EOF'
refactor: migrate Upcoming Program to api/gapless

UpcomingProgramViewModel.load now issues one api/gapless call per
enabled channel (numSongs = rowCount * 2 to absorb promo filtering)
instead of a multi-block stitching loop against api/play. Row.song
type changes from PlayListSong to GaplessSong.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Drop `api/play`, `api/get_block`, `BlockSongs`, `GetBlock`, `PlayAction`, dead fixtures

**Files:**

- Modify: `Sources/RPPlayer/Api/RpApiClient.swift` (remove `play` + `getBlock` from protocol + LiveRpApiClient + PlayAction enum)
- Modify: `Sources/RPPlayer/Api/ApiModels.swift` (remove `GetBlock` struct + extension)
- Delete: `Sources/RPPlayer/Playback/BlockSongs.swift`
- Modify: stub clients in `Tests/` (remove `play` / `getBlock` impls)
- Delete: `Tests/RPPlayerTests/Playback/BlockSongsTests.swift` (if exists)
- Delete: any `Tests/RPPlayerTests/Fixtures/Api/get_block_*.json` and `play_*.json` files
- Modify: `Tests/RPPlayerTests/Api/RpApiClientTests.swift` — drop `play` + `getBlock` tests
- Modify: any test that constructs `GetBlock(...)` or `PlayAction.start` — should be zero after Tasks 4–6 but verify.

### Step 7.1: Discover dead code

- [ ] `grep -rn "GetBlock\|api.play\|api.getBlock\|PlayAction\|BlockSongs\|getBlock(" Sources/ Tests/`. Catalogue every hit. After Tasks 4–6 the only remaining hits should be:
  - `RpApiClient` protocol
  - `LiveRpApiClient` impl
  - Stub clients in tests
  - `ApiModels.swift` `GetBlock` struct
  - `BlockSongs.swift` (and its tests if any)
  - `RpApiClientTests` for `play` / `getBlock`

  If you find hits outside these — those are bugs left over from earlier tasks. Fix them first.

### Step 7.2: Remove `play` + `getBlock` from `RpApiClient`

- [ ] In `Sources/RPPlayer/Api/RpApiClient.swift`:
  - Delete the `play(...)` and `getBlock(...)` lines from the protocol.
  - Delete the `play(...)` and `getBlock(...)` methods from `LiveRpApiClient`.
  - Delete the `PlayAction` enum (top of the file).

### Step 7.3: Remove `GetBlock` from `ApiModels.swift`

- [ ] In `Sources/RPPlayer/Api/ApiModels.swift`, delete:
  - The `GetBlock` struct.
  - The `extension GetBlock: Decodable` block.

### Step 7.4: Delete `BlockSongs.swift`

- [ ] `git rm Sources/RPPlayer/Playback/BlockSongs.swift`.
- [ ] If `Tests/RPPlayerTests/Playback/BlockSongsTests.swift` exists: `git rm` it too.

### Step 7.5: Remove dead fixtures

- [ ] `git rm Tests/RPPlayerTests/Fixtures/Api/get_block_*.json` (any matching).
- [ ] `git rm Tests/RPPlayerTests/Fixtures/Api/play_*.json` (any matching, but be careful: not all `play_*.json` files necessarily relate to the dead endpoints — inspect names like `play_promo.json` first).

### Step 7.6: Clean up stub clients

- [ ] In each stub client, remove the `play` and `getBlock` methods.

### Step 7.7: Drop dead tests

- [ ] In `RpApiClientTests`, delete the test cases for `play` and `getBlock`.

### Step 7.8: Build + test

- [ ] `swift build`. Expected: green.
- [ ] `swift test`. Expected: all green. Test count should be ≈ 450–460.

### Step 7.9: Commit

- [ ] ```bash
git add -A
git status  # verify nothing unexpected staged
git commit -m "$(cat <<'EOF'
refactor: drop api/play + api/get_block + BlockSongs + GetBlock

All call sites migrated to api/gapless + queue model. PlayAction enum
deleted. Test fixtures for the old endpoints removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Update CLAUDE.md + CHANGELOG.md

**Files:**

- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

### Step 8.1: CHANGELOG.md

- [ ] Read current `CHANGELOG.md`. Locate `## [Unreleased]` section. Add entries:

```markdown
## [Unreleased]

### Added
- `api/gapless` endpoint integration (`RpApiClient.gapless(channel:bitrate:numSongs:)`). Each song is a self-contained file URL with its own cue + duration + event_id.
- `GaplessSong` + `GaplessResponse` API types in `ApiModels.swift`.

### Changed
- `LivePlaybackCoordinator` migrated from block-centric state (`currentBlock` + `orderedSongs[]` + `startsAt[]` + `currentSongIndex`) to queue-centric (`queue: [GaplessSong]`). Boundary advance via `MPV_EVENT_START_FILE` → `queue.removeFirst()` → emit NowPlaying → fire telemetry → queue next.
- `UpcomingProgramViewModel.load` now issues one `api/gapless` call per enabled channel instead of stitching consecutive blocks via `api/play`.
- `NowPlaying` simplified: `songIndexInBlock` / `blockDurationSeconds` / `songStartSeconds` / `songEndSeconds` / `blockBitrate` replaced by `songDurationSeconds` + `bitrateLabel`. `song` field type: `PlayListSong` → `GaplessSong`.
- Position stream (`positionUpdates`) semantics: now per-song-relative (was: block-relative).

### Removed
- `RpApiClient.play(channel:bitrate:event:action:audioType:episodeId:sliceNum:)` (replaced by `gapless`).
- `RpApiClient.getBlock(channel:bitrate:event:)` (last consumer was Upcoming Program; migrated to `gapless`).
- `PlayAction` enum.
- `GetBlock` struct + Decodable extension.
- `BlockSongs` enum (`isStale` / `orderedSongs` / `startsAtSeconds` / `totalDurationSeconds` / `indexOfSong`) — block stitching no longer needed in the gapless model.
- Stale-block bootstrap recovery (PR 24) — gapless cursor + per-song self-contained URLs make the recovery redundant.
- `prefetchedBlock` / `prefetchTask` / `queuedToEngine` / `absorbPrefetchResult` / `swapToPrefetchedBlockState` / `swapToPrefetchedBlockIfAvailable` / `maybeStartPrefetch` / `advancePastUnplayableBlock` (replaced by `kickRefetch` + `handleSongPlaybackError`).
```

### Step 8.2: CLAUDE.md PR status table

- [ ] Add a row to the PR status table for PR 31 (after PR 30):

```markdown
| 31   | claude/pr31-gapless-migration | ✅ | api/gapless migration: queue-centric coordinator (`queue: [GaplessSong]`), one call per channel for Upcoming, drop api/play + api/get_block + BlockSongs + GetBlock + PlayAction. NowPlaying simplifies (per-song duration + bitrateLabel). Telemetry unchanged. PR 30 stall watchdog preserved. |
```

### Step 8.3: CLAUDE.md "Current state" line

- [ ] Update the "Last merged" line near the top:

```markdown
- Last merged: **PR 31** — api/gapless migration. See PR status table for details. `swift test` count ≈ <actual count from `swift test 2>&1 | grep "Executed.*tests"`>.
```

### Step 8.4: CLAUDE.md "Next up" + "Deferred" sections

- [ ] Replace the "Next up: PR 30" bullet with a blank "Next up:" placeholder or remove until the next PR is planned.
- [ ] In the Deferred section, no new entries from this PR (everything was in scope).

### Step 8.5: CLAUDE.md Test counts by PR

- [ ] Add a new bullet after the PR 30 entry:

```markdown
- After PR 31 api/gapless migration — `GaplessSong` + `GaplessResponse` decoders + `RpApiClient.gapless`; coordinator queue model (`queue: [GaplessSong]`, `kickRefetch`, `handleSongPlaybackError`); `MPV_EVENT_START_FILE`-driven boundary advance with per-song telemetry; long-idle resume refetches via gapless; UpcomingProgramViewModel single-call-per-channel; drop api/play + api/get_block + PlayAction + GetBlock + BlockSongs + stale-block detection: <actual count>
```

(Substitute the actual test count from `swift test`.)

### Step 8.6: CLAUDE.md Key technical decisions

- [ ] Add a new subsection inside *Key technical decisions* under a new heading "Gapless playback model":

```markdown
### Gapless playback model (PR 31)

- Each song from `api/gapless` is a self-contained file URL with its own `cue` (ms), `duration` (ms), `event_id`, `type` (M/P), `slice_num`. Block boundaries dissolve at the data layer — promo songs are inline-mixed with `type=P`, `update_history=false`.
- `LivePlaybackCoordinator` state is `queue: [GaplessSong]` where `queue[0]` is currently playing and `queue[1]` is queued in mpv via `loadfile <url> append-play` (1-ahead pattern from PR 28). Boundary advance via `MPV_EVENT_START_FILE` → `queue.removeFirst()` → emit `NowPlaying` → fire `update_history` for the just-finished song → `queueNext` for new `queue[1]`. Refetch (`kickRefetch`) triggered when `queue.count < 3` post-advance, on bootstrap, channel change, and long-idle resume (≥ 59 min).
- Backend cursor is authoritative — driven by `update_history` / `update_pause` telemetry. On refetch, server returns `songs[0] = current_event_id`. No client-side stale-block detection (gone with the model).
- `kickRefetch` race-guards on `currentChannelId` snapshot + `queue.first?.eventId` snapshot taken before the await; discards the result if either changed during the network call. Filters response to `eventId > queue[0].eventId` and replaces `queue[1..]`. Calls `engine.queueNext` only when mpv had nothing queued (queue went from < 2 to ≥ 2).
- `handleSongPlaybackError(code:)` (mpv -16 etc.) drops `queue[0]` and `engine.play(queue[1])`. Replaces the old `advancePastUnplayableBlock` logic.
- `slice_num` is `Int` in `GaplessSong` (was `String?` in `PlayListSong`). Telemetry call sites convert via `String(song.sliceNum)`.
- `NowPlaying.song: GaplessSong` carries cover via `coverLarge ?? coverMedium` (was: `PlayListSong.cover: String?`). View models updated to read from the new fields.
```

### Step 8.7: README.md

- [ ] Skim README. No user-facing changes from this PR. Skip unless something surfaces.

### Step 8.8: Commit

- [ ] ```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: PR 31 — CLAUDE.md + CHANGELOG.md for api/gapless migration

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `swift build`. Green.
- [ ] `swift test`. All green. Note final count.
- [ ] `git log --oneline main..HEAD`. Confirm 7 commits (Tasks 1, 2, 4, 5, 6, 7, 8 — Task 3 doesn't commit on its own).
- [ ] Hand off to user for smoke test on real Radio Paradise streams.

---

## Spec coverage check

| Spec section | Covered by |
|---|---|
| §API surface — `gapless` method + new types | Task 1, 2 |
| §Coordinator refactor — state | Task 4.3 |
| §Coordinator refactor — `play` | Task 4.4 |
| §Coordinator refactor — `.fileStarted` | Task 4.6 |
| §Coordinator refactor — `.fileEnded(.eof)` | Task 4.6 |
| §Coordinator refactor — `skipForward` | Task 4.7 |
| §Coordinator refactor — `pause` / `resume` | Task 4.8, 4.9 |
| §Coordinator refactor — `changeChannel` / `stop` / `shutdown` / `handlePlaybackError` | Task 4.10 |
| §Coordinator refactor — `kickRefetch` / `handleSongPlaybackError` | Task 4.11 |
| §Coordinator refactor — logging | Task 4.4 (`describeQueue`) |
| §Upcoming Program migration | Task 6 |
| §Drops | Task 7 |
| §`NowPlaying` shape change | Task 3 + 4.5 + 5 |
| §Edge cases — dedup / race / EOF / -16 / long-idle / favorites | Task 4.6, 4.7, 4.11 + manual verification noted in spec |
| §Test plan | Tasks 1, 2, 4.14, 6.4 |
| §Documentation | Task 8 |
