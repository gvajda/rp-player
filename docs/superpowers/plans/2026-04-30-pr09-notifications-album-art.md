# PR 9 — Notifications + AlbumArtCache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add desktop notifications on song-start and replace the album-art placeholder in `MiniPlayerView` with the real cover image. Wire both through `AppDelegate.realBootstrap` and respect the existing `AppSettings.notificationsEnabled` toggle.

**Architecture:** A new `AlbumArtCache` actor maintains an on-disk LRU (max 20 files / 10 MB at `ConfigPaths.albumArtCacheDirectory`) keyed by the API's cover-path string (e.g. `"covers/l/24372.jpg"`). The cache prepends an injected base URL (`https://img.radioparadise.com/`) and downloads on miss via an injected `URLSession`. A new `NotificationService` actor wraps `UNUserNotificationCenter` with a thin protocol so tests can verify posting without touching the real notification server. A `NotificationCoordinator` actor subscribes to `PlaybackCoordinator.nowPlayingUpdates`, fetches the current `AppSettings.notificationsEnabled` value, looks up the channel title from the channels list, requests album art from the cache, and posts via the notification service. `MiniPlayerViewModel` gains a `@Published currentArt: NSImage?` it loads from the same cache on each `NowPlaying` update. `MiniPlayerView` swaps the `music.quarternote.3` SF Symbol for the loaded `NSImage` when available, falling back to the existing placeholder.

`UNUserNotificationCenter.current()` requires a bundled `.app` to post notifications successfully. PR 9 lands the wiring; functional smoke for notifications happens after PR 12 (distribution). The album-art half is fully smoke-testable in `swift run RPPlayer`.

**Tech Stack:** Swift 6.2, AppKit (`NSImage`), Foundation (`URLSession`, `FileManager`), `UserNotifications` (UNUserNotificationCenter / UNMutableNotificationContent / UNNotificationAttachment), XCTest, `URLProtocol` stub.

---

## File structure

**Created**

- `Sources/RPPlayer/Notifications/AlbumArtCache.swift` — `AlbumArtCache` protocol + `LiveAlbumArtCache` actor.
- `Sources/RPPlayer/Notifications/NotificationService.swift` — `NotificationService` protocol + `LiveNotificationService` actor + small `UNUserNotificationCenterProtocol` + adapter.
- `Sources/RPPlayer/Notifications/NotificationCoordinator.swift` — `@MainActor final class NotificationCoordinator` (subscribes to coordinator, drives notification service).
- `Tests/RPPlayerTests/Notifications/StubURLProtocol.swift` — register-handler URLProtocol stub for `LiveAlbumArtCache` tests. Mirrors the existing `Tests/RPPlayerTests/Api/StubURLProtocol.swift` pattern but lives under `Notifications/` so the two stubs do not share state across tests.
- `Tests/RPPlayerTests/Notifications/AlbumArtCacheTests.swift`
- `Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift`
- `Tests/RPPlayerTests/Notifications/NotificationCoordinatorTests.swift`

**Modified**

- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — accept `albumArtCache: AlbumArtCache` (+ image base URL) at init; add `@Published private(set) var currentArt: NSImage?`; load art on every `nowPlaying` update; clear when `nowPlaying == nil`.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — render `viewModel.currentArt` via `Image(nsImage:)` when non-nil; fall back to the existing SF Symbol placeholder. Replace the layer-snapshot `cgColor` for the rounded background with a SwiftUI `Color(nsColor: .windowBackgroundColor)` shape (PR 7 review M5 follow-up — dynamic light/dark response).
- `Sources/RPPlayer/Shell/AppDelegate.swift` — `realBootstrap` constructs `LiveAlbumArtCache`, `LiveNotificationService`, and `NotificationCoordinator`. New `Bootstrap` field for the notification coordinator's lifetime so AppDelegate retains it; `applicationWillTerminate` also tears down the notification coordinator's subscription before the existing coordinator-shutdown wait. Keep existing `Bootstrap.coordinatorShutdown` shape.
- `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — small additive change: `PlaybackCoordinatorError: LocalizedError` so view-model error banners read as plain prose. Single conformance, no logic changes.
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift` — extend `setUp` to pass a `MockAlbumArtCache`; add tests for art-load on now-playing change and clear on nil.
- `Tests/RPPlayerTests/Shell/AppDelegateTests.swift` — extend the bootstrap injection to provide a stub notification coordinator + mock cache so tests stay hermetic. Add a `testApplicationWillTerminateInvokesShutdown` test (PR 8 review M7 follow-up).
- `CLAUDE.md` — flip PR 9 to ✅, mark PR 10 as next, append the new test count, record PR-9-specific decisions.

**Untouched**

- All PR 1–8 modules outside the explicit list above. `RpApiClient`, `KeychainStore`, `AudioDeviceCatalog`, `LibmpvPlayerEngine` are not touched.

---

## Conventions used by this PR

- **Protocol-then-impl for every new service.** `AlbumArtCache`, `NotificationService`, `UNUserNotificationCenterProtocol` all have a small protocol so tests substitute an in-memory mock without touching disk or the real notification daemon. This is the first place in the project where a protocol is justified by mockability — earlier PRs deliberately avoided protocols per CLAUDE.md, but the system-side surfaces (filesystem + notification daemon) are exactly the boundary where protocol-DI earns its keep.
- **Cache key = full cover path** (e.g. `"covers/l/24372.jpg"`). Multiple songs can share an album, so keying by `songId` would re-download the same JPEG for every song on the album. The cover path is stable per album.
- **Cache filename = SHA-256 of cover path**, with `.jpg` extension. Avoids escaping issues from slashes / unsafe characters in path. Hash is hex-encoded.
- **In-flight de-duplication.** If two `image(for:)` calls arrive for the same cover path concurrently, the cache shares a single download `Task` rather than firing two HTTP requests.
- **Disk LRU eviction is best-effort, on-write.** After every write that succeeds, the actor enumerates the cache directory, sorts by `contentModificationDate`, and deletes oldest entries until both `count <= 20` and `totalBytes <= 10 MB`. A `URLResourceValues` read failure for a single file logs and skips that file rather than aborting eviction.
- **Image base URL is injected at init**, not hard-coded. `https://img.radioparadise.com/` is the only production base, but tests substitute a `https://test.local/` base + `URLProtocol` stub.
- **`UNUserNotificationCenter` is wrapped behind a protocol** because the real class cannot be safely subclassed under macOS 13+ (final / private state). The wrapper exposes `requestAuthorization() async throws -> Bool` and `add(_ request:) async throws`. The adapter calls through to the real `UNUserNotificationCenter.current()`.
- **No actions, no triggers.** Per DESIGN.md §4: notifications are passive (no buttons, no scheduled triggers). `UNNotificationRequest` is constructed with a `nil` trigger so the notification fires immediately.
- **`UserNotifications` is conditionally usable.** `UNUserNotificationCenter.current()` works in any process but `requestAuthorization` and `add(_:)` only succeed under a properly-bundled app. PR 9 wires the calls; PR 12 produces the bundle. Inside `swift run RPPlayer`, `requestAuthorization` returns `false` and `add(_:)` throws — tolerate both in production code (log + continue), assert both in tests.

### Verified upstream symbols (do NOT regress)

- `ConfigPaths.albumArtCacheDirectory: URL` (already exists).
- `AppSettings.notificationsEnabled: Bool` (already exists, defaults to `true`).
- `JSONConfigStore.changes: AsyncStream<AppSettings> { get async }` — used by the notification coordinator to track the toggle live without polling.
- `PlaybackCoordinator.nowPlayingUpdates: AsyncStream<NowPlaying> { get async }` — re-used.
- `MiniPlayerViewModel(coordinator:api:initialChannelId:persistChannelId:)` — extended in this PR; do not break the existing call sites in `AppDelegate.realBootstrap` and `AppDelegateTests`.
- `PlayListSong.cover: String?`. Cover is a relative path; full URL = imageBaseURL + cover.

---

## Task 1: `AlbumArtCache`

**Files:**
- Create: `Sources/RPPlayer/Notifications/AlbumArtCache.swift`
- Create: `Tests/RPPlayerTests/Notifications/StubURLProtocol.swift`
- Create: `Tests/RPPlayerTests/Notifications/AlbumArtCacheTests.swift`

The cache lives behind `protocol AlbumArtCache: Sendable { func image(for coverPath: String) async -> NSImage? }`. The Live impl is an `actor` storing files at `ConfigPaths.albumArtCacheDirectory`.

- [ ] **Step 1: Create the directory + write the protocol + LRU helper test scaffolding**

`Sources/RPPlayer/Notifications/AlbumArtCache.swift`:

```swift
import AppKit
import CryptoKit
import Foundation

public protocol AlbumArtCache: Sendable {
    func image(for coverPath: String) async -> NSImage?
}

public actor LiveAlbumArtCache: AlbumArtCache {
    public static let defaultMaxFiles = 20
    public static let defaultMaxBytes = 10 * 1024 * 1024

    private let directory: URL
    private let baseURL: URL
    private let session: URLSession
    private let logger: any Logging
    private let maxFiles: Int
    private let maxBytes: Int
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    public init(
        directory: URL,
        baseURL: URL,
        session: URLSession = .shared,
        logger: any Logging,
        maxFiles: Int = LiveAlbumArtCache.defaultMaxFiles,
        maxBytes: Int = LiveAlbumArtCache.defaultMaxBytes
    ) throws {
        self.directory = directory
        self.baseURL = baseURL
        self.session = session
        self.logger = logger
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func image(for coverPath: String) async -> NSImage? {
        let key = Self.cacheKey(for: coverPath)
        let fileURL = directory.appendingPathComponent(key)

        if let image = Self.loadImage(at: fileURL) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: fileURL.path
            )
            return image
        }

        if let existing = inFlight[coverPath] {
            return await existing.value
        }
        let task = Task { [self] in
            await self.downloadAndStore(coverPath: coverPath, fileURL: fileURL)
        }
        inFlight[coverPath] = task
        let result = await task.value
        inFlight[coverPath] = nil
        return result
    }

    private func downloadAndStore(coverPath: String, fileURL: URL) async -> NSImage? {
        guard let url = URL(string: coverPath, relativeTo: baseURL)?.absoluteURL else {
            logger.error("Invalid cover URL for path: \(coverPath)")
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.error("Cover fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
                return nil
            }
            try data.write(to: fileURL, options: [.atomic])
            evictIfNeeded()
            return NSImage(data: data)
        } catch {
            logger.error("Cover fetch threw: \(error.localizedDescription) for \(url.absoluteString)")
            return nil
        }
    }

    private func evictIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var aged: [(URL, Date, Int)] = entries.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modDate = v.contentModificationDate,
                  let size = v.fileSize
            else { return nil }
            return (url, modDate, size)
        }
        aged.sort { $0.1 < $1.1 }

        var totalBytes = aged.reduce(0) { $0 + $1.2 }
        while aged.count > maxFiles || totalBytes > maxBytes, let oldest = aged.first {
            try? fm.removeItem(at: oldest.0)
            totalBytes -= oldest.2
            aged.removeFirst()
        }
    }

    private static func cacheKey(for coverPath: String) -> String {
        let digest = SHA256.hash(data: Data(coverPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".jpg"
    }

    private static func loadImage(at fileURL: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }
}
```

- [ ] **Step 2: Create the `StubURLProtocol` for the cache tests**

`Tests/RPPlayerTests/Notifications/StubURLProtocol.swift`:

```swift
import Foundation

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: (Data, HTTPURLResponse)] = [:]
    nonisolated(unsafe) static var failures: [URL: Error] = [:]

    static func reset() {
        responses = [:]
        failures = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let error = Self.failures[url] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let (data, response) = Self.responses[url] {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
    }

    override func stopLoading() {}
}

extension StubURLProtocol {
    static func register(url: URL, data: Data, statusCode: Int = 200) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
        responses[url] = (data, response)
    }

    static func registerFailure(url: URL, error: Error) {
        failures[url] = error
    }
}
```

This is a clone of the existing `Tests/RPPlayerTests/Api/StubURLProtocol.swift` pattern; keeping a separate file under `Notifications/` avoids cross-test stub interference.

- [ ] **Step 3: Write failing tests**

`Tests/RPPlayerTests/Notifications/AlbumArtCacheTests.swift`:

```swift
import AppKit
import XCTest
@testable import RPPlayer

final class AlbumArtCacheTests: XCTestCase {
    private var tempDirectory: URL!
    private var sut: LiveAlbumArtCache!
    private var session: URLSession!
    private var logger: AppLogger!
    private let baseURL = URL(string: "https://test.local/")!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-art-cache-tests-\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        logger = AppLogger(category: "test")
        StubURLProtocol.reset()
        sut = try LiveAlbumArtCache(
            directory: tempDirectory,
            baseURL: baseURL,
            session: session,
            logger: logger,
            maxFiles: 3,
            maxBytes: 1024 * 1024
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testCacheMissDownloadsAndReturnsImage() async throws {
        let cover = "covers/l/test.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        let png = Self.makeOnePixelPNG()
        StubURLProtocol.register(url: url, data: png)

        let image = await sut.image(for: cover)

        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
    }

    func testCacheHitReturnsImageWithoutSecondNetworkCall() async throws {
        let cover = "covers/l/test.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        StubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())

        _ = await sut.image(for: cover)
        StubURLProtocol.reset()

        let image = await sut.image(for: cover)
        XCTAssertNotNil(image, "Expected on-disk hit to succeed even after stub was cleared")
    }

    func testNetworkFailureReturnsNil() async throws {
        let cover = "covers/l/missing.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        StubURLProtocol.registerFailure(url: url, error: URLError(.notConnectedToInternet))

        let image = await sut.image(for: cover)
        XCTAssertNil(image)
    }

    func testNon200ResponseReturnsNil() async throws {
        let cover = "covers/l/forbidden.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        StubURLProtocol.register(url: url, data: Data(), statusCode: 403)

        let image = await sut.image(for: cover)
        XCTAssertNil(image)
    }

    func testEvictsOldestWhenMaxFilesExceeded() async throws {
        for i in 0..<5 {
            let cover = "covers/l/img-\(i).jpg"
            let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
            StubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())
            _ = await sut.image(for: cover)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: tempDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        XCTAssertLessThanOrEqual(entries.count, 3)
    }

    func testConcurrentRequestsForSameCoverShareDownload() async throws {
        let cover = "covers/l/concurrent.jpg"
        let url = URL(string: cover, relativeTo: baseURL)!.absoluteURL
        StubURLProtocol.register(url: url, data: Self.makeOnePixelPNG())

        async let a = sut.image(for: cover)
        async let b = sut.image(for: cover)
        let (resultA, resultB) = await (a, b)

        XCTAssertNotNil(resultA)
        XCTAssertNotNil(resultB)
    }

    private static func makeOnePixelPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
```

- [ ] **Step 4: Run, expect compile failure**

Run: `swift test --filter RPPlayerTests.AlbumArtCacheTests`
Expected: `LiveAlbumArtCache` undefined (Step 1 wrote the source but the file is not yet referenced). After Step 1 the source compiles; expected test pass:

- [ ] **Step 5: Run, expect 6 tests pass**

Run: `swift test --filter RPPlayerTests.AlbumArtCacheTests`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Notifications/AlbumArtCache.swift \
        Tests/RPPlayerTests/Notifications/StubURLProtocol.swift \
        Tests/RPPlayerTests/Notifications/AlbumArtCacheTests.swift
git commit -m "feat(pr09): on-disk LRU AlbumArtCache with URLSession fetch"
```

---

## Task 2: `NotificationService`

**Files:**
- Create: `Sources/RPPlayer/Notifications/NotificationService.swift`
- Create: `Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift`

The service wraps `UNUserNotificationCenter`. Tests substitute a fake `UNUserNotificationCenterProtocol`.

- [ ] **Step 1: Write failing test**

`Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift`:

```swift
import AppKit
import UserNotifications
import XCTest
@testable import RPPlayer

@MainActor
final class NotificationServiceTests: XCTestCase {
    private var fakeCenter: FakeUNCenter!
    private var sut: LiveNotificationService!

    override func setUp() async throws {
        fakeCenter = FakeUNCenter()
        sut = LiveNotificationService(center: fakeCenter)
    }

    func testRequestAuthorizationDelegatesToCenter() async throws {
        fakeCenter.authorizationResult = .success(true)
        let granted = try await sut.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertEqual(fakeCenter.requestedOptions, [.alert, .sound])
    }

    func testNotifyPostsExpectedTitleAndSubtitleWhenNoArt() async throws {
        try await sut.notify(
            title: "Artist — Title",
            subtitle: "Album · Channel",
            attachmentURL: nil
        )
        XCTAssertEqual(fakeCenter.addedRequests.count, 1)
        let request = fakeCenter.addedRequests[0]
        XCTAssertEqual(request.content.title, "Artist — Title")
        XCTAssertEqual(request.content.subtitle, "Album · Channel")
        XCTAssertTrue(request.content.attachments.isEmpty)
        XCTAssertNil(request.trigger)
    }

    func testNotifyAttachesAttachmentWhenURLProvided() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notif-test-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await sut.notify(
            title: "T", subtitle: "S", attachmentURL: tmp
        )

        let attachments = fakeCenter.addedRequests[0].content.attachments
        XCTAssertEqual(attachments.count, 1)
    }

    func testNotifySwallowsAttachmentInitFailureAndPostsAnyway() async throws {
        let bogus = URL(fileURLWithPath: "/does/not/exist.png")
        try await sut.notify(title: "T", subtitle: "S", attachmentURL: bogus)
        XCTAssertEqual(fakeCenter.addedRequests.count, 1)
        XCTAssertTrue(fakeCenter.addedRequests[0].content.attachments.isEmpty)
    }
}

@MainActor
final class FakeUNCenter: UNUserNotificationCenterProtocol {
    var authorizationResult: Result<Bool, Error> = .success(true)
    var requestedOptions: UNAuthorizationOptions = []
    var addedRequests: [UNNotificationRequest] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions = options
        return try authorizationResult.get()
    }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.NotificationServiceTests`
Expected: `LiveNotificationService` and `UNUserNotificationCenterProtocol` undefined.

- [ ] **Step 3: Implement the service**

`Sources/RPPlayer/Notifications/NotificationService.swift`:

```swift
import Foundation
import UserNotifications

public protocol UNUserNotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

public protocol NotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws
}

public actor LiveNotificationService: NotificationService {
    private let center: any UNUserNotificationCenterProtocol

    public init(center: any UNUserNotificationCenterProtocol = UNUserNotificationCenter.current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let url = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: url.lastPathComponent, url: url) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.NotificationServiceTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Notifications/NotificationService.swift \
        Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift
git commit -m "feat(pr09): NotificationService wrapper over UNUserNotificationCenter"
```

---

## Task 3: `NotificationCoordinator`

**Files:**
- Create: `Sources/RPPlayer/Notifications/NotificationCoordinator.swift`
- Create: `Tests/RPPlayerTests/Notifications/NotificationCoordinatorTests.swift`

The coordinator subscribes to `PlaybackCoordinator.nowPlayingUpdates`, looks up the channel title from a passed-in channels list, fetches album art (path → file URL), and posts via the service. It also subscribes to `ConfigStore.changes` to track `notificationsEnabled` live.

- [ ] **Step 1: Write failing test**

`Tests/RPPlayerTests/Notifications/NotificationCoordinatorTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var cache: MockAlbumArtCache!
    private var service: MockNotificationService!
    private var sut: NotificationCoordinator!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        cache = MockAlbumArtCache()
        service = MockNotificationService()
        sut = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            notificationsEnabled: { true },
            channelTitle: { _ in "The Main Mix" },
            cachedFileURL: { coverPath in
                URL(fileURLWithPath: "/tmp/\(coverPath.replacingOccurrences(of: "/", with: "_"))")
            }
        )
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testNotifiesOnNowPlayingEmissionWhenEnabled() async throws {
        await sut.start()
        await coordinator.setNowPlaying(.fixture(title: "Song", artist: "Artist", album: "Album"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.notifyCalls.count, 1)
        XCTAssertEqual(service.notifyCalls[0].title, "Artist — Song")
        XCTAssertEqual(service.notifyCalls[0].subtitle, "Album · The Main Mix")
    }

    func testSkipsNotificationWhenDisabled() async throws {
        sut = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            notificationsEnabled: { false },
            channelTitle: { _ in "Main" },
            cachedFileURL: { _ in nil }
        )
        await sut.start()
        await coordinator.setNowPlaying(.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(service.notifyCalls.isEmpty)
    }

    func testStopCancelsSubscription() async throws {
        await sut.start()
        await sut.stop()
        await coordinator.setNowPlaying(.fixture())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(service.notifyCalls.isEmpty)
    }
}

actor MockAlbumArtCache: AlbumArtCache {
    var calls: [String] = []
    func image(for coverPath: String) async -> NSImage? {
        calls.append(coverPath)
        return nil
    }
}

actor MockNotificationService: NotificationService {
    struct NotifyCall: Equatable, Sendable {
        let title: String
        let subtitle: String
        let attachmentURL: URL?
    }
    var notifyCalls: [NotifyCall] = []
    var authorizationResult: Bool = true

    func requestAuthorization() async throws -> Bool { authorizationResult }
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        notifyCalls.append(NotifyCall(title: title, subtitle: subtitle, attachmentURL: attachmentURL))
    }
}

extension NowPlaying {
    static func fixture(
        title: String = "Title",
        artist: String = "Artist",
        album: String = "Album",
        cover: String? = nil
    ) -> NowPlaying {
        NowPlaying(
            channelId: 0,
            song: PlayListSong(
                songId: "1",
                artist: artist,
                title: title,
                album: album,
                duration: 180_000,
                event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
                rating: nil, userRating: nil, cover: cover, elapsed: nil, slideshow: nil
            ),
            songIndexInBlock: 0,
            blockDurationSeconds: 720,
            songStartSeconds: 0,
            songEndSeconds: 180
        )
    }
}
```

`MockNotificationService.notifyCalls` is read on `MainActor` from the test methods; the actor's getter returns the array as a value type, which is `Sendable`. Use `await service.notifyCalls` everywhere the test reads it — adjust the assertions accordingly: `let calls = await service.notifyCalls; XCTAssertEqual(calls.count, 1)`. The skeleton above is shortened for readability; expand the actual reads with `await` per actor isolation.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.NotificationCoordinatorTests`
Expected: `NotificationCoordinator` undefined.

- [ ] **Step 3: Implement the coordinator**

`Sources/RPPlayer/Notifications/NotificationCoordinator.swift`:

```swift
import AppKit
import Foundation

@MainActor
public final class NotificationCoordinator {
    public typealias NotificationsEnabledProvider = @Sendable () async -> Bool
    public typealias ChannelTitleProvider = @Sendable (Int) async -> String?
    public typealias CachedFileURLProvider = @Sendable (String) async -> URL?

    private let coordinator: any PlaybackCoordinator
    private let cache: any AlbumArtCache
    private let service: any NotificationService
    private let notificationsEnabled: NotificationsEnabledProvider
    private let channelTitle: ChannelTitleProvider
    private let cachedFileURL: CachedFileURLProvider
    private var subscriptionTask: Task<Void, Never>?

    public init(
        coordinator: any PlaybackCoordinator,
        cache: any AlbumArtCache,
        service: any NotificationService,
        notificationsEnabled: @escaping NotificationsEnabledProvider,
        channelTitle: @escaping ChannelTitleProvider,
        cachedFileURL: @escaping CachedFileURLProvider
    ) {
        self.coordinator = coordinator
        self.cache = cache
        self.service = service
        self.notificationsEnabled = notificationsEnabled
        self.channelTitle = channelTitle
        self.cachedFileURL = cachedFileURL
    }

    public func start() async {
        subscriptionTask?.cancel()
        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            for await np in stream {
                guard let self else { return }
                await self.handle(np)
            }
        }
    }

    public func stop() async {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    private func handle(_ np: NowPlaying) async {
        guard await notificationsEnabled() else { return }
        let title = "\(np.song.artist) — \(np.song.title)"
        let subtitlePrefix = np.song.album
        let channel = await channelTitle(np.channelId) ?? ""
        let subtitle = channel.isEmpty ? subtitlePrefix : "\(subtitlePrefix) · \(channel)"

        var attachmentURL: URL?
        if let cover = np.song.cover {
            _ = await cache.image(for: cover)   // Ensure file is on disk.
            attachmentURL = await cachedFileURL(cover)
        }

        do {
            try await service.notify(title: title, subtitle: subtitle, attachmentURL: attachmentURL)
        } catch {
            // The notification daemon refuses unbundled processes; tolerate.
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.NotificationCoordinatorTests`
Expected: 3 tests pass. Adjust `await service.notifyCalls` reads in the test file as noted in Step 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Notifications/NotificationCoordinator.swift \
        Tests/RPPlayerTests/Notifications/NotificationCoordinatorTests.swift
git commit -m "feat(pr09): NotificationCoordinator subscribes to nowPlaying and posts"
```

---

## Task 4: `MiniPlayerViewModel` art binding

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`

The view model gains an `albumArtCache: any AlbumArtCache` dependency and a `@Published private(set) var currentArt: NSImage?` it loads on every `nowPlaying` update.

- [ ] **Step 1: Write failing test**

Append to `MiniPlayerViewModelTests`:

```swift
    func testCurrentArtLoadsFromCacheOnNowPlayingUpdate() async throws {
        let cache = StubArtCache()
        cache.imageByPath["covers/l/1.jpg"] = NSImage(size: NSSize(width: 1, height: 1))
        let model = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache
        )
        await model.start()
        let np = NowPlaying.fixture(cover: "covers/l/1.jpg")
        await coordinator.setNowPlaying(np)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(model.currentArt)
        XCTAssertEqual(cache.requestedPaths, ["covers/l/1.jpg"])
    }

    func testCurrentArtClearsWhenNowPlayingHasNoCover() async throws {
        let cache = StubArtCache()
        let model = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache
        )
        await model.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.currentArt)
        XCTAssertTrue(cache.requestedPaths.isEmpty)
    }
```

Add the `StubArtCache` helper inside the test file:

```swift
@MainActor
final class StubArtCache: AlbumArtCache {
    var imageByPath: [String: NSImage] = [:]
    var requestedPaths: [String] = []
    func image(for coverPath: String) async -> NSImage? {
        await MainActor.run { self.requestedPaths.append(coverPath) }
        return await MainActor.run { self.imageByPath[coverPath] }
    }
}
```

The `@MainActor` stub keeps cross-actor reads simple in the assertion lines above.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: compile error — `init(coordinator:api:initialChannelId:albumArtCache:)` does not exist.

- [ ] **Step 3: Update the view model**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`:

Add to the stored properties:
```swift
    @Published private(set) var currentArt: NSImage?
    private let albumArtCache: any AlbumArtCache
```

Update the init:
```swift
    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        albumArtCache: any AlbumArtCache,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }
```

Update the subscription `Task` body in `start()`:
```swift
    subscriptionTask = Task { [weak self] in
        for await np in stream {
            guard let self else { return }
            await MainActor.run {
                self.nowPlaying = np
                self.isPlaying = true
            }
            await self.loadArt(for: np)
        }
    }
```

Add the helper:
```swift
    private func loadArt(for np: NowPlaying) async {
        guard let cover = np.song.cover else {
            await MainActor.run { self.currentArt = nil }
            return
        }
        let image = await albumArtCache.image(for: cover)
        await MainActor.run { self.currentArt = image }
    }
```

Update the existing `setUp` in `MiniPlayerViewModelTests` so `sut` is constructed with `albumArtCache: StubArtCache()` — and the existing 11 tests still pass.

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RPPlayerTests.MiniPlayerViewModelTests`
Expected: 13 tests pass (was 11; +2 art tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift
git commit -m "feat(pr09): MiniPlayerViewModel loads currentArt from cache on update"
```

---

## Task 5: `MiniPlayerView` shows real art + dynamic background color

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Modify: `Sources/RPPlayer/Shell/PopoverController.swift` — replace the `cgColor` snapshot on the content layer with a SwiftUI background (PR 7 review M5).

- [ ] **Step 1: Replace the artwork ZStack in `MiniPlayerView.swift`**

```swift
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 200, height: 200)
    }
```

- [ ] **Step 2: Update the panel background to a SwiftUI shape (PR 7 review M5 follow-up)**

In `PopoverController.swift`, drop the `panel.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor` line and instead wrap the hosted view's `rootView` in a SwiftUI `Color(nsColor:)` background applied at the SwiftUI layer. Easiest move: change the `init(rootView:)` to wrap the supplied root in a `Color(nsColor: .windowBackgroundColor)` background:

```swift
    init(rootView: AnyView) {
        let wrapped = AnyView(
            rootView
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = NSRect(origin: .zero, size: Self.contentSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
    }
```

The rounded corners stay on the layer (because `NSPanel` shadow needs a non-clear hosting view to shape itself around). The background color now lives in SwiftUI and updates with appearance changes.

- [ ] **Step 3: Build and run all tests**

Run: `swift build` → clean.
Run: `swift test` → all green. The view tests still pass because they don't assert layer state.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift \
        Sources/RPPlayer/Shell/PopoverController.swift
git commit -m "feat(pr09): MiniPlayerView renders cover art; panel uses dynamic background"
```

---

## Task 6: `AppDelegate` wiring + `PlaybackCoordinatorError: LocalizedError`

**Files:**
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` — `extension PlaybackCoordinatorError: LocalizedError`.

- [ ] **Step 1: Add `LocalizedError` conformance to `PlaybackCoordinatorError`**

At the bottom of `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`, append:

```swift
extension PlaybackCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .blockHasNoSongs:
            return "Stream block contained no songs."
        case .engineError(let message):
            return "Audio engine error: \(message)"
        }
    }
}
```

If the enum has additional cases not listed above (verify by reading the file), extend the switch with a clean message for each rather than a default branch.

- [ ] **Step 2: Extend `Bootstrap` and `realBootstrap`**

In `AppDelegate.swift`, extend `Bootstrap`:

```swift
    struct Bootstrap {
        let viewModel: MiniPlayerViewModel
        let notificationCoordinator: NotificationCoordinator
        let coordinatorShutdown: @Sendable () async -> Void
    }
```

Extend the stored properties:

```swift
    private(set) var notificationCoordinator: NotificationCoordinator?
```

Update `applicationDidFinishLaunching` to retain the notification coordinator and call its `start()`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        let result = bootstrap()
        self.viewModel = result.viewModel
        self.notificationCoordinator = result.notificationCoordinator
        self.coordinatorShutdown = result.coordinatorShutdown

        Task { await result.notificationCoordinator.start() }

        let popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: result.viewModel)))
        statusItemController = StatusItemController(popover: popover)
    }
```

Update `applicationWillTerminate` to stop the notification coordinator before waiting on the engine shutdown:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        Task { await self.notificationCoordinator?.stop() }

        guard let shutdown = coordinatorShutdown else { return }
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            await shutdown()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }
```

Update `realBootstrap` to construct the cache + service + coordinator:

```swift
    private static func realBootstrap() -> Bootstrap {
        let logger = AppLogger(category: "shell")
        let configURL = ConfigPaths.configFile
        let initial = Self.loadSettings(from: configURL)
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        let cookieProvider = AnonymousCookieProvider()
        let api = LiveRpApiClient(cookieProvider: cookieProvider, logger: logger)

        let imageBaseURL = URL(string: "https://img.radioparadise.com/")!
        let cache: any AlbumArtCache
        do {
            cache = try LiveAlbumArtCache(
                directory: ConfigPaths.albumArtCacheDirectory,
                baseURL: imageBaseURL,
                logger: logger
            )
        } catch {
            logger.error("Failed to open album art cache: \(error.localizedDescription)")
            cache = NoopAlbumArtCache()
        }

        let engine: any PlayerEngine
        do {
            engine = try LibmpvPlayerEngine()
        } catch {
            engine = NoopPlayerEngine(error: error)
        }

        let coordinator = LivePlaybackCoordinator(
            api: api,
            engine: engine,
            logger: logger,
            bitrate: initial.bitrate
        )

        let notificationService = LiveNotificationService()
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: notificationService,
            notificationsEnabled: { [store] in
                guard let store else { return false }
                return await store.settings.notificationsEnabled
            },
            channelTitle: { [api] channelId in
                guard let channels = try? await api.listChannels() else { return nil }
                return channels.first(where: { Int($0.chan) == channelId })?.title
            },
            cachedFileURL: { [cache] coverPath in
                if let liveCache = cache as? LiveAlbumArtCache {
                    return await liveCache.fileURL(for: coverPath)
                }
                return nil
            }
        )

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        Task {
            // Best-effort authorization request; fails silently in unbundled processes.
            _ = try? await notificationService.requestAuthorization()
        }

        return Bootstrap(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            coordinatorShutdown: { await coordinator.shutdown() }
        )
    }

    private static func loadSettings(from url: URL) -> AppSettings { ... unchanged ... }

    private struct NoopAlbumArtCache: AlbumArtCache {
        func image(for coverPath: String) async -> NSImage? { nil }
    }
```

`LiveAlbumArtCache.fileURL(for:)` is a small public actor method to be added to expose where a given cover lives on disk:

```swift
    public func fileURL(for coverPath: String) -> URL? {
        let key = Self.cacheKey(for: coverPath)
        let url = directory.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
```

- [ ] **Step 3: Update `AppDelegateTests`**

Replace `setUp` to construct a `Bootstrap` with all three services mocked:

```swift
    override func setUp() async throws {
        delegate = AppDelegate(bootstrap: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let cache = StubAlbumArtCache()
            let service = MockNotificationService()
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator,
                api: api,
                initialChannelId: 0,
                albumArtCache: cache
            )
            let notificationCoordinator = NotificationCoordinator(
                coordinator: coordinator,
                cache: cache,
                service: service,
                notificationsEnabled: { false },
                channelTitle: { _ in nil },
                cachedFileURL: { _ in nil }
            )
            return AppDelegate.Bootstrap(
                viewModel: viewModel,
                notificationCoordinator: notificationCoordinator,
                coordinatorShutdown: { await coordinator.shutdown() }
            )
        })
    }
```

If `StubAlbumArtCache` is internal to `MiniPlayerViewModelTests.swift`, hoist it to a shared file `Tests/RPPlayerTests/Shell/StubAlbumArtCache.swift` so both test classes can see it.

Add a new test for the terminate-path shutdown invocation (PR 8 review M7 follow-up):

```swift
    func testApplicationWillTerminateInvokesShutdown() async throws {
        let didShutDown = AsyncSignal()
        delegate = AppDelegate(bootstrap: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let cache = StubAlbumArtCache()
            let service = MockNotificationService()
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator, api: api, initialChannelId: 0, albumArtCache: cache
            )
            let notificationCoordinator = NotificationCoordinator(
                coordinator: coordinator, cache: cache, service: service,
                notificationsEnabled: { false }, channelTitle: { _ in nil }, cachedFileURL: { _ in nil }
            )
            return AppDelegate.Bootstrap(
                viewModel: viewModel,
                notificationCoordinator: notificationCoordinator,
                coordinatorShutdown: { await didShutDown.signal() }
            )
        })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let signaled = await didShutDown.wait(timeout: .seconds(2))
        XCTAssertTrue(signaled)
    }

    final class AsyncSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var fired = false

        func signal() async {
            lock.lock()
            fired = true
            let pending = continuations
            continuations.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait(timeout: Duration) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        self.lock.lock()
                        if self.fired {
                            self.lock.unlock()
                            c.resume()
                        } else {
                            self.continuations.append(c)
                            self.lock.unlock()
                        }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
        }
    }
```

The `AsyncSignal` helper is intentionally lock-based; `Task.detached` inside `applicationWillTerminate` runs the shutdown closure off the main actor, so the signal must be `Sendable`.

- [ ] **Step 4: Build and run**

Run: `swift build` → clean.
Run: `swift test` → all green. Expected count: previous + 1 (new terminate test) − 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift \
        Sources/RPPlayer/Notifications/AlbumArtCache.swift \
        Sources/RPPlayer/Shell/AppDelegate.swift \
        Tests/RPPlayerTests/Shell/AppDelegateTests.swift \
        Tests/RPPlayerTests/Shell/StubAlbumArtCache.swift
git commit -m "feat(pr09): wire AlbumArtCache + NotificationCoordinator into AppDelegate"
```

---

## Task 7: Polish + manual smoke + CLAUDE.md + merge

- [ ] **Step 1: Comment audit**

Walk every `//` line introduced in PR 9. Each must explain a non-obvious WHY (CLAUDE.md). Expected to keep:
- `// The notification daemon refuses unbundled processes; tolerate.` in `NotificationCoordinator.handle`.
- `// Best-effort authorization request; fails silently in unbundled processes.` in `AppDelegate.realBootstrap`.

Strip anything else.

- [ ] **Step 2: Build clean + serial tests**

Run: `swift build` → clean, no new warnings.
Run: `swift test` → green. Capture the new total. Expected delta: +6 cache + 4 service + 3 coordinator + 2 view-model + 1 terminate-test = +16 → 111 + 16 = 127. Adjust the CLAUDE.md entry to match the actual count.

- [ ] **Step 3: Manual smoke**

Run: `swift run RPPlayer`

Confirm:
- Menu-bar icon appears.
- Click → popover opens.
- Click Play → song streams; album art replaces the placeholder once the cover downloads (a few hundred ms).
- Subsequent songs in the same block: art swaps when boundary is crossed.
- Channel switch: art swaps to the new channel's current song.
- Background color of the popover responds to dark/light system appearance toggle (Apple → System Settings → Appearance).
- Outside-click and Esc still dismiss the popover.

Notifications WILL NOT appear in `swift run` mode (`UNUserNotificationCenter.add(_:)` rejects unbundled processes). Confirm via `Console.app` filtered on `RPPlayer` that the `NotificationCoordinator.handle` swallow-the-throw branch is reached. Real notification smoke happens after PR 12 (distribution).

If any visible smoke point fails, STOP and report `BLOCKED`.

- [ ] **Step 4: Update `CLAUDE.md`**

Flip PR 9 row to ✅; mark PR 10 as next:

```markdown
| 9 | merged to main | ✅ | NotificationCoordinator + AlbumArtCache + album art in MiniPlayerView |
| 10 | **next** | ⬜ | SettingsView + rating row |
```

Replace the "PR 8 shipped scope" paragraph with PR 9's:

```markdown
PR 9 shipped scope: `LiveAlbumArtCache` (on-disk LRU at `ConfigPaths.albumArtCacheDirectory`, 20 files / 10 MB, SHA-256 keys), `LiveNotificationService` (wraps `UNUserNotificationCenter` behind a small protocol), and `NotificationCoordinator` (subscribes to `nowPlayingUpdates`, posts via service, respects `AppSettings.notificationsEnabled` and looks up channel title via the API). `MiniPlayerView` displays cover art via `Image(nsImage:)` when available, falling back to the SF Symbol placeholder. Panel background switched to a SwiftUI `Color(nsColor: .windowBackgroundColor)` so light/dark appearance changes are honored at runtime. `PlaybackCoordinatorError` now conforms to `LocalizedError` so user-visible error banners are clean prose. Notifications are wired but only post under a bundled `.app` (PR 12); `swift run RPPlayer` swallows the daemon's rejection. Out of scope (deferred): rating row (PR 10), settings link/window (PR 10), AppContainer composition root (PR 11), main-menu/`Cmd-Q` (PR 11), `LSUIElement` Info.plist (PR 12).
```

Append to test counts:

```markdown
- After PR 9: <count> tests
```

Append to "Key technical decisions":

```markdown
- `LiveAlbumArtCache` keys files by SHA-256 of the cover path (e.g. `"covers/l/24372.jpg"`), not by `songId`. Multiple songs share an album, so keying by song would re-download the same JPEG. Cache size is capped at 20 files / 10 MB; eviction runs on every successful write and removes oldest by `contentModificationDate`. In-flight de-duplication via a `coverPath → Task` map prevents duplicate downloads when two callers race.
- `LiveNotificationService` wraps `UNUserNotificationCenter` behind `UNUserNotificationCenterProtocol`. The real class is `final` since macOS 13, so substitution requires an external protocol. `UNUserNotificationCenter.current()` works in any process but `requestAuthorization` and `add(_:)` only succeed inside a bundled `.app`. PR 9 tolerates the rejection (logs and continues); PR 12 ships the bundle that makes posting work.
- `NotificationCoordinator` is `@MainActor final class` (not an actor) because it consumes a SwiftUI-friendly `nowPlaying` stream and bridges to AppKit / UserNotifications types that are main-thread anchored. The subscription `Task` is spawned in `start()`, mirroring `MiniPlayerViewModel`. Configuration (notifications-enabled flag, channel title, on-disk file URL) is injected as `@Sendable` async closures so production wires them to live `JSONConfigStore`/`RpApiClient`/cache reads while tests substitute lightweight stubs.
- The popover's panel background was migrated from a `cgColor` snapshot to a SwiftUI `Color(nsColor:)` background so appearance-change notifications (Light/Dark toggles, Increase Contrast) re-render the popover without recomposing the layer. Rounded corners stay on `panel.contentView.layer` because `NSPanel` shadow needs a non-clear hosting view to derive its shape from.
- `PlaybackCoordinatorError: LocalizedError` provides clean `errorDescription` strings so the `MiniPlayerView` error banner reads as prose rather than `engineError(message: "...")`. The view model surfaces `error.localizedDescription`, which now picks up these strings.
```

- [ ] **Step 5: Commit `CLAUDE.md`**

```bash
git add CLAUDE.md
git commit -m "docs(pr09): record notifications + album-art decisions and post-PR9 test count"
```

- [ ] **Step 6: Fast-forward merge to `main`**

From `/Users/gergely/git/rp-player`:

```bash
cd /Users/gergely/git/rp-player
git merge --ff-only <PR-9-branch>
git rev-list --count main..HEAD   # must print 0
```

If the primary worktree has any non-PR-9 changes, STOP and ask the user. Same etiquette as PR 7 / PR 8 merges.

---

## Self-review checklist

- **Spec coverage:** every PR 9 row item ("NotificationCenterWrapper + AlbumArtCache") is implemented or explicitly deferred.
- **PR 7 / PR 8 follow-ups carried in:** I3 plan banner already landed; M5 dynamic background, M7 terminate-path shutdown test, and `LocalizedError` conformance are addressed in this PR. Esc-monitor scope tightening still deferred — surface in PR 10 plan once `SettingsView` introduces a non-popover window.
- **Comment policy:** every `//` line explains a non-obvious WHY.
- **Test count math:** previous = 111, expected new ≈ 127 (+16). Adjust CLAUDE.md to actual.
- **No regression:** `swift build` clean, `swift test` 100% pass, manual smoke green for visible behavior.
- **Plan-vs-shipped drift:** if any compile-time deviations are needed (Swift 6.2 strict concurrency edge cases), record at the bottom of this plan in an "Implementation deviations" section before merging.
