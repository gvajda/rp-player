# PR 32 — SongFileCache + Download-Then-Play Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the audible gap between songs by pre-downloading each gapless song to disk and handing mpv a local `file://` URL via `loadfile <local> append-play`. This removes the HTTP body-fetch latency at the song boundary that `prefetch-playlist=yes` cannot eliminate (per mpv#6437: prefetch only opens the URL, it does not pull body bytes).

**Architecture:** New actor `LiveSongFileCache` (protocol `SongFileCache`) mirroring `LiveAlbumArtCache`'s shape. Cache lives under `~/Library/Application Support/RP Player/SongFileCache/`. Files keyed by `SHA256(gaplessUrl)` with file extension preserved. `LivePlaybackCoordinator` owns the sequential downloader: at play / channel-change bootstrap, await download of `queue[0]` then `engine.play(localUrl)`; in background, a `Task<Void, Never>` walks `queue.dropFirst()` and downloads songs one at a time; on every `MPV_EVENT_START_FILE`-driven `syncQueueHeadFromMpv()` boundary advance, evict dropped songs' files (after `update_history` telemetry has been fired). `engine.queueNext` and `engine.play` are agnostic — same URL surface, file or http. mpv baseline (`gapless-audio=yes`, `demuxer-max-bytes=32MiB`) from commit 505f777 remains.

**Tech Stack:** Swift 6.2, macOS 14, libmpv 0.36.0, `URLSession`, `CryptoKit` (SHA-256), `FileManager`, XCTest, `StubURLProtocol` for download tests.

---

## File Structure

**Create:**
- `Sources/RPPlayer/Playback/SongFileCache.swift` — `SongFileCache` protocol, `LiveSongFileCache` actor, `NoopSongFileCache` (private) used by `AppContainer.live()` when cache directory creation fails.
- `Tests/RPPlayerTests/Playback/SongFileCacheTests.swift` — unit tests for cache (uses `StubURLProtocol`).
- `Tests/RPPlayerTests/Helpers/MockSongFileCache.swift` — test double used by coordinator + Upcoming-window tests.

**Modify:**
- `Sources/RPPlayer/Config/ConfigPaths.swift` — add `songFileCacheDirectory` static property.
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — inject `SongFileCache`, replace remote URLs with cache-resolved local URLs at play / skip / boundary-advance call sites, add private `downloaderTask` running sequential prefetch, evict dropped songs after telemetry, clear cache on stop / channel-change / shutdown / device-unavailable.
- `Sources/RPPlayer/App/AppContainer.swift` — construct `LiveSongFileCache` with `ConfigPaths.songFileCacheDirectory`; fall back to `NoopSongFileCache` on failure; pass into `LivePlaybackCoordinator` init.
- `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift` (or wherever the live-coordinator tests live) — update factory helpers to inject `MockSongFileCache`; add tests for download-before-play, eviction-on-advance, channel-change-clears, download-failure-fallback.
- `Tests/RPPlayerTests/Helpers/CoordinatorTestHelpers.swift` (or equivalent) — wire `MockSongFileCache` into existing factory functions so unrelated tests keep working.
- `CLAUDE.md` — append PR 32 row to status table; append entry to *Test counts by PR*; add a *Key technical decisions* sub-section under "Coordinator playback" describing the sequential-download model.
- `CHANGELOG.md` — `[Unreleased]` `Added` / `Changed` entries.

**No changes to:**
- `Sources/RPPlayer/Player/MpvPlayerEngine.swift` — the engine's `play(url:)` / `queueNext(url:)` already accept any URL.
- `Sources/RPPlayer/Audio/HogModeController.swift` — unaffected.
- `Sources/RPPlayer/API/*` — gapless API client unchanged; we still download from the same `gaplessUrl`.

---

## Type Contract (locked before coding)

```swift
public protocol SongFileCache: Sendable {
    /// Returns the local file URL for the given song, downloading it if absent.
    /// Returns nil on download failure (network error, non-2xx, empty body, disk write fail).
    /// Concurrent calls for the same song dedupe to a single download.
    func localFile(for song: GaplessSong) async -> URL?

    /// Returns the local file URL only if already cached on disk. Does NOT trigger download.
    func cachedFile(for song: GaplessSong) -> URL?

    /// Removes the cached file for the given song. No-op if missing.
    func evict(_ song: GaplessSong) async

    /// Removes every cached file. No-op if directory empty/missing.
    func clear() async
}
```

**Filename derivation (deterministic, in `LiveSongFileCache`):**
```swift
private static func cacheFilename(for song: GaplessSong) -> String {
    let digest = SHA256.hash(data: Data(song.gaplessUrl.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    let ext = (URL(string: song.gaplessUrl)?.pathExtension ?? "").isEmpty
        ? "bin"
        : URL(string: song.gaplessUrl)!.pathExtension
    return "\(hex).\(ext)"
}
```

**No size / count cap.** Eviction is event-driven (boundary advance + channel change + stop). Worst case: full queue ≈ 20 songs ≈ 1 GB FLAC; in practice 2-3 ahead. Document the trade-off in CLAUDE.md; revisit if disk usage complaints arrive.

---

## Sequential download model (in `LivePlaybackCoordinator`)

- `downloaderTask: Task<Void, Never>?` — at most one outstanding.
- After every queue mutation (`play(channelId:)` bootstrap, `syncQueueHeadFromMpv` advance, `skipForward` sync-refetch, `runRefetch` merge), cancel + restart via `kickSequentialDownload()`.
- `kickSequentialDownload()` body (in actor context):
  ```swift
  downloaderTask?.cancel()
  let snapshot = queue
  downloaderTask = Task { [weak self] in
      for song in snapshot.dropFirst() {
          if Task.isCancelled { return }
          _ = await self?.songFileCache.localFile(for: song)
      }
  }
  ```
- `play()` / `skipForward` sync-refetch await `cache.localFile(for: queue[0])` synchronously BEFORE `engine.play`. If returned nil → fall back to `URL(string: song.gaplessUrl)`.
- `syncQueueHeadFromMpv` advance: evict each `dropped` song (after the existing telemetry `Task.detached { ... updateHistory }` is spawned), then resolve `queue[1]`'s URL via `cache.cachedFile(for:)` and `engine.queueNext`. If `cachedFile` returns nil, await `cache.localFile` inline (rare, may add brief delay but only when prefetch hasn't completed yet).

---

## Task list

### Task 1: Add `ConfigPaths.songFileCacheDirectory`

**Files:**
- Modify: `Sources/RPPlayer/Config/ConfigPaths.swift`
- Test: `Tests/RPPlayerTests/Config/ConfigPathsTests.swift` (if it exists; if not, skip — this is a trivial static property)

- [ ] **Step 1: Inspect existing file**

Run: `cat Sources/RPPlayer/Config/ConfigPaths.swift`
Expected output: file already containing `applicationSupportRoot`, `configFile`, `albumArtCacheDirectory`, `logsDirectory`.

- [ ] **Step 2: Check whether a `ConfigPathsTests.swift` exists**

Run: `find Tests -name "ConfigPathsTests.swift"`
Expected: either empty (skip Step 3) or a path. If the file exists, add a test below mirroring the album-art-cache directory test.

- [ ] **Step 3: Add static property**

Edit `Sources/RPPlayer/Config/ConfigPaths.swift`. Insert after `albumArtCacheDirectory`:

```swift
    public static var songFileCacheDirectory: URL {
        applicationSupportRoot.appendingPathComponent("SongFileCache", isDirectory: true)
    }
```

- [ ] **Step 4: Build to verify syntax**

Run: `swift build`
Expected: success, no warnings about this file.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/ConfigPaths.swift
git commit -m "feat: add ConfigPaths.songFileCacheDirectory

For the upcoming SongFileCache that pre-downloads gapless songs to
local disk before feeding their file URLs to mpv.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Write failing tests for `LiveSongFileCache`

**Files:**
- Create: `Tests/RPPlayerTests/Playback/SongFileCacheTests.swift`
- Test target depends on: `StubURLProtocol` (search `Tests/RPPlayerTests/` for prior usage; `LiveAlbumArtCacheTests` is the closest pattern).

- [ ] **Step 1: Inspect `StubURLProtocol` + `LiveAlbumArtCacheTests` to mirror style**

Run: `find Tests -name "StubURLProtocol*"` and `find Tests -name "*AlbumArtCache*"`

- [ ] **Step 2: Inspect helper that constructs a `GaplessSong` for tests**

Run: `cat Tests/RPPlayerTests/Helpers/GaplessFactories.swift`
Expected: `makeGaplessSong(...)` helper exists (added in PR 31).

- [ ] **Step 3: Write the test file**

Create `Tests/RPPlayerTests/Playback/SongFileCacheTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class SongFileCacheTests: XCTestCase {

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SongFileCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sessionWithStub() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeSong(url: String = "https://stream.radioparadise.com/test.flac",
                         eventId: Int = 1) -> GaplessSong {
        makeGaplessSong(gaplessUrl: url, eventId: eventId)
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - tests

    func testLocalFileDownloadsAndStoresAtKeyedPath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data(repeating: 0xAB, count: 1024)
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: body)

        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )

        let local = await cache.localFile(for: song)

        XCTAssertNotNil(local)
        XCTAssertEqual(try Data(contentsOf: local!), body)
        XCTAssertEqual(local!.deletingLastPathComponent(), dir)
        XCTAssertEqual(local!.pathExtension, "flac")
    }

    func testLocalFileReturnsCachedWithoutRefetch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = Data(repeating: 0x01, count: 512)
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: body)

        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )

        _ = await cache.localFile(for: song)
        StubURLProtocol.reset() // any new fetch attempt would now 404
        let local = await cache.localFile(for: song)

        XCTAssertNotNil(local)
        XCTAssertEqual(try Data(contentsOf: local!), body)
    }

    func testCachedFileReturnsNilForUnknownSong() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        XCTAssertNil(cache.cachedFile(for: makeSong()))
    }

    func testCachedFileReturnsUrlAfterDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: Data([0xFF]))
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        _ = await cache.localFile(for: song)
        XCTAssertNotNil(cache.cachedFile(for: song))
    }

    func testEvictRemovesFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: Data([1,2,3]))
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        let local = await cache.localFile(for: song)
        XCTAssertNotNil(local)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local!.path))

        await cache.evict(song)

        XCTAssertFalse(FileManager.default.fileExists(atPath: local!.path))
        XCTAssertNil(cache.cachedFile(for: song))
    }

    func testClearRemovesAll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song1 = makeSong(url: "https://s.example.com/a.flac", eventId: 1)
        let song2 = makeSong(url: "https://s.example.com/b.flac", eventId: 2)
        StubURLProtocol.register(url: URL(string: song1.gaplessUrl)!, statusCode: 200, data: Data([1]))
        StubURLProtocol.register(url: URL(string: song2.gaplessUrl)!, statusCode: 200, data: Data([2]))
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        _ = await cache.localFile(for: song1)
        _ = await cache.localFile(for: song2)

        await cache.clear()

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, [])
        XCTAssertNil(cache.cachedFile(for: song1))
        XCTAssertNil(cache.cachedFile(for: song2))
    }

    func testLocalFileReturnsNilOnHttpError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 503, data: Data())
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        let local = await cache.localFile(for: song)
        XCTAssertNil(local)
        XCTAssertNil(cache.cachedFile(for: song))
    }

    func testLocalFileReturnsNilOnEmptyBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: Data())
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )
        XCTAssertNil(await cache.localFile(for: song))
    }

    func testParallelLocalFileCallsDedupe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = makeSong()
        let body = Data(repeating: 0x77, count: 256)
        StubURLProtocol.register(url: URL(string: song.gaplessUrl)!, statusCode: 200, data: body, delayMs: 200)
        let cache = try LiveSongFileCache(
            directory: dir,
            session: sessionWithStub(),
            logger: NoopLogger()
        )

        async let a = cache.localFile(for: song)
        async let b = cache.localFile(for: song)
        async let c = cache.localFile(for: song)
        let results = await [a, b, c]

        XCTAssertEqual(StubURLProtocol.requestCount(for: URL(string: song.gaplessUrl)!), 1)
        for r in results {
            XCTAssertNotNil(r)
            XCTAssertEqual(try Data(contentsOf: r!), body)
        }
    }
}
```

> NOTE: If `StubURLProtocol` does NOT currently support a `delayMs:` knob, defer the last test to Task 3 (after the cache impl lands) and add the `delayMs` parameter then; or implement the de-dup test without artificial delay by relying on Task ordering. Either is acceptable.

> NOTE: `NoopLogger` is the project's no-op `Logging` implementation; if its name differs (e.g. `StubLogger`), substitute accordingly. Run `grep -n "class NoopLogger\|struct NoopLogger" Tests Sources` to confirm.

- [ ] **Step 4: Run tests — confirm they fail with "cannot find type 'LiveSongFileCache'"**

Run: `swift test --filter SongFileCacheTests 2>&1 | tail -20`
Expected: compile error; the symbol doesn't exist yet.

- [ ] **Step 5: Commit (failing tests only)**

```bash
git add Tests/RPPlayerTests/Playback/SongFileCacheTests.swift
git commit -m "test: failing tests for LiveSongFileCache

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Implement `LiveSongFileCache`

**Files:**
- Create: `Sources/RPPlayer/Playback/SongFileCache.swift`

- [ ] **Step 1: Write the file**

Create `Sources/RPPlayer/Playback/SongFileCache.swift`:

```swift
import CryptoKit
import Foundation

public protocol SongFileCache: Sendable {
    func localFile(for song: GaplessSong) async -> URL?
    func cachedFile(for song: GaplessSong) -> URL?
    func evict(_ song: GaplessSong) async
    func clear() async
}

public actor LiveSongFileCache: SongFileCache {
    private let directory: URL
    private let session: URLSession
    private let logger: any Logging
    private var inFlight: [String: Task<URL?, Never>] = [:]

    public init(
        directory: URL,
        session: URLSession = .shared,
        logger: any Logging
    ) throws {
        self.directory = directory
        self.session = session
        self.logger = logger
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func localFile(for song: GaplessSong) async -> URL? {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path
            )
            return fileURL
        }
        if let existing = inFlight[filename] {
            return await existing.value
        }
        let task = Task { [weak self] () -> URL? in
            let result = await self?.downloadAndStore(song: song, fileURL: fileURL) ?? nil
            await self?.clearInFlight(filename: filename)
            return result
        }
        inFlight[filename] = task
        return await task.value
    }

    public nonisolated func cachedFile(for song: GaplessSong) -> URL? {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    public func evict(_ song: GaplessSong) {
        let filename = Self.cacheFilename(for: song)
        let fileURL = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func clear() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }

    private func clearInFlight(filename: String) {
        inFlight[filename] = nil
    }

    private func downloadAndStore(song: GaplessSong, fileURL: URL) async -> URL? {
        guard let url = URL(string: song.gaplessUrl) else {
            logger.error("SongFileCache: invalid gapless URL: \(song.gaplessUrl)")
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.error("SongFileCache fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
                return nil
            }
            guard !data.isEmpty else {
                logger.error("SongFileCache response was empty: \(url.absoluteString)")
                return nil
            }
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.error("SongFileCache fetch threw: \(error.localizedDescription) for \(url.absoluteString)")
            return nil
        }
    }

    private nonisolated static func cacheFilename(for song: GaplessSong) -> String {
        let digest = SHA256.hash(data: Data(song.gaplessUrl.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let parsedExt = URL(string: song.gaplessUrl)?.pathExtension ?? ""
        let ext = parsedExt.isEmpty ? "bin" : parsedExt
        return "\(hex).\(ext)"
    }
}
```

> NOTE: The `nonisolated` annotation on `cachedFile(for:)` is intentional — callers (the coordinator) need to consult it synchronously inside other actor work; reading the filesystem is safe off-actor.

- [ ] **Step 2: Run the tests**

Run: `swift test --filter SongFileCacheTests 2>&1 | tail -30`
Expected: all 9 tests pass. If `testParallelLocalFileCallsDedupe` fails because `StubURLProtocol` lacks a `delayMs:` knob, either add it (preferred) or convert the test to an order-based check that does not rely on artificial delay.

- [ ] **Step 3: Run the full suite to catch unexpected breakage**

Run: `swift test 2>&1 | tail -5`
Expected: total = previous (375) + 9 = 384, all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Playback/SongFileCache.swift
git commit -m "feat: LiveSongFileCache actor for pre-downloading gapless songs

SHA256(gaplessUrl)-keyed file cache with in-flight dedup. Mirrors the
LiveAlbumArtCache shape: actor-isolated mutators, nonisolated
cachedFile(for:) for the synchronous \"is this already on disk?\"
lookup the coordinator needs. No size/count cap — eviction is
event-driven from the coordinator on every queue-head advance + on
stop/changeChannel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `MockSongFileCache` test helper

**Files:**
- Create: `Tests/RPPlayerTests/Helpers/MockSongFileCache.swift`

- [ ] **Step 1: Write the helper**

```swift
import Foundation
@testable import RPPlayer

/// Test double. Two modes:
///   - default `.passthrough`: `localFile(for:)` returns `URL(string: song.gaplessUrl)`. No real download.
///   - `.failures`: `localFile(for:)` returns nil for any song whose `eventId` is in `failingEventIds`.
///
/// Records every call (localFile, cachedFile, evict, clear) for assertion. Concurrency-safe.
actor MockSongFileCache: SongFileCache {
    enum Mode {
        case passthrough            // returns remote URL — caller treats it as if cached
        case downloaded(URL)        // returns a fixed file URL for any song (tests that need a file URL specifically)
    }

    var mode: Mode = .passthrough
    var failingEventIds: Set<Int> = []
    private(set) var localFileCalls: [Int] = []
    private(set) var cachedFileCalls: [Int] = []
    private(set) var evictCalls: [Int] = []
    private(set) var clearCalls: Int = 0
    private var downloadedEventIds: Set<Int> = []

    func setMode(_ m: Mode) { mode = m }
    func setFailing(_ ids: Set<Int>) { failingEventIds = ids }
    func markDownloaded(_ ids: Set<Int>) { downloadedEventIds.formUnion(ids) }

    func localFile(for song: GaplessSong) async -> URL? {
        localFileCalls.append(song.eventId)
        if failingEventIds.contains(song.eventId) { return nil }
        downloadedEventIds.insert(song.eventId)
        switch mode {
        case .passthrough: return URL(string: song.gaplessUrl)
        case .downloaded(let u): return u
        }
    }

    nonisolated func cachedFile(for song: GaplessSong) -> URL? {
        // Cannot read actor state nonisolated — return nil here.
        // Tests that need "already cached?" semantics should drive through localFile.
        return nil
    }

    func evict(_ song: GaplessSong) async {
        evictCalls.append(song.eventId)
        downloadedEventIds.remove(song.eventId)
    }

    func clear() async {
        clearCalls += 1
        downloadedEventIds.removeAll()
    }
}
```

> NOTE: This mock returns nil from `cachedFile` because that method is `nonisolated` (cannot read actor state). The coordinator's `syncQueueHeadFromMpv` therefore falls into the `await localFile(for:)` path in tests — which is fine because the mock resolves immediately.

> NOTE: The coordinator code path that depends on `cachedFile` semantics ("is this song already on disk?") needs a small adjustment: the *real* `LiveSongFileCache.cachedFile(for:)` is `nonisolated` (cheap fs probe). The mock cannot match that exactly. The coordinator should treat `cachedFile == nil` as "do an awaited resolve" — which is the correct fallback in production too if the file genuinely isn't there yet. Tests assert the awaited resolve happens.

- [ ] **Step 2: Build**

Run: `swift build --target RPPlayerTests` (or `swift build`)
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Tests/RPPlayerTests/Helpers/MockSongFileCache.swift
git commit -m "test: MockSongFileCache helper actor for coordinator tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Inject `SongFileCache` into `LivePlaybackCoordinator` (compile-only; behavior unchanged)

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` (init signature + stored property only)
- Modify: every existing coordinator-test factory helper to pass a `MockSongFileCache` instance

- [ ] **Step 1: Find every site that constructs `LivePlaybackCoordinator`**

Run: `grep -rn "LivePlaybackCoordinator(" Sources Tests | head -40`

- [ ] **Step 2: Add stored property + init param**

Edit `LivePlaybackCoordinator`:

```swift
    private let songFileCache: any SongFileCache
```

Update `init(...)` signature, adding `songFileCache:` right after `engine:`:

```swift
    public init(
        api: any RpApiClient,
        engine: any PlayerEngine,
        songFileCache: any SongFileCache,
        logger: any Logging,
        bitrateProvider: @escaping @Sendable () async -> Int,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { ns in try? await Task.sleep(nanoseconds: ns) },
        prefetchArt: @escaping @Sendable (String) -> Void = { _ in },
        onDeviceUnavailable: (@Sendable () async -> Void)? = nil,
        prePlayHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.api = api
        self.engine = engine
        self.songFileCache = songFileCache
        self.logger = logger
        // ... (rest unchanged)
    }
```

- [ ] **Step 3: Update `AppContainer.live()` to construct + pass the cache**

Open `Sources/RPPlayer/App/AppContainer.swift`. Find the `LivePlaybackCoordinator(` call site. Add cache construction near the album-art-cache block:

```swift
        let songFileCache: any SongFileCache
        do {
            songFileCache = try LiveSongFileCache(
                directory: ConfigPaths.songFileCacheDirectory,
                logger: logger
            )
        } catch {
            logger.error("Failed to open song file cache: \(error.localizedDescription)")
            songFileCache = NoopSongFileCache()
        }
```

Pass `songFileCache: songFileCache` into the coordinator's init.

Add a private `NoopSongFileCache` at the bottom of `AppContainer.swift` (next to the existing `Noop*` types):

```swift
private actor NoopSongFileCache: SongFileCache {
    func localFile(for song: GaplessSong) async -> URL? { URL(string: song.gaplessUrl) }
    nonisolated func cachedFile(for song: GaplessSong) -> URL? { nil }
    func evict(_ song: GaplessSong) async {}
    func clear() async {}
}
```

> NOTE: Noop falls back to remote URL so the engine still works if the directory can't be created. That matches the previous behavior end-to-end.

- [ ] **Step 4: Update every test factory + every direct `LivePlaybackCoordinator(` construction**

For each match found in Step 1, add `songFileCache: MockSongFileCache()` (or a shared instance held by the test). Where a test helper builds a coordinator, give the helper an optional `songFileCache:` parameter defaulting to a fresh `MockSongFileCache()`.

- [ ] **Step 5: Build + run full test suite — behavior must be unchanged**

Run: `swift test 2>&1 | tail -5`
Expected: total = previous (384) — same number, all pass. (No new tests yet; injection is plumbing.)

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Sources/RPPlayer/App/AppContainer.swift Tests/
git commit -m "feat: inject SongFileCache into LivePlaybackCoordinator (no behavior change)

Adds the dependency + wires LiveSongFileCache via AppContainer with
NoopSongFileCache fallback. Test factories now pass MockSongFileCache.
Subsequent commits replace remote-URL plays with cache-resolved local
URLs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Failing test — `play(channelId:)` resolves URL via cache before `engine.play`

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift` (or split into a new `PlaybackCoordinatorDownloadTests.swift` if the main file is already large)

- [ ] **Step 1: Add the test**

```swift
func testPlayChannelIdResolvesUrlViaSongFileCacheBeforeEnginePlay() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let local = URL(string: "file:///tmp/song-1.flac")!
    await cache.setMode(.downloaded(local))

    let response = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
        makeGaplessSong(eventId: 2, gaplessUrl: "https://s.example.com/2.flac"),
    ])
    api.gaplessResponses = [response]

    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)

    try await coordinator.play(channelId: 0)

    let calls = await cache.localFileCalls
    XCTAssertTrue(calls.contains(1), "expected localFile(for: song 1) to be called before engine.play")
    let plays = await engine.playCalls
    XCTAssertEqual(plays.first?.url, local)
}
```

- [ ] **Step 2: Run the test — expect failure (current `play` uses remote URL)**

Run: `swift test --filter testPlayChannelIdResolvesUrlViaSongFileCacheBeforeEnginePlay 2>&1 | tail -10`
Expected: FAIL with `engine.play` called with the remote URL, not the local file URL.

- [ ] **Step 3: Commit the failing test**

```bash
git add Tests/RPPlayerTests/Playback/
git commit -m "test: failing test for play() routing through SongFileCache

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Make `play(channelId:)` go through `SongFileCache` + queueNext via cache + kick sequential download

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — `play(channelId:)`, add `downloaderTask: Task<Void, Never>?` property, add private `kickSequentialDownload()` method.

- [ ] **Step 1: Add `downloaderTask` property near the other `Task` properties**

```swift
    private var downloaderTask: Task<Void, Never>?
```

- [ ] **Step 2: Replace the URL resolution + engine.play + engine.queueNext block inside `play(channelId:)`**

Find:
```swift
        guard let url = URL(string: head.gaplessUrl) else {
            throw PlaybackCoordinatorError.engineError(message: "invalid gapless url: \(head.gaplessUrl)")
        }
        // ...
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }

        if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
            try? await engine.queueNext(url: nextUrl, startSeconds: nil)
        }
```

Replace with:
```swift
        let resolvedHeadUrl = await songFileCache.localFile(for: head)
            ?? URL(string: head.gaplessUrl)
        guard let url = resolvedHeadUrl else {
            throw PlaybackCoordinatorError.engineError(message: "invalid gapless url: \(head.gaplessUrl)")
        }
        logger.debug("play engine.play url=\(url.absoluteString) (cache hit=\(url.isFileURL))")

        // ... (prePlayHook + lastStartedEventId reset stay unchanged) ...

        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        } catch {
            throw PlaybackCoordinatorError.engineError(message: String(describing: error))
        }

        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl {
                try? await engine.queueNext(url: nextUrl, startSeconds: nil)
            }
        }

        kickSequentialDownload()
```

> NOTE: The `await` on `localFile(for: next)` is on the actor's executor — it suspends `play()` until the second song is downloaded. That is intentional: the second song must be ready before the first finishes for true gapless. If the second is large (FLAC) and the user's network is slow this could block `play()` for several seconds — acceptable for the initial bootstrap; we revisit if it bites.

- [ ] **Step 3: Add `kickSequentialDownload()` method**

Place it near `kickRefetch` / `runRefetch`:

```swift
    /// Starts a background task that downloads queue.dropFirst() songs in order, one at a time.
    /// Idempotent: cancels and restarts on every call so a queue mutation always re-bases the prefetch order.
    private func kickSequentialDownload() {
        downloaderTask?.cancel()
        let snapshot = queue
        let cache = songFileCache
        downloaderTask = Task { [weak self] in
            for song in snapshot.dropFirst() {
                if Task.isCancelled { return }
                _ = await cache.localFile(for: song)
                _ = self // keep the actor alive
            }
        }
    }
```

> NOTE: `_ = self` is a no-op that prevents the compiler from eliding the weak capture when nothing else inside the closure references `self`. Without it, `[weak self]` is a warning.

- [ ] **Step 4: Run the failing test — confirm it passes**

Run: `swift test --filter testPlayChannelIdResolvesUrlViaSongFileCacheBeforeEnginePlay 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Run full suite — confirm no regressions**

Run: `swift test 2>&1 | tail -5`
Expected: total = previous + 1, all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git commit -m "feat: play() resolves song URLs through SongFileCache

Bootstrap path now:
1) await songFileCache.localFile(for: queue[0]) → engine.play(local)
2) await songFileCache.localFile(for: queue[1]) → engine.queueNext(local)
3) kickSequentialDownload() walks queue.dropFirst() in order to prefetch

Falls back to the remote gaplessUrl when the cache returns nil
(network failure, disk error, or NoopSongFileCache).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Failing test — `syncQueueHeadFromMpv` evicts dropped songs after telemetry + queueNext via cache

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift` (or the new download-focused test file)

- [ ] **Step 1: Add the tests**

```swift
func testQueueAdvanceEvictsDroppedSongFromCache() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let local0 = URL(string: "file:///tmp/0.flac")!
    let local1 = URL(string: "file:///tmp/1.flac")!
    await cache.setMode(.downloaded(local0)) // first localFile resolves to local0

    let response = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 10, gaplessUrl: "https://s.example.com/0.flac"),
        makeGaplessSong(eventId: 20, gaplessUrl: "https://s.example.com/1.flac"),
    ])
    api.gaplessResponses = [response]

    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)
    try await coordinator.play(channelId: 0)

    // mpv reports it advanced to queue[1]
    await engine.setCurrentPath(response.songs[1].gaplessUrl)
    await coordinator.handleEngineEventForTesting(.fileStarted) // exposed via @testable

    let evicted = await cache.evictCalls
    XCTAssertTrue(evicted.contains(10), "expected song 10 (just-finished) to be evicted")
    XCTAssertFalse(evicted.contains(20), "expected song 20 (now-current) NOT to be evicted")
}

func testQueueAdvanceQueuesNextSongFromCache() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()

    let response = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 10, gaplessUrl: "https://s.example.com/0.flac"),
        makeGaplessSong(eventId: 20, gaplessUrl: "https://s.example.com/1.flac"),
        makeGaplessSong(eventId: 30, gaplessUrl: "https://s.example.com/2.flac"),
    ])
    api.gaplessResponses = [response]

    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)
    try await coordinator.play(channelId: 0)
    let beforeCount = await engine.queueNextCalls.count

    await engine.setCurrentPath(response.songs[1].gaplessUrl)
    await coordinator.handleEngineEventForTesting(.fileStarted)

    let afterCount = await engine.queueNextCalls.count
    XCTAssertEqual(afterCount, beforeCount + 1, "advance must queue exactly one new song")
    let calls = await cache.localFileCalls
    XCTAssertTrue(calls.filter { $0 == 30 }.count >= 1, "queueNext path must resolve song 30 via cache")
}
```

> NOTE: `handleEngineEventForTesting` likely exists; if not, search for the existing testing seam: `grep -n "handleEngineEvent\b\|forTesting" Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests`. Use whatever the existing PR-31 boundary-advance tests use.

- [ ] **Step 2: Run — confirm failure**

Run: `swift test --filter testQueueAdvanceEvictsDroppedSongFromCache 2>&1 | tail -10`
Expected: FAIL — eviction is not yet wired.

- [ ] **Step 3: Commit failing test**

```bash
git add Tests/RPPlayerTests/Playback/
git commit -m "test: failing tests for queue-advance eviction + cache-driven queueNext

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Wire eviction + cache-driven `queueNext` into `syncQueueHeadFromMpv`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

- [ ] **Step 1: Edit `syncQueueHeadFromMpv` body**

Replace the existing `if idx > 0 { ... queue.removeFirst(idx); for finished in dropped where finished.updateHistory { ... } }` block AND the `if isAdvance, queue.count >= 2 { ... queueNext(remoteUrl) }` block with:

```swift
        if idx > 0 {
            let dropped = Array(queue.prefix(idx))
            queue.removeFirst(idx)
            for finished in dropped where finished.updateHistory {
                if let channelId = currentChannelId {
                    let api = self.api
                    let songId = finished.songId
                    let event = String(finished.eventId)
                    let audioType = finished.type
                    let sliceNum = String(finished.sliceNum)
                    let durationMs = finished.duration
                    let playtime = max(1, Int(currentPositionSeconds.rounded()))
                    Task.detached {
                        try? await api.updateHistory(
                            songId: songId, chan: channelId, event: event, audioType: audioType,
                            sliceNum: sliceNum, playPositionMillis: durationMs,
                            playtimeSecs: playtime, pauseFlag: false
                        )
                    }
                }
            }
            // Evict every dropped song's file. Telemetry is fire-and-forget above; eviction is
            // ordered after the spawn so the file URL captured by Task.detached above (when we
            // start sending the file content as part of telemetry — we don't today, but the
            // ordering is the contract the user asked for) is conceptually still valid.
            let cache = songFileCache
            Task { [dropped] in
                for song in dropped {
                    await cache.evict(song)
                }
            }
        }
        lastStartedEventId = queue[0].eventId
        currentPositionSeconds = 0
        let kind = isAdvance ? "advance" : "initial"
        logger.info("song.started (\(kind)) \(describeSong(queue[0]))")
        emitNowPlaying(forSongAt: 0)
        if let channelId = currentChannelId {
            fireSongStartTelemetry(song: queue[0], channelId: channelId)
        }
        if isAdvance, queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl {
                try? await engine.queueNext(url: nextUrl, startSeconds: nil)
            }
        }
        kickSequentialDownload()
        if queue.count < 3 {
            kickRefetch()
        }
    }
```

> NOTE: The `await` on `cache.localFile(for: next)` may briefly block the actor if `queue[1]` hasn't been downloaded by `kickSequentialDownload` yet (slow network, large file). The fallback to the remote URL means the worst case degrades to today's behavior — gap returns for one boundary, then catches up.

- [ ] **Step 2: Run the failing tests — they must pass**

Run: `swift test --filter testQueueAdvance 2>&1 | tail -20`
Expected: both `testQueueAdvanceEvictsDroppedSongFromCache` and `testQueueAdvanceQueuesNextSongFromCache` PASS.

- [ ] **Step 3: Run full suite**

Run: `swift test 2>&1 | tail -5`
Expected: total += 2, all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift
git commit -m "feat: syncQueueHeadFromMpv evicts dropped songs + queues next via cache

On every START_FILE-driven boundary advance:
1) Fire update_history telemetry for dropped song(s) (existing).
2) Evict each dropped song's local file (new — bounded by the unique
   eventIds in flight; never accumulates beyond ~queue length).
3) Resolve queue[1]'s URL via cache.localFile; engine.queueNext(local).
4) kickSequentialDownload() to keep the prefetch chain moving.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Wire cache resolution into `skipForward` (both paths) + `runRefetch`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — `skipForward()` sync-refetch fallback + `runRefetch`.

- [ ] **Step 1: Write failing test for `skipForward` sync-refetch path**

```swift
func testSkipForwardSyncRefetchPlaysViaCachedFile() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let local = URL(string: "file:///tmp/refetched.flac")!
    await cache.setMode(.downloaded(local))

    let initial = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 100, gaplessUrl: "https://s.example.com/100.flac"),
    ])
    let after = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 200, gaplessUrl: "https://s.example.com/200.flac"),
    ])
    api.gaplessResponses = [initial, after]
    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)
    try await coordinator.play(channelId: 0)

    try await coordinator.skipForward() // queue is 1-deep → sync refetch path

    let lastPlay = await engine.playCalls.last
    XCTAssertEqual(lastPlay?.url, local)
}
```

- [ ] **Step 2: Run — confirm failure**

Run: `swift test --filter testSkipForwardSyncRefetchPlaysViaCachedFile 2>&1 | tail -10`
Expected: FAIL — `engine.play` is still called with the remote URL.

- [ ] **Step 3: Edit `skipForward()`'s sync-refetch fallback**

Find inside `skipForward`:
```swift
        guard let url = URL(string: head.gaplessUrl) else {
            errorsContinuation?.yield("Cannot skip — invalid url.")
            return
        }
        let startSeconds: Double? = nil
        lastStartedEventId = nil
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        }
```

Replace with:
```swift
        let resolvedHeadUrl = await songFileCache.localFile(for: head)
            ?? URL(string: head.gaplessUrl)
        guard let url = resolvedHeadUrl else {
            errorsContinuation?.yield("Cannot skip — invalid url.")
            return
        }
        let startSeconds: Double? = nil
        lastStartedEventId = nil
        do {
            try await engine.play(url: url, startSeconds: startSeconds)
        }
```

And the trailing queueNext inside the same path:
```swift
        if queue.count >= 2, let nextUrl = URL(string: queue[1].gaplessUrl) {
            try? await engine.queueNext(url: nextUrl, startSeconds: nil)
        }
```
becomes:
```swift
        if queue.count >= 2 {
            let next = queue[1]
            let nextUrl = await songFileCache.localFile(for: next)
                ?? URL(string: next.gaplessUrl)
            if let nextUrl {
                try? await engine.queueNext(url: nextUrl, startSeconds: nil)
            }
        }
        kickSequentialDownload()
```

- [ ] **Step 4: Edit `runRefetch` so refetch-driven queue merges trigger a fresh prefetch walk**

Find inside `runRefetch` (or wherever the merge applies — look for `queue = [queue[0]] + newSongs`). Right after that assignment, add:
```swift
        kickSequentialDownload()
```

- [ ] **Step 5: Run failing test — confirm pass**

Run: `swift test --filter testSkipForwardSyncRefetchPlaysViaCachedFile 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Run full suite**

Run: `swift test 2>&1 | tail -5`
Expected: total += 1, all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/
git commit -m "feat: skipForward + runRefetch use cache-resolved URLs + kick prefetch

skipForward's engine.advanceToQueued path was already correct (the file
was queued earlier via syncQueueHeadFromMpv). Only the sync-refetch
fallback needed cache resolution. runRefetch now kicks
kickSequentialDownload after every queue merge so newly-appended songs
start downloading immediately.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Clear cache on stop / changeChannel / shutdown / handlePlaybackError

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

- [ ] **Step 1: Failing test — channel-change clears cache**

```swift
func testChangeChannelClearsSongFileCache() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    let response = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 1, gaplessUrl: "https://s.example.com/1.flac"),
    ])
    api.gaplessResponses = [response, response]
    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)
    try await coordinator.play(channelId: 0)
    let clearsBefore = await cache.clearCalls

    try await coordinator.changeChannel(to: 1)

    let clearsAfter = await cache.clearCalls
    XCTAssertGreaterThanOrEqual(clearsAfter, clearsBefore + 1)
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --filter testChangeChannelClearsSongFileCache 2>&1 | tail -10`
Expected: FAIL.

- [ ] **Step 3: Wire `await songFileCache.clear()` into the four cleanup sites**

In `stop()`, after the existing `try? await engine.clearPlaylist()` line, add:
```swift
        downloaderTask?.cancel()
        downloaderTask = nil
        let cacheRef = songFileCache
        Task { await cacheRef.clear() }
```

In `changeChannel(to:)`, same insertion right after `try? await engine.clearPlaylist()`.

In `shutdown()`, before the existing engine teardown:
```swift
        downloaderTask?.cancel()
        downloaderTask = nil
        await songFileCache.clear()
```

In `handlePlaybackError(code:)`, alongside the existing `try? await engine.clearPlaylist()`:
```swift
        downloaderTask?.cancel()
        downloaderTask = nil
        let cacheRef = songFileCache
        Task { await cacheRef.clear() }
```

> NOTE: The detached `Task { await cacheRef.clear() }` is used in `stop` / `changeChannel` / `handlePlaybackError` because we don't want `await songFileCache.clear()` to suspend the caller before `engine.stop` runs. In `shutdown` the `await` is direct because we WANT the cache cleared before the actor goes away.

- [ ] **Step 4: Run failing test — confirm pass**

Run: `swift test --filter testChangeChannelClearsSongFileCache 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Add the analogous tests for stop + shutdown + handlePlaybackError**

```swift
func testStopClearsSongFileCache() async throws { /* same shape as above, calling coordinator.stop() */ }
func testShutdownClearsSongFileCache() async throws { /* coordinator.shutdown(); assert clearCalls >= 1 */ }
func testHandlePlaybackErrorClearsSongFileCache() async throws {
    // Drive the coordinator through .fileEnded(.error(code: -14)) and assert clearCalls >= 1.
}
```

- [ ] **Step 6: Run full suite**

Run: `swift test 2>&1 | tail -5`
Expected: total += 4, all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/RPPlayerTests/Playback/
git commit -m "feat: clear SongFileCache on stop / changeChannel / shutdown / playback error

Also cancels the in-flight downloaderTask so dropped songs aren't
left waiting on now-irrelevant downloads.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Failing test — download failure falls back to remote URL

**Files:**
- Modify: `Tests/RPPlayerTests/Playback/PlaybackCoordinatorTests.swift`

- [ ] **Step 1: Add the test**

```swift
func testPlayFallsBackToRemoteUrlWhenCacheFails() async throws {
    let api = MockRpApiClient()
    let engine = MockPlayerEngine()
    let cache = MockSongFileCache()
    await cache.setFailing([42])

    let response = makeGaplessResponse(songs: [
        makeGaplessSong(eventId: 42, gaplessUrl: "https://s.example.com/42.flac"),
    ])
    api.gaplessResponses = [response]
    let coordinator = makeCoordinator(api: api, engine: engine, songFileCache: cache)

    try await coordinator.play(channelId: 0)

    let firstPlay = await engine.playCalls.first
    XCTAssertEqual(firstPlay?.url, URL(string: "https://s.example.com/42.flac"))
}
```

- [ ] **Step 2: Run — should already PASS because the fallback was implemented in Task 7**

Run: `swift test --filter testPlayFallsBackToRemoteUrlWhenCacheFails 2>&1 | tail -10`
Expected: PASS.

If it FAILS, the `?? URL(string: head.gaplessUrl)` branch is wired wrong — fix before continuing.

- [ ] **Step 3: Commit (regression-guard test)**

```bash
git add Tests/RPPlayerTests/Playback/
git commit -m "test: regression — play() falls back to remote URL on cache failure

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Documentation — CLAUDE.md + CHANGELOG.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append a PR 32 row to the status table in CLAUDE.md**

```
| 32   | merged to main | ✅      | SongFileCache + download-then-play: new actor `LiveSongFileCache` (SHA256(gaplessUrl)-keyed file store under `~/Library/Application Support/RP Player/SongFileCache/`); `LivePlaybackCoordinator` pre-downloads each gapless song to disk and hands mpv a local `file://` URL via `engine.play` / `engine.queueNext`, eliminating the boundary HTTP-fetch latency that `prefetch-playlist=yes` cannot remove. `kickSequentialDownload()` runs at most one outstanding download, walking `queue.dropFirst()` in order; restarted on every queue mutation. `syncQueueHeadFromMpv` evicts each dropped song's file immediately after spawning its `update_history` telemetry. `stop` / `changeChannel` / `shutdown` / `handlePlaybackError` all `cache.clear()` + cancel `downloaderTask`. Falls back to remote URL when the cache returns nil (network failure, disk error, NoopSongFileCache). Adds: `SongFileCache` protocol, `LiveSongFileCache` actor, `NoopSongFileCache` (private in AppContainer), `ConfigPaths.songFileCacheDirectory`, `MockSongFileCache` test helper. |
```

- [ ] **Step 2: Update "Test counts by PR" with the new total**

Compute via `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`. Add a line of the form:
```
- After PR 32 SongFileCache + download-then-play (...summary of test deltas, e.g. +20 to 395): 395
```

- [ ] **Step 3: Add a new sub-section under "Coordinator playback (gapless model, PR 31)"**

Title: `### Coordinator playback — pre-downloaded files (PR 32)`. Cover: motivation (prefetch-playlist=yes only opens URL, body fetch is at boundary — mpv#6437), cache shape (SHA256 key, dir under Application Support, no size cap, event-driven eviction), sequential download model (`downloaderTask`, restart on queue mutation, one outstanding at a time), eviction ordering (after telemetry spawn), fallback to remote URL on cache failure.

- [ ] **Step 4: Update CHANGELOG.md**

Under `## [Unreleased]`:

```markdown
### Added
- Pre-downloaded song file cache (`LiveSongFileCache`). Songs are downloaded to `~/Library/Application Support/RP Player/SongFileCache/` before being handed to mpv as `file://` URLs, eliminating the audible inter-song gap caused by HTTP body-fetch latency at the playlist boundary.

### Changed
- `LivePlaybackCoordinator` now resolves every play / queueNext URL through `SongFileCache`. Falls back to the remote `gaplessUrl` on cache failure so playback never breaks because of a download error.
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: PR 32 — SongFileCache + download-then-play

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: Final verification

- [ ] **Step 1: Run the full suite + collect total**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`

- [ ] **Step 2: Build the app**

Run: `swift build 2>&1 | tail -5`
Expected: no errors.

- [ ] **Step 3: Smoke-test manually (out-of-band; not a checkbox you tick programmatically)**

Launch the app, play a FLAC channel, listen across at least 3 song boundaries. Expected: no audible gap. Also confirm: pause is still immediate; skip-forward works; channel change works; quitting the app removes the `SongFileCache` directory contents (or at least every file inside it).

- [ ] **Step 4: Open the PR**

When smoke test is green, push the branch and open a PR via the project's standard `gh pr create` workflow.

---

## Self-review checklist (run after writing this plan)

- ✅ Spec coverage: every requirement the user stated (`SongFileCache` named, sibling of `AlbumArtCache`, sequential download, evict after telemetry, channel-change/stop cleanup) is in a task.
- ✅ No placeholders: every code block is complete and runnable; no "TBD" / "etc." in code positions.
- ✅ Type consistency: `SongFileCache` protocol shape is used identically in Tasks 3, 4, 5, 7, 9, 10, 11; `localFile` / `cachedFile` / `evict` / `clear` names match throughout.
- ✅ TDD ordering: every implementation task is preceded by a failing-test task or a code-block already-tested-by-prior-task.
- ✅ Frequent commits: 13 commits across the plan, each ≤ ~150 lines of diff.
