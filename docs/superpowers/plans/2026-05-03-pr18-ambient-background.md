# PR 18 — Ambient Background from Album Art — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in setting that paints the popover panel with a vertical color gradient derived from the current album art's bottom edge, fading to the system `windowBackgroundColor`.

**Architecture:** A new `AmbientPaletteExtractor` actor extracts the average color of the bottom strip of an `NSImage`. `MiniPlayerViewModel` consumes the extractor and the config store; on each successful art load it publishes an `ambientTopColor`, with sticky retention during track-art-load, and reset on promo blocks (`songId == "0"`), engine errors, or ambient toggle OFF. `MiniPlayerView` renders a 2-stop `LinearGradient` background (`ambientTopColor → windowBackgroundColor`) animated with a 0.4s `easeInOut`. Setting lives in the existing `appearanceSection` of `SettingsView`, default OFF.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSImage`, `CGImage`, `CGContext`), XCTest, SPM.

**Branch:** `claude/pr18-ambient-background` off `main`.

**Spec:** `docs/superpowers/specs/2026-05-03-pr18-ambient-background-design.md`

---

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift` | **New.** Protocol `AmbientPaletteExtracting`, `Sendable` value type `ExtractedColor`, concrete `AmbientPaletteExtractor` actor that samples the bottom-edge strip of an `NSImage` and returns its average color. |
| `Sources/RPPlayer/Config/AppSettings.swift` | **Modify.** Add `ambientBackgroundEnabled: Bool` (default `false`). |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | **Modify.** Add `ambientBackgroundEnabled` published property, `setAmbientBackgroundEnabled(_:)`, hydrate from config stream. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | **Modify.** Add a `Toggle` to `appearanceSection`. |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | **Modify.** New required init params `configStore: any ConfigStore` and `paletteExtractor: any AmbientPaletteExtracting`. Add `@Published ambientTopColor: Color?`, `@Published ambientEnabled: Bool`. Subscribe to settings stream. After art loads, kick off extraction and publish color (guarded by `lastLoadedCoverPath` for staleness). Clear on promo / error / disable. |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift` | **Modify.** Apply `.background(ambientBackground)` + `.animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)` to the outer `VStack`. |
| `Sources/RPPlayer/App/AppContainer.swift` | **Modify.** Instantiate `AmbientPaletteExtractor()` in `live()`. Thread `paletteExtractor` and the existing `store` into `MiniPlayerViewModel.init`. Add `NoopAmbientPaletteExtractor` to the private fallbacks. Update tests' construction sites if any directly call this init. |
| `Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift` | **New.** 4 tests over in-memory bitmap fixtures. |
| `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift` | **New.** 6 tests covering state transitions. |
| `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift` | **Modify.** Add `StubAmbientPaletteExtractor`. |
| `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift` | **Modify.** Update all `MiniPlayerViewModel.init` call sites to pass new `configStore` and `paletteExtractor` params (using stubs). |
| `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` | **Modify.** Add 2 tests for ambient toggle. |
| `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` | **Modify.** Add 2 tests for round-trip + missing-key default. |
| `CLAUDE.md` | **Modify.** Bump PR list, test count, add ambient-background notes. |

---

## Task 1: AmbientPaletteExtractor — value type, protocol, actor

**Files:**
- Create: `Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift`
- Test: `Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift`

- [ ] **Step 1.1: Write failing tests**

Create `Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift`:

```swift
import AppKit
import XCTest
@testable import RPPlayer

final class AmbientPaletteExtractorTests: XCTestCase {
    private let sut = AmbientPaletteExtractor()

    func testExtractsAverageOfBottomStripFromSolidRedImage() async throws {
        let image = makeSolidColorImage(red: 1.0, green: 0.0, blue: 0.0, size: 100)
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(color.green, 0.0, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.05)
    }

    func testSamplesBottomStripNotWholeImage() async throws {
        // Top half blue, bottom half red. Bottom-edge sample must be red.
        let image = makeTwoBandImage(
            topRed: 0.0, topGreen: 0.0, topBlue: 1.0,
            bottomRed: 1.0, bottomGreen: 0.0, bottomBlue: 0.0,
            size: 100
        )
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 1.0, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.05)
    }

    func testExtractsMidGrayFromSolidGrayImage() async throws {
        let image = makeSolidColorImage(red: 0.5, green: 0.5, blue: 0.5, size: 60)
        let result = await sut.extractBottomEdgeColor(from: image)
        let color = try XCTUnwrap(result)
        XCTAssertEqual(color.red, 0.5, accuracy: 0.05)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.05)
        XCTAssertEqual(color.blue, 0.5, accuracy: 0.05)
    }

    func testReturnsNilForEmptyImage() async {
        let empty = NSImage(size: .zero)
        let result = await sut.extractBottomEdgeColor(from: empty)
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func makeSolidColorImage(red: CGFloat, green: CGFloat, blue: CGFloat, size: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        let color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    private func makeTwoBandImage(
        topRed: CGFloat, topGreen: CGFloat, topBlue: CGFloat,
        bottomRed: CGFloat, bottomGreen: CGFloat, bottomBlue: CGFloat,
        size: Int
    ) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // NSGraphicsContext origin is bottom-left. "Top" half draws at upper y range.
        let half = CGFloat(size) / 2.0
        NSColor(srgbRed: topRed, green: topGreen, blue: topBlue, alpha: 1.0).setFill()
        NSRect(x: 0, y: half, width: CGFloat(size), height: half).fill()
        NSColor(srgbRed: bottomRed, green: bottomGreen, blue: bottomBlue, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(size), height: half).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

Run: `swift test --filter AmbientPaletteExtractorTests`

Expected: build fails — `AmbientPaletteExtractor` and `ExtractedColor` undefined.

- [ ] **Step 1.3: Implement AmbientPaletteExtractor**

Create `Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift`:

```swift
import AppKit
import CoreGraphics
import SwiftUI

protocol AmbientPaletteExtracting: Sendable {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor?
}

struct ExtractedColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

actor AmbientPaletteExtractor: AmbientPaletteExtracting {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let height = cgImage.height
        let width = cgImage.width
        guard width > 0, height > 0 else { return nil }
        let stripHeight = max(1, height / 20)
        let stripRect = CGRect(x: 0, y: height - stripHeight, width: width, height: stripHeight)
        guard let strip = cgImage.cropping(to: stripRect) else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &bitmap,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return ExtractedColor(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

Run: `swift test --filter AmbientPaletteExtractorTests`

Expected: 4 tests pass.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift
git commit -m "feat(ui): add AmbientPaletteExtractor for album-art bottom-edge color sampling"
```

---

## Task 2: AppSettings.ambientBackgroundEnabled

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Test: `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`

- [ ] **Step 2.1: Write failing tests**

Append to `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`:

```swift
    func testRoundTripPreservesAmbientBackgroundEnabled() throws {
        var settings = AppSettings.default
        settings.ambientBackgroundEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.ambientBackgroundEnabled)
    }

    func testMissingAmbientBackgroundEnabledKeyDecodesAsFalse() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.ambientBackgroundEnabled)
    }
```

- [ ] **Step 2.2: Run tests to verify they fail**

Run: `swift test --filter AppSettingsCodableTests`

Expected: build fails — `ambientBackgroundEnabled` undefined.

- [ ] **Step 2.3: Add field to AppSettings**

In `Sources/RPPlayer/Config/AppSettings.swift`:

Add stored property after `appearance` (between `appearance` and `bitrate`):

```swift
    public var ambientBackgroundEnabled: Bool
```

Update `init(...)` parameter list, default-arg, and assignment. Final `init` should be:

```swift
    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        ambientBackgroundEnabled: Bool = false,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false,
        playerId: String? = nil
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.ambientBackgroundEnabled = ambientBackgroundEnabled
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
        self.playerId = playerId
    }
```

Update `init(from decoder:)` — add this line after the `appearance` line:

```swift
        self.ambientBackgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? false
```

- [ ] **Step 2.4: Run tests to verify all pass**

Run: `swift test --filter AppSettingsCodableTests`

Expected: 7 tests pass (5 existing + 2 new).

- [ ] **Step 2.5: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift
git commit -m "feat(config): add ambientBackgroundEnabled setting (default false)"
```

---

## Task 3: SettingsViewModel — ambient toggle wiring

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

- [ ] **Step 3.1: Write failing tests**

Append to `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` (just before the closing `}`):

```swift
    func testAmbientBackgroundEnabledDefaultsToFalse() async {
        let store = StubConfigStore(initial: .default)
        let catalog = StubAudioDeviceCatalog(initial: [])
        let auth = StubKeychainAuth()
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: catalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        XCTAssertFalse(sut.ambientBackgroundEnabled)
    }

    func testSetAmbientBackgroundEnabledPersistsAndUpdatesViewModel() async throws {
        let store = StubConfigStore(initial: .default)
        let catalog = StubAudioDeviceCatalog(initial: [])
        let auth = StubKeychainAuth()
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: catalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await sut.start()
        await sut.setAmbientBackgroundEnabled(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(sut.ambientBackgroundEnabled)
        XCTAssertTrue(store.current.ambientBackgroundEnabled)
        await sut.stop()
    }
```

- [ ] **Step 3.2: Run tests to verify they fail**

Run: `swift test --filter SettingsViewModelTests`

Expected: build fails — `ambientBackgroundEnabled` and `setAmbientBackgroundEnabled` undefined on `SettingsViewModel`.

- [ ] **Step 3.3: Add property + setter to SettingsViewModel**

In `Sources/RPPlayer/Shell/SettingsViewModel.swift`:

Add `@Published` after `appearance`:

```swift
    @Published private(set) var ambientBackgroundEnabled: Bool
```

In `init(...)`, after `self.appearance = snapshot.appearance`:

```swift
        self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
```

Inside `start()`'s config-stream consumer (the `await MainActor.run {...}` block), append after the `self.appearance = snapshot.appearance` line:

```swift
                    self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
```

After the existing `setAppearance(_:)` method, add:

```swift
    func setAmbientBackgroundEnabled(_ value: Bool) async {
        await update { $0.ambientBackgroundEnabled = value }
    }
```

- [ ] **Step 3.4: Run tests to verify they pass**

Run: `swift test --filter SettingsViewModelTests`

Expected: all pass (existing + 2 new).

- [ ] **Step 3.5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(settings-vm): expose ambientBackgroundEnabled toggle"
```

---

## Task 4: SettingsView — ambient toggle UI

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

- [ ] **Step 4.1: Add Toggle and binding**

In `Sources/RPPlayer/Shell/SettingsView.swift`:

Replace the `appearanceSection` body so it contains the picker AND a new toggle:

```swift
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: appearanceBinding) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.menu)
            Toggle("Ambient background from album art", isOn: ambientBackgroundBinding)
        }
    }
```

Below the existing `appearanceBinding` computed property, add:

```swift
    private var ambientBackgroundBinding: Binding<Bool> {
        Binding(
            get: { viewModel.ambientBackgroundEnabled },
            set: { newValue in Task { await viewModel.setAmbientBackgroundEnabled(newValue) } }
        )
    }
```

- [ ] **Step 4.2: Build + run smoke tests**

Run: `swift test --filter SettingsViewTests`

Expected: existing render-without-crash test passes (the structural change adds a `Toggle` row to an existing `Section`, no separate test needed).

- [ ] **Step 4.3: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(settings-ui): add ambient background toggle in Appearance section"
```

---

## Task 5: MiniPlayerViewModel — ambient state machine

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift`
- Modify: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`
- Create: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift`

This is the largest task. It changes the VM's init signature, so existing tests must be updated alongside the impl. Order: (a) update stub file with `StubAmbientPaletteExtractor`, (b) update existing tests to pass new params (use stubs that don't change behavior), (c) write new failing tests for ambient behavior, (d) implement, (e) run all.

- [ ] **Step 5.1: Add StubAmbientPaletteExtractor to test stubs**

In `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift`, append:

```swift
@MainActor
final class StubAmbientPaletteExtractor: AmbientPaletteExtracting {
    var nextResult: ExtractedColor?
    var calls: [NSImage] = []

    init(nextResult: ExtractedColor? = nil) {
        self.nextResult = nextResult
    }

    nonisolated func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor? {
        await MainActor.run {
            calls.append(image)
            return nextResult
        }
    }
}
```

- [ ] **Step 5.2: Update existing MiniPlayerViewModelTests construction sites**

In `Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`, every place that constructs `MiniPlayerViewModel(...)` must pass `configStore:` and `paletteExtractor:`. This applies to:

- The `setUp` block (line ~18).
- The local model constructed in `testSelectChannelInvokesPersistenceClosureOnSuccess` (line ~101).
- The local model in `testCurrentArtLoadsFromCacheOnNowPlayingUpdate` (line ~137).
- The local model in `testCurrentArtClearsWhenNowPlayingHasNoCover` (line ~155).
- The reassignment in `testCurrentArtClearsImmediatelyOnNowPlayingChange` (line ~239).
- The reassignment in `testCurrentArtPersistsWhenOnlyBitrateChanges` (line ~272).
- The reassignment in `testCurrentArtReloadsWhenCoverPathChanges` (line ~303).

For each call site, add the two new arguments. Concrete edits:

`setUp`:

```swift
    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        auth = StubKeychainAuth()
        openSettingsCalls = 0
        sut = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: auth,
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: { [unowned self] in self.openSettingsCalls += 1 }
        )
    }
```

`testSelectChannelInvokesPersistenceClosureOnSuccess` — replace the `MiniPlayerViewModel(...)` block with:

```swift
        let model = MiniPlayerViewModel(
            coordinator: coord,
            api: api,
            initialChannelId: 0,
            albumArtCache: StubAlbumArtCache(),
            auth: StubKeychainAuth(),
            configStore: StubConfigStore(initial: .default),
            paletteExtractor: StubAmbientPaletteExtractor(),
            openSettings: { },
            persistChannelId: { id in await capture.record(id) }
        )
```

For all other sites, follow the same pattern: insert `configStore: StubConfigStore(initial: .default), paletteExtractor: StubAmbientPaletteExtractor(),` between `auth:` and `openSettings:`.

- [ ] **Step 5.3: Run existing tests to verify they fail at compile time**

Run: `swift test --filter MiniPlayerViewModelTests`

Expected: build fails — `MiniPlayerViewModel.init` does not yet accept `configStore` or `paletteExtractor`.

- [ ] **Step 5.4: Write new ambient-behavior tests**

Create `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewModelAmbientTests: XCTestCase {
    private var coordinator: MockPlaybackCoordinator!
    private var api: MockRpApiClient!
    private var auth: StubKeychainAuth!
    private var cache: StubAlbumArtCache!
    private var extractor: StubAmbientPaletteExtractor!
    private var store: StubConfigStore!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        api = MockRpApiClient()
        auth = StubKeychainAuth()
        cache = StubAlbumArtCache()
        extractor = StubAmbientPaletteExtractor()
        var initial = AppSettings.default
        initial.ambientBackgroundEnabled = true
        store = StubConfigStore(initial: initial)
    }

    private func makeSUT(ambientEnabled: Bool = true) -> MiniPlayerViewModel {
        var initial = AppSettings.default
        initial.ambientBackgroundEnabled = ambientEnabled
        store = StubConfigStore(initial: initial)
        return MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: auth,
            configStore: store,
            paletteExtractor: extractor,
            openSettings: { }
        )
    }

    func testAmbientTopColorRemainsNilWhenAmbientDisabled() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT(ambientEnabled: false)
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(sut.ambientTopColor)
        await sut.stop()
    }

    func testAmbientTopColorPublishedAfterArtLoadsWhenEnabled() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)
        await sut.stop()
    }

    func testAmbientTopColorClearedOnPromoBlock() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        await coordinator.setNowPlaying(NowPlaying.fixture(cover: nil, songId: "0"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "promo block (songId == 0) must clear ambient color")
        await sut.stop()
    }

    func testAmbientTopColorStickyDuringTrackChangeArtLoad() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        cache.imageByPath["covers/l/b.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        let firstColor = sut.ambientTopColor
        XCTAssertNotNil(firstColor)

        // New nowPlaying arrives. currentArt momentarily clears (existing VM
        // behavior). Ambient color must NOT clear here — it should persist
        // until the new art loads.
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/b.jpg", songId: "2"))
        // Sample IMMEDIATELY before extraction completes.
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(sut.ambientTopColor, firstColor, "ambient color must remain sticky during track-art-load")

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor, "ambient color should be set once new art loads")
        await sut.stop()
    }

    func testAmbientTopColorClearedOnEngineError() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        await coordinator.errorsContinuation.yield("Audio device lost")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "engine error must clear ambient color")
        await sut.stop()
    }

    func testAmbientTopColorClearedWhenAmbientDisabledMidPlayback() async throws {
        cache.imageByPath["covers/l/a.jpg"] = NSImage(size: NSSize(width: 4, height: 4))
        extractor.nextResult = ExtractedColor(red: 0.9, green: 0.1, blue: 0.1)
        let sut = makeSUT()
        await sut.start()
        await coordinator.setNowPlaying(NowPlaying.fixture(cover: "covers/l/a.jpg", songId: "1"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNotNil(sut.ambientTopColor)

        try await store.update { $0.ambientBackgroundEnabled = false }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sut.ambientTopColor, "disabling ambient must clear current color")
        await sut.stop()
    }
}
```

- [ ] **Step 5.5: Run new tests to verify they fail**

Run: `swift test --filter MiniPlayerViewModelAmbientTests`

Expected: build fails — `ambientTopColor` undefined on `MiniPlayerViewModel`.

- [ ] **Step 5.6: Implement state machine in MiniPlayerViewModel**

In `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`:

Add `import SwiftUI` at the top alongside the existing imports.

Add new published properties after the existing ones (just below `songDurationSeconds`):

```swift
    @Published private(set) var ambientTopColor: Color?
    @Published private(set) var ambientEnabled: Bool = false
```

Add new stored properties (next to `private var lastLoadedCoverPath: String?`):

```swift
    private let configStore: any ConfigStore
    private let paletteExtractor: any AmbientPaletteExtracting
    private var settingsSubscriptionTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
```

Update `init(...)` signature — insert two new required params between `auth:` and `openSettings:`:

```swift
    init(
        coordinator: any PlaybackCoordinator,
        api: any RpApiClient,
        initialChannelId: Int,
        albumArtCache: any AlbumArtCache,
        auth: any KeychainAuth,
        configStore: any ConfigStore,
        paletteExtractor: any AmbientPaletteExtracting,
        openSettings: @escaping @MainActor () -> Void,
        persistChannelId: @escaping PersistChannelId = { _ in }
    ) {
        self.coordinator = coordinator
        self.api = api
        self.albumArtCache = albumArtCache
        self.auth = auth
        self.configStore = configStore
        self.paletteExtractor = paletteExtractor
        self.openSettingsAction = openSettings
        self.selectedChannelId = initialChannelId
        self.persistChannelId = persistChannelId
    }
```

In `start()`, at the very beginning (just after the existing cancellation block of `errorsSubscriptionTask`), add cancellation of the new tasks:

```swift
        settingsSubscriptionTask?.cancel()
        settingsSubscriptionTask = nil
        paletteTask?.cancel()
        paletteTask = nil
```

At the end of `start()` (after the existing errors-stream subscription), append a settings subscription:

```swift
        let settingsStream = await configStore.changes
        settingsSubscriptionTask = Task { [weak self] in
            for await snapshot in settingsStream {
                guard let self else { return }
                await MainActor.run {
                    let wasEnabled = self.ambientEnabled
                    self.ambientEnabled = snapshot.ambientBackgroundEnabled
                    if wasEnabled, !snapshot.ambientBackgroundEnabled {
                        self.ambientTopColor = nil
                    }
                }
            }
        }
```

In `stop()`, append cancellation:

```swift
        settingsSubscriptionTask?.cancel(); settingsSubscriptionTask = nil
        paletteTask?.cancel(); paletteTask = nil
```

In the existing `nowPlayingUpdates` consumer, locate the `MainActor.run` closure that sets state. Inside it, immediately after the line that assigns `self.nowPlaying = np`, branch on promo to clear the ambient color (without disturbing other behavior). Replace the existing closure body so it returns BOTH a `coverChanged` bool AND clears ambient color when promo. Concrete final form of that closure:

```swift
                let coverChanged = await MainActor.run { () -> Bool in
                    self.nowPlaying = np
                    self.isPlaying = true
                    self.isSignedIn = self.auth.isLoggedIn
                    self.currentRating = Self.parseRating(from: np.song.userRating)
                    self.currentBitrateLabel = BlockBitrateLabel.display(np.blockBitrate)
                    let newDuration = max(0, np.songEndSeconds - np.songStartSeconds)
                    if np.songStartSeconds != self.lastSongStartSeconds {
                        self.lastSongStartSeconds = np.songStartSeconds
                        self.songElapsedSeconds = 0
                        self.songDurationSeconds = newDuration
                    } else {
                        self.songDurationSeconds = newDuration
                    }
                    if np.song.songId == "0" {
                        self.ambientTopColor = nil
                    }
                    let newCover = np.song.cover
                    if newCover != self.lastLoadedCoverPath {
                        self.lastLoadedCoverPath = newCover
                        self.currentArt = nil
                        return true
                    }
                    return false
                }
```

Replace the existing `loadArt(for:)` method body to also kick off palette extraction after a successful art load:

```swift
    private func loadArt(for np: NowPlaying) async {
        guard let cover = np.song.cover else {
            await MainActor.run { self.currentArt = nil }
            return
        }
        let image = await albumArtCache.image(for: cover)
        await MainActor.run {
            self.currentArt = image
        }
        guard let image, ambientEnabled else { return }
        // Stale-guard: if user has skipped to a different cover by the time
        // extraction completes, drop the result.
        let coverAtKickoff = cover
        paletteTask?.cancel()
        paletteTask = Task { [weak self, paletteExtractor] in
            let extracted = await paletteExtractor.extractBottomEdgeColor(from: image)
            guard let self else { return }
            await MainActor.run {
                guard self.lastLoadedCoverPath == coverAtKickoff else { return }
                self.ambientTopColor = extracted?.swiftUIColor
            }
        }
    }
```

In the errors-stream subscription, immediately after `self.nowPlaying = nil`, append:

```swift
                self.ambientTopColor = nil
```

So the final errors block is:

```swift
        let errorsStream = await coordinator.errors
        errorsSubscriptionTask = Task { [weak self] in
            for await message in errorsStream {
                guard let self else { return }
                self.errorMessage = message
                self.isPlaying = false
                self.nowPlaying = nil
                self.ambientTopColor = nil
                self.showPopoverIfNeeded()
            }
        }
```

- [ ] **Step 5.7: Run all tests to verify they pass**

Run: `swift test`

Expected: full test suite green, including the 6 new ambient tests and all existing MiniPlayerViewModel tests.

If any of the existing 25-ish MiniPlayerViewModel tests fail because of timing (the new `paletteTask` is async and a test was racing it), bump that test's `Task.sleep` window or adjust assertions. Do not weaken state guards.

- [ ] **Step 5.8: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift Tests/RPPlayerTests/Shell/SettingsTestStubs.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift
git commit -m "feat(mini-player-vm): publish ambientTopColor with sticky+promo+error+toggle handling"
```

---

## Task 6: MiniPlayerView — gradient layer

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 6.1: Apply gradient background and animation**

In `Sources/RPPlayer/Shell/MiniPlayerView.swift`:

Update the outer `body` so the `VStack(spacing: 0)` carries the gradient and animation. Final form:

```swift
    var body: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 318)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            albumArt
            VStack(spacing: 12) {
                titleRow
                progressRow
                transport
                channelRow
            }
            .padding(12)
        }
        .frame(width: 342)
        .background(ambientBackground)
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .task { await viewModel.start() }
    }

    private var ambientBackground: some View {
        LinearGradient(
            colors: [
                viewModel.ambientTopColor ?? Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
```

- [ ] **Step 6.2: Run smoke tests**

Run: `swift test --filter MiniPlayerViewTests`

Expected: render-without-crash test passes.

- [ ] **Step 6.3: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat(mini-player): paint gradient background from ambientTopColor"
```

---

## Task 7: AppContainer wiring + Noop fallback

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

- [ ] **Step 7.1: Add NoopAmbientPaletteExtractor**

At the bottom of `Sources/RPPlayer/App/AppContainer.swift`, alongside the other private `Noop*` types, append:

```swift
private struct NoopAmbientPaletteExtractor: AmbientPaletteExtracting {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor? { nil }
}
```

- [ ] **Step 7.2: Construct and thread the extractor**

Inside `static func live() throws -> AppContainer`, locate the `MiniPlayerViewModel(...)` construction. Just above it, declare the extractor:

```swift
        let paletteExtractor = AmbientPaletteExtractor()
```

Replace the `MiniPlayerViewModel(...)` construction with:

```swift
        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: keychainAuth,
            configStore: store ?? NoopConfigStore(),
            paletteExtractor: paletteExtractor,
            openSettings: { [settingsWindowController] in settingsWindowController.show() },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )
```

- [ ] **Step 7.3: Build + run full suite**

Run: `swift build`

Expected: build succeeds.

Run: `swift test`

Expected: full suite green.

- [ ] **Step 7.4: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(container): wire AmbientPaletteExtractor and configStore into MiniPlayerViewModel"
```

---

## Task 8: CLAUDE.md update

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 8.1: Capture final test count**

Run: `swift test 2>&1 | tail -5`

Note the actual test count from the output line `Executed N tests, with 0 failures`. Use this number in the next step.

- [ ] **Step 8.2: Update CLAUDE.md**

In `CLAUDE.md`:

1. In the "PR status" table, change the PR 18 row from `TBD` to `Ambient background from album art (opt-in gradient, sticky during track-art-load, fade on promo/error/disable)` and mark status `✅`.
2. Update the "Last merged" line at the top of "Current state" to: `Last merged: **PR 18** — ambient background from album art. <N> tests passing on main.` (substituting actual count).
3. Update "Upcoming: **PR 19** — TBD."
4. In "Test counts by PR", append a new bullet: `- After PR 18 ambient background (palette extractor, configStore wiring in MiniPlayerViewModel, gradient layer in MiniPlayerView; <N - 272> new tests): <N>`.
5. Under "Key technical decisions (non-obvious, not in code)" → add a new subsection at the end of the existing "Shell (AppKit + SwiftUI)" section:

   ```markdown
   - **Ambient background.** Opt-in (`AppSettings.ambientBackgroundEnabled`, default false; toggle in Settings → Appearance). When ON, `MiniPlayerView` paints a vertical `LinearGradient` background: top stop = `viewModel.ambientTopColor` (extracted from album art's bottom-edge strip via `AmbientPaletteExtractor` actor; sampling rect = bottom 5% of the source CGImage drawn into a 1×1 destination via `CGContext.draw` with high interpolation). Bottom stop = `Color(nsColor: .windowBackgroundColor)` so the gradient fades into the panel's existing system-colored base. Animation: SwiftUI `.animation(.easeInOut(duration: 0.4), value: ambientTopColor)`. Sticky behavior: VM only clears `ambientTopColor` on (a) promo block (`song.songId == "0"`), (b) engine error (errors-stream subscription), or (c) ambient toggle OFF. During mid-track art loading the previous color persists until the new extraction completes. Stale-guard: extraction tasks check `lastLoadedCoverPath` before publishing — if the user skipped to a different cover, the result is dropped. `MiniPlayerViewModel.init` therefore takes both `configStore: any ConfigStore` (to subscribe to `ambientBackgroundEnabled`) and `paletteExtractor: any AmbientPaletteExtracting` (production = `AmbientPaletteExtractor()`; tests use `StubAmbientPaletteExtractor`).
   ```

- [ ] **Step 8.3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for PR 18 — ambient background"
```

---

## Manual smoke (run after Task 8)

1. `swift build` succeeds.
2. `swift test` — full suite green; ~10–12 new tests.
3. Build the .app: `./scripts/make-app.sh && open /Applications/RP\ Player.app` (or current build script).
4. Open popover. Default: looks identical to before.
5. Open Settings → Appearance. New toggle "Ambient background from album art" below the picker. Default OFF.
6. Toggle ON. Within ~0.4s of next song's art loading, popover panel below the album art picks up the bottom-edge color and fades to system background. Seam between art and gradient is invisible.
7. Skip forward. Color crossfades smoothly to next song's color.
8. Wait for a promo block (~5s talk segment between songs). Gradient fades back to plain panel during the promo.
9. Switch to Dark in Appearance picker. Gradient bottom stop now blends into dark background.
10. Toggle OFF. Gradient fades out to plain panel within 0.4s.
11. Quit and relaunch. Setting persists.

---

## Self-review notes

**Spec coverage:**
- Decision 1 (independent toggle, coexists with Appearance): Task 2 + Task 3 + Task 4. ✅
- Decision 2 (vertical 2-stop gradient): Task 6. ✅
- Decision 3 (top stop = bottom-edge color): Task 1. ✅
- Decision 4 (bottom stop = windowBackgroundColor): Task 6. ✅
- Decision 5 (0.4s easeInOut animation): Task 6. ✅
- Decision 6 (sticky during art-load; fade on promo/error/disable): Task 5. ✅
- Decision 7 (toggle in `appearanceSection`): Task 4. ✅
- Decision 8 (default OFF): Task 2. ✅
- Stale-guard via `lastLoadedCoverPath`: Task 5 (loadArt impl). ✅
- Test fixtures built in-memory: Task 1 helpers. ✅

**Type consistency:**
- `AmbientPaletteExtracting` protocol method name `extractBottomEdgeColor(from:)` used identically across Task 1 (definition), Task 5 (consumption), Task 7 (Noop), and tests.
- `ExtractedColor` shape (`red`/`green`/`blue` Doubles + `swiftUIColor`) used identically in tests and impl.
- `MiniPlayerViewModel.init` final shape: positional order `coordinator, api, initialChannelId, albumArtCache, auth, configStore, paletteExtractor, openSettings, persistChannelId` — matched in Task 5 stubs, Task 5 impl, Task 7 wiring, and all updated test sites.
- `ambientTopColor: Color?` and `ambientEnabled: Bool` published-property names consistent across Task 5 impl, Task 5 tests, and Task 6 view.

**No placeholders:** every step has concrete code, file paths, and commands.
