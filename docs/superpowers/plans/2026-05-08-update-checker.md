# Update Checker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify the user when a newer GitHub release of RP Player is available, with an in-popover button, a sticky menu item, and a release-notes panel offering Download DMG / View Full Notes / Later. No auto-update; informational only.

**Architecture:** New `UpdateChecker` actor (`Sources/RPPlayer/Updates/`) polls `api.github.com/repos/gvajda/rp-player/releases/latest` on startup + every 24h, publishes `AsyncStream<UpdateState>`. View models subscribe and drive popover button + menu item visibility. `UpdatePanelController` hosts a SwiftUI panel with three actions. Persistence via 4 new fields on `AppSettings`.

**Tech Stack:** Swift 6.2, macOS 14, SwiftUI + AppKit, async/await actors, `URLSession` + `StubURLProtocol`. Spec: `docs/superpowers/specs/2026-05-08-update-checker-design.md`.

---

## File map

**New:**

- `Sources/RPPlayer/Updates/UpdateCheckerTypes.swift` — `SemVer`, `ReleaseInfo`, `UpdateState`, `GitHubRelease` (decode model), `GitHubReleaseAsset`.
- `Sources/RPPlayer/Updates/UpdateChecker.swift` — `UpdateChecking` protocol + `UpdateChecker` actor + `NoopUpdateChecker`.
- `Sources/RPPlayer/Shell/UpdatePanelView.swift` — SwiftUI view for the release-notes panel.
- `Sources/RPPlayer/Shell/UpdatePanelController.swift` — `@MainActor` controller wrapping an `NSPanel` + `NSHostingView`.
- `Tests/RPPlayerTests/Updates/SemVerTests.swift`
- `Tests/RPPlayerTests/Updates/UpdateCheckerTypesTests.swift`
- `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest.json`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest_prerelease.json`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest_no_dmg.json`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest_multi_asset.json`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest_draft.json`

**Modified:**

- `Sources/RPPlayer/Config/AppSettings.swift` — 4 new fields + decoder defaults.
- `Sources/RPPlayer/App/AppContainer.swift` — wire `UpdateChecker` (or `NoopUpdateChecker`); start on launch.
- `Sources/RPPlayer/Shell/AppDelegate.swift` — construct `UpdatePanelController`; late-bind `MiniPlayerViewModel.openUpdatePanel`.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — replace `Text("RP Player")` with conditional `UpdateAvailableButton`; add menu item between About and Quit.
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — `updateButtonVisible`, `updateAvailableForMenu`, `openUpdatePanel` closure, subscription to `updateChecker.stateUpdates`.
- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — Updates section bindings + setters.
- `Sources/RPPlayer/Shell/SettingsView.swift` — new Updates `Section`.
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift` — new state cases.
- `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` — toggle + checkNow + status line.
- `Tests/RPPlayerTests/App/AppContainerTests.swift` — pass-through stub.

---

### Task 1: SemVer type + parsing/comparison tests

**Files:**

- Create: `Sources/RPPlayer/Updates/UpdateCheckerTypes.swift`
- Test: `Tests/RPPlayerTests/Updates/SemVerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RPPlayerTests/Updates/SemVerTests.swift
import XCTest
@testable import RPPlayer

final class SemVerTests: XCTestCase {
    func testParseStripsLeadingV() {
        XCTAssertEqual(SemVer.parse("v0.5.2"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseAcceptsBareSemver() {
        XCTAssertEqual(SemVer.parse("0.5.2"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseStripsPrereleaseSuffix() {
        XCTAssertEqual(SemVer.parse("v0.5.2-beta.1"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SemVer.parse("garbage"))
        XCTAssertNil(SemVer.parse("v"))
        XCTAssertNil(SemVer.parse(""))
        XCTAssertNil(SemVer.parse("v1.2"))
        XCTAssertNil(SemVer.parse("v1.2.x"))
    }

    func testCompareNumericNotLex() {
        XCTAssertLessThan(
            SemVer(major: 0, minor: 5, patch: 2),
            SemVer(major: 0, minor: 5, patch: 10)
        )
    }

    func testCompareMajorBeatsMinor() {
        XCTAssertGreaterThan(
            SemVer(major: 1, minor: 0, patch: 0),
            SemVer(major: 0, minor: 99, patch: 99)
        )
    }

    func testEqualityIgnoresPrereleaseSuffix() {
        XCTAssertEqual(SemVer.parse("v0.5.2"), SemVer.parse("v0.5.2-rc.1"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SemVerTests`
Expected: FAIL with "cannot find 'SemVer' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/RPPlayer/Updates/UpdateCheckerTypes.swift
import Foundation

public struct SemVer: Sendable, Equatable, Comparable, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(_ raw: String) -> SemVer? {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        return SemVer(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SemVerTests`
Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Updates/UpdateCheckerTypes.swift Tests/RPPlayerTests/Updates/SemVerTests.swift
git commit -m "feat: add SemVer type for update version comparison"
```

---

### Task 2: ReleaseInfo, UpdateState, GitHubRelease decode model

**Files:**

- Modify: `Sources/RPPlayer/Updates/UpdateCheckerTypes.swift`
- Create: `Tests/RPPlayerTests/Updates/UpdateCheckerTypesTests.swift`
- Create: `Tests/RPPlayerTests/Fixtures/Updates/release_latest.json`
- Create: `Tests/RPPlayerTests/Fixtures/Updates/release_latest_prerelease.json`
- Create: `Tests/RPPlayerTests/Fixtures/Updates/release_latest_no_dmg.json`
- Create: `Tests/RPPlayerTests/Fixtures/Updates/release_latest_multi_asset.json`
- Create: `Tests/RPPlayerTests/Fixtures/Updates/release_latest_draft.json`

- [ ] **Step 1: Create the JSON fixtures**

`Tests/RPPlayerTests/Fixtures/Updates/release_latest.json` — minimal real-shape sample with one DMG asset:

```json
{
  "tag_name": "v0.5.0",
  "name": "v0.5.0",
  "body": "## What's new\n\n- Gapless block transitions\n- Update checker\n- Per-device audio settings",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-05-08T10:00:00Z",
  "html_url": "https://github.com/gvajda/rp-player/releases/tag/v0.5.0",
  "assets": [
    {
      "name": "RP Player-v0.5.0.dmg",
      "browser_download_url": "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
    }
  ]
}
```

`Tests/RPPlayerTests/Fixtures/Updates/release_latest_prerelease.json`:

```json
{
  "tag_name": "v0.6.0-beta.1",
  "name": "v0.6.0 beta",
  "body": "Beta build.",
  "draft": false,
  "prerelease": true,
  "published_at": "2026-05-09T10:00:00Z",
  "html_url": "https://github.com/gvajda/rp-player/releases/tag/v0.6.0-beta.1",
  "assets": []
}
```

`Tests/RPPlayerTests/Fixtures/Updates/release_latest_draft.json`:

```json
{
  "tag_name": "v0.7.0",
  "name": "v0.7.0",
  "body": "Draft.",
  "draft": true,
  "prerelease": false,
  "published_at": "2026-05-10T10:00:00Z",
  "html_url": "https://github.com/gvajda/rp-player/releases/tag/v0.7.0",
  "assets": []
}
```

`Tests/RPPlayerTests/Fixtures/Updates/release_latest_no_dmg.json`:

```json
{
  "tag_name": "v0.5.0",
  "name": "v0.5.0",
  "body": "Zip-only release.",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-05-08T10:00:00Z",
  "html_url": "https://github.com/gvajda/rp-player/releases/tag/v0.5.0",
  "assets": [
    {
      "name": "RP Player-v0.5.0.zip",
      "browser_download_url": "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.zip"
    }
  ]
}
```

`Tests/RPPlayerTests/Fixtures/Updates/release_latest_multi_asset.json`:

```json
{
  "tag_name": "v0.5.0",
  "name": "v0.5.0",
  "body": "Mixed assets.",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-05-08T10:00:00Z",
  "html_url": "https://github.com/gvajda/rp-player/releases/tag/v0.5.0",
  "assets": [
    {
      "name": "source.zip",
      "browser_download_url": "https://example.com/source.zip"
    },
    {
      "name": "RP Player-v0.5.0.dmg",
      "browser_download_url": "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
    }
  ]
}
```

- [ ] **Step 2: Wire fixtures into the SwiftPM target**

Modify `Package.swift`'s `RPPlayerTests` target so the new fixtures are bundled. Search for existing `resources:` for `RPPlayerTests` and add:

```swift
.copy("Fixtures/Updates/release_latest.json"),
.copy("Fixtures/Updates/release_latest_prerelease.json"),
.copy("Fixtures/Updates/release_latest_no_dmg.json"),
.copy("Fixtures/Updates/release_latest_multi_asset.json"),
.copy("Fixtures/Updates/release_latest_draft.json"),
```

If existing fixtures use `.copy("Fixtures/Api/...")` per-file, follow that pattern. If they use `.copy("Fixtures")` directory-wide, no change needed beyond confirming.

Run: `swift build --target RPPlayerTests`
Expected: builds (no behavior yet).

- [ ] **Step 3: Write failing decode tests**

```swift
// Tests/RPPlayerTests/Updates/UpdateCheckerTypesTests.swift
import XCTest
@testable import RPPlayer

final class UpdateCheckerTypesTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Updates")
                ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testDecodeMinimalRelease() throws {
        let data = try loadFixture("release_latest")
        let release = try GitHubRelease.decode(from: data)
        XCTAssertEqual(release.tagName, "v0.5.0")
        XCTAssertFalse(release.prerelease)
        XCTAssertFalse(release.draft)
        XCTAssertEqual(release.htmlUrl.absoluteString, "https://github.com/gvajda/rp-player/releases/tag/v0.5.0")
        XCTAssertTrue(release.body.contains("Gapless block transitions"))
        XCTAssertEqual(release.assets.count, 1)
    }

    func testReleaseInfoFromDecode() throws {
        let data = try loadFixture("release_latest")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertEqual(info.version, SemVer(major: 0, minor: 5, patch: 0))
        XCTAssertEqual(
            info.dmgAssetUrl?.absoluteString,
            "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
        )
    }

    func testReleaseInfoNoDmgAsset() throws {
        let data = try loadFixture("release_latest_no_dmg")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertNil(info.dmgAssetUrl)
    }

    func testReleaseInfoPicksDmgFromMultiAsset() throws {
        let data = try loadFixture("release_latest_multi_asset")
        let release = try GitHubRelease.decode(from: data)
        let info = try XCTUnwrap(ReleaseInfo(release: release))
        XCTAssertEqual(
            info.dmgAssetUrl?.absoluteString,
            "https://github.com/gvajda/rp-player/releases/download/v0.5.0/RP%20Player-v0.5.0.dmg"
        )
    }

    func testReleaseInfoNilWhenTagUnparseable() throws {
        // Synthesize a release with bad tag name.
        let raw = """
        {"tag_name":"garbage","name":"x","body":"","draft":false,"prerelease":false,
         "published_at":"2026-05-08T10:00:00Z","html_url":"https://example.com","assets":[]}
        """.data(using: .utf8)!
        let release = try GitHubRelease.decode(from: raw)
        XCTAssertNil(ReleaseInfo(release: release))
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTypesTests`
Expected: FAIL with "cannot find 'GitHubRelease' in scope" / "cannot find 'ReleaseInfo' in scope".

- [ ] **Step 5: Implement types**

Append to `Sources/RPPlayer/Updates/UpdateCheckerTypes.swift`:

```swift
public struct GitHubReleaseAsset: Sendable, Decodable, Equatable {
    public let name: String
    public let browserDownloadUrl: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

public struct GitHubRelease: Sendable, Decodable, Equatable {
    public let tagName: String
    public let body: String
    public let draft: Bool
    public let prerelease: Bool
    public let publishedAt: Date
    public let htmlUrl: URL
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case htmlUrl = "html_url"
        case assets
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

public struct ReleaseInfo: Sendable, Equatable, Codable {
    public let tagName: String
    public let version: SemVer
    public let publishedAt: Date
    public let body: String
    public let htmlUrl: URL
    public let dmgAssetUrl: URL?

    public init(
        tagName: String,
        version: SemVer,
        publishedAt: Date,
        body: String,
        htmlUrl: URL,
        dmgAssetUrl: URL?
    ) {
        self.tagName = tagName
        self.version = version
        self.publishedAt = publishedAt
        self.body = body
        self.htmlUrl = htmlUrl
        self.dmgAssetUrl = dmgAssetUrl
    }

    public init?(release: GitHubRelease) {
        guard let version = SemVer.parse(release.tagName) else { return nil }
        let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
        self.init(
            tagName: release.tagName,
            version: version,
            publishedAt: release.publishedAt,
            body: release.body,
            htmlUrl: release.htmlUrl,
            dmgAssetUrl: dmg?.browserDownloadUrl
        )
    }
}

public enum UpdateState: Sendable, Equatable {
    case unknown
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo, dismissedFromButton: Bool)
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerTypesTests`
Expected: All 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Updates/UpdateCheckerTypes.swift \
        Tests/RPPlayerTests/Updates/UpdateCheckerTypesTests.swift \
        Tests/RPPlayerTests/Fixtures/Updates/ \
        Package.swift
git commit -m "feat: add GitHubRelease decode + ReleaseInfo + UpdateState"
```

---

### Task 3: AppSettings — 4 new fields with defaults

**Files:**

- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Test: existing `Tests/RPPlayerTests/Config/AppSettingsTests.swift` (or create if missing — confirm by listing dir)

- [ ] **Step 1: Write failing tests**

If `Tests/RPPlayerTests/Config/AppSettingsTests.swift` exists, append. Otherwise create. Use this test:

```swift
// Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift
import XCTest
@testable import RPPlayer

final class AppSettingsUpdateFieldsTests: XCTestCase {
    func testDefaultsForNewUpdateFields() {
        let s = AppSettings.default
        XCTAssertTrue(s.updateCheckEnabled)
        XCTAssertNil(s.lastUpdateCheckAt)
        XCTAssertNil(s.dismissedUpdateVersion)
        XCTAssertNil(s.cachedLatestRelease)
    }

    func testCodableRoundTripPreservesUpdateFields() throws {
        var s = AppSettings.default
        s.updateCheckEnabled = false
        s.lastUpdateCheckAt = Date(timeIntervalSince1970: 1_715_000_000)
        s.dismissedUpdateVersion = "v0.5.0"
        s.cachedLatestRelease = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(timeIntervalSince1970: 1_715_000_000),
            body: "notes",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: URL(string: "https://example.com/x.dmg")
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func testDecodeFromOldJsonMissingUpdateFieldsUsesDefaults() throws {
        // Simulate a pre-PR-29 settings JSON: emit current AppSettings without the new keys.
        let json = """
        {
          "selectedChannelId": 0,
          "hogModeEnabled": true,
          "releaseHogOnPauseEnabled": true,
          "forceMaxVolumeEnabled": false,
          "applyReplayGainEnabled": false,
          "notificationsEnabled": true,
          "appearance": "system",
          "menuBarIconStyle": "template",
          "ambientBackgroundEnabled": true,
          "popoverStyle": "ambient",
          "frostedUpcomingEnabled": false,
          "bitrate": 4,
          "logLevel": "info",
          "verboseLoggingEnabled": false,
          "upcomingRowCount": 5,
          "upcomingHiddenChannelIds": [],
          "popoverFloating": false,
          "audioProfiles": {}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.updateCheckEnabled)
        XCTAssertNil(decoded.lastUpdateCheckAt)
        XCTAssertNil(decoded.dismissedUpdateVersion)
        XCTAssertNil(decoded.cachedLatestRelease)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppSettingsUpdateFieldsTests`
Expected: FAIL with "value of type 'AppSettings' has no member 'updateCheckEnabled'".

- [ ] **Step 3: Add fields to `AppSettings`**

In `Sources/RPPlayer/Config/AppSettings.swift`, add after `audioProfiles`:

```swift
    public var updateCheckEnabled: Bool
    public var lastUpdateCheckAt: Date?
    public var dismissedUpdateVersion: String?
    public var cachedLatestRelease: ReleaseInfo?
```

Add to the `init(...)` parameter list (after `audioProfiles`):

```swift
        updateCheckEnabled: Bool = true,
        lastUpdateCheckAt: Date? = nil,
        dismissedUpdateVersion: String? = nil,
        cachedLatestRelease: ReleaseInfo? = nil
```

Add to the assignments in `init`:

```swift
        self.updateCheckEnabled = updateCheckEnabled
        self.lastUpdateCheckAt = lastUpdateCheckAt
        self.dismissedUpdateVersion = dismissedUpdateVersion
        self.cachedLatestRelease = cachedLatestRelease
```

Add to `init(from:)`:

```swift
        self.updateCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .updateCheckEnabled) ?? true
        self.lastUpdateCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheckAt)
        self.dismissedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .dismissedUpdateVersion)
        self.cachedLatestRelease = try c.decodeIfPresent(ReleaseInfo.self, forKey: .cachedLatestRelease)
```

Note: `AppSettings` synthesizes `CodingKeys` automatically from stored properties when no explicit `enum CodingKeys` exists. If the file already has explicit `CodingKeys`, add the four new cases. Inspect the file before editing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppSettingsUpdateFieldsTests`
Expected: All 3 tests pass.

Run all tests to confirm nothing else broke: `swift test`
Expected: PASS (current count + 3).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift \
        Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift
git commit -m "feat: add updateCheckEnabled, lastUpdateCheckAt, dismissedUpdateVersion, cachedLatestRelease to AppSettings"
```

---

### Task 4: `UpdateChecking` protocol + `NoopUpdateChecker`

**Files:**

- Create: `Sources/RPPlayer/Updates/UpdateChecker.swift`

- [ ] **Step 1: Write the protocol + Noop implementation**

```swift
// Sources/RPPlayer/Updates/UpdateChecker.swift
import Foundation

public protocol UpdateChecking: Sendable, AnyObject {
    func start() async
    func checkNow() async
    func dismissCurrentForButton() async
    var stateUpdates: AsyncStream<UpdateState> { get async }
    var currentState: UpdateState { get async }
}

public final class NoopUpdateChecker: UpdateChecking {
    public init() {}
    public func start() async {}
    public func checkNow() async {}
    public func dismissCurrentForButton() async {}
    public var stateUpdates: AsyncStream<UpdateState> {
        get async {
            AsyncStream { continuation in
                continuation.yield(.unknown)
                continuation.finish()
            }
        }
    }
    public var currentState: UpdateState { get async { .unknown } }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Updates/UpdateChecker.swift
git commit -m "feat: add UpdateChecking protocol + NoopUpdateChecker"
```

---

### Task 5: `UpdateChecker` actor — `checkNow()` happy path

**Files:**

- Modify: `Sources/RPPlayer/Updates/UpdateChecker.swift`
- Create: `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift
import XCTest
@testable import RPPlayer

final class UpdateCheckerTests: XCTestCase {
    private var fixedNow = Date(timeIntervalSince1970: 1_715_100_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Updates")
                ?? Bundle.module.url(forResource: name, withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    private func makeChecker(
        currentVersion: SemVer = SemVer(major: 0, minor: 4, patch: 1),
        store: any ConfigStore = StubConfigStore(initial: .default)
    ) -> UpdateChecker {
        let session = StubURLProtocol.makeSession()
        return UpdateChecker(
            currentVersion: currentVersion,
            repoOwner: "gvajda",
            repoName: "rp-player",
            urlSession: session,
            configStore: store,
            clock: { [self] in fixedNow }
        )
    }

    private static let endpoint = URL(
        string: "https://api.github.com/repos/gvajda/rp-player/releases/latest"
    )!

    func testCheckNowAvailable() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        let state = await checker.currentState
        guard case .available(let info, let dismissed) = state else {
            return XCTFail("expected .available, got \(state)")
        }
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertFalse(dismissed)
        XCTAssertEqual(await store.settings.lastUpdateCheckAt, fixedNow)
        XCTAssertEqual(await store.settings.cachedLatestRelease?.tagName, "v0.5.0")
    }

    func testCheckNowUpToDate() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(
            currentVersion: SemVer(major: 0, minor: 5, patch: 0),
            store: store
        )
        await checker.checkNow()

        let state = await checker.currentState
        guard case .upToDate(let when) = state else {
            return XCTFail("expected .upToDate, got \(state)")
        }
        XCTAssertEqual(when, fixedNow)
        XCTAssertEqual(await store.settings.lastUpdateCheckAt, fixedNow)
    }

    func testCheckNowFiltersPrerelease() async throws {
        let body = try loadFixture("release_latest_prerelease")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker()
        await checker.checkNow()

        let state = await checker.currentState
        guard case .upToDate = state else {
            return XCTFail("prerelease should be treated as upToDate, got \(state)")
        }
    }

    func testCheckNowFiltersDraft() async throws {
        let body = try loadFixture("release_latest_draft")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker()
        await checker.checkNow()

        guard case .upToDate = await checker.currentState else {
            return XCTFail("draft should be treated as upToDate")
        }
    }

    func testCheckNowNetworkErrorLeavesStateUnchanged() async throws {
        StubURLProtocol.registerError(url: Self.endpoint, error: URLError(.notConnectedToInternet))
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        XCTAssertEqual(await checker.currentState, .unknown)
        XCTAssertNil(await store.settings.lastUpdateCheckAt)
    }

    func testCheckNowHttp500LeavesStateUnchanged() async throws {
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 500)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        XCTAssertEqual(await checker.currentState, .unknown)
        XCTAssertNil(await store.settings.lastUpdateCheckAt)
    }

    func testCheckNowMalformedTagNotPersisted() async throws {
        let raw = """
        {"tag_name":"garbage","name":"x","body":"","draft":false,"prerelease":false,
         "published_at":"2026-05-08T10:00:00Z","html_url":"https://example.com","assets":[]}
        """.data(using: .utf8)!
        StubURLProtocol.register(url: Self.endpoint, body: raw, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()

        XCTAssertEqual(await checker.currentState, .unknown)
        XCTAssertNil(await store.settings.lastUpdateCheckAt)
    }
}
```

Note: This requires `StubURLProtocol.registerError(url:error:)`. Check whether it exists; if not, add it as a small extension in this test file:

```swift
// Append to top of UpdateCheckerTests.swift if registerError is missing.
// Inspect Tests/RPPlayerTests/Api/StubURLProtocol.swift first — only add if absent.
```

If `registerError` is missing in `StubURLProtocol`, add it there in this same task:

```swift
// Tests/RPPlayerTests/Api/StubURLProtocol.swift — extension or new method
extension StubURLProtocol {
    static func registerError(url: URL, error: Error) {
        // implement the same way existing register does, but call client?.urlProtocol(_:didFailWithError:)
        // Use existing internal storage pattern in the file.
    }
}
```

Inspect the file first; if the existing pattern keys storage by URL, add an `errors: [URL: Error]` parallel storage and check for it in `startLoading()` before falling through to body lookup.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTests`
Expected: FAIL with "missing argument for parameter 'currentVersion' in call" or "cannot find member 'init(...)' on 'UpdateChecker'".

- [ ] **Step 3: Implement `UpdateChecker` actor**

Append to `Sources/RPPlayer/Updates/UpdateChecker.swift`:

```swift
public actor UpdateChecker: UpdateChecking {
    private let currentVersion: SemVer
    private let repoOwner: String
    private let repoName: String
    private let urlSession: URLSession
    private let configStore: any ConfigStore
    private let clock: @Sendable () -> Date

    private var state: UpdateState = .unknown
    private var continuations: [UUID: AsyncStream<UpdateState>.Continuation] = [:]

    public init(
        currentVersion: SemVer,
        repoOwner: String,
        repoName: String,
        urlSession: URLSession,
        configStore: any ConfigStore,
        clock: @escaping @Sendable () -> Date
    ) {
        self.currentVersion = currentVersion
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.urlSession = urlSession
        self.configStore = configStore
        self.clock = clock
    }

    public var currentState: UpdateState { state }

    public var stateUpdates: AsyncStream<UpdateState> {
        let id = UUID()
        let snapshot = state
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func start() async {
        // Filled in Task 6.
        await checkNow()
    }

    public func checkNow() async {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            AppLogger.shared.debug("update check failed: \(error)", category: "updates")
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            AppLogger.shared.debug(
                "update check non-2xx: \((response as? HTTPURLResponse)?.statusCode ?? -1)",
                category: "updates"
            )
            return
        }

        let release: GitHubRelease
        do {
            release = try GitHubRelease.decode(from: data)
        } catch {
            AppLogger.shared.debug("update check decode failed: \(error)", category: "updates")
            return
        }

        let now = clock()

        if release.draft || release.prerelease {
            await applyUpToDate(now: now, cachedRelease: nil)
            return
        }

        guard let info = ReleaseInfo(release: release) else {
            AppLogger.shared.debug("update check tag unparseable: \(release.tagName)", category: "updates")
            return
        }

        if info.version > currentVersion {
            let dismissed = await readDismissedTag() == info.tagName
            await applyAvailable(info: info, dismissedFromButton: dismissed, now: now)
        } else {
            await applyUpToDate(now: now, cachedRelease: nil)
        }
    }

    public func dismissCurrentForButton() async {
        guard case .available(let info, _) = state else { return }
        try? await configStore.update { $0.dismissedUpdateVersion = info.tagName }
        emit(.available(info, dismissedFromButton: true))
    }

    private func readDismissedTag() async -> String? {
        await configStore.settings.dismissedUpdateVersion
    }

    private func applyAvailable(info: ReleaseInfo, dismissedFromButton: Bool, now: Date) async {
        try? await configStore.update {
            $0.lastUpdateCheckAt = now
            $0.cachedLatestRelease = info
        }
        emit(.available(info, dismissedFromButton: dismissedFromButton))
    }

    private func applyUpToDate(now: Date, cachedRelease: ReleaseInfo?) async {
        try? await configStore.update {
            $0.lastUpdateCheckAt = now
            $0.cachedLatestRelease = cachedRelease
        }
        emit(.upToDate(checkedAt: now))
    }

    private func emit(_ next: UpdateState) {
        state = next
        for c in continuations.values {
            c.yield(next)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter UpdateCheckerTests`
Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Updates/UpdateChecker.swift \
        Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift \
        Tests/RPPlayerTests/Api/StubURLProtocol.swift
git commit -m "feat: implement UpdateChecker.checkNow with state stream + ConfigStore writes"
```

---

### Task 6: `UpdateChecker.start()` — startup probe + 24h ticker

**Files:**

- Modify: `Sources/RPPlayer/Updates/UpdateChecker.swift`
- Modify: `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `UpdateCheckerTests`:

```swift
    func testStartSkipsCheckWhenToggleOff() async throws {
        var settings = AppSettings.default
        settings.updateCheckEnabled = false
        let store = StubConfigStore(initial: settings)
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 200)
        let checker = makeChecker(store: store)
        await checker.start()
        // Network was registered but state must remain .unknown because we never fetched.
        XCTAssertEqual(await checker.currentState, .unknown)
    }

    func testStartSeedsStateFromCachedRelease() async throws {
        let cached = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(timeIntervalSince1970: 1_715_000_000),
            body: "old notes",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        var settings = AppSettings.default
        settings.cachedLatestRelease = cached
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-3600)
        // Toggle off so start() seeds from cache then exits without firing checkNow,
        // making the seed the deterministic terminal state under test.
        settings.updateCheckEnabled = false
        let store = StubConfigStore(initial: settings)
        let checker = makeChecker(store: store)

        await checker.start()

        guard case .available(let info, let dismissed) = await checker.currentState else {
            return XCTFail("expected seeded .available, got \(await checker.currentState)")
        }
        XCTAssertEqual(info.tagName, "v0.5.0")
        XCTAssertFalse(dismissed)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTests`
Expected: at least one of the new tests fails because `start()` does not yet honor the toggle / seed from cache.

- [ ] **Step 3: Update `start()` and add seed logic**

Replace the `start()` body in `Sources/RPPlayer/Updates/UpdateChecker.swift`:

```swift
    public func start() async {
        let snapshot = await configStore.settings
        // Seed initial state from cached release so subscribers see something useful before checkNow returns.
        if let cached = snapshot.cachedLatestRelease, cached.version > currentVersion {
            let dismissed = snapshot.dismissedUpdateVersion == cached.tagName
            emit(.available(cached, dismissedFromButton: dismissed))
        } else if let last = snapshot.lastUpdateCheckAt {
            emit(.upToDate(checkedAt: last))
        }

        guard snapshot.updateCheckEnabled else { return }

        await checkNow()
        await scheduleDailyTicker()
    }

    private func scheduleDailyTicker() async {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(3600 * 1_000_000_000))  // 1 hour
                guard let self else { return }
                await self.tickIfDue()
            }
        }
    }

    private func tickIfDue() async {
        let snapshot = await configStore.settings
        guard snapshot.updateCheckEnabled else { return }
        let now = clock()
        if let last = snapshot.lastUpdateCheckAt {
            if now.timeIntervalSince(last) < 24 * 3600 { return }
        }
        await checkNow()
    }
```

Note: The 1h `Task.sleep` cannot be tested with the injected clock alone — that's intentional. The deterministic tests cover `tickIfDue()`'s due-check below; the wall-clock sleep is only verified indirectly. To make the schedule decision testable, expose `tickIfDue()` as `internal` (drop `private`) and add the test in step 4.

- [ ] **Step 4: Add test for `tickIfDue()` due-checking**

Append to `UpdateCheckerTests`:

```swift
    func testTickIfDueSkipsWhenLessThan24h() async throws {
        var settings = AppSettings.default
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-23 * 3600)  // 23h ago
        let store = StubConfigStore(initial: settings)
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        // No checkNow → state stays .unknown because we did not seed.
        XCTAssertEqual(await checker.currentState, .unknown)
        // lastUpdateCheckAt unchanged.
        XCTAssertEqual(await store.settings.lastUpdateCheckAt, fixedNow.addingTimeInterval(-23 * 3600))
    }

    func testTickIfDueRunsWhen25hElapsed() async throws {
        var settings = AppSettings.default
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-25 * 3600)
        let store = StubConfigStore(initial: settings)
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        guard case .available = await checker.currentState else {
            return XCTFail("expected check to fire and state to become .available")
        }
        XCTAssertEqual(await store.settings.lastUpdateCheckAt, fixedNow)
    }

    func testTickIfDueSkipsWhenToggleOff() async throws {
        var settings = AppSettings.default
        settings.updateCheckEnabled = false
        settings.lastUpdateCheckAt = fixedNow.addingTimeInterval(-48 * 3600)
        let store = StubConfigStore(initial: settings)
        StubURLProtocol.register(url: Self.endpoint, body: Data(), status: 200)
        let checker = makeChecker(store: store)
        await checker.tickIfDue()
        XCTAssertEqual(await checker.currentState, .unknown)
    }
```

Drop `private` on `tickIfDue` so the tests can call it (mark it `internal`):

```swift
    func tickIfDue() async {  // was `private func`
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter UpdateCheckerTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Updates/UpdateChecker.swift \
        Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift
git commit -m "feat: UpdateChecker.start seeds from cache + schedules 24h ticker"
```

---

### Task 7: Auto-reset of dismissedFromButton when latest > dismissed version

**Files:**

- Modify: `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`
- (No production change expected — `checkNow` already compares `dismissedUpdateVersion == info.tagName`. Verify and add the regression test.)

- [ ] **Step 1: Add the test**

Append:

```swift
    func testDismissedTagAutoResetsOnHigherRelease() async throws {
        var settings = AppSettings.default
        settings.dismissedUpdateVersion = "v0.5.0"
        let store = StubConfigStore(initial: settings)

        // Release fixture is v0.5.0 — same tag as dismissed → dismissed=true.
        let bodySame = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: bodySame, status: 200)
        let checker = makeChecker(
            currentVersion: SemVer(major: 0, minor: 4, patch: 1),
            store: store
        )
        await checker.checkNow()
        guard case .available(_, dismissedFromButton: true) = await checker.currentState else {
            return XCTFail("expected dismissedFromButton=true (same tag)")
        }

        // Now simulate a newer release v0.6.0; dismissed should auto-reset.
        StubURLProtocol.reset()
        let bodyHigher = """
        {"tag_name":"v0.6.0","name":"v0.6.0","body":"new","draft":false,"prerelease":false,
         "published_at":"2026-05-09T10:00:00Z",
         "html_url":"https://github.com/gvajda/rp-player/releases/tag/v0.6.0",
         "assets":[
           {"name":"RP Player-v0.6.0.dmg",
            "browser_download_url":"https://example.com/x.dmg"}
         ]}
        """.data(using: .utf8)!
        StubURLProtocol.register(url: Self.endpoint, body: bodyHigher, status: 200)
        await checker.checkNow()
        guard case .available(let info, dismissedFromButton: false) = await checker.currentState else {
            return XCTFail("expected dismissedFromButton=false on higher tag")
        }
        XCTAssertEqual(info.tagName, "v0.6.0")
    }

    func testDismissCurrentForButtonPersistsAndEmits() async throws {
        let body = try loadFixture("release_latest")
        StubURLProtocol.register(url: Self.endpoint, body: body, status: 200)
        let store = StubConfigStore(initial: .default)
        let checker = makeChecker(store: store)
        await checker.checkNow()
        guard case .available(_, dismissedFromButton: false) = await checker.currentState else {
            return XCTFail("setup: expected available")
        }
        await checker.dismissCurrentForButton()
        XCTAssertEqual(await store.settings.dismissedUpdateVersion, "v0.5.0")
        guard case .available(_, dismissedFromButton: true) = await checker.currentState else {
            return XCTFail("expected dismissedFromButton=true after dismiss")
        }
    }
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter UpdateCheckerTests`
Expected: PASS (no production change, just regression coverage).

- [ ] **Step 3: Commit**

```bash
git add Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift
git commit -m "test: cover dismissed-tag auto-reset + dismissCurrentForButton flow"
```

---

### Task 8: AppContainer wiring

**Files:**

- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Modify: `Tests/RPPlayerTests/App/AppContainerTests.swift`

- [ ] **Step 1: Inspect `AppContainer.swift`**

Open the file and locate:

(a) The init parameter list — add `updateChecker: any UpdateChecking` (default `NoopUpdateChecker()`) to the test seam.
(b) `static func live() throws -> AppContainer` — construct the real `UpdateChecker` (or `NoopUpdateChecker`) based on `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")`.
(c) `runOnLaunchTasks()` — add `await updateChecker.start()` to the task group.

- [ ] **Step 2: Add `updateChecker` to AppContainer**

Add a stored property:

```swift
    public let updateChecker: any UpdateChecking
```

Add to the `init(...)` test-seam parameters (with a default):

```swift
        updateChecker: any UpdateChecking = NoopUpdateChecker(),
```

Assign in init:

```swift
        self.updateChecker = updateChecker
```

In `static func live()`, before the return:

```swift
        let updateChecker: any UpdateChecking
        if let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let version = SemVer.parse(raw) {
            updateChecker = UpdateChecker(
                currentVersion: version,
                repoOwner: "gvajda",
                repoName: "rp-player",
                urlSession: .shared,
                configStore: configStore,
                clock: { Date() }
            )
        } else {
            updateChecker = NoopUpdateChecker()
        }
```

Pass to the init at the bottom of `live()`.

In `runOnLaunchTasks()`, add a child task:

```swift
        group.addTask { [updateChecker] in
            await updateChecker.start()
        }
```

(Match the existing pattern of `withTaskGroup`/`addTask` already in the file. If the file uses `await withTaskGroup(of: Void.self) { group in ... }`, follow that exact shape.)

- [ ] **Step 3: Add a smoke test**

Append to `Tests/RPPlayerTests/App/AppContainerTests.swift`:

```swift
    func testContainerHoldsNoopUpdateCheckerByDefault() async throws {
        let container = AppContainer(
            // pass-through using whatever defaults already exist in the test helper.
            // If existing tests construct a container with explicit args, mirror that and
            // omit `updateChecker:` so it picks up the default `NoopUpdateChecker()`.
        )
        let state = await container.updateChecker.currentState
        XCTAssertEqual(state, .unknown)
    }
```

If `AppContainer.init` does not have a default-constructible signature, follow the existing test pattern in this file (the `setUp` you can see uses `StubConfigStore(initial: .default)` etc.) and just verify `await container.updateChecker.currentState == .unknown`.

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: all tests pass (existing 384 + Task-1-through-7 additions still pass; new `testContainerHoldsNoopUpdateCheckerByDefault` passes).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift \
        Tests/RPPlayerTests/App/AppContainerTests.swift
git commit -m "feat: wire UpdateChecker into AppContainer (Noop fallback when unbundled)"
```

---

### Task 9: SettingsViewModel — toggle + checkNow + status line

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

- [ ] **Step 1: Inspect `SettingsViewModel.swift`**

Identify:

- Existing `@MainActor` annotation, `@Published` properties, and how setters call `configStore.update { ... }`.
- Whether the VM holds dependency objects (likely yes — `configStore`, etc.).

- [ ] **Step 2: Write failing tests**

```swift
// Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift — append, do not replace
    func testSetUpdateCheckEnabledPersists() async throws {
        let store = StubConfigStore(initial: .default)
        let vm = await SettingsViewModel(
            configStore: store,
            updateChecker: NoopUpdateChecker()
            // pass any other deps the existing init requires; mirror existing tests in this file.
        )
        await vm.setUpdateCheckEnabled(false)
        XCTAssertFalse(await store.settings.updateCheckEnabled)
        await vm.setUpdateCheckEnabled(true)
        XCTAssertTrue(await store.settings.updateCheckEnabled)
    }

    func testCheckNowInvokesUpdateChecker() async throws {
        actor SpyChecker: UpdateChecking {
            var checkNowCallCount = 0
            func start() async {}
            func checkNow() async { checkNowCallCount += 1 }
            func dismissCurrentForButton() async {}
            var stateUpdates: AsyncStream<UpdateState> {
                AsyncStream { $0.finish() }
            }
            var currentState: UpdateState { .unknown }
        }
        let spy = SpyChecker()
        let vm = await SettingsViewModel(
            configStore: StubConfigStore(initial: .default),
            updateChecker: spy
        )
        await vm.checkNow()
        let count = await spy.checkNowCallCount
        XCTAssertEqual(count, 1)
    }

    func testCurrentVersionLineUpToDate() async {
        let vm = await SettingsViewModel(
            configStore: StubConfigStore(initial: .default),
            updateChecker: NoopUpdateChecker(),
            currentVersionString: "v0.4.1"
        )
        await vm.applyUpdateState(.upToDate(checkedAt: Date(timeIntervalSince1970: 1_715_100_000)))
        let line = await vm.currentVersionLine
        XCTAssertEqual(line, "v0.4.1 (up to date)")
    }

    func testCurrentVersionLineAvailable() async {
        let vm = await SettingsViewModel(
            configStore: StubConfigStore(initial: .default),
            updateChecker: NoopUpdateChecker(),
            currentVersionString: "v0.4.1"
        )
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        await vm.applyUpdateState(.available(info, dismissedFromButton: false))
        let line = await vm.currentVersionLine
        XCTAssertEqual(line, "v0.5.0 available — open Update Available menu")
    }
```

- [ ] **Step 3: Run tests to confirm they fail**

Run: `swift test --filter SettingsViewModelTests`
Expected: FAIL — VM doesn't have new methods/properties.

- [ ] **Step 4: Add to SettingsViewModel**

In `SettingsViewModel.swift`:

(a) Add to the init signature:

```swift
    private let updateChecker: any UpdateChecking
    private let currentVersionString: String

    public init(
        // ... existing params,
        updateChecker: any UpdateChecking,
        currentVersionString: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    ) {
        // ... existing assignments
        self.updateChecker = updateChecker
        self.currentVersionString = currentVersionString
    }
```

(b) Add `@Published` properties:

```swift
    @Published public var updateCheckEnabled: Bool = true
    @Published public var lastCheckedRelative: String = "never"
    @Published public var currentVersionLine: String = ""
```

(c) Add setters:

```swift
    public func setUpdateCheckEnabled(_ value: Bool) async {
        try? await configStore.update { $0.updateCheckEnabled = value }
        updateCheckEnabled = value
    }

    public func checkNow() async {
        await updateChecker.checkNow()
    }

    public func applyUpdateState(_ state: UpdateState) {
        switch state {
        case .unknown:
            currentVersionLine = "\(displayVersion) (status unknown)"
        case .upToDate:
            currentVersionLine = "\(displayVersion) (up to date)"
        case .available(let info, _):
            currentVersionLine = "\(info.tagName) available — open Update Available menu"
        }
    }

    private var displayVersion: String {
        currentVersionString.hasPrefix("v") ? currentVersionString : "v" + currentVersionString
    }

    public func applyLastChecked(_ date: Date?) {
        guard let date else { lastCheckedRelative = "never"; return }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        lastCheckedRelative = f.localizedString(for: date, relativeTo: Date())
    }
```

(d) In an existing settings-subscription Task (or a new one started in `start()` if the VM has one), add:

```swift
        Task { [weak self, updateChecker] in
            guard let self else { return }
            for await state in await updateChecker.stateUpdates {
                await MainActor.run { self.applyUpdateState(state) }
            }
        }
```

And in the existing config subscription (where `updateCheckEnabled`, `lastUpdateCheckAt` flow), wire:

```swift
                self.updateCheckEnabled = settings.updateCheckEnabled
                self.applyLastChecked(settings.lastUpdateCheckAt)
```

- [ ] **Step 5: Run tests to confirm they pass**

Run: `swift test --filter SettingsViewModelTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat: SettingsViewModel — toggle, checkNow, version + lastChecked status lines"
```

---

### Task 10: SettingsView — Updates section UI

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

- [ ] **Step 1: Inspect existing structure**

Locate the `Form` and existing `Section`s (support, Output Device, etc.). Identify how toggles + buttons are wired (likely `Toggle("...", isOn: $viewModel.something) { ... } .onChange(of:) { Task { await ... } }` or `Toggle` bound to a method via `.onChange`).

- [ ] **Step 2: Add the Updates section**

Insert a new `Section("Updates")` after the support section and before Output Device. Use the same wiring pattern as existing toggles in this file:

```swift
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { viewModel.updateCheckEnabled },
                    set: { newValue in Task { await viewModel.setUpdateCheckEnabled(newValue) } }
                ))
                Text("Daily, while the app is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Button("Check Now") {
                        Task { await viewModel.checkNow() }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last checked: \(viewModel.lastCheckedRelative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.currentVersionLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
```

- [ ] **Step 3: Build to confirm SwiftUI compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 4: Smoke-launch the app to eyeball the section**

Run: `swift run RPPlayer` (skip if no terminal session; otherwise verify the Settings window shows the new section with sensible defaults).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat: Settings — Updates section (toggle + Check Now + status lines)"
```

---

### Task 11: MiniPlayerViewModel — update state subscription + button visibility

**Files:**

- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift — append
    func testUpdateButtonVisibleWhenAvailableAndNotDismissed() async throws {
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        let vm = await makeMiniPlayerViewModelForUpdateTests()  // helper below
        await vm.applyUpdateState(.available(info, dismissedFromButton: false))
        XCTAssertTrue(await vm.updateButtonVisible)
        XCTAssertNotNil(await vm.updateAvailableForMenu)
    }

    func testUpdateButtonHiddenWhenDismissedButMenuStays() async throws {
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        let vm = await makeMiniPlayerViewModelForUpdateTests()
        await vm.applyUpdateState(.available(info, dismissedFromButton: true))
        XCTAssertFalse(await vm.updateButtonVisible)
        XCTAssertNotNil(await vm.updateAvailableForMenu)
    }

    func testUpdateButtonAndMenuHiddenWhenUpToDate() async throws {
        let vm = await makeMiniPlayerViewModelForUpdateTests()
        await vm.applyUpdateState(.upToDate(checkedAt: Date()))
        XCTAssertFalse(await vm.updateButtonVisible)
        XCTAssertNil(await vm.updateAvailableForMenu)
    }

    func testOpenUpdatePanelInvokesClosureAndDismisses() async throws {
        actor SpyChecker: UpdateChecking {
            var dismissed = 0
            func start() async {}
            func checkNow() async {}
            func dismissCurrentForButton() async { dismissed += 1 }
            var stateUpdates: AsyncStream<UpdateState> { AsyncStream { $0.finish() } }
            var currentState: UpdateState { .unknown }
        }
        let spy = SpyChecker()
        let vm = await makeMiniPlayerViewModelForUpdateTests(updateChecker: spy)
        var openCount = 0
        await MainActor.run { vm.openUpdatePanel = { openCount += 1 } }
        await vm.requestOpenUpdatePanel()
        XCTAssertEqual(openCount, 1)
        let dismissed = await spy.dismissed
        XCTAssertEqual(dismissed, 1)
    }
```

`makeMiniPlayerViewModelForUpdateTests` is a helper to add at the top of this test file (look at how the existing tests construct the VM and reuse that pattern; pass a `NoopUpdateChecker()` by default):

```swift
    @MainActor
    private func makeMiniPlayerViewModelForUpdateTests(
        updateChecker: any UpdateChecking = NoopUpdateChecker()
    ) -> MiniPlayerViewModel {
        // Copy the constructor call from an existing test in this file (run
        // `grep -n "MiniPlayerViewModel(" Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`
        // and reuse the closest setUp/factory). Add `updateChecker: updateChecker` to
        // whichever existing init you copied. The construction must succeed without network.
        // Example shape (adjust deps to match the file):
        return MiniPlayerViewModel(
            coordinator: StubLivePlaybackCoordinator(),
            albumArtCache: NoopAlbumArtCache(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            updateChecker: updateChecker
        )
    }
```

When implementing the helper, find an existing VM construction in this file (use `grep "MiniPlayerViewModel(" Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`) and replicate, adding `updateChecker: updateChecker`.

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter MiniPlayerViewModelTests`
Expected: FAIL — `MiniPlayerViewModel` has no `updateButtonVisible`.

- [ ] **Step 3: Add to `MiniPlayerViewModel`**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`:

(a) Add stored dep:

```swift
    private let updateChecker: any UpdateChecking
```

Add to init signature with a default:

```swift
        updateChecker: any UpdateChecking = NoopUpdateChecker(),
```

Assign in init.

(b) Add published props:

```swift
    @Published public var updateButtonVisible: Bool = false
    @Published public var updateAvailableForMenu: ReleaseInfo?
    public var openUpdatePanel: @MainActor () -> Void = {}
```

(c) Add the apply method + request method:

```swift
    public func applyUpdateState(_ state: UpdateState) {
        switch state {
        case .unknown, .upToDate:
            updateButtonVisible = false
            updateAvailableForMenu = nil
        case .available(let info, let dismissedFromButton):
            updateButtonVisible = !dismissedFromButton
            updateAvailableForMenu = info
        }
    }

    public func requestOpenUpdatePanel() async {
        openUpdatePanel()
        await updateChecker.dismissCurrentForButton()
    }
```

(d) In the existing `start()` (or whatever method spawns subscription tasks — pattern: there's already a `start()` method per CLAUDE.md), add:

```swift
        Task { [weak self, updateChecker] in
            guard let self else { return }
            for await state in await updateChecker.stateUpdates {
                await MainActor.run { self.applyUpdateState(state) }
            }
        }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter MiniPlayerViewModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift \
        Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift
git commit -m "feat: MiniPlayerViewModel — updateButtonVisible, menu binding, openUpdatePanel"
```

---

### Task 12: MiniPlayerView — popover button + hamburger menu item

**Files:**

- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 1: Locate the channel row HStack**

Find the line that renders `Text("RP Player")` (per CLAUDE.md, it's in the trailing HStack of the `channelRow` ZStack overlay).

- [ ] **Step 2: Replace with conditional update button**

```swift
            // Replace `Text("RP Player")` (and only that — keep the surrounding HStack):
            if viewModel.updateButtonVisible {
                Button {
                    Task { await viewModel.requestOpenUpdatePanel() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Update Available")
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .font(.callout)  // match the existing "RP Player" font
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.secondary.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Text("RP Player")
                    .font(.callout)  // ensure font matches the existing line; preserve whatever the current line uses
            }
```

If the existing `Text("RP Player")` uses a different font modifier or has additional styling, copy that exact styling onto the `else` branch and the button label so the visual size stays identical.

- [ ] **Step 3: Add the hamburger menu item**

Locate the existing `Menu` for the hamburger (`line.3.horizontal` icon). Inside the second `Section` (the one currently containing `About RP Player`), add — between About and the third Section's `Quit RP Player`:

```swift
                if viewModel.updateAvailableForMenu != nil {
                    Button("Update Available…") {
                        Task { await viewModel.requestOpenUpdatePanel() }
                    }
                }
```

If the existing structure has `Quit` in its own Section, add a third intermediate Section above the Quit one:

```swift
                if let _ = viewModel.updateAvailableForMenu {
                    Section {
                        Button("Update Available…") {
                            Task { await viewModel.requestOpenUpdatePanel() }
                        }
                    }
                }
```

Inspect the actual `Menu { Section { ... } Section { ... } Section { ... } }` shape and pick whichever branch fits.

- [ ] **Step 4: Build + smoke-launch**

Run: `swift build` then `scripts/local-build-copy-open.sh` (or `swift run RPPlayer` for unbundled).

Expected: with `updateCheckEnabled = true` and a release available on GitHub, the popover shows the Update Available button instead of "RP Player". Clicking opens the update panel (panel itself is in the next task; for now confirm the closure fires by checking logs / placing a `print`).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat: popover — Update Available button + hamburger menu item"
```

---

### Task 13: UpdatePanelView — SwiftUI panel content

**Files:**

- Create: `Sources/RPPlayer/Shell/UpdatePanelView.swift`

- [ ] **Step 1: Implement the view**

```swift
// Sources/RPPlayer/Shell/UpdatePanelView.swift
import SwiftUI

public struct UpdatePanelView: View {
    public let release: ReleaseInfo
    public let onDownloadDmg: (URL) -> Void
    public let onViewFullNotes: (URL) -> Void
    public let onLater: () -> Void

    public init(
        release: ReleaseInfo,
        onDownloadDmg: @escaping (URL) -> Void,
        onViewFullNotes: @escaping (URL) -> Void,
        onLater: @escaping () -> Void
    ) {
        self.release = release
        self.onDownloadDmg = onDownloadDmg
        self.onViewFullNotes = onViewFullNotes
        self.onLater = onLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RP Player \(release.tagName) available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Released \(relativeDate)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Text(truncatedNotes)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("You can come back to this from the menu → Update Available.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Later", action: onLater)
                Spacer()
                Button("View Full Notes") { onViewFullNotes(release.htmlUrl) }
                if let dmg = release.dmgAssetUrl {
                    Button("Download DMG") { onDownloadDmg(dmg) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: release.publishedAt, relativeTo: Date())
    }

    private var truncatedNotes: AttributedString {
        let lines = release.body.split(separator: "\n", maxSplits: 6, omittingEmptySubsequences: false)
        let head = lines.prefix(5).joined(separator: "\n")
        let didTruncate = release.body.contains("\n") && lines.count > 5
        let display = didTruncate ? head + "\n…" : head
        if let attributed = try? AttributedString(markdown: display) {
            return attributed
        }
        return AttributedString(display)
    }
}
```

- [ ] **Step 2: Build to confirm**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/UpdatePanelView.swift
git commit -m "feat: add UpdatePanelView (release notes panel SwiftUI content)"
```

---

### Task 14: UpdatePanelController — NSPanel host

**Files:**

- Create: `Sources/RPPlayer/Shell/UpdatePanelController.swift`

- [ ] **Step 1: Implement the controller**

```swift
// Sources/RPPlayer/Shell/UpdatePanelController.swift
import AppKit
import SwiftUI

@MainActor
public final class UpdatePanelController: NSObject {
    private var panel: NSPanel?
    private var hosting: NSHostingView<UpdatePanelView>?
    private var localKeyMonitor: Any?

    public override init() {
        super.init()
    }

    public func show(release: ReleaseInfo) {
        if panel == nil {
            buildPanel(release: release)
        } else {
            replaceContent(release: release)
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    public func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    private func buildPanel(release: ReleaseInfo) {
        let view = UpdatePanelView(
            release: release,
            onDownloadDmg: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onViewFullNotes: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onLater: { [weak self] in
                self?.close()
            }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = host

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = "Update Available"
        p.isFloatingPanel = true
        p.level = .floating
        p.contentView = host
        self.panel = p
    }

    private func replaceContent(release: ReleaseInfo) {
        guard let hosting else { return }
        hosting.rootView = UpdatePanelView(
            release: release,
            onDownloadDmg: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onViewFullNotes: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onLater: { [weak self] in
                self?.close()
            }
        )
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc keycode = 53.
            if event.keyCode == 53, event.window === self?.panel {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    deinit {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Shell/UpdatePanelController.swift
git commit -m "feat: UpdatePanelController — NSPanel host with Esc dismissal"
```

---

### Task 15: AppDelegate — construct panel + late-bind closure

**Files:**

- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`

- [ ] **Step 1: Add stored property**

```swift
    private let updatePanelController = UpdatePanelController()
```

(or wherever `@MainActor` properties of similar shape live — match existing style; the past-song equivalent is already there).

- [ ] **Step 2: Late-bind the closure on `MiniPlayerViewModel`**

Find the place where `MiniPlayerViewModel.showPopoverIfNeeded` is wired (CLAUDE.md mentions this exists). Right next to it, add:

```swift
        miniPlayerViewModel.openUpdatePanel = { [weak self] in
            guard let self else { return }
            guard let info = self.miniPlayerViewModel.updateAvailableForMenu else { return }
            self.updatePanelController.show(release: info)
        }
```

- [ ] **Step 3: Build + smoke-launch**

Run: `swift build && scripts/local-build-copy-open.sh` (or whatever launches the bundled app — refer to `make-app.sh`).

Smoke-test (manual, with the bundled app running and a real release available on GitHub):

1. Wait for startup check to fire (or invoke Settings → Check Now).
2. Confirm the popover shows the Update Available button.
3. Click it → panel opens with title, body preview, three buttons.
4. Click `Later` → panel closes; popover button reverts to "RP Player"; menu item still shows "Update Available…".
5. Re-open via menu → panel reopens.
6. Click `Download DMG` → browser opens to the dmg URL.
7. Click `View Full Notes` → browser opens to the GitHub release page.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/AppDelegate.swift
git commit -m "feat: AppDelegate — late-bind openUpdatePanel + hold UpdatePanelController"
```

---

### Task 16: Manual integration smoke + CLAUDE.md update

**Files:**

- Modify: `CLAUDE.md`

- [ ] **Step 1: Update test count**

In `CLAUDE.md`'s "Test counts by PR" section, append a line like:

```text
- After PR 29 Update checker — `UpdateChecker` actor + `SemVer` + `ReleaseInfo` + `GitHubRelease` decode + `UpdateState` stream + GitHub releases poll (startup + 24h tick); Settings: Updates section (toggle, Check Now, last-checked + version status); MiniPlayer: Update Available button (replaces "RP Player" until clicked, sticky-resets on higher version) + hamburger menu item (sticky until version match); UpdatePanelController + UpdatePanelView with Download DMG / View Full Notes / Later; `AppSettings.updateCheckEnabled` (default true) + `lastUpdateCheckAt` + `dismissedUpdateVersion` + `cachedLatestRelease`; `NoopUpdateChecker` injected in unbundled `swift run`: <new count>
```

Replace `<new count>` with `swift test 2>&1 | tail -3`'s reported number.

- [ ] **Step 2: Add to "Current state" + "PR status" tables**

In the PR status table at the top of `CLAUDE.md`, add the PR 29 row.

In "Current state", update the "Last merged" line (after PR 29 ships) — leave as a note that this entry needs updating once merged.

- [ ] **Step 3: Run full test suite**

Run: `swift test`
Expected: all tests pass; new count > 384.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — update test count + PR 29 entry for update checker"
```

---

## Self-review notes (for the executing engineer)

- All paths above use the actual repo layout — `AppSettings` lives in `Sources/RPPlayer/Config/`, not `Sources/RPPlayer/Settings/` (the spec's filename was misleading; the plan corrects it).
- `StubURLProtocol.registerError` may not yet exist; Task 5 includes a brief check + add. If it does exist, skip the addition.
- `Task.sleep` for the 24h ticker is intentionally not under test — the deterministic coverage is on `tickIfDue()`.
- The `AppLogger.shared.debug` calls in `UpdateChecker` use the existing logger; if the project's logger API uses a different signature (e.g. `AppLogger.shared.log(.debug, "msg")`), adapt to whatever is in `Sources/RPPlayer/Logging/` — don't invent.
- Tests for the popover button styling (outline + SF Symbol) are visual; not adding XCTest coverage. Smoke-test manually per Task 15.
- After each task: `swift test` must pass before committing.
