# PR 2 — RpApiClient (Anonymous) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land a Swift client for Radio Paradise's public REST API — anonymous-only (Keychain auth lands in PR 3). Cover the endpoints needed for playback (`api/list_chan`, `api/get_block`, `api/info`, `api/auth-state`) plus the `api/rating` endpoint (anonymous test only). Include `URLProtocol`-based fixture infrastructure so all API tests run offline against real captured JSON.

**Architecture:** `LiveRpApiClient` is a value-type `Sendable` struct that takes an injected `URLSession`, base URL, `CookieProvider`, and `Logging`. Each method builds a `URL` from `baseURL` plus a query string, attaches a `Cookie` header from the provider when available, sends the request via the session, and decodes the JSON response into a Codable model using `JSONDecoder` with `.convertFromSnakeCase`. Tests inject a `URLSession` configured with the `StubURLProtocol` test helper, which serves canned responses keyed by URL. Fixture JSON files are captured from the live RP API via `curl` and committed under `Tests/RPPlayerTests/Fixtures/Api/` so tests run offline.

**Tech Stack:** Swift 6.2, `Foundation.URLSession`, `JSONDecoder`, XCTest, `URLProtocol` for stubs.

---

## File structure

**Created**

- `Sources/RPPlayer/Api/RpApiError.swift` — `RpApiError` enum (network, invalidResponse, decoding).
- `Sources/RPPlayer/Api/CookieProvider.swift` — `CookieProvider` protocol + `AnonymousCookieProvider` (returns `nil`; placeholder until PR 3).
- `Sources/RPPlayer/Api/ApiModels.swift` — Codable models: `Channel`, `PlayListSong`, `GetBlock`, `SongInfo`, `Rating`, `Auth`.
- `Sources/RPPlayer/Api/RpApiClient.swift` — `RpApiClient` protocol + `LiveRpApiClient` struct.
- `Tests/RPPlayerTests/Api/StubURLProtocol.swift` — `URLProtocol` subclass for fixture-driven tests.
- `Tests/RPPlayerTests/Api/ApiModelsTests.swift` — decode each fixture into the corresponding model.
- `Tests/RPPlayerTests/Api/RpApiClientTests.swift` — exercise each endpoint via stubbed session.
- `Tests/RPPlayerTests/Fixtures/Api/list_chan.json` — captured live response.
- `Tests/RPPlayerTests/Fixtures/Api/get_block.json` — captured live response.
- `Tests/RPPlayerTests/Fixtures/Api/info.json` — captured live response.
- `Tests/RPPlayerTests/Fixtures/Api/auth_state_anonymous.json` — captured anonymous response.
- `Tests/RPPlayerTests/Fixtures/Api/rating_success.json` — synthetic (success path requires auth, deferred to PR 3).

**Modified**

- `Package.swift` — register fixtures as test-target resources via `.copy("Fixtures")`.

**Untouched**

- All PR 1 modules (`Logging/`, `Config/`).

---

## Conventions used by this PR

- Field naming: API JSON is `snake_case`; Swift models are `camelCase`. Decoder uses `keyDecodingStrategy = .convertFromSnakeCase` globally; explicit `CodingKeys` are used only when a field name cannot be derived from snake_case (none expected in this PR; verify against captured fixtures).
- Optionals: every API field that the legacy C# treats as a plain string (no `[Required]` attribute) is modelled as `Optional<T>` in Swift — this makes the decoder tolerant of missing fields, which matches the live API's behaviour.
- `song_id` polymorphism: `SongInfo.songId` is declared `Int` but the field is sometimes returned as a string by the API (the legacy uses `JsonNumberHandling.AllowReadingFromString`). Handle this with a custom decoder for `Int?`-from-`Int|String`. `PlayListSong.songId` and `Rating.songId` are not affected — the API returns them in their native shape per the legacy attributes.
- Numeric fields known to come as strings from the API (e.g. `bitrate`, `length`, `rating`, `user_rating`, `num_ratings`) stay as `String`/`String?` in the model. Conversion to `Int`/`Double` happens at the caller site, not in the model. This matches the legacy behaviour and keeps Codable decoding simple.
- Numeric fields confirmed-as-numeric by live captures: `PlayListSong.duration` (milliseconds, `Int`), `GetBlock.endEvent` (`Int?`), `SongInfo.songId` (`Int`, with custom decoder for the legacy string-fallback contract). The legacy C# typed `duration` and `end_event` as `string`; the live API returns them as integers, so the Swift models follow the wire format.

---

## Task 1: Capture live API fixtures via curl

**Files:**
- Create: `Tests/RPPlayerTests/Fixtures/Api/list_chan.json`
- Create: `Tests/RPPlayerTests/Fixtures/Api/get_block.json`
- Create: `Tests/RPPlayerTests/Fixtures/Api/info.json`
- Create: `Tests/RPPlayerTests/Fixtures/Api/auth_state_anonymous.json`

- [ ] **Step 1: Create the fixtures directory**

```bash
mkdir -p Tests/RPPlayerTests/Fixtures/Api
```

- [ ] **Step 2: Capture `list_chan`**

```bash
curl -fsS 'https://api.radioparadise.com/api/list_chan' \
  | python3 -m json.tool > Tests/RPPlayerTests/Fixtures/Api/list_chan.json
```

The `python3 -m json.tool` step pretty-prints the JSON for readability and confirms it is valid. If `curl` fails (e.g. non-zero status, network failure), STOP and report `BLOCKED — fixture capture requires network access`.

- [ ] **Step 3: Capture `get_block` for channel 0 (Main Mix), bitrate 4 (FLAC), info=true**

```bash
curl -fsS 'https://api.radioparadise.com/api/get_block?chan=0&bitrate=4&info=true' \
  | python3 -m json.tool > Tests/RPPlayerTests/Fixtures/Api/get_block.json
```

- [ ] **Step 4: Capture `info` for a real song**

Read the first song ID from the just-captured `get_block.json`:

```bash
SONG_ID=$(python3 -c "import json; b=json.load(open('Tests/RPPlayerTests/Fixtures/Api/get_block.json')); print(next(iter(b['song'].values()))['song_id'])")
echo "Capturing info for song_id=$SONG_ID"
curl -fsS "https://api.radioparadise.com/api/info?song_id=$SONG_ID" \
  | python3 -m json.tool > Tests/RPPlayerTests/Fixtures/Api/info.json
```

If the resulting file is empty or contains an error JSON, STOP and report.

- [ ] **Step 5: Capture anonymous `auth-state`**

```bash
curl -fsS 'https://api.radioparadise.com/api/auth-state' \
  | python3 -m json.tool > Tests/RPPlayerTests/Fixtures/Api/auth_state_anonymous.json
```

- [ ] **Step 6: Sanity-check the captures**

Each file must be non-empty and parse as JSON. Quick check:

```bash
for f in Tests/RPPlayerTests/Fixtures/Api/*.json; do
  python3 -c "import json; json.load(open('$f'))" && echo "OK: $f"
done
```

Expected: four `OK:` lines.

- [ ] **Step 7: Commit the captured fixtures**

```bash
git add Tests/RPPlayerTests/Fixtures/Api/list_chan.json \
        Tests/RPPlayerTests/Fixtures/Api/get_block.json \
        Tests/RPPlayerTests/Fixtures/Api/info.json \
        Tests/RPPlayerTests/Fixtures/Api/auth_state_anonymous.json
git commit -m "test(pr02): capture RP API fixtures for offline tests"
```

---

## Task 2: Synthetic `rating_success.json` fixture

The `api/rating` success path requires an authenticated cookie, which we don't have until PR 3. We commit a synthetic fixture matching the documented success shape so the rating endpoint can still be tested in PR 2.

**Files:**
- Create: `Tests/RPPlayerTests/Fixtures/Api/rating_success.json`

- [ ] **Step 1: Write the file**

```json
{
    "status": "success",
    "song_id": 12345,
    "user_id": "999",
    "rating": 7
}
```

- [ ] **Step 2: Commit**

```bash
git add Tests/RPPlayerTests/Fixtures/Api/rating_success.json
git commit -m "test(pr02): add synthetic rating success fixture"
```

---

## Task 3: Register fixtures as test-target resources in `Package.swift`

SwiftPM does not bundle non-source files into the test executable unless declared. Tests load fixtures via `Bundle.module`.

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Replace the `.testTarget` block**

In the existing `Package.swift`, replace:

```swift
        .testTarget(
            name: "RPPlayerTests",
            dependencies: ["RPPlayer"],
            path: "Tests/RPPlayerTests"
        ),
```

with:

```swift
        .testTarget(
            name: "RPPlayerTests",
            dependencies: ["RPPlayer"],
            path: "Tests/RPPlayerTests",
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 2: Verify build still succeeds**

Run: `swift build`
Expected: `Build complete!`, no warnings.

- [ ] **Step 3: Verify existing 7 tests still pass**

Run: `swift test`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "build(pr02): bundle Tests/RPPlayerTests/Fixtures as test resources"
```

---

## Task 4: `RpApiError` and `StubURLProtocol`

These are foundational helpers used by every following task. Group them into one commit.

**Files:**
- Create: `Sources/RPPlayer/Api/RpApiError.swift`
- Create: `Tests/RPPlayerTests/Api/StubURLProtocol.swift`

- [ ] **Step 1: Write `RpApiError.swift`**

```swift
import Foundation

public enum RpApiError: Error, Sendable {
    /// Underlying network failure (connectivity, TLS, timeout).
    case network(URLError)
    /// Server returned a non-2xx status. `body` is the response payload, useful for diagnostics.
    case invalidResponse(statusCode: Int, body: Data)
    /// JSON could not be decoded into the expected model.
    case decoding(DecodingError)
    /// Underlying error of an unexpected type (catch-all).
    case underlying(Error)
}
```

- [ ] **Step 2: Write `StubURLProtocol.swift`**

```swift
import Foundation

/// URLProtocol subclass that serves canned `(Data, HTTPURLResponse)` pairs
/// keyed by request URL. Use via `StubURLProtocol.register(url:body:status:)`
/// then plug `StubURLProtocol.makeSession()` into the system under test.
final class StubURLProtocol: URLProtocol {
    /// Stub registry. Synchronised via `lock` because URLProtocol callbacks
    /// can come from any thread under URLSession's internal queues.
    nonisolated(unsafe) private static var stubs: [URL: (Data, HTTPURLResponse)] = [:]
    private static let lock = NSLock()

    static func register(url: URL, body: Data, status: Int = 200, headers: [String: String] = [:]) {
        var allHeaders = headers
        if allHeaders["Content-Type"] == nil { allHeaders["Content-Type"] = "application/json" }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (body, response)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        lock.lock(); defer { lock.unlock() }
        return stubs[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let entry = Self.stubs[url]
        Self.lock.unlock()
        guard let (data, response) = entry else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: `Build complete!` with zero warnings.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: 7 existing tests still pass; no new tests yet.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiError.swift Tests/RPPlayerTests/Api/StubURLProtocol.swift
git commit -m "feat(pr02): add RpApiError and StubURLProtocol test helper"
```

---

## Task 5: API models — failing tests

TDD step: write tests that load each fixture and decode it into the expected model. Tests fail until Task 6 introduces the models.

**Files:**
- Create: `Tests/RPPlayerTests/Api/ApiModelsTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import RPPlayer

final class ApiModelsTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func testDecodesListChan() throws {
        let data = try loadFixture("list_chan")
        let channels = try decoder.decode([Channel].self, from: data)
        XCTAssertGreaterThan(channels.count, 0, "list_chan fixture must contain at least one channel")
        let main = try XCTUnwrap(channels.first)
        XCTAssertFalse(main.title.isEmpty)
    }

    func testDecodesGetBlock() throws {
        let data = try loadFixture("get_block")
        let block = try decoder.decode(GetBlock.self, from: data)
        XCTAssertFalse(block.url.isEmpty)
        XCTAssertGreaterThan(block.song.count, 0, "get_block must contain at least one song")
        XCTAssertGreaterThan(block.expiration, 0)
    }

    func testDecodesSongInfo() throws {
        let data = try loadFixture("info")
        let info = try decoder.decode(SongInfo.self, from: data)
        XCTAssertGreaterThan(info.songId, 0)
        XCTAssertFalse(info.artist.isEmpty)
        XCTAssertFalse(info.title.isEmpty)
    }

    func testDecodesAuthStateAnonymous() throws {
        let data = try loadFixture("auth_state_anonymous")
        let auth = try decoder.decode(Auth.self, from: data)
        // Anonymous responses still decode; specific field values vary by API state.
        XCTAssertNotNil(auth)
    }

    func testDecodesRatingSuccess() throws {
        let data = try loadFixture("rating_success")
        let rating = try decoder.decode(Rating.self, from: data)
        XCTAssertEqual(rating.status, "success")
        XCTAssertEqual(rating.songId, 12345)
        XCTAssertEqual(rating.userRating, 7)
    }
}
```

- [ ] **Step 2: Run the tests, confirm compile failure**

Run: `swift test --filter ApiModelsTests`
Expected: build fails with `cannot find 'Channel' in scope` (and similar for `GetBlock`, `SongInfo`, `Auth`, `Rating`).

---

## Task 6: API models — implementation

**Files:**
- Create: `Sources/RPPlayer/Api/ApiModels.swift`

- [ ] **Step 1: Write the file**

The concrete field set below follows the legacy C# response models in `docs/legacy/RpApiResponseModel.cs`. **Before committing, verify against captured fixtures**: if the real `get_block` response contains a field not modelled here, decoding still succeeds (Swift Codable ignores unknown JSON keys), but if a field that *is* modelled here is missing from the fixture, the decode will fail unless the property is `Optional`. Our defaults below mark every non-essential field optional. A handful of essential fields are required (`url`, `chan`, `expiration`, `imageBase`, `song` for `GetBlock`, `songId`/`artist`/`title` for `SongInfo`).

```swift
import Foundation

public struct Channel: Codable, Sendable, Equatable {
    public let chan: String
    public let title: String
    public let streamName: String?
    public let bannerUrl: String?
    public let slug: String?
    public let image: String?
}

public struct PlayListSong: Codable, Sendable, Equatable {
    public let songId: String
    public let artist: String
    public let title: String
    public let album: String
    /// Duration in milliseconds. The legacy C# typed this as `string`, but the
    /// live API returns it as an integer (e.g. 158807).
    public let duration: Int
    public let event: String?
    public let schedTime: String?
    public let chan: String?
    public let year: String?
    public let asin: String?
    public let rating: String?
    public let userRating: String?
    public let cover: String?
    public let elapsed: Int?
    public let slideshow: String?
}

public struct GetBlock: Codable, Sendable, Equatable {
    public let url: String
    public let chan: Int
    public let bitrate: String?
    public let cue: Int
    public let expiration: Int
    public let length: String?
    public let imageBase: String
    public let song: [String: PlayListSong]
    public let channel: Channel?
    public let event: String?
    /// Live API returns this as an integer; legacy C# had it as `string`.
    public let endEvent: Int?
    public let type: String?
    public let ext: String?
    public let filename: [String: String]?
}

public struct SongInfo: Codable, Sendable, Equatable {
    public let songId: Int
    public let artist: String
    public let title: String
    public let album: String?
    public let asin: String?
    public let avgRating: Double?
    public let numRatings: String?
    public let userRating: Int?
    public let webLink: String?
    public let wikiLink: String?
    public let lyricsAvail: String?
    public let lyrics: String?
    public let medCover: String?
    public let largeCover: String?
    public let releaseDate: String?
    public let length: String?
    public let plays30: Int?
    public let slideshow: String?

    private enum CodingKeys: String, CodingKey {
        case songId, artist, title, album, asin, avgRating, numRatings, userRating
        case webLink, wikiLink, lyricsAvail, lyrics, medCover, largeCover
        case releaseDate, length, plays30, slideshow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // song_id may be Int or String per legacy AllowReadingFromString contract.
        if let i = try? c.decode(Int.self, forKey: .songId) {
            songId = i
        } else if let s = try? c.decode(String.self, forKey: .songId), let i = Int(s) {
            songId = i
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                .init(codingPath: c.codingPath, debugDescription: "song_id is neither Int nor numeric String")
            )
        }
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        avgRating = try c.decodeIfPresent(Double.self, forKey: .avgRating)
        numRatings = try c.decodeIfPresent(String.self, forKey: .numRatings)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating)
        webLink = try c.decodeIfPresent(String.self, forKey: .webLink)
        wikiLink = try c.decodeIfPresent(String.self, forKey: .wikiLink)
        lyricsAvail = try c.decodeIfPresent(String.self, forKey: .lyricsAvail)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        medCover = try c.decodeIfPresent(String.self, forKey: .medCover)
        largeCover = try c.decodeIfPresent(String.self, forKey: .largeCover)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        length = try c.decodeIfPresent(String.self, forKey: .length)
        plays30 = try c.decodeIfPresent(Int.self, forKey: .plays30)
        slideshow = try c.decodeIfPresent(String.self, forKey: .slideshow)
    }
}

public struct Rating: Codable, Sendable, Equatable {
    public let status: String?
    public let songId: Int?
    public let userId: String?
    public let userRating: Int?

    private enum CodingKeys: String, CodingKey {
        case status, songId, userId
        case userRating = "rating"
    }
}

public struct Auth: Codable, Sendable, Equatable {
    public let userId: String?
    public let postOk: String?
    public let username: String?
    public let level: String?
    public let countryCode: String?
    public let avatar: String?
    public let privmsgNew: Bool?
    public let status: String?
}
```

Notes:
- `Rating.userRating` maps to JSON key `rating` because the API returns the user's submitted rating under that key (per legacy `Rating.UserRating` mapping). All four fields are optional because the real-world response shape is loose (e.g. an "error" status response may omit `song_id`).
- `Auth` fields are all optional for the same reason — anonymous responses omit most fields.
- `SongInfo` requires a custom `init(from:)` only to handle the `song_id` polymorphism. All other models rely on default Codable synthesis with the decoder's `convertFromSnakeCase` strategy.
- `GetBlock.bitrate` is optional and string-typed in case the API ever omits it or returns it as something other than the requested value.

- [ ] **Step 2: Run the tests, confirm 5 pass**

Run: `swift test --filter ApiModelsTests`
Expected: 5 tests pass, 0 failures. If a test fails because a real fixture has a shape we did not anticipate, fix the model (typically by relaxing a non-optional field to optional). Document any model deviations from the legacy C# in a brief comment.

- [ ] **Step 3: Run full suite**

Run: `swift test`
Expected: 12 tests pass (7 existing + 5 new).

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Api/ApiModels.swift Tests/RPPlayerTests/Api/ApiModelsTests.swift
git commit -m "feat(pr02): add Codable models for RP API responses"
```

---

## Task 7: `CookieProvider` protocol + `AnonymousCookieProvider`

**Files:**
- Create: `Sources/RPPlayer/Api/CookieProvider.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Supplies a `Cookie` header value for outgoing RP API requests.
/// Implementations are responsible for deciding whether the user is
/// currently authenticated — `nil` means "send no Cookie header".
public protocol CookieProvider: Sendable {
    func currentCookie() async -> String?
}

/// PR 2 placeholder: always anonymous. Replaced in PR 3 by a Keychain-backed implementation.
public struct AnonymousCookieProvider: CookieProvider {
    public init() {}
    public func currentCookie() async -> String? { nil }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: `Build complete!` with zero warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Api/CookieProvider.swift
git commit -m "feat(pr02): add CookieProvider protocol and anonymous implementation"
```

---

## Task 8: `RpApiClient` — failing tests

TDD step: drive the client with stubbed `URLSession` against captured fixtures.

**Files:**
- Create: `Tests/RPPlayerTests/Api/RpApiClientTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
@testable import RPPlayer

final class RpApiClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.radioparadise.com/")!

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/Api/\(name)", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func makeClient() -> LiveRpApiClient {
        LiveRpApiClient(
            baseURL: baseURL,
            session: StubURLProtocol.makeSession(),
            cookieProvider: AnonymousCookieProvider(),
            logger: AppLogger(category: "RpApiClientTests")
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testListChannelsReturnsDecodedArray() async throws {
        let url = baseURL.appendingPathComponent("api/list_chan")
        StubURLProtocol.register(url: url, body: try loadFixture("list_chan"))

        let client = makeClient()
        let channels = try await client.listChannels()
        XCTAssertGreaterThan(channels.count, 0)
    }

    func testGetBlockBuildsCorrectQueryAndDecodes() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/get_block"), resolvingAgainstBaseURL: false)!
        // Match the client's deterministic alpha-by-name ordering of query items.
        components.queryItems = [
            URLQueryItem(name: "bitrate", value: "4"),
            URLQueryItem(name: "chan", value: "0"),
            URLQueryItem(name: "info", value: "true"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("get_block"))

        let client = makeClient()
        let block = try await client.getBlock(channel: 0, bitrate: 4, info: true)
        XCTAssertFalse(block.url.isEmpty)
        XCTAssertGreaterThan(block.song.count, 0)
    }

    func testInfoBuildsCorrectQueryAndDecodes() async throws {
        // Read the song_id from the get_block fixture so the query matches what info expects.
        let blockData = try loadFixture("get_block")
        let block = try JSONDecoder.rpDecoder.decode(GetBlock.self, from: blockData)
        let firstSongId = try XCTUnwrap(block.song.values.first?.songId)

        var components = URLComponents(url: baseURL.appendingPathComponent("api/info"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "song_id", value: firstSongId)]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("info"))

        let client = makeClient()
        let info = try await client.info(songId: Int(firstSongId)!)
        XCTAssertFalse(info.artist.isEmpty)
    }

    func testAuthStateAnonymousDecodes() async throws {
        let url = baseURL.appendingPathComponent("api/auth-state")
        StubURLProtocol.register(url: url, body: try loadFixture("auth_state_anonymous"))

        let client = makeClient()
        let auth = try await client.authState()
        // Just verify it decodes; field shape is loose.
        _ = auth
    }

    func testRateBuildsCorrectQueryAndDecodes() async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/rating"), resolvingAgainstBaseURL: false)!
        // Match the client's deterministic alpha-by-name ordering of query items.
        components.queryItems = [
            URLQueryItem(name: "rating", value: "7"),
            URLQueryItem(name: "song_id", value: "12345"),
        ]
        StubURLProtocol.register(url: components.url!, body: try loadFixture("rating_success"))

        let client = makeClient()
        let rating = try await client.rate(songId: 12345, value: 7)
        XCTAssertEqual(rating.status, "success")
        XCTAssertEqual(rating.userRating, 7)
    }

    func testNon200StatusThrowsInvalidResponse() async throws {
        let url = baseURL.appendingPathComponent("api/list_chan")
        StubURLProtocol.register(url: url, body: Data("server error".utf8), status: 500)

        let client = makeClient()
        do {
            _ = try await client.listChannels()
            XCTFail("Expected RpApiError.invalidResponse")
        } catch let error as RpApiError {
            guard case .invalidResponse(let code, _) = error else {
                XCTFail("Expected .invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }
}
```

- [ ] **Step 2: Run tests, confirm compile failure**

Run: `swift test --filter RpApiClientTests`
Expected: build fails with `cannot find 'LiveRpApiClient' in scope` and `cannot find 'JSONDecoder.rpDecoder'`.

---

## Task 9: `RpApiClient` — implementation

**Files:**
- Create: `Sources/RPPlayer/Api/RpApiClient.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

public protocol RpApiClient: Sendable {
    func listChannels() async throws -> [Channel]
    func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock
    func info(songId: Int) async throws -> SongInfo
    func rate(songId: Int, value: Int) async throws -> Rating
    func authState() async throws -> Auth
}

public struct LiveRpApiClient: RpApiClient {
    public static let defaultBaseURL = URL(string: "https://api.radioparadise.com/")!

    private let baseURL: URL
    private let session: URLSession
    private let cookieProvider: any CookieProvider
    private let logger: any Logging

    public init(
        baseURL: URL = LiveRpApiClient.defaultBaseURL,
        session: URLSession = .shared,
        cookieProvider: any CookieProvider,
        logger: any Logging
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cookieProvider = cookieProvider
        self.logger = logger
    }

    public func listChannels() async throws -> [Channel] {
        try await get(path: "api/list_chan", query: [:])
    }

    public func getBlock(channel: Int, bitrate: Int, info: Bool) async throws -> GetBlock {
        try await get(path: "api/get_block", query: [
            "chan": String(channel),
            "bitrate": String(bitrate),
            "info": info ? "true" : "false",
        ])
    }

    public func info(songId: Int) async throws -> SongInfo {
        try await get(path: "api/info", query: ["song_id": String(songId)])
    }

    public func rate(songId: Int, value: Int) async throws -> Rating {
        try await get(path: "api/rating", query: [
            "song_id": String(songId),
            "rating": String(value),
        ])
    }

    public func authState() async throws -> Auth {
        try await get(path: "api/auth-state", query: [:])
    }

    private func get<T: Decodable>(path: String, query: [String: String]) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw RpApiError.network(URLError(.badURL))
        }
        if !query.isEmpty {
            // Sort keys for deterministic URLs (helps tests register stubs predictably).
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw RpApiError.network(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let cookie = await cookieProvider.currentCookie() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        logger.debug("GET \(url.absoluteString)")

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
            logger.error("HTTP \(http.statusCode) for \(url.absoluteString)")
            throw RpApiError.invalidResponse(statusCode: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder.rpDecoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            logger.error("Decode failure for \(url.absoluteString): \(error)")
            throw RpApiError.decoding(error)
        } catch {
            throw RpApiError.underlying(error)
        }
    }
}

extension JSONDecoder {
    /// Shared decoder used for all RP API responses. snake_case → camelCase.
    static let rpDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
```

- [ ] **Step 2: Run client tests, confirm 6 pass**

Run: `swift test --filter RpApiClientTests`
Expected: 6 tests pass (5 happy-path endpoint tests + 1 error-path test), 0 failures.

- [ ] **Step 3: Run full suite**

Run: `swift test`
Expected: 18 tests pass (7 PR-1 + 5 model + 6 client), 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Api/RpApiClient.swift
git commit -m "feat(pr02): add RpApiClient protocol and LiveRpApiClient struct"
```

---

## Task 10: Final verification

- [ ] **Step 1: Clean release build**

Run: `swift build -c release`
Expected: `Build complete!` with no warnings.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: 18 tests pass, 0 failures.

- [ ] **Step 3: Three back-to-back test runs to catch flakes**

```bash
for i in 1 2 3; do swift test 2>&1 | tail -3; done
```

Expected: each run reports `Executed 18 tests, with 0 failures`.

- [ ] **Step 4: Inspect captured fixtures one more time**

```bash
ls -la Tests/RPPlayerTests/Fixtures/Api/
wc -c Tests/RPPlayerTests/Fixtures/Api/*.json
```

Expected: five files, each non-empty (typical sizes: list_chan ~5–10 KB, get_block ~3–6 KB, info ~2–4 KB, auth_state_anonymous ~200 B, rating_success ~80 B).

- [ ] **Step 5: Confirm git tree is clean**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

- [ ] **Step 6: History sanity check**

Run: `git log --oneline main..HEAD`
Expected: 7 commits, all `(pr02)` scoped, in this order:
1. `test(pr02): capture RP API fixtures for offline tests`
2. `test(pr02): add synthetic rating success fixture`
3. `build(pr02): bundle Tests/RPPlayerTests/Fixtures as test resources`
4. `feat(pr02): add RpApiError and StubURLProtocol test helper`
5. `feat(pr02): add Codable models for RP API responses`
6. `feat(pr02): add CookieProvider protocol and anonymous implementation`
7. `feat(pr02): add RpApiClient protocol and LiveRpApiClient struct`

(Review-driven follow-up commits, if any, land on top.)
