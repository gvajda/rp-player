# Notification Click → Past-Song Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a song notification opens a popover for that song. If it's the song currently playing, open the existing main popover. If it's a past song, open a new compact `PastSongView` popover with album art + title row + working rating dropdown — using cached metadata when available, falling back to `api/info` when not.

**Architecture:** Notification request id becomes `"<UUID>|<songId>"`. A small `SongRegistry` actor caches the last 100 notified `PlayListSong`s in memory. A `NotificationClickRouter` (UNUserNotificationCenterDelegate) decodes the id, asks the coordinator if the song is currently playing, then either opens the main popover or fetches the song from the registry / `api/info` and shows a stripped-down `PastSongView` popover.

**Tech Stack:** Swift 6.2, AppKit (`UNUserNotificationCenterDelegate`, borderless `NSPanel`), SwiftUI (`PastSongView` reusing `RatingMenu`), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-02-notification-click-past-song-design.md`

**Branch:** `claude/notification-click-past-song` off `main`.

---

## Pre-flight

- [ ] **Step 0a: Create branch**

```bash
git checkout main
git checkout -b claude/notification-click-past-song
```

- [ ] **Step 0b: Confirm baseline**

```bash
swift test 2>&1 | tail -5
```

Expected: 222 tests passing on `main`.

---

## Task 1: `SongRegistry` actor + tests

**Files:**
- Create: `Sources/RPPlayer/Notifications/SongRegistry.swift`
- Create: `Tests/RPPlayerTests/Notifications/SongRegistryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import RPPlayer

private func makeSong(id: String, title: String = "T") -> PlayListSong {
    PlayListSong(
        songId: id, artist: "A", title: title, album: "Al", duration: 1000,
        event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
        rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
    )
}

final class SongRegistryTests: XCTestCase {
    func testRecordAndLookupReturnsTheRecordedSong() async {
        let registry = SongRegistry(capacity: 10)
        await registry.record(makeSong(id: "1", title: "First"))
        let result = await registry.lookup(songId: "1")
        XCTAssertEqual(result?.title, "First")
    }

    func testLookupReturnsNilForUnknownId() async {
        let registry = SongRegistry(capacity: 10)
        let result = await registry.lookup(songId: "missing")
        XCTAssertNil(result)
    }

    func testCapacityEvictsOldestFirst() async {
        let registry = SongRegistry(capacity: 3)
        await registry.record(makeSong(id: "1"))
        await registry.record(makeSong(id: "2"))
        await registry.record(makeSong(id: "3"))
        await registry.record(makeSong(id: "4"))
        let evicted = await registry.lookup(songId: "1")
        let kept = await registry.lookup(songId: "4")
        XCTAssertNil(evicted)
        XCTAssertNotNil(kept)
    }

    func testDuplicateRecordMovesToFrontAndReplaces() async {
        let registry = SongRegistry(capacity: 3)
        await registry.record(makeSong(id: "1", title: "First"))
        await registry.record(makeSong(id: "2"))
        await registry.record(makeSong(id: "3"))
        // Re-record id=1 with new metadata.
        await registry.record(makeSong(id: "1", title: "First (updated)"))
        // Now record id=4 — id=2 (oldest after the move) should be evicted, NOT id=1.
        await registry.record(makeSong(id: "4"))
        let updated = await registry.lookup(songId: "1")
        let evicted = await registry.lookup(songId: "2")
        XCTAssertEqual(updated?.title, "First (updated)")
        XCTAssertNil(evicted)
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

```bash
swift test --filter SongRegistryTests 2>&1 | tail -10
```

Expected: build error — `SongRegistry` not defined.

- [ ] **Step 3: Implement `SongRegistry`**

```swift
import Foundation

public actor SongRegistry {
    private struct Entry {
        let songId: String
        let song: PlayListSong
    }

    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 100) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func record(_ song: PlayListSong) {
        entries.removeAll { $0.songId == song.songId }
        entries.append(Entry(songId: song.songId, song: song))
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    public func lookup(songId: String) -> PlayListSong? {
        entries.first(where: { $0.songId == songId })?.song
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter SongRegistryTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 226 tests pass (222 + 4).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Notifications/SongRegistry.swift Tests/RPPlayerTests/Notifications/SongRegistryTests.swift
git commit -m "feat(notifications): add SongRegistry — bounded ring buffer of recently notified songs"
```

---

## Task 2: `LiveNotificationService` identifier suffix + extractSongId

**Files:**
- Modify: `Sources/RPPlayer/Notifications/NotificationService.swift`
- Create: `Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UserNotifications
@testable import RPPlayer

private actor RecordingCenter: UNUserNotificationCenterProtocol {
    var requests: [UNNotificationRequest] = []
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }
}

final class NotificationServiceTests: XCTestCase {
    func testNotifyWithIdentifierSuffixComposesPipeFormat() async throws {
        let center = RecordingCenter()
        let service = LiveNotificationService(center: center)
        try await service.notify(title: "T", subtitle: "S", attachmentURL: nil, identifierSuffix: "12345")
        let requests = await center.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].identifier.contains("|12345"),
                      "identifier should end with '|12345', got: \(requests[0].identifier)")
        XCTAssertEqual(requests[0].identifier.split(separator: "|").count, 2)
    }

    func testNotifyWithoutSuffixHasNoSeparator() async throws {
        let center = RecordingCenter()
        let service = LiveNotificationService(center: center)
        try await service.notify(title: "T", subtitle: "S", attachmentURL: nil)
        let requests = await center.requests
        XCTAssertFalse(requests[0].identifier.contains("|"))
    }

    func testExtractSongIdParsesSuffixForm() {
        let id = "ABC-DEF-GHI|9999"
        XCTAssertEqual(LiveNotificationService.extractSongId(from: id), "9999")
    }

    func testExtractSongIdReturnsNilForLegacyIdWithoutSeparator() {
        XCTAssertNil(LiveNotificationService.extractSongId(from: "no-separator"))
    }

    func testExtractSongIdReturnsNilForEmptySuffix() {
        XCTAssertNil(LiveNotificationService.extractSongId(from: "uuid|"))
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter NotificationServiceTests 2>&1 | tail -10
```

Expected: build error — `notify(...identifierSuffix:)` and `extractSongId(from:)` don't exist yet.

- [ ] **Step 3: Update protocol + impl + add static helper**

Open `Sources/RPPlayer/Notifications/NotificationService.swift`. Replace the file with:

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
    func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws
}

public extension NotificationService {
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {
        try await notify(title: title, subtitle: subtitle, attachmentURL: attachmentURL, identifierSuffix: nil)
    }
}

public actor LiveNotificationService: NotificationService {
    private let center: any UNUserNotificationCenterProtocol

    public init(center: any UNUserNotificationCenterProtocol) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let url = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: url.lastPathComponent, url: url) {
            content.attachments = [attachment]
        }
        let identifier: String
        if let suffix = identifierSuffix, !suffix.isEmpty {
            identifier = "\(UUID().uuidString)|\(suffix)"
        } else {
            identifier = UUID().uuidString
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    public static func extractSongId(from requestIdentifier: String) -> String? {
        let parts = requestIdentifier.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let suffix = String(parts[1])
        return suffix.isEmpty ? nil : suffix
    }
}
```

Also update `NoopNotificationService` (search for it — it's in `AppContainer.swift`):

```swift
private final class NoopNotificationService: NotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func notify(title: String, subtitle: String, attachmentURL: URL?, identifierSuffix: String?) async throws {}
}
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter NotificationServiceTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 5 new tests pass; full suite at 231 (226 + 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Notifications/NotificationService.swift Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift
git commit -m "feat(notifications): identifier suffix + extractSongId for routing notifications back to a song"
```

---

## Task 3: `NotificationCoordinator` records to registry + passes suffix

**Files:**
- Modify: `Sources/RPPlayer/Notifications/NotificationCoordinator.swift`

- [ ] **Step 1: Add `registry` parameter and use it**

Replace the file with:

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
    private let registry: SongRegistry
    private let notificationsEnabled: NotificationsEnabledProvider
    private let channelTitle: ChannelTitleProvider
    private let cachedFileURL: CachedFileURLProvider
    private var subscriptionTask: Task<Void, Never>?

    public init(
        coordinator: any PlaybackCoordinator,
        cache: any AlbumArtCache,
        service: any NotificationService,
        registry: SongRegistry,
        notificationsEnabled: @escaping NotificationsEnabledProvider,
        channelTitle: @escaping ChannelTitleProvider,
        cachedFileURL: @escaping CachedFileURLProvider
    ) {
        self.coordinator = coordinator
        self.cache = cache
        self.service = service
        self.registry = registry
        self.notificationsEnabled = notificationsEnabled
        self.channelTitle = channelTitle
        self.cachedFileURL = cachedFileURL
    }

    public func start() async {
        subscriptionTask?.cancel()
        let stream = await coordinator.nowPlayingUpdates
        subscriptionTask = Task { [weak self] in
            for await np in stream {
                if Task.isCancelled { return }
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
        await registry.record(np.song)
        guard await notificationsEnabled() else { return }
        let title = "\(np.song.artist) — \(np.song.title)"
        let subtitlePrefix = np.song.album ?? ""
        let channel = await channelTitle(np.channelId) ?? ""
        let subtitle: String
        if subtitlePrefix.isEmpty {
            subtitle = channel
        } else if channel.isEmpty {
            subtitle = subtitlePrefix
        } else {
            subtitle = "\(subtitlePrefix) · \(channel)"
        }

        var attachmentURL: URL?
        if let cover = np.song.cover {
            _ = await cache.image(for: cover)
            attachmentURL = await cachedFileURL(cover)
        }

        do {
            try await service.notify(
                title: title,
                subtitle: subtitle,
                attachmentURL: attachmentURL,
                identifierSuffix: np.song.songId
            )
        } catch {
            // The notification daemon refuses unbundled processes; tolerate.
        }
    }
}
```

- [ ] **Step 2: Update existing call sites**

`AppContainer.live()` constructs `NotificationCoordinator(...)` — find it and add `registry: registry` (the registry will be added in Task 7's wire-up). For now, to keep the project compiling, add a temporary inline `registry: SongRegistry()` at the call site.

Existing `NotificationCoordinatorTests` (search with `find Tests -name "NotificationCoordinatorTests*"`) need their constructor calls updated too — add `registry: SongRegistry()` to every `NotificationCoordinator(...)` call in test setup. Existing tests should keep passing because the coordinator's only new behavior is calling `registry.record(np.song)` before the existing notify path.

- [ ] **Step 3: Build + run full suite**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: 231 tests still passing.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Notifications/NotificationCoordinator.swift Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/Notifications/
git commit -m "feat(notifications): NotificationCoordinator records to SongRegistry + passes songId as identifier suffix"
```

---

## Task 4: `PlayListSong` adapter from `SongInfo`

**Files:**
- Modify: `Sources/RPPlayer/Api/ApiModels.swift`
- Test: `Tests/RPPlayerTests/Api/PlayListSongFromInfoTests.swift` (new file)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RPPlayer

final class PlayListSongFromInfoTests: XCTestCase {
    func testInitFromSongInfoMapsCommonFieldsAndPrefersLargeCover() {
        let info = SongInfo(
            songId: 4242,
            artist: "Bowie",
            title: "Heroes",
            album: "\"Heroes\"",
            asin: nil,
            avgRating: 9.1,
            numRatings: nil,
            userRating: 9,
            webLink: nil,
            wikiLink: nil,
            lyricsAvail: nil,
            lyrics: nil,
            medCover: "covers/m/abc.jpg",
            largeCover: "covers/l/abc.jpg",
            releaseDate: nil,
            length: "367",
            plays30: nil,
            slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertEqual(song.songId, "4242")
        XCTAssertEqual(song.artist, "Bowie")
        XCTAssertEqual(song.title, "Heroes")
        XCTAssertEqual(song.album, "\"Heroes\"")
        XCTAssertEqual(song.cover, "covers/l/abc.jpg")
        XCTAssertEqual(song.userRating, "9")
        XCTAssertEqual(song.duration, 367_000)
    }

    func testInitFallsBackToMedCoverWhenLargeMissing() {
        let info = SongInfo(
            songId: 1, artist: "A", title: "T", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: "m.jpg", largeCover: nil,
            releaseDate: nil, length: nil, plays30: nil, slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertEqual(song.cover, "m.jpg")
        XCTAssertNil(song.userRating)
        XCTAssertEqual(song.duration, 0)
    }

    func testInitHandlesAllNilCovers() {
        let info = SongInfo(
            songId: 1, artist: "A", title: "T", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: nil, largeCover: nil,
            releaseDate: nil, length: nil, plays30: nil, slideshow: nil
        )
        let song = PlayListSong(from: info)
        XCTAssertNil(song.cover)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter PlayListSongFromInfoTests 2>&1 | tail -10
```

Expected: build error — `init(from: SongInfo)` doesn't exist.

- [ ] **Step 3: Add adapter init**

Open `Sources/RPPlayer/Api/ApiModels.swift`. After the `PlayListSong` struct definition (around line 31), add an extension:

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
            slideshow: info.slideshow
        )
    }
}
```

`SongInfo.length` is a `String?` representing seconds; `PlayListSong.duration` is `Int` ms. Conversion: parse → multiply by 1000. Default to 0 if missing.

If `PlayListSong.init(songId:artist:title:album:duration:...)` is the auto-synthesized memberwise init and it isn't `public`, add an explicit public init mirroring the field order. Check by looking at existing call sites — `Tests/RPPlayerTests/Playback/NowPlayingFixture.swift` uses `PlayListSong(songId:artist:...)` with named args, so the memberwise init is already callable (Swift's synthesized init for `public struct` with all-`let` `public` properties is `internal`, but it's reachable from `@testable import` — for production use we need an explicit `public` init). Add it at the top of the struct body if not present:

```swift
public init(
    songId: String, artist: String, title: String, album: String?,
    duration: Int, event: String?, schedTime: String?, chan: String?,
    year: String?, asin: String?, rating: String?, userRating: String?,
    cover: String?, elapsed: Int?, slideshow: String?
) {
    self.songId = songId; self.artist = artist; self.title = title; self.album = album
    self.duration = duration; self.event = event; self.schedTime = schedTime; self.chan = chan
    self.year = year; self.asin = asin; self.rating = rating; self.userRating = userRating
    self.cover = cover; self.elapsed = elapsed; self.slideshow = slideshow
}
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter PlayListSongFromInfoTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 3 new tests pass; full suite at 234 (231 + 3).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Api/ApiModels.swift Tests/RPPlayerTests/Api/PlayListSongFromInfoTests.swift
git commit -m "feat(api): PlayListSong.init(from: SongInfo) adapter for /api/info → past-song view"
```

---

## Task 5: `PastSongViewModel` + tests

**Files:**
- Create: `Sources/RPPlayer/Shell/PastSongViewModel.swift`
- Create: `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongViewModelTests: XCTestCase {
    private func makeSong(rating: String? = nil, cover: String? = nil) -> PlayListSong {
        PlayListSong(
            songId: "100", artist: "Artist", title: "Title", album: "Album",
            duration: 0, event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: rating, cover: cover, elapsed: nil, slideshow: nil
        )
    }

    func testStartHydratesRatingFromUserRating() async {
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let auth = StubKeychainAuth()
        auth.loggedIn = true
        let sut = PastSongViewModel(song: makeSong(rating: "8"), albumArtCache: cache, auth: auth, api: api)
        await sut.start()
        XCTAssertEqual(sut.currentRating, 8)
        XCTAssertTrue(sut.isSignedIn)
    }

    func testStartHydratesNilRatingWhenAbsent() async {
        let sut = PastSongViewModel(
            song: makeSong(rating: nil),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        await sut.start()
        XCTAssertNil(sut.currentRating)
    }

    func testStartLoadsArtFromCacheWhenCoverPresent() async {
        let cache = StubAlbumArtCache()
        cache.images["covers/l/x.jpg"] = NSImage(size: NSSize(width: 16, height: 16))
        let sut = PastSongViewModel(
            song: makeSong(cover: "covers/l/x.jpg"),
            albumArtCache: cache,
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        await sut.start()
        XCTAssertNotNil(sut.currentArt)
    }

    func testRateCallsApiAndUpdatesCurrentRating() async {
        let api = MockRpApiClient()
        let sut = PastSongViewModel(
            song: makeSong(rating: "5"),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: api
        )
        await sut.start()
        await sut.rate(9)
        let calls = await api.recordedRateCalls()
        XCTAssertEqual(calls, [.init(songId: 100, rating: 9)])
        XCTAssertEqual(sut.currentRating, 9)
    }

    func testRateLeavesRatingUnchangedOnError() async {
        let api = MockRpApiClient()
        await api.setNextError(RpApiError.unauthorized)
        let sut = PastSongViewModel(
            song: makeSong(rating: "5"),
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: api
        )
        await sut.start()
        await sut.rate(9)
        XCTAssertEqual(sut.currentRating, 5)
    }
}
```

If `MockRpApiClient` doesn't already expose `recordedRateCalls()`, look at existing tests (e.g. `MiniPlayerViewModelTests.testRate*`) for the pattern in use and adapt the assertion to whatever `MockRpApiClient` exposes. If `setNextError` doesn't exist on the mock, use whatever error-injection helper does. Worst case: stub the `rate` method directly in this test file via a tiny anonymous conforming class.

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter PastSongViewModelTests 2>&1 | tail -10
```

Expected: build error — `PastSongViewModel` doesn't exist.

- [ ] **Step 3: Implement `PastSongViewModel`**

```swift
import AppKit
import Foundation

@MainActor
public final class PastSongViewModel: ObservableObject {
    public let song: PlayListSong
    @Published public private(set) var currentArt: NSImage?
    @Published public private(set) var currentRating: Int?
    @Published public private(set) var isSignedIn: Bool

    private let albumArtCache: any AlbumArtCache
    private let auth: any KeychainAuth
    private let api: any RpApiClient

    public init(
        song: PlayListSong,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        api: any RpApiClient
    ) {
        self.song = song
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.api = api
        self.currentRating = Self.parseRating(song.userRating)
        self.isSignedIn = auth.isLoggedIn
    }

    public func start() async {
        isSignedIn = auth.isLoggedIn
        currentRating = Self.parseRating(song.userRating)
        guard let cover = song.cover else { return }
        let image = await albumArtCache.image(for: cover)
        currentArt = image
    }

    public func rate(_ value: Int) async {
        guard let id = Int(song.songId) else { return }
        do {
            _ = try await api.rate(songId: id, rating: value)
            currentRating = value
        } catch {
            // Leave currentRating unchanged. No error UI in this minimal view.
        }
    }

    private static func parseRating(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (1...10).contains(value) else { return nil }
        return value
    }
}
```

If `KeychainAuth` is the protocol name in this codebase, use it. Otherwise check `MiniPlayerViewModel`'s constructor for the actual protocol used (e.g. `auth: any AuthState`). Mirror exactly.

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter PastSongViewModelTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 5 new tests pass; full suite at 239 (234 + 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongViewModel.swift Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift
git commit -m "feat(shell): PastSongViewModel — rating + art for notification-targeted past songs"
```

---

## Task 6: `PastSongView` SwiftUI view + smoke test

**Files:**
- Create: `Sources/RPPlayer/Shell/PastSongView.swift`
- Create: `Tests/RPPlayerTests/Shell/PastSongViewTests.swift`

- [ ] **Step 1: Write the smoke test**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let song = PlayListSong(
            songId: "1", artist: "A", title: "T", album: "Al", duration: 0,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
        let viewModel = PastSongViewModel(
            song: song,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        let host = NSHostingController(rootView: PastSongView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
```

- [ ] **Step 2: Run test, expect failure**

```bash
swift test --filter PastSongViewTests 2>&1 | tail -10
```

Expected: build error — `PastSongView` doesn't exist.

- [ ] **Step 3: Implement `PastSongView`**

```swift
import AppKit
import SwiftUI

struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

    var body: some View {
        VStack(spacing: 0) {
            albumArt
            VStack(spacing: 12) {
                titleRow
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }

    private var albumArt: some View {
        Group {
            if let art = viewModel.currentArt {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 342, height: 342)
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .padding(80)
                    .foregroundStyle(.secondary)
                    .frame(width: 342, height: 342)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = viewModel.song.album, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(
                currentRating: viewModel.currentRating,
                isSignedIn: viewModel.isSignedIn
            ) { value in
                Task { await viewModel.rate(value) }
            }
        }
        .frame(width: 318)
    }
}
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter PastSongViewTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 1 new test passes; full suite at 240.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongView.swift Tests/RPPlayerTests/Shell/PastSongViewTests.swift
git commit -m "feat(shell): PastSongView — stripped-down popover for notification-clicked songs"
```

---

## Task 7: `PastSongPopoverController` + tests

**Files:**
- Create: `Sources/RPPlayer/Shell/PastSongPopoverController.swift`
- Create: `Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift`

- [ ] **Step 1: Write the smoke test**

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PastSongPopoverControllerTests: XCTestCase {
    func testShowMakesPanelVisibleAndCloseHidesIt() {
        let controller = PastSongPopoverController()
        XCTAssertFalse(controller.isShown)
        // Show with a synthetic anchor — full geometry path doesn't matter for smoke.
        let anchor = NSView(frame: .zero)
        let song = PlayListSong(
            songId: "1", artist: "A", title: "T", album: nil, duration: 0,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
        let viewModel = PastSongViewModel(
            song: song,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            api: MockRpApiClient()
        )
        controller.present(viewModel: viewModel, relativeTo: anchor)
        // Panel may or may not become visible depending on anchor.window — just
        // assert no crash and that close() flips state cleanly.
        controller.close()
        XCTAssertFalse(controller.isShown)
    }
}
```

- [ ] **Step 2: Run test, expect failure**

```bash
swift test --filter PastSongPopoverControllerTests 2>&1 | tail -10
```

Expected: build error — `PastSongPopoverController` doesn't exist.

- [ ] **Step 3: Implement `PastSongPopoverController`**

```swift
import AppKit
import SwiftUI

@MainActor
final class PastSongPopoverController {
    private static let contentSize = NSSize(width: 342, height: 540)
    private static let escapeKeyCode: UInt16 = 53

    private let panel: NSPanel
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init() {
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
        self.panel = panel
    }

    var isShown: Bool { panel.isVisible }

    func present(viewModel: PastSongViewModel, relativeTo anchor: NSView) {
        let root = AnyView(
            PastSongView(viewModel: viewModel)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.contentSize)
        panel.contentView = host
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 10
        panel.contentView?.layer?.masksToBounds = true
        hostingView = host

        guard let buttonWindow = anchor.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            anchor.convert(anchor.bounds, to: nil)
        )
        NSApp.activate(ignoringOtherApps: true)
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectInScreen.midX - panelSize.width / 2,
            y: buttonWindow.frame.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        removeMonitors()
        panel.orderOut(nil)
        hostingView = nil
        panel.contentView = nil
    }

    private func installMonitors() {
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.close() }
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                if event.keyCode == Self.escapeKeyCode {
                    Task { @MainActor [weak self] in self?.close() }
                    return nil
                }
                return event
            }
        }
    }

    private func removeMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter PastSongPopoverControllerTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 1 new test passes; full suite at 241.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongPopoverController.swift Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift
git commit -m "feat(shell): PastSongPopoverController — borderless NSPanel host for past-song view"
```

---

## Task 8: `NotificationClickRouter` + tests

**Files:**
- Create: `Sources/RPPlayer/Notifications/NotificationClickRouter.swift`
- Create: `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import UserNotifications
@testable import RPPlayer

@MainActor
final class NotificationClickRouterTests: XCTestCase {
    private func makeSong(id: String) -> PlayListSong {
        PlayListSong(
            songId: id, artist: "A", title: "T", album: nil, duration: 0,
            event: nil, schedTime: nil, chan: nil, year: nil, asin: nil,
            rating: nil, userRating: nil, cover: nil, elapsed: nil, slideshow: nil
        )
    }

    private func makeNowPlaying(songId: String) -> NowPlaying {
        NowPlaying(
            channelId: 0, song: makeSong(id: songId), songIndexInBlock: 0,
            blockDurationSeconds: 0, songStartSeconds: 0, songEndSeconds: 0
        )
    }

    private func makeResponse(requestId: String) -> UNNotificationResponse {
        // UNNotificationResponse has no public init, but request can be built directly.
        // We'll bypass the response wrapper by exposing the routing logic separately
        // (see Task 8 Step 3 — the public method takes the requestIdentifier directly,
        // and the UN delegate adapter forwards to it).
        fatalError("see route(requestIdentifier:) test below")
    }

    func testCurrentSongOpensMainPopover() async {
        let coordinator = MockPlaybackCoordinator()
        await coordinator.setNowPlaying(makeNowPlaying(songId: "55"))
        let registry = SongRegistry()
        let api = MockRpApiClient()
        var mainCalled = 0
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "abc|55")
        XCTAssertEqual(mainCalled, 1)
        XCTAssertTrue(pastSongs.isEmpty)
    }

    func testCachedPastSongOpensPastSongPopover() async {
        let coordinator = MockPlaybackCoordinator()
        await coordinator.setNowPlaying(makeNowPlaying(songId: "55"))
        let registry = SongRegistry()
        await registry.record(makeSong(id: "99"))
        var mainCalled = 0
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: MockRpApiClient(),
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "abc|99")
        XCTAssertEqual(mainCalled, 0)
        XCTAssertEqual(pastSongs.map(\.songId), ["99"])
    }

    func testApiInfoFallbackOnCacheMiss() async {
        let coordinator = MockPlaybackCoordinator()
        let registry = SongRegistry()
        let api = MockRpApiClient()
        let stubInfo = SongInfo(
            songId: 12345, artist: "From API", title: "From API", album: nil, asin: nil,
            avgRating: nil, numRatings: nil, userRating: nil,
            webLink: nil, wikiLink: nil, lyricsAvail: nil, lyrics: nil,
            medCover: nil, largeCover: nil, releaseDate: nil, length: nil,
            plays30: nil, slideshow: nil
        )
        await api.setNextInfo(stubInfo)
        var pastSongs: [PlayListSong] = []
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: {},
            pastSongPresenter: { song in pastSongs.append(song) }
        )
        await router.route(requestIdentifier: "uuid|12345")
        XCTAssertEqual(pastSongs.map(\.artist), ["From API"])
    }

    func testApiInfoFailureFallsBackToMainPopover() async {
        let coordinator = MockPlaybackCoordinator()
        let registry = SongRegistry()
        let api = MockRpApiClient()
        await api.setNextError(RpApiError.unauthorized)
        var mainCalled = 0
        let router = NotificationClickRouter(
            coordinator: coordinator,
            registry: registry,
            api: api,
            mainPresenter: { mainCalled += 1 },
            pastSongPresenter: { _ in }
        )
        await router.route(requestIdentifier: "uuid|99999")
        XCTAssertEqual(mainCalled, 1)
    }
}
```

`MockRpApiClient` likely needs `setNextInfo(_:)` if it doesn't have one. Search `Tests/` for the existing `MockRpApiClient` definition. If `setNextInfo` doesn't exist, add it as a small extension in the test target (or directly in the mock file) — mirror whatever pattern `setBlockResponses` follows.

- [ ] **Step 2: Run tests, expect failure**

```bash
swift test --filter NotificationClickRouterTests 2>&1 | tail -10
```

Expected: build error — `NotificationClickRouter` and likely `setNextInfo` don't exist.

- [ ] **Step 3: Implement `NotificationClickRouter`**

```swift
import AppKit
import Foundation
import UserNotifications

@MainActor
public final class NotificationClickRouter: NSObject, UNUserNotificationCenterDelegate {
    public typealias MainPresenter = @MainActor () -> Void
    public typealias PastSongPresenter = @MainActor (PlayListSong) -> Void

    private let coordinator: any PlaybackCoordinator
    private let registry: SongRegistry
    private let api: any RpApiClient
    private let mainPresenter: MainPresenter
    private let pastSongPresenter: PastSongPresenter

    public init(
        coordinator: any PlaybackCoordinator,
        registry: SongRegistry,
        api: any RpApiClient,
        mainPresenter: @escaping MainPresenter,
        pastSongPresenter: @escaping PastSongPresenter
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.api = api
        self.mainPresenter = mainPresenter
        self.pastSongPresenter = pastSongPresenter
    }

    public func route(requestIdentifier: String) async {
        guard let songId = LiveNotificationService.extractSongId(from: requestIdentifier) else {
            mainPresenter()
            return
        }
        if let np = await coordinator.nowPlaying, np.song.songId == songId {
            mainPresenter()
            return
        }
        if let cached = await registry.lookup(songId: songId) {
            pastSongPresenter(cached)
            return
        }
        guard let id = Int(songId) else {
            mainPresenter()
            return
        }
        do {
            let info = try await api.info(songId: id)
            pastSongPresenter(PlayListSong(from: info))
        } catch {
            mainPresenter()
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            await self.route(requestIdentifier: identifier)
            completionHandler()
        }
    }
}
```

- [ ] **Step 4: Run tests + full suite**

```bash
swift test --filter NotificationClickRouterTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 4 new tests pass; full suite at 245 (241 + 4).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Notifications/NotificationClickRouter.swift Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift Tests/RPPlayerTests/Api/MockRpApiClient.swift
git commit -m "feat(notifications): NotificationClickRouter — UN delegate routing notification clicks to main or past-song popover"
```

(If `MockRpApiClient.swift` lives at a different path, adjust the `git add` accordingly.)

---

## Task 9: Wire into `AppContainer` + `AppDelegate`

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`

- [ ] **Step 1: Construct registry, router, past-song controller in `AppContainer.live()`**

In `AppContainer.live()`:

1. After other top-level constructions, near the existing notification wiring, add:

```swift
let songRegistry = SongRegistry(capacity: 100)
```

2. Replace the existing inline `registry: SongRegistry()` placeholder in the `NotificationCoordinator(...)` call (added in Task 3) with `registry: songRegistry`.

3. Add a stored property on `AppContainer` to hold the router (so it stays alive — `UN.delegate` is `weak`):

```swift
public let notificationClickRouter: NotificationClickRouter?
public let pastSongPopoverController: PastSongPopoverController
```

Initialize them and pass them through the `init(...)`. The router is `nil` for the `Noop`/no-bundle path; non-`nil` for the live path.

4. In `live()`, after constructing `popoverController` and `statusItemController`, construct the past-song controller:

```swift
let pastSongPopoverController = PastSongPopoverController()
```

5. Construct the router only when `Bundle.main.bundleIdentifier != nil` (mirrors the live notification gate):

```swift
let notificationClickRouter: NotificationClickRouter?
if bundleId != nil {
    let router = NotificationClickRouter(
        coordinator: coordinator,
        registry: songRegistry,
        api: api,
        mainPresenter: { [weak statusItemController] in
            // Open via the status item so the popover anchors correctly.
            statusItemController?.toggleIfHidden()
        },
        pastSongPresenter: { [weak pastSongPopoverController, weak statusItemController, cache, keychainAuth, api] song in
            guard let pastSongPopoverController, let anchor = statusItemController?.statusItem.button else { return }
            // Close the main popover if it's showing.
            statusItemController?.closeIfShown()
            let viewModel = PastSongViewModel(
                song: song, albumArtCache: cache, auth: keychainAuth, api: api
            )
            pastSongPopoverController.present(viewModel: viewModel, relativeTo: anchor)
        }
    )
    UNUserNotificationCenter.current().delegate = router
    notificationClickRouter = router
} else {
    notificationClickRouter = nil
}
```

6. Pass both new fields into the returned `AppContainer(...)`.

- [ ] **Step 2: Add `toggleIfHidden()` and `closeIfShown()` to `StatusItemController`**

Open `Sources/RPPlayer/Shell/StatusItemController.swift`. After `toggle()` (around line 43) add:

```swift
func toggleIfHidden() {
    if !popover.isShown, let button = statusItem.button {
        showHandler(button)
    }
}

func closeIfShown() {
    if popover.isShown {
        closeHandler()
    }
}
```

These let the router open/close the main popover idempotently without the toggle-flips that confuse the past-song flow.

- [ ] **Step 3: Build + run full suite**

```bash
swift build 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: build succeeds; 245 tests passing (Tasks 1–8 + no regressions).

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Sources/RPPlayer/Shell/StatusItemController.swift Sources/RPPlayer/Shell/AppDelegate.swift
git commit -m "feat(app): wire SongRegistry + NotificationClickRouter + PastSongPopoverController into composition root"
```

---

## Task 10: Manual smoke

The behavior needs end-to-end verification — UN delegate paths, popover positioning, sign-in state, API fallback. Defer to user.

- [ ] **Step 1: Rebuild + reinstall the .app**

```bash
./scripts/make-app.sh release
pkill -f "RP Player" 2>/dev/null
rm -rf "/Applications/RP Player.app"
cp -R "build/RP Player.app" /Applications/
open "/Applications/RP Player.app"
```

- [ ] **Step 2: Walk the smoke checklist**

1. Play. Notification fires on song change. Click notification → main popover opens with the current song.
2. Skip forward to a new song. Click the previous song's notification (still in Notification Center) → past-song popover with that song's artist/title/album + album art (cache hit, no network). Pick a rating → digit updates immediately.
3. Switch channel. Click an earlier-channel notification → past-song popover with the cross-channel song.
4. Quit + relaunch. Click an old notification still in Notification Center. Album art may be a placeholder briefly while the cache fetches; song info comes from `api/info` (small delay before popover fills).
5. Sign out (Settings → Account → Sign out). Click any notification → past-song popover renders, rating shows `☆` and is disabled.

- [ ] **Step 3: No commit unless a fix lands.**

---

## Task 11: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump test count**

Append to the existing test-count list:

```
- After notification click → past-song popover (SongRegistry + identifier suffix + NotificationClickRouter + PastSongView + PastSongPopoverController + PlayListSong(from: SongInfo)): 245
```

- [ ] **Step 2: Add a "Notifications routing" bullet under the existing Notifications section**

Append:

```
- Notification request id format: `"<UUID>|<songId>"`. `LiveNotificationService.extractSongId(from:)` parses the suffix; the UUID prefix prevents `usernoted` from collapsing duplicate notifications when the same song replays.
- `SongRegistry` (in-memory, 100-song bounded ring buffer keyed by songId) caches every notified `PlayListSong` so notification clicks can recover full metadata without an API round-trip when the app is still running. `NotificationCoordinator.handle` records before notifying.
- `NotificationClickRouter` is the `UNUserNotificationCenterDelegate`. On click it: (a) extracts the songId from the request identifier; (b) if it matches `coordinator.nowPlaying`, opens the main popover; (c) else looks up the song in `SongRegistry`; (d) if missing (post-restart, distant past), fetches via `api/info` and converts to `PlayListSong` via `PlayListSong.init(from: SongInfo)`; (e) on API failure, falls back to opening the main popover. Held strongly on `AppContainer` because `UN.delegate` is `weak`.
- `PastSongPopoverController` mirrors `PopoverController` (borderless NSPanel + 10pt corner radius) but rebuilds its hosted `NSHostingView<PastSongView>` per `present(viewModel:relativeTo:)`. Mutual exclusion with the main popover — `pastSongPresenter` calls `statusItemController.closeIfShown()` first.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): note notification routing + SongRegistry + past-song popover"
```

---

## Task 12: Final verification + handoff

- [ ] **Step 1: Build + tests + git state**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
git log --oneline main..HEAD
```

Expected: build succeeds; 245 tests passing; ~12 commits ahead of `main`.

- [ ] **Step 2: Hand back to user for ff-merge**

User is the merge gatekeeper.

---

## Self-review notes

- **Spec coverage:**
  - Identifier format → Tasks 2, 3.
  - SongRegistry → Tasks 1, 3.
  - Click routing → Task 8.
  - PlayListSong adapter → Task 4.
  - PastSongView/ViewModel → Tasks 5, 6.
  - PastSongPopoverController → Task 7.
  - Wire-up + mutual exclusion → Task 9.
  - Manual smoke → Task 10.
  - Docs → Task 11.
- **Type consistency:** `SongRegistry`, `record(_:)`, `lookup(songId:)`, `extractSongId(from:)`, `identifierSuffix:`, `NotificationClickRouter.route(requestIdentifier:)`, `PastSongPopoverController.present(viewModel:relativeTo:)` all consistent across tasks.
- **No placeholders:** every step has either exact code or an exact command + expected output. Tasks 5 and 8 include explicit "search the codebase if mock helper has a different name" instructions because the existing mock conventions weren't fully captured by my exploration — implementer must adapt to whatever's in `MockRpApiClient` / `StubKeychainAuth` / `StubAlbumArtCache`.
- **TDD:** every behavior task is failing-test-first. The view tasks (6, 7) use the existing render-without-crash smoke-test pattern only; manual smoke (Task 10) covers visual behavior.
