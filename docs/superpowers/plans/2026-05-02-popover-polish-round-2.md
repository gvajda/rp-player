# Popover Polish Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six small popover/settings polish items: outline play button, star-icon rating label, drop a stale settings caption, add an Appearance picker (Light/Dark/System), restructure the channel row to fold "RP Player" + bitrate-with-`@` + centered picker, drop the footer.

**Architecture:** Pure-additive setting wired into AppSettings + AppContainer (`NSApp.appearance` binder), plus localized SwiftUI tweaks in `MiniPlayerView`, `RatingMenu`, `SettingsView`, `SettingsViewModel`. No coordinator or engine changes.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSApp.appearance`, `NSAppearance`), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-02-popover-polish-round-2-design.md`

**Branch:** continue on `claude/popover-visual-polish` (round 1 not yet merged into `main`; rounds will land together when the user finishes manual smoke).

---

## Pre-flight

- [ ] **Step 0a: Confirm branch + clean state**

```bash
git status
git log --oneline main..HEAD | head -5
```

Expected: branch is `claude/popover-visual-polish`, working tree clean, recent commit is `fix(review): strengthen shutdown stream assertion + clarify gear-style note`.

- [ ] **Step 0b: Confirm baseline tests pass**

```bash
swift test 2>&1 | tail -5
```

Expected: 217 tests passing.

If anything is off, stop. Investigate.

---

## Task 1: Add `AppearanceMode` enum

**Files:**
- Create: `Sources/RPPlayer/Config/AppearanceMode.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Config/AppearanceMode.swift
git commit -m "feat(config): add AppearanceMode enum (system/light/dark)"
```

---

## Task 2: Add `appearance` to `AppSettings`

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`

- [ ] **Step 1: Add the stored property + init param + decoder default**

The current struct has 8 stored properties (`selectedChannelId`, `hogModeEnabled`, `softwareVolumeEnabled`, `notificationsEnabled`, `bitrate`, `outputDeviceUID`, `logLevel`, `verboseLoggingEnabled`) and a custom `init(from:)` that supplies defaults via `decodeIfPresent ?? <fallback>`.

Add `appearance` as the 9th property. Place it next to `notificationsEnabled` so the related UI-shell settings are clustered.

```swift
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Radio Paradise channel ID. 0 = Main Mix, 1 = Mellow Mix, 2 = Rock Mix, 3 = Global Mix, etc.
    /// Authoritative list comes from `api/list_chan` at runtime.
    public var selectedChannelId: Int
    public var hogModeEnabled: Bool
    public var softwareVolumeEnabled: Bool
    public var notificationsEnabled: Bool
    public var appearance: AppearanceMode
    /// Radio Paradise bitrate code passed to `api/get_block`.
    /// 0 = 32k aac, 1 = 64k aac, 2 = 128k aac, 3 = 320k aac, 4 = flac, 5 = 128k mp3, 6 = 320k mp3.
    /// Default 4 (FLAC) to honour the project's bit-perfect goal.
    public var bitrate: Int
    public var outputDeviceUID: String?
    public var logLevel: AppLogger.Level
    public var verboseLoggingEnabled: Bool

    public init(
        selectedChannelId: Int = 0,
        hogModeEnabled: Bool = true,
        softwareVolumeEnabled: Bool = false,
        notificationsEnabled: Bool = true,
        appearance: AppearanceMode = .system,
        bitrate: Int = 4,
        outputDeviceUID: String? = nil,
        logLevel: AppLogger.Level = .info,
        verboseLoggingEnabled: Bool = false
    ) {
        self.selectedChannelId = selectedChannelId
        self.hogModeEnabled = hogModeEnabled
        self.softwareVolumeEnabled = softwareVolumeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.appearance = appearance
        self.bitrate = bitrate
        self.outputDeviceUID = outputDeviceUID
        self.logLevel = logLevel
        self.verboseLoggingEnabled = verboseLoggingEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedChannelId = try c.decodeIfPresent(Int.self, forKey: .selectedChannelId) ?? 0
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? true
        self.softwareVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .softwareVolumeEnabled) ?? false
        self.notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 4
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.logLevel = try c.decodeIfPresent(AppLogger.Level.self, forKey: .logLevel) ?? .info
        self.verboseLoggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .verboseLoggingEnabled) ?? false
    }

    public static let `default` = AppSettings()
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift
git commit -m "feat(config): AppSettings.appearance defaulting to .system"
```

---

## Task 3: Codable round-trip + default-on-missing-key tests for `AppSettings`

**Files:**
- Create: `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import RPPlayer

final class AppSettingsCodableTests: XCTestCase {
    func testRoundTripPreservesAppearance() throws {
        var settings = AppSettings.default
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.appearance, .dark)
    }

    func testMissingAppearanceKeyDecodesAsSystem() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.appearance, .system)
    }

    func testAllAppearanceCasesRoundTrip() throws {
        for mode in AppearanceMode.allCases {
            var settings = AppSettings.default
            settings.appearance = mode
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.appearance, mode, "round-trip failed for \(mode)")
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter AppSettingsCodableTests 2>&1 | tail -10`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift
git commit -m "test(config): AppSettings appearance round-trip + missing-key default"
```

---

## Task 4: `SettingsViewModel` — `appearance` published property + setter

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`, immediately before the closing `}` of the test class:

```swift
    func testAppearanceDefaultsToSystem() async throws {
        let store = StubConfigStore(initial: .default)
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubDeviceCatalog(),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {}
        )
        XCTAssertEqual(sut.appearance, .system)
    }

    func testSetAppearancePersists() async throws {
        let store = StubConfigStore(initial: .default)
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubDeviceCatalog(),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {}
        )
        await sut.setAppearance(.dark)
        let snapshot = await store.settings
        XCTAssertEqual(snapshot.appearance, .dark)
        XCTAssertEqual(sut.appearance, .dark)
    }
```

If the existing tests reference `StubConfigStore` / `StubDeviceCatalog` / `StubKeychainAuth` under different names, search the file for the existing setUp pattern (`grep -n "configStore\|StubConfigStore" Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift | head -5`) and adapt the constructor calls to match. Reuse exactly whatever helpers the existing tests use.

The `await sut.setAppearance(.dark)` followed by `await sut.appearance` works if the setter awaits the store update before yielding. The existing `setVerboseLoggingEnabled` follows the same `await update { … }` shape; mirroring it gives us the same observable timing.

- [ ] **Step 2: Run the tests, expect failure**

Run: `swift test --filter SettingsViewModelTests.testAppearanceDefaultsToSystem 2>&1 | tail -10`
Expected: build error — `sut.appearance` and `sut.setAppearance` don't exist yet.

- [ ] **Step 3: Add the published property + the setter + the hydration paths**

Open `Sources/RPPlayer/Shell/SettingsViewModel.swift`. Find the `@Published private(set) var verboseLoggingEnabled: Bool` line (around line 12) and add a sibling:

```swift
@Published private(set) var appearance: AppearanceMode
```

Find the constructor's body where existing `@Published` properties get hydrated from `snapshot` (around lines 40–47) and add:

```swift
self.appearance = snapshot.appearance
```

Find the `start()` method's `MainActor.run { … }` block (around lines 56–64) where the same hydration is mirrored on every `configStore.changes` emission and add the same line:

```swift
self.appearance = snapshot.appearance
```

After the existing `setVerboseLoggingEnabled(_:)` method (around lines 105–107), add:

```swift
func setAppearance(_ value: AppearanceMode) async {
    await update { $0.appearance = value }
}
```

- [ ] **Step 4: Run the new tests, expect pass**

Run: `swift test --filter SettingsViewModelTests 2>&1 | tail -15`
Expected: all `SettingsViewModelTests` pass, including the two new ones.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 222 tests pass (217 + 3 from Task 3 + 2 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(view-model): SettingsViewModel exposes appearance + setter"
```

---

## Task 5: `SettingsView` — drop verbose-logging caption + add Appearance section

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

- [ ] **Step 1: Drop the "Reset on app restart." caption**

In `dataSection` (around lines 71–80), the current shape is:

```swift
private var dataSection: some View {
    Section("Data") {
        Button("Show application data") { viewModel.openApplicationData() }
        Toggle("Verbose logging", isOn: verboseLoggingBinding)
        if viewModel.verboseLoggingEnabled {
            Text("Logs every API call, decision, and state transition. Reset on app restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

Replace with:

```swift
private var dataSection: some View {
    Section("Data") {
        Button("Show application data") { viewModel.openApplicationData() }
        Toggle("Verbose logging", isOn: verboseLoggingBinding)
    }
}
```

- [ ] **Step 2: Add the appearance section + binding**

Add a new computed property next to the others (e.g. after `notificationsSection`):

```swift
private var appearanceSection: some View {
    Section("Appearance") {
        Picker("Appearance", selection: appearanceBinding) {
            Text("System").tag(AppearanceMode.system)
            Text("Light").tag(AppearanceMode.light)
            Text("Dark").tag(AppearanceMode.dark)
        }
        .pickerStyle(.menu)
    }
}

private var appearanceBinding: Binding<AppearanceMode> {
    Binding(
        get: { viewModel.appearance },
        set: { newValue in Task { await viewModel.setAppearance(newValue) } }
    )
}
```

(Place `appearanceBinding` next to the existing `verboseLoggingBinding` for visual consistency.)

In `body` (around lines 6–12), insert `appearanceSection` between `notificationsSection` and `accountSection`:

```swift
var body: some View {
    Form {
        audioSection
        notificationsSection
        appearanceSection
        accountSection
        dataSection
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 560)
    .task { await viewModel.start() }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Run the smoke test for SettingsView**

Run: `swift test --filter SettingsViewTests 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 222 tests pass (no regression).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(settings): drop verbose-logging caption; add Appearance picker section"
```

---

## Task 6: `AppContainer.live()` — bind `NSApp.appearance` to settings

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

- [ ] **Step 1: Add the appearance binder Task**

Find the existing settings-binder Tasks inside `live()` (around lines 117–135 — there's a hog-mode-and-output-device binder, and a verbose-logging binder). Add a third sibling Task that consumes `store.changes` and writes `NSApp.appearance` on the main actor:

```swift
Task { @MainActor in
    let stream = await store.changes
    for await settings in stream {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
```

Place it next to the existing two binders. The `@MainActor` attribute on the Task is required because the existing binders are non-`@MainActor` Tasks (they don't touch AppKit). `NSApp` is `@MainActor`-isolated, so this Task must be too.

The initial application happens implicitly: `JSONConfigStore` yields the loaded settings as the first `store.changes` element, so the `for await` body runs once with the persisted appearance immediately.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds. If you see a `Sendable` warning about capturing the Task closure across actor boundaries, the `@MainActor` attribute on the Task should resolve it; double-check the syntax.

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: 222 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(app): bind NSApp.appearance to AppSettings.appearance"
```

---

## Task 7: `RatingMenu` — star icons + minWidth bump

**Files:**
- Modify: `Sources/RPPlayer/Shell/RatingMenu.swift`

- [ ] **Step 1: Update the label computed property + frame**

Open `Sources/RPPlayer/Shell/RatingMenu.swift`. Replace the body and label:

```swift
import SwiftUI

struct RatingMenu: View {
    let currentRating: Int?
    let isSignedIn: Bool
    let onRate: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(Array((1...10).reversed()), id: \.self) { value in
                Button("\(value)") { onRate(value) }
            }
        } label: {
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 32, alignment: .center)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isSignedIn)
        .help(isSignedIn ? "Rate this song" : "Sign in to rate")
        .accessibilityLabel(isSignedIn ? "Rate this song" : "Rating (sign in to rate)")
    }

    private var label: String {
        if let r = currentRating { return "★ \(r)" }
        return "☆"
    }
}
```

The em-dash `—` is gone; the star characters are `★` (U+2605) and `☆` (U+2606). `minWidth` bumped from 22 to 32 to fit "★ 10".

- [ ] **Step 2: Build + run RatingMenu tests**

```bash
swift build 2>&1 | tail -5
swift test --filter RatingMenuTests 2>&1 | tail -10
```

Expected: build succeeds; all 3 RatingMenu smoke tests still pass (they don't inspect the label string).

- [ ] **Step 3: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 222 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/RatingMenu.swift
git commit -m "feat(shell): RatingMenu shows ★ <n> when rated, ☆ when unrated"
```

---

## Task 8: `MiniPlayerView` — outline play symbols + restructured channel row + drop footer

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- [ ] **Step 1: Replace the file body**

Open `Sources/RPPlayer/Shell/MiniPlayerView.swift` and replace its full contents with:

```swift
import AppKit
import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel

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
                channelRow
                transport
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
                Text(viewModel.nowPlaying?.song.title ?? "—")
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.nowPlaying?.song.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let song = viewModel.nowPlaying?.song,
                   let album = song.album,
                   !album.isEmpty {
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

    private var progressRow: some View {
        VStack(spacing: 2) {
            ProgressView(
                value: viewModel.songElapsedSeconds,
                total: max(viewModel.songDurationSeconds, 0.001)
            )
            .progressViewStyle(.linear)
            HStack {
                Text(formatTime(viewModel.songElapsedSeconds))
                Spacer()
                Text(formatTime(viewModel.songDurationSeconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(width: 318)
    }

    private var channelRow: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    if let label = viewModel.currentBitrateLabel {
                        Text(label)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("@")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("RP Player")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Menu {
                        Button("Settings…") { viewModel.openSettings() }
                        Divider()
                        Button("Quit RP Player") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .regular))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Settings and Quit")
                }
            }
            channelPicker
                .fixedSize()
        }
        .frame(width: 318)
    }

    private var channelPicker: some View {
        Picker(selection: Binding(
            get: { viewModel.selectedChannelId },
            set: { newId in Task { await viewModel.selectChannel(newId) } }
        )) {
            ForEach(viewModel.channels, id: \.chan) { channel in
                if let id = Int(channel.chan) {
                    Text(channel.title).tag(id)
                }
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button {
                Task { await viewModel.togglePlayPause() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle" : "play.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(PressOpacityButtonStyle())
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.skipForward() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(PressOpacityButtonStyle())
            .frame(width: 38, height: 38)
            .disabled(!viewModel.isPlaying)
            .accessibilityLabel("Skip Forward")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

Diff vs. the round-1 file:
- `body` no longer invokes `footer`.
- `transport` uses `pause.circle` / `play.circle` (no `.fill`).
- `channelRow` is a `ZStack` with `channelPicker` geometrically centered; the surrounding `HStack` has the bitrate group on the left and the "RP Player" + gear group on the right.
- `footer` computed property removed.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Run the smoke test for MiniPlayerView**

Run: `swift test --filter MiniPlayerViewTests 2>&1 | tail -10`
Expected: pass.

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 222 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerView.swift
git commit -m "feat(shell): outline play button, centered picker w/ bitrate@ and inline RP Player, drop footer"
```

---

## Task 9: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump test count**

Find the existing line:

```
- After popover visual polish (positionUpdates stream + RatingMenu + edge-to-edge art + Quit menu + press-opacity buttons; deletes RatingRow): 217
```

Append a new line beneath it:

```
- After popover polish round 2 (Appearance setting + outline play button + ★/☆ rating label + centered picker w/ bitrate@ + inline RP Player; drops verbose-logging caption + footer): 222
```

(Adjust `222` to whatever the actual count is after Task 8.)

- [ ] **Step 2: Add a Settings note in the "Shell (AppKit + SwiftUI)" section**

Append under the existing bullets in `### Shell (AppKit + SwiftUI)`:

```
- Channel row layout uses a `ZStack` so `channelPicker` is geometrically centered. Outer `HStack` holds the leading bitrate group (`<bitrate> @`) and the trailing `RP Player` text + gear group. The previous bottom "RP Player" footer line is gone — the channel-row layout absorbs it.
- Play button uses the SF Symbol outline variants (`play.circle` / `pause.circle`); skip stays filled (`forward.end.fill`). Both transport buttons keep `PressOpacityButtonStyle`.
- `RatingMenu` label: `★ <n>` when rated, `☆` when unrated.
```

- [ ] **Step 3: Add a Settings note**

Find the section header `### Persistence` (or add a new `### Settings` mini-section if there isn't one). Add a bullet about appearance:

```
- `AppSettings.appearance: AppearanceMode` (`.system` / `.light` / `.dark`, default `.system`). `AppContainer.live()` runs a dedicated `@MainActor` settings binder Task that translates each value to `NSApp.appearance` (`nil`, `.aqua`, `.darkAqua` respectively). Persisted JSON without the `appearance` key decodes as `.system` for backwards compatibility.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): note round-2 polish (appearance setting, outline play, centered picker, ★/☆)"
```

---

## Task 10: Final verification

- [ ] **Step 1: Build everything**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!` with no warnings new vs. baseline.

- [ ] **Step 2: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: 222 tests passing (or whatever count CLAUDE.md was bumped to).

- [ ] **Step 3: Verify commit chain**

```bash
git log --oneline main..HEAD
```

Expected: round-1 commits + 9 new round-2 commits at the top.

- [ ] **Step 4: Hand back to user for manual smoke**

Run the spec's smoke checklist:

1. Play button is now a tinted-outline circle.
2. Pressing play does not flash blue (PressOpacityButtonStyle still applies).
3. Channel row: bitrate `@` on the left, picker geometrically centered, "RP Player" text + gear on the right.
4. Bottom of popover: no footer line; transport row sits flush with the inner padding.
5. Rating menu shows `☆` when no rating, `★ 7` (etc.) when rated. Picking updates the label.
6. Settings → Appearance picks System/Light/Dark; entire app switches immediately.
7. Quit and relaunch — appearance persists.
8. Settings → Data: Verbose toggle still works; "Reset on app restart." caption is gone.

User is the merge gatekeeper. Don't merge.

---

## Self-review notes

- **Spec coverage:**
  - Item 1 (outline play) → Task 8.
  - Item 2 (★/☆ rating label) → Task 7.
  - Item 3 (drop verbose-logging caption) → Task 5.
  - Item 4 (Appearance picker) → Tasks 1, 2, 3, 4, 5, 6.
  - Item 5 (channel row restructure + drop footer) → Task 8.
  - Item 6 (skipped) → no task.
- **Type consistency:** `AppearanceMode` named consistently in enum, `AppSettings.appearance`, `SettingsViewModel.appearance`, `setAppearance(_:)`, picker tags. `NSAppearance.Name.aqua` / `.darkAqua` are the correct AppKit constants.
- **No placeholders:** every step has either exact code or an exact command + expected output.
- **TDD:** Task 3 (Codable tests before any view-model change), Task 4 (view-model test before view-model code). UI restructure tasks (5, 7, 8) have no behavior to TDD beyond the existing render-without-crash smoke; manual smoke covers them.
