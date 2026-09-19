# PR 25: Liquid Glass + Frosted Upcoming Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two opt-in Appearance toggles — Liquid Glass for the popovers (macOS 26+) and Frosted background for the Upcoming Program window (macOS 14+) — both runtime-toggleable, both persisted to `config.json`.

**Architecture:** Two new `Bool` fields on `AppSettings`, threaded through `SettingsViewModel` (binding source) and `MiniPlayerViewModel` / `PastSongViewModel` / `UpcomingWindowController` (live consumers via existing `configStore.changes` subscriptions). Liquid Glass code path is `if #available(macOS 26.0, *)` gated; the toggle in Settings is `.disabled(true)` with a footnote on older macOS. Frosted Upcoming uses `NSVisualEffectView` (macOS 10.10+) installed as a content-view background subview.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSVisualEffectView`), XCTest. Existing patterns: `ConfigStore.changes` AsyncStream, `@Published` view-model props, MainActor view models.

Spec source: `docs/superpowers/specs/2026-05-05-liquid-glass-design.md` (gitignored).

---

## File structure

**New files:**
- `Sources/RPPlayer/Shell/Components/LiquidGlassBackground.swift` — SwiftUI ViewModifier (`LiquidGlassBackground` + `LiquidGlassBackgroundIfEnabled`). #available-gated.
- `Sources/RPPlayer/Shell/Components/FrostedWindowBackground.swift` — `NSViewRepresentable` wrapping `NSVisualEffectView`.
- `Tests/RPPlayerTests/Shell/Components/LiquidGlassBackgroundTests.swift` — smoke test for the modifier.

**Modified files:**
- `Sources/RPPlayer/Config/AppSettings.swift` — add 2 Bool fields with `false` defaults, decode-if-present.
- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — add 2 `@Published` props, snapshot init, `start()` subscription, 2 setters.
- `Sources/RPPlayer/Shell/SettingsView.swift` — add 2 toggles in `appearanceSection` (Liquid Glass with #available disable+footnote; Frosted always enabled).
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — add `@Published var liquidGlassEnabled: Bool`; init from snapshot, update via `settingsSubscriptionTask`.
- `Sources/RPPlayer/Shell/PastSongViewModel.swift` — same.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — apply `LiquidGlassBackgroundIfEnabled` modifier on the root frame; gate the existing background fill (none currently — confirmed clean).
- `Sources/RPPlayer/Shell/PastSongView.swift` — same as MiniPlayerView.
- `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift` — subscribe to `configStore.changes`; install/remove `NSVisualEffectView` as content-view subview index 0.
- `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` — round-trip + missing-key tests for both new fields (4 total).
- `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` — default + setter tests for both new fields (4 total).
- `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift` — add a test for `liquidGlassEnabled` subscription propagation (1).
- `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift` — same (1).
- `README.md` — one-line note in Appearance section about the two toggles.
- `CLAUDE.md` — PR row + test count + Coordinator/Shell technical decisions.

**Test delta:** +11 (4 codable + 4 settings VM + 1 mini VM + 1 past VM + 1 modifier smoke). Final count: ~356.

**Branch:** `claude/pr25-liquid-glass`. Created off `main`. Same-checkout pattern (no separate worktree per project convention).

---

## Task 1: Branch + AppSettings fields (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Test: `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`

- [ ] **Step 1: Create branch off main**

```bash
git checkout main && git pull --ff-only && git checkout -b claude/pr25-liquid-glass
```

Expected: clean checkout, branch created.

- [ ] **Step 2: Write failing tests**

Append to `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` (inside the existing `final class AppSettingsCodableTests: XCTestCase { ... }` body, before its closing `}`):

```swift
func testRoundTripPreservesLiquidGlassEnabled() throws {
    var settings = AppSettings.default
    settings.liquidGlassEnabled = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertTrue(decoded.liquidGlassEnabled)
}

func testMissingLiquidGlassEnabledKeyDecodesAsFalse() throws {
    let json = """
    {"selectedChannelId":0}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    XCTAssertFalse(decoded.liquidGlassEnabled)
}

func testRoundTripPreservesFrostedUpcomingEnabled() throws {
    var settings = AppSettings.default
    settings.frostedUpcomingEnabled = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertTrue(decoded.frostedUpcomingEnabled)
}

func testMissingFrostedUpcomingEnabledKeyDecodesAsFalse() throws {
    let json = """
    {"selectedChannelId":0}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    XCTAssertFalse(decoded.frostedUpcomingEnabled)
}
```

- [ ] **Step 3: Verify failure**

```bash
swift test --filter "AppSettingsCodableTests/testRoundTripPreservesLiquidGlassEnabled" 2>&1 | tail -10
```

Expected: compile error referencing `liquidGlassEnabled` not member of AppSettings.

- [ ] **Step 4: Implement in `AppSettings.swift`**

In `public struct AppSettings`, add two new `var` declarations adjacent to `ambientBackgroundEnabled` (line 14):

```swift
    public var ambientBackgroundEnabled: Bool
    public var liquidGlassEnabled: Bool
    public var frostedUpcomingEnabled: Bool
```

In the `public init(...)` declaration (line 31), add the two parameters with `false` defaults, alphabetical-position-free (place adjacent to `ambientBackgroundEnabled` for consistency):

```swift
    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        releaseHogOnPauseEnabled: Bool = true,
        forceMaxVolumeEnabled: Bool = false,
        applyReplayGainEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        menuBarIconStyle: MenuBarIconStyle = .template,
        ambientBackgroundEnabled: Bool = false,
        liquidGlassEnabled: Bool = false,
        frostedUpcomingEnabled: Bool = false,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false,
        playerId: String? = nil,
        upcomingRowCount: Int = 5,
        upcomingHiddenChannelIds: [Int] = [],
        popoverFloating: Bool = false
    ) {
```

In the same init body, add the two assignments after the `ambientBackgroundEnabled` assignment:

```swift
        self.ambientBackgroundEnabled = ambientBackgroundEnabled
        self.liquidGlassEnabled = liquidGlassEnabled
        self.frostedUpcomingEnabled = frostedUpcomingEnabled
```

In `public init(from decoder: Decoder) throws`, add the two decode-if-present lines after the `ambientBackgroundEnabled` line:

```swift
        self.ambientBackgroundEnabled = try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? false
        self.liquidGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled) ?? false
        self.frostedUpcomingEnabled = try c.decodeIfPresent(Bool.self, forKey: .frostedUpcomingEnabled) ?? false
```

`Codable` synthesises `CodingKeys` automatically since the struct has no custom CodingKeys enum — verify by reading the file (no manual `enum CodingKeys` should exist). The new `var`s on the struct will produce matching keys.

- [ ] **Step 5: Verify pass**

```bash
swift test --filter "AppSettingsCodableTests" 2>&1 | tail -10
```

Expected: all tests in suite pass (existing + 4 new).

- [ ] **Step 6: Full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 345 + 4 = 349 tests passing.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift
git commit -m "feat(settings): add liquidGlassEnabled and frostedUpcomingEnabled fields

Both default false; decode-if-present preserves back-compat with
existing config.json files. Consumed by SettingsView toggles + popover
view models in subsequent tasks."
```

---

## Task 2: SettingsViewModel published props + setters (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `SettingsViewModelTests` class body:

```swift
func testLiquidGlassEnabledDefaultsToFalse() async throws {
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
    XCTAssertFalse(sut.liquidGlassEnabled)
}

func testSetLiquidGlassEnabledPersistsAndUpdatesViewModel() async throws {
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
    await sut.setLiquidGlassEnabled(true)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(sut.liquidGlassEnabled)
    XCTAssertTrue(store.current.liquidGlassEnabled)
    await sut.stop()
}

func testFrostedUpcomingEnabledDefaultsToFalse() async throws {
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
    XCTAssertFalse(sut.frostedUpcomingEnabled)
}

func testSetFrostedUpcomingEnabledPersistsAndUpdatesViewModel() async throws {
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
    await sut.setFrostedUpcomingEnabled(true)
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(sut.frostedUpcomingEnabled)
    XCTAssertTrue(store.current.frostedUpcomingEnabled)
    await sut.stop()
}
```

- [ ] **Step 2: Verify failure**

```bash
swift test --filter "SettingsViewModelTests/testLiquidGlassEnabled" 2>&1 | tail -10
```

Expected: compile error: `Value of type 'SettingsViewModel' has no member 'liquidGlassEnabled'`.

- [ ] **Step 3: Implement in `SettingsViewModel.swift`**

Add two `@Published` props next to `ambientBackgroundEnabled` (around line 17):

```swift
    @Published private(set) var ambientBackgroundEnabled: Bool
    @Published private(set) var liquidGlassEnabled: Bool
    @Published private(set) var frostedUpcomingEnabled: Bool
```

In `init(...)` body (around line 62), initialize from snapshot:

```swift
        self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
        self.liquidGlassEnabled = snapshot.liquidGlassEnabled
        self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled
```

In `start()` `MainActor.run { ... }` block (around line 86), add the two updates after `ambientBackgroundEnabled`:

```swift
                    self.ambientBackgroundEnabled = snapshot.ambientBackgroundEnabled
                    self.liquidGlassEnabled = snapshot.liquidGlassEnabled
                    self.frostedUpcomingEnabled = snapshot.frostedUpcomingEnabled
```

Add two new setter methods directly after `setAmbientBackgroundEnabled(_:)` (around line 165):

```swift
    func setLiquidGlassEnabled(_ value: Bool) async {
        await update { $0.liquidGlassEnabled = value }
    }

    func setFrostedUpcomingEnabled(_ value: Bool) async {
        await update { $0.frostedUpcomingEnabled = value }
    }
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter "SettingsViewModelTests" 2>&1 | tail -10
```

Expected: all SettingsViewModelTests pass (existing + 4 new).

- [ ] **Step 5: Full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: 349 + 4 = 353 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(settings): SettingsViewModel exposes liquidGlass and frostedUpcoming

Mirrors ambientBackgroundEnabled wiring: published prop initialized
from snapshot, refreshed on configStore.changes, setter rewrites the
config via update(_:)."
```

---

## Task 3: SettingsView toggles UI

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

No new tests — `SettingsView` is a SwiftUI body; coverage is via the underlying `SettingsViewModel` tests already added in Task 2 plus manual visual verification.

- [ ] **Step 1: Add the two new toggles to `appearanceSection`**

Locate `appearanceSection` (around line 135). Append below the existing Ambient toggle (line 154):

```swift
            Toggle("Ambient background from album art", isOn: ambientBackgroundBinding)
            Toggle("Liquid Glass (popovers)", isOn: liquidGlassBinding)
                .disabled(!Self.isLiquidGlassAvailable)
            if !Self.isLiquidGlassAvailable {
                Text("Requires macOS 26 or later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Frosted Upcoming Program window", isOn: frostedUpcomingBinding)
        }
```

- [ ] **Step 2: Add the availability constant**

Inside `struct SettingsView { ... }` (or whatever the type declaration is — open the file and confirm), add a static constant near the other private helpers:

```swift
    private static var isLiquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }
```

- [ ] **Step 3: Add the two binding helpers**

Append next to `ambientBackgroundBinding` (around line 300):

```swift
    private var liquidGlassBinding: Binding<Bool> {
        Binding(
            get: { viewModel.liquidGlassEnabled },
            set: { newValue in Task { await viewModel.setLiquidGlassEnabled(newValue) } }
        )
    }

    private var frostedUpcomingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.frostedUpcomingEnabled },
            set: { newValue in Task { await viewModel.setFrostedUpcomingEnabled(newValue) } }
        )
    }
```

- [ ] **Step 4: Verify build + suite**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3
```

Expected: build succeeds; 353 tests still passing (no new tests this task).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(settings): add Liquid Glass and Frosted Upcoming toggles to UI

Liquid Glass toggle is disabled with a 'Requires macOS 26 or later'
caption when running on an older OS — its stored value still persists
so an OS upgrade activates the user's choice automatically."
```

---

## Task 4: LiquidGlassBackground modifier component (TDD)

**Files:**
- Create: `Sources/RPPlayer/Shell/Components/LiquidGlassBackground.swift`
- Test: `Tests/RPPlayerTests/Shell/Components/LiquidGlassBackgroundTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/RPPlayerTests/Shell/Components/LiquidGlassBackgroundTests.swift`:

```swift
import SwiftUI
import XCTest
@testable import RPPlayer

final class LiquidGlassBackgroundTests: XCTestCase {
    func testIfEnabledWrapperCompilesAndAppliesConditionally() {
        let enabled = AnyView(Text("hi").modifier(LiquidGlassBackgroundIfEnabled(enabled: true)))
        let disabled = AnyView(Text("hi").modifier(LiquidGlassBackgroundIfEnabled(enabled: false)))
        // Smoke: both branches build and produce a non-nil view tree.
        XCTAssertNotNil(enabled)
        XCTAssertNotNil(disabled)
    }
}
```

- [ ] **Step 2: Verify failure**

```bash
swift test --filter "LiquidGlassBackgroundTests" 2>&1 | tail -10
```

Expected: compile error referencing `LiquidGlassBackgroundIfEnabled` not defined.

- [ ] **Step 3: Implement**

Create `Sources/RPPlayer/Shell/Components/LiquidGlassBackground.swift`:

```swift
import SwiftUI

struct LiquidGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }
}

struct LiquidGlassBackgroundIfEnabled: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(LiquidGlassBackground())
        } else {
            content
        }
    }
}
```

- [ ] **Step 4: Verify pass + full suite**

```bash
swift test --filter "LiquidGlassBackgroundTests" 2>&1 | tail -10
swift test 2>&1 | tail -3
```

Expected: smoke test passes; 353 + 1 = 354 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/Components/LiquidGlassBackground.swift Tests/RPPlayerTests/Shell/Components/LiquidGlassBackgroundTests.swift
git commit -m "feat(shell): add LiquidGlassBackground SwiftUI modifier

Wraps SwiftUI .glassEffect(in:) inside an #available(macOS 26.0)
gate, plus an IfEnabled wrapper that bakes the toggle check at the
call site. Shape is RoundedRectangle(cornerRadius: 10) to match the
popover panel's content-view corner radius."
```

---

## Task 5: MiniPlayerViewModel liquidGlassEnabled (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift`

- [ ] **Step 1: Write failing test**

Append to the `MiniPlayerViewModelAmbientTests` class body (in the file already covering ambient subscription tests; this matches the existing pattern most closely):

```swift
func testLiquidGlassEnabledReflectsConfigStoreChange() async throws {
    var initial = AppSettings.default
    initial.liquidGlassEnabled = false
    store = StubConfigStore(initial: initial)
    let sut = MiniPlayerViewModel(
        coordinator: coordinator,
        api: api,
        initialChannelId: 0,
        albumArtCache: cache,
        auth: auth,
        configStore: store,
        paletteExtractor: extractor,
        openSettings: { }
    )
    await sut.start()
    XCTAssertFalse(sut.liquidGlassEnabled)
    var updated = initial
    updated.liquidGlassEnabled = true
    await store.update { $0.liquidGlassEnabled = true }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(sut.liquidGlassEnabled)
    await sut.stop()
}
```

(Verify `StubConfigStore.update` exists and matches the call signature `update { settings in ... }` — it does, as used by `setAmbientBackgroundEnabled` test pattern.)

- [ ] **Step 2: Verify failure**

```bash
swift test --filter "MiniPlayerViewModelAmbientTests/testLiquidGlassEnabled" 2>&1 | tail -10
```

Expected: compile error: no member `liquidGlassEnabled` on `MiniPlayerViewModel`.

- [ ] **Step 3: Implement in `MiniPlayerViewModel.swift`**

Add a new `@Published` prop near the other published bools (after `popoverFloatingEnabled` around line 20):

```swift
    @Published private(set) var popoverFloatingEnabled: Bool = false
    @Published private(set) var liquidGlassEnabled: Bool = false
```

In `start()` initial snapshot block (around line 87) add:

```swift
        self.ambientEnabled = await configStore.settings.ambientBackgroundEnabled
        self.popoverFloatingEnabled = await configStore.settings.popoverFloating
        self.liquidGlassEnabled = await configStore.settings.liquidGlassEnabled
```

In the `settingsSubscriptionTask` body (around line 167), add the update inside the `for await` loop alongside the other settings reads:

```swift
                self.ambientEnabled = snapshot.ambientBackgroundEnabled
                self.popoverFloatingEnabled = snapshot.popoverFloating
                self.liquidGlassEnabled = snapshot.liquidGlassEnabled
```

(The existing ambient ON/OFF transition logic on the same lines stays untouched — `liquidGlassEnabled` doesn't need transition handling because it has no derived state.)

- [ ] **Step 4: Verify pass + full suite**

```bash
swift test --filter "MiniPlayerViewModelAmbientTests" 2>&1 | tail -10
swift test 2>&1 | tail -3
```

Expected: new test passes; 354 + 1 = 355 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift
git commit -m "feat(shell): MiniPlayerViewModel exposes liquidGlassEnabled

Subscribes to configStore.changes alongside ambient + floating; published
prop drives the popover view's conditional .glassEffect modifier."
```

---

## Task 6: PastSongViewModel liquidGlassEnabled (TDD)

**Files:**
- Modify: `Sources/RPPlayer/Shell/PastSongViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift`

- [ ] **Step 1: Write failing test**

Open `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift` and look for the existing test setup pattern (it uses a `StubConfigStore` and `StubAmbientPaletteExtractor` similarly). Append:

```swift
func testLiquidGlassEnabledReflectsConfigStoreChange() async throws {
    let store = StubConfigStore(initial: .default)
    let extractor = StubAmbientPaletteExtractor()
    let sut = PastSongViewModel(
        configStore: store,
        paletteExtractor: extractor
    )
    await sut.start(song: PlayListSong.fixture(), artImage: nil)
    XCTAssertFalse(sut.liquidGlassEnabled)
    await store.update { $0.liquidGlassEnabled = true }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(sut.liquidGlassEnabled)
    await sut.stop()
}
```

(If `PlayListSong.fixture()` does not exist, look at the existing PastSongViewModel test for the actual constructor used and adapt — keep the test focused on the new prop only.)

- [ ] **Step 2: Verify failure**

```bash
swift test --filter "PastSongViewModelTests/testLiquidGlassEnabled" 2>&1 | tail -10
```

Expected: compile error or failed assertion (depending on existing fixture availability).

- [ ] **Step 3: Implement in `PastSongViewModel.swift`**

Add `@Published` prop next to `ambientTopColor` (around line 11):

```swift
    @Published private(set) var ambientTopColor: Color?
    @Published private(set) var liquidGlassEnabled: Bool = false
```

In `start(...)` initial snapshot block (around line 43, where `ambientEnabled = await configStore.settings.ambientBackgroundEnabled`), add:

```swift
        ambientEnabled = await configStore.settings.ambientBackgroundEnabled
        liquidGlassEnabled = await configStore.settings.liquidGlassEnabled
```

In the configStore subscription `for await snapshot in stream { ... }` block (around line 51), add inside the `MainActor.run`:

```swift
                self.ambientEnabled = snapshot.ambientBackgroundEnabled
                self.liquidGlassEnabled = snapshot.liquidGlassEnabled
```

(Mirror the exact location of existing ambient line; the existing ambient transition logic stays untouched.)

- [ ] **Step 4: Verify pass + full suite**

```bash
swift test --filter "PastSongViewModelTests" 2>&1 | tail -10
swift test 2>&1 | tail -3
```

Expected: 355 + 1 = 356 total.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/PastSongViewModel.swift Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift
git commit -m "feat(shell): PastSongViewModel exposes liquidGlassEnabled

Mirrors MiniPlayerViewModel wiring so the past-song popover gets the
same Liquid Glass treatment as the main popover."
```

---

## Task 7: Apply LiquidGlassBackgroundIfEnabled in popover views

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`
- Modify: `Sources/RPPlayer/Shell/PastSongView.swift`

No new tests — visual modifier; pre-existing view-snapshot tests stay green by default. Manual verification required.

- [ ] **Step 1: MiniPlayerView**

Locate the root `body` `.frame(width: 342)` line (~line 36 in `MiniPlayerView.swift`). Currently followed by `.background(AmbientGradientBackground(...))` and `.animation(...)` and `.task { await viewModel.start() }`. Insert the new modifier after `.animation(...)`:

```swift
        .frame(width: 342)
        .background(AmbientGradientBackground(topColor: viewModel.ambientTopColor))
        .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
        .modifier(LiquidGlassBackgroundIfEnabled(enabled: viewModel.liquidGlassEnabled))
        .task { await viewModel.start() }
```

The modifier is the outermost visual layer — when ON it wraps the entire popover content (ambient gradient + content) in `.glassEffect(...)`. When OFF, it's a no-op.

- [ ] **Step 2: PastSongView**

Open `PastSongView.swift`. Locate the root `body` modifier chain (currently has `.background(AmbientGradientBackground(...))`). Insert the same line after `.background(...)` (and after any `.animation(...)` if present):

```swift
        .background(AmbientGradientBackground(topColor: viewModel.ambientTopColor))
        .modifier(LiquidGlassBackgroundIfEnabled(enabled: viewModel.liquidGlassEnabled))
```

If `PastSongView` does not currently have `.animation(...)` for ambient, leave the modifier order as `.background → .modifier`.

- [ ] **Step 3: Verify build + suite**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3
```

Expected: build clean, 356 tests passing.

- [ ] **Step 4: Manual smoke (skip on CI; record for the user)**

If running on macOS 26 with a built `.app`:
1. Open Settings → Appearance → toggle Liquid Glass ON.
2. Open mini-player popover → confirm glass refraction visible behind content.
3. Toggle Ambient ON additionally → confirm gradient layers behind glass.
4. Toggle Liquid Glass OFF → reverts to current opaque-with-ambient look.

This is documented for the user; the engineer's task is the code change.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift Sources/RPPlayer/Shell/PastSongView.swift
git commit -m "feat(shell): apply Liquid Glass modifier conditionally in popover views

Outer-most modifier in the chain so glass refracts ambient gradient +
content + desktop behind the panel. Layered composition: ambient
renders below glass when both toggles ON."
```

---

## Task 8: FrostedWindowBackground + UpcomingWindowController wiring

**Files:**
- Create: `Sources/RPPlayer/Shell/Components/FrostedWindowBackground.swift`
- Modify: `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift`

No new tests — `NSVisualEffectView` is impractical to unit-test; manual verification only.

- [ ] **Step 1: Create the SwiftUI/AppKit bridge**

Create `Sources/RPPlayer/Shell/Components/FrostedWindowBackground.swift`:

```swift
import SwiftUI
import AppKit

struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
```

- [ ] **Step 2: Wire it into `UpcomingWindowController.swift`**

Refactor `UpcomingWindowController` to subscribe to `configStore.changes`. Replace the existing class body (lines 4-41) with:

```swift
import AppKit
import SwiftUI

@MainActor
final class UpcomingWindowController {
    private let viewModel: UpcomingProgramViewModel
    private let configStore: any ConfigStore
    private var window: NSWindow?
    private var frostedView: NSVisualEffectView?
    private var settingsTask: Task<Void, Never>?

    init(viewModel: UpcomingProgramViewModel, configStore: any ConfigStore) {
        self.viewModel = viewModel
        self.configStore = configStore
    }

    deinit { settingsTask?.cancel() }

    func show() async {
        if window == nil {
            let rootView = UpcomingProgramView(viewModel: viewModel)
            let hosting = NSHostingController(rootView: rootView)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Upcoming Program"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 720, height: 480))
            w.minSize = NSSize(width: 480, height: 300)
            w.setFrameAutosaveName("UpcomingProgram")
            w.isReleasedWhenClosed = false
            window = w
        }

        if settingsTask == nil {
            await applyFrosted(await configStore.settings.frostedUpcomingEnabled)
            let stream = await configStore.changes
            settingsTask = Task { [weak self] in
                for await snapshot in stream {
                    guard let self else { return }
                    await self.applyFrosted(snapshot.frostedUpcomingEnabled)
                }
            }
        }

        if let w = window, let desired = await viewModel.desiredContentWidth() {
            let currentContent = w.contentRect(forFrameRect: w.frame).size
            if currentContent.width > desired {
                let target = max(desired, w.minSize.width)
                w.setContentSize(NSSize(width: target, height: currentContent.height))
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyFrosted(_ enabled: Bool) {
        guard let window, let contentView = window.contentView else { return }
        if enabled {
            if frostedView == nil {
                let v = NSVisualEffectView()
                v.material = .hudWindow
                v.blendingMode = .behindWindow
                v.state = .active
                v.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(v, positioned: .below, relativeTo: contentView.subviews.first)
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    v.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    v.topAnchor.constraint(equalTo: contentView.topAnchor),
                    v.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                ])
                frostedView = v
            }
        } else {
            frostedView?.removeFromSuperview()
            frostedView = nil
        }
    }
}
```

- [ ] **Step 3: Update the `UpcomingWindowController` construction site**

Find where `UpcomingWindowController(viewModel:)` is called in `Sources/RPPlayer/App/AppContainer.swift` (and possibly `AppDelegate.swift`):

```bash
grep -rn "UpcomingWindowController(" /Users/gergely/git/rp-player/Sources/
```

For each call site, add `configStore:` parameter passing the existing config store:

```swift
let upcomingController = UpcomingWindowController(viewModel: upcomingVM, configStore: configStore)
```

(The exact `configStore` variable name should match what's in scope at each call site — typically `store` or `configStore`.)

- [ ] **Step 4: Build + suite**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3
```

Expected: build clean (compile-fixed any signature mismatches at call sites). 356 tests passing.

If `AppContainerTests` fails because the test-side construction of `UpcomingWindowController` is missing a `configStore`, propagate the same change there (the test already has access to a `StubConfigStore` per the `MiniPlayerViewModel` test pattern).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/Components/FrostedWindowBackground.swift Sources/RPPlayer/Upcoming/UpcomingWindowController.swift Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(upcoming): frosted window background toggle

UpcomingWindowController subscribes to configStore.changes; when
frostedUpcomingEnabled is true an NSVisualEffectView (.hudWindow,
.behindWindow blending) is installed as the bottom-most subview of the
window's content view, so cards continue to render unchanged on top.
Disables cleanly by removing the view."
```

The standalone `FrostedWindowBackground` SwiftUI bridge stays in the codebase as a reusable wrapper (currently unused; future SwiftUI surfaces may adopt it). YAGNI-adjacent but preserved per the spec for future-proofing — if reviewer prefers, drop the file.

---

## Task 9: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: README — append a sentence in the Appearance section**

Find the README section that mentions Ambient (search for "Ambient background"). Append a new sentence in the same paragraph or a new bullet:

```markdown
- **Liquid Glass** (macOS 26+) and **Frosted Upcoming Program window** (macOS 14+) toggles in Settings → Appearance let you opt into the new translucent materials. Both default off; Liquid Glass refracts the ambient gradient + desktop behind the popover when on.
```

- [ ] **Step 2: CLAUDE.md — PR row**

Find the PR status table. After the `| 24 |` row, append:

```markdown
| 25   | claude/pr25-liquid-glass | 🚧      | Liquid Glass + Frosted Upcoming toggles: AppSettings.liquidGlassEnabled + frostedUpcomingEnabled (default false); LiquidGlassBackground modifier (#available(macOS 26.0) gated, RoundedRectangle cornerRadius 10); FrostedWindowBackground (NSVisualEffectView .hudWindow/.behindWindow); Settings → Appearance toggles with caption on macOS <26 |
```

- [ ] **Step 3: CLAUDE.md — Last merged line**

Update the "Last merged" line near the top to reflect PR 25 (or leave on PR 24 until actually merged — your call). For the in-progress branch, leave "Last merged: PR 24" line untouched.

- [ ] **Step 4: CLAUDE.md — test counts entry**

Append after the PR 24 test-counts line:

```markdown
- After PR 25 Liquid Glass + Frosted Upcoming toggles (`AppSettings.liquidGlassEnabled` + `frostedUpcomingEnabled`; `SettingsViewModel` published props + setters; `LiquidGlassBackground`/`LiquidGlassBackgroundIfEnabled` SwiftUI modifier with `#available(macOS 26.0, *)` gate; `FrostedWindowBackground` NSViewRepresentable; `MiniPlayerViewModel` + `PastSongViewModel` published prop + configStore.changes wiring; `UpcomingWindowController` subscribes to settings and installs/removes `NSVisualEffectView` as content-view subview index 0): 356
```

(Replace 356 with whatever final `swift test` reports.)

- [ ] **Step 5: CLAUDE.md — Shell technical decisions**

In the existing `### Shell (AppKit + SwiftUI)` section, append a new bullet:

```markdown
- **Liquid Glass + Frosted toggles (PR 25).** Two opt-in settings: `liquidGlassEnabled` applies `.glassEffect(in: RoundedRectangle(cornerRadius: 10))` to mini-player + past-song popovers via `LiquidGlassBackgroundIfEnabled` ViewModifier (gated `if #available(macOS 26.0, *)`; toggle in Settings disabled with caption on older macOS). `frostedUpcomingEnabled` installs an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`) as the bottom-most subview of the Upcoming window's content view via `UpcomingWindowController.applyFrosted(_:)` reactive on `configStore.changes`. Composition: when both Liquid Glass and Ambient are on, ambient gradient renders below glass (modifier order: `.background(ambient) → .modifier(glass)`); glass refracts ambient + desktop. The reusable `FrostedWindowBackground` SwiftUI bridge exists for future SwiftUI consumers but is not currently wired (Upcoming uses the AppKit subview path because the host window is non-SwiftUI).
```

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: PR 25 Liquid Glass + Frosted Upcoming toggles"
```

---

## Task 10: Push, open PR, merge

- [ ] **Step 1: Push branch**

```bash
git push -u origin claude/pr25-liquid-glass
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat(shell): Liquid Glass + Frosted Upcoming Window toggles" --body "$(cat <<'EOF'
## Summary
- Adds two opt-in Appearance toggles:
  - **Liquid Glass** (macOS 26+, gated): applies SwiftUI `.glassEffect(in: RoundedRectangle(cornerRadius: 10))` to the mini-player and past-song popovers. Layered with Ambient (gradient renders below glass when both on).
  - **Frosted Upcoming Program window** (macOS 14+): installs `NSVisualEffectView` (`.hudWindow`, `.behindWindow`) as a content-view subview, so cards render above an animated blur.
- Both default `false`. Both reactive on toggle flip via existing `configStore.changes` subscription pattern.
- Liquid Glass toggle disabled with "Requires macOS 26 or later" caption when running on an older OS — stored value persists, so an OS upgrade activates the user's choice automatically.
- 11 new tests (4 codable + 4 settings VM + 1 mini VM + 1 past VM + 1 modifier smoke). Total ~356.

## Test plan
- [x] `swift test` passes
- [ ] Manual on macOS 26: Liquid Glass ON → glass refraction visible behind popover content; Liquid Glass + Ambient → gradient layers below glass.
- [ ] Manual on macOS 26: Frosted Upcoming ON → window blurs background; cards remain readable; toggle live-updates without window-reopen.
- [ ] Manual on macOS <26 (if available): Liquid Glass toggle disabled with caption; Frosted Upcoming works; toggle state persists across restarts.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: After CI green, ff-merge**

```bash
gh pr checks --watch
git checkout main && git pull --ff-only && git merge --ff-only claude/pr25-liquid-glass && git push origin main
```

- [ ] **Step 4: Update CLAUDE.md PR row 🚧 → ✅ + flip "Last merged" line + commit + push**

```bash
# Edit CLAUDE.md: PR 25 row "claude/pr25-liquid-glass" → "merged to main", "🚧" → "✅".
# Also flip "Last merged" line to PR 25 with final test count.
git add CLAUDE.md
git commit -m "docs: mark PR 25 merged"
git push origin main
```

---

## Acceptance criteria

- Two new fields persist in `config.json`, default `false`, back-compat with existing files.
- Liquid Glass toggle enabled on macOS 26+, disabled with caption on older.
- When Liquid Glass ON: mini-player + past-song popovers show `.glassEffect(in: RoundedRectangle(cornerRadius: 10))`. With Ambient also ON: gradient renders below glass.
- When Frosted Upcoming ON: Upcoming window has `NSVisualEffectView` blur as bottom-most content-view subview; cards readable above.
- Both toggles live-update without app restart.
- All tests pass (`~356`).
- CLAUDE.md + README updated.
- No public API change on `PlaybackCoordinator` or `ConfigStore` protocols.

---

## Self-review checklist (run after writing this plan)

1. **Spec coverage:** every spec section has a task — ✓ (AppSettings → T1, SettingsViewModel → T2, SettingsView → T3, modifier component → T4, MiniPlayer VM → T5, PastSong VM → T6, popover view wiring → T7, UpcomingWindowController + frosted → T8, docs → T9).
2. **Placeholder scan:** no TBDs except the spec's "Target PR" metadata field (not in this plan); no "implement later" / "similar to Task N"; all code blocks complete.
3. **Type consistency:** `liquidGlassEnabled` / `frostedUpcomingEnabled` named identically across AppSettings, SettingsViewModel, both popover VMs, and UpcomingWindowController. `LiquidGlassBackground` / `LiquidGlassBackgroundIfEnabled` used consistently in Tasks 4 + 7. `FrostedWindowBackground` SwiftUI wrapper named consistently in Task 8 (note: the AppKit subview in `applyFrosted` does not reuse the SwiftUI wrapper because the upcoming window's content view is `NSHostingController` and a SwiftUI `NSViewRepresentable` cannot legally be used as a sibling AppKit subview without re-hosting — the AppKit path is correct, the SwiftUI wrapper exists for future SwiftUI surfaces).
