# Volume Mode Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two boolean rows `Toggle("Force Max Volume")` + `Toggle("Apply ReplayGain")` with a single 3-state segmented picker `Volume: [None | ReplayGain ⓘ | Force Max ⓘ]` placed at the bottom of the device-settings section (not indented under Hog). The mutual-exclusion + force-max-requires-hog rules are encoded in a single `VolumeMode` enum, removing the dual-bool drift. Persist per device via the existing `AudioProfile` mechanism.

**Architecture:**
- New `VolumeMode` enum (`Codable, Equatable, Sendable`) with cases `.none / .replayGain / .forceMax`.
- Replace `forceMaxVolumeEnabled: Bool` + `applyReplayGainEnabled: Bool` on `AppSettings` and `AudioProfile` with single `volumeMode: VolumeMode`. JSON decode migrates legacy bool pair → enum (`force_max=true → .forceMax`, else `replaygain=true → .replayGain`, else `.none`).
- `MpvPlayerEngine.setForceMaxVolume` / `setApplyReplayGain` engine API unchanged — `AppContainer` binder reads new enum and maps to the existing two engine calls. Limits blast radius.
- `SettingsViewModel` swaps two `@Published` bools for one `@Published volumeMode: VolumeMode` + replacement setter `setVolumeMode(_:)`. Old setters deleted.
- `SettingsView` replaces the two `Toggle` rows with a single `Picker(.segmented)` carrying inline `HoverInfoIcon` ⓘ tooltips on ReplayGain and Force Max segments. Force Max segment disabled when `!hogModeEnabled`. Force Max destructive-confirmation alert moves to the picker binding's `set` closure.
- Hog OFF→ON ground-truth check (currently downgrades `forceMaxVolumeEnabled` if device volume < max) updates to downgrade `volumeMode == .forceMax → .none`.
- Strip the "(bit-perfect)" suffix from the Hog mode toggle label; the bit-perfect statement moves into the Force Max tooltip.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest, SPM (`swift test` / `swift build`).

---

## File Structure

**Create:**
- `Sources/RPPlayer/Config/VolumeMode.swift` — enum + Codable
- `Tests/RPPlayerTests/Config/VolumeModeTests.swift` — enum round-trip + raw-value contract
- `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift` — legacy-bool decode → enum migration
- `Tests/RPPlayerTests/Config/AppSettingsVolumeModeMigrationTests.swift` — same migration at AppSettings level
- `Tests/RPPlayerTests/Shell/SettingsViewModelVolumeModeTests.swift` — VM surface + setter + alert path

**Modify:**
- `Sources/RPPlayer/Config/AudioProfile.swift` — replace two bools with one enum + custom `init(from:)` for migration + custom CodingKeys
- `Sources/RPPlayer/Config/AppSettings.swift` — same shape change as AudioProfile; init defaults; `init(from:)` migration; CodingKeys cleaned
- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — drop `forceMaxVolumeEnabled`/`applyReplayGainEnabled` published vars + setters; add `volumeMode` + `setVolumeMode(_:)`
- `Sources/RPPlayer/Shell/SettingsView.swift` — strip `(bit-perfect)` from Hog row, replace force-max + replaygain Toggles with `Picker(.segmented)`; alert wiring; tooltip strings
- `Sources/RPPlayer/App/AppContainer.swift` — binder reads `volumeMode`; map to existing engine calls; device-switch + atomic write path; safety wipe sites
- `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` — every existing test that mentions the legacy bools → switch to `volumeMode`; keep legacy-bool decode coverage that explicitly tests migration
- `Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift` — same
- `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` — adjust assertions that read the old bool fields
- `Tests/RPPlayerTests/App/AppContainerTests.swift` if it exists — bind tests adjusted (search reveals; check during task)
- `CHANGELOG.md` — `## [Unreleased]` entries (Changed)
- `CLAUDE.md` — PR status row, *Test counts by PR* entry, *Key technical decisions* > Audio pipeline notes (drop the dead-`softwareVolumeEnabled` mention, replace with `volumeMode` description)

---

## Task 1: VolumeMode enum

**Files:**
- Create: `Sources/RPPlayer/Config/VolumeMode.swift`
- Test: `Tests/RPPlayerTests/Config/VolumeModeTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/RPPlayerTests/Config/VolumeModeTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class VolumeModeTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(VolumeMode.none.rawValue, "none")
        XCTAssertEqual(VolumeMode.replayGain.rawValue, "replayGain")
        XCTAssertEqual(VolumeMode.forceMax.rawValue, "forceMax")
    }

    func testCodableRoundTrip() throws {
        for mode in [VolumeMode.none, .replayGain, .forceMax] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(VolumeMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VolumeModeTests`
Expected: FAIL — `cannot find 'VolumeMode' in scope`.

- [ ] **Step 3: Create enum**

Create `Sources/RPPlayer/Config/VolumeMode.swift`:

```swift
import Foundation

public enum VolumeMode: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case replayGain
    case forceMax
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VolumeModeTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/VolumeMode.swift Tests/RPPlayerTests/Config/VolumeModeTests.swift
git commit -m "feat(volume): add VolumeMode enum (none/replayGain/forceMax)"
```

---

## Task 2: AudioProfile migration to volumeMode

**Files:**
- Modify: `Sources/RPPlayer/Config/AudioProfile.swift`
- Test: `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift`

Read current shape first:
```
public struct AudioProfile: Codable, Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var forceMaxVolumeEnabled: Bool
    public var applyReplayGainEnabled: Bool
    public var bitrate: Int
    ...
}
```

- [ ] **Step 1: Write migration test**

Create `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class AudioProfileMigrationTests: XCTestCase {
    func testLegacyForceMaxBoolMigratesToForceMaxEnum() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":true,"applyReplayGainEnabled":false,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testLegacyReplayGainBoolMigratesToReplayGain() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":false,"applyReplayGainEnabled":true,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testLegacyBothFalseMigratesToNone() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":false,"applyReplayGainEnabled":false,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }

    func testLegacyBothTrueMigratesToForceMax() throws {
        // Force Max takes precedence — matches current effective-RG rule.
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":true,"applyReplayGainEnabled":true,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testNewKeyDecodesDirectly() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "volumeMode":"replayGain","bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testRoundTripUsesVolumeModeKeyNotLegacyBools() throws {
        let profile = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: true,
            volumeMode: .forceMax,
            bitrate: 4
        )
        let data = try JSONEncoder().encode(profile)
        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("\"volumeMode\""))
        XCTAssertFalse(string.contains("forceMaxVolumeEnabled"))
        XCTAssertFalse(string.contains("applyReplayGainEnabled"))
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testSafeDefaultUsesNoneMode() {
        XCTAssertEqual(AudioProfile.safeDefault.volumeMode, VolumeMode.none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AudioProfileMigrationTests`
Expected: FAIL — compile errors because `AudioProfile` still has old fields + no `volumeMode`.

- [ ] **Step 3: Update AudioProfile**

Replace `Sources/RPPlayer/Config/AudioProfile.swift` entirely:

```swift
import Foundation

public struct AudioProfile: Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var volumeMode: VolumeMode
    public var bitrate: Int

    public init(
        hogModeEnabled: Bool,
        releaseHogOnPauseEnabled: Bool,
        volumeMode: VolumeMode,
        bitrate: Int
    ) {
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.volumeMode = volumeMode
        self.bitrate = bitrate
    }

    public static let safeDefault = AudioProfile(
        hogModeEnabled: false,
        releaseHogOnPauseEnabled: false,
        volumeMode: .none,
        bitrate: 3
    )
}

extension AudioProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case hogModeEnabled
        case releaseHogOnPauseEnabled
        case volumeMode
        case bitrate
        // Legacy keys for migration only — never encoded.
        case forceMaxVolumeEnabled
        case applyReplayGainEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hogModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .hogModeEnabled) ?? false
        self.releaseHogOnPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .releaseHogOnPauseEnabled) ?? false
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 3
        if let mode = try c.decodeIfPresent(VolumeMode.self, forKey: .volumeMode) {
            self.volumeMode = mode
        } else {
            let forceMax = try c.decodeIfPresent(Bool.self, forKey: .forceMaxVolumeEnabled) ?? false
            let rg = try c.decodeIfPresent(Bool.self, forKey: .applyReplayGainEnabled) ?? false
            self.volumeMode = forceMax ? .forceMax : (rg ? .replayGain : VolumeMode.none)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
        try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
        try c.encode(volumeMode, forKey: .volumeMode)
        try c.encode(bitrate, forKey: .bitrate)
    }
}
```

- [ ] **Step 4: Fix existing AudioProfile call sites**

These will produce compile errors after the field rename. Update each:

Run: `grep -rn "forceMaxVolumeEnabled\|applyReplayGainEnabled" Sources Tests`

Update every `AudioProfile(...)` call site to use `volumeMode:` instead of the two bools. Use the same precedence (`forceMax ? .forceMax : (rg ? .replayGain : .none)`) when collapsing two bools.

Specifically:
- `Sources/RPPlayer/App/AppContainer.swift` line ~348 (atomic write block): replace `forceMaxVolumeEnabled:`/`applyReplayGainEnabled:` initializer args with single `volumeMode: s.volumeMode`.
- `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`: every `AudioProfile(...)` construction.
- Anywhere else grep finds `AudioProfile(`.

For AppContainer and AppSettings call sites that read `forceMaxVolumeEnabled`/`applyReplayGainEnabled` from the AudioProfile or AppSettings struct, defer the source-side rename to Tasks 3 and 5. Just stop reading them from the profile after Task 5. For this task, keep the bools on AppSettings (Task 3 swaps that), but for AudioProfile the bools are gone — call sites that copy AudioProfile → AppSettings fields need updating in Task 3.

For this task, the AppContainer code block at lines ~265-273 (atomic write on device switch) reads `profile.forceMaxVolumeEnabled` / `profile.applyReplayGainEnabled` — replace with mapping to the existing AppSettings bools (still present until Task 3):

```swift
s.forceMaxVolumeEnabled = (profile.volumeMode == .forceMax)
s.applyReplayGainEnabled = (profile.volumeMode == .replayGain)
```

And the atomic write site at line ~348 needs to construct `AudioProfile(..., volumeMode: ...)`:

```swift
s.audioProfiles[uid] = AudioProfile(
    hogModeEnabled: s.hogModeEnabled,
    releaseHogOnPauseEnabled: s.releaseHogOnPauseEnabled,
    volumeMode: s.forceMaxVolumeEnabled
        ? .forceMax
        : (s.applyReplayGainEnabled ? .replayGain : VolumeMode.none),
    bitrate: s.bitrate
)
```

Also the lines 283-285 + similar where `lastForceMax` is read off the profile: replace with `profile.volumeMode == .forceMax`.

Run: `swift build` to confirm compiles.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AudioProfileMigrationTests`
Expected: PASS, 7 tests.

Also run the whole `Config` slice to catch regressions:
Run: `swift test --filter Config`
Expected: PASS (some tests may fail in `AppSettingsCodableTests` — update them inline now so the suite is green before commit. Replace `forceMaxVolumeEnabled: X, applyReplayGainEnabled: Y` arguments with the corresponding `volumeMode:` value; replace `XCTAssertFalse(d.forceMaxVolumeEnabled)` style assertions with `XCTAssertEqual(d.volumeMode, .none)`).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Config/AudioProfile.swift \
        Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift \
        Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift \
        Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(volume): migrate AudioProfile to volumeMode enum

Legacy forceMaxVolumeEnabled+applyReplayGainEnabled bool pair decoded
into VolumeMode via custom init(from:). Precedence on conflict:
forceMax wins (matches current effective-RG rule). Round-trip writes
only the new volumeMode key."
```

---

## Task 3: AppSettings migration to volumeMode

**Files:**
- Modify: `Sources/RPPlayer/Config/AppSettings.swift`
- Test: `Tests/RPPlayerTests/Config/AppSettingsVolumeModeMigrationTests.swift`

- [ ] **Step 1: Write migration test**

Create `Tests/RPPlayerTests/Config/AppSettingsVolumeModeMigrationTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class AppSettingsVolumeModeMigrationTests: XCTestCase {
    func testLegacyBoolsMigrateForceMaxWins() throws {
        let json = """
        {"forceMaxVolumeEnabled":true,"applyReplayGainEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testLegacyReplayGainOnly() throws {
        let json = """
        {"forceMaxVolumeEnabled":false,"applyReplayGainEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testLegacyBothOff() throws {
        let json = """
        {"forceMaxVolumeEnabled":false,"applyReplayGainEnabled":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }

    func testNewKeyTakesPrecedenceWhenBothPresent() throws {
        let json = """
        {"forceMaxVolumeEnabled":true,"applyReplayGainEnabled":false,
         "volumeMode":"replayGain"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testEncodedJSONOmitsLegacyKeys() throws {
        var settings = AppSettings.default
        settings.volumeMode = .forceMax
        let data = try JSONEncoder().encode(settings)
        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("\"volumeMode\":\"forceMax\""))
        XCTAssertFalse(string.contains("forceMaxVolumeEnabled"))
        XCTAssertFalse(string.contains("applyReplayGainEnabled"))
    }

    func testMissingFieldDefaultsToNone() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppSettingsVolumeModeMigrationTests`
Expected: FAIL — compile errors (no `volumeMode` field on `AppSettings`).

- [ ] **Step 3: Update AppSettings**

Open `Sources/RPPlayer/Config/AppSettings.swift`. Perform these edits:

1. Replace the two stored properties:
```swift
public var forceMaxVolumeEnabled: Bool
public var applyReplayGainEnabled: Bool
```
with:
```swift
public var volumeMode: VolumeMode
```

2. Replace the matching `init` parameters:
```swift
forceMaxVolumeEnabled: Bool = false,
applyReplayGainEnabled: Bool = false,
```
with:
```swift
volumeMode: VolumeMode = .none,
```
and matching assignment:
```swift
self.volumeMode = volumeMode
```
(delete the two `self.forceMaxVolumeEnabled = ...` / `self.applyReplayGainEnabled = ...` lines).

3. Update `init(from:)` to migrate. Replace the two decode-if-present lines for the legacy bools with the merged migration:

```swift
if let mode = try c.decodeIfPresent(VolumeMode.self, forKey: .volumeMode) {
    self.volumeMode = mode
} else {
    let forceMax = try c.decodeIfPresent(Bool.self, forKey: .forceMaxVolumeEnabled) ?? false
    let rg = try c.decodeIfPresent(Bool.self, forKey: .applyReplayGainEnabled) ?? false
    self.volumeMode = forceMax ? .forceMax : (rg ? .replayGain : .none)
}
```

4. `CodingKeys` (synthesized) won't include the legacy keys after the property rename, which breaks the migration `decodeIfPresent` calls. Add explicit `CodingKeys` to retain the legacy cases for read-only migration:

```swift
private enum CodingKeys: String, CodingKey {
    case selectedChannelId, hogModeEnabled, releaseHogOnPauseEnabled
    case volumeMode
    case notificationsEnabled, appearance, menuBarIconStyle
    case ambientBackgroundEnabled, popoverStyle, frostedUpcomingEnabled
    case bitrate, outputDeviceUID, logLevel, verboseLoggingEnabled
    case playerId, upcomingRowCount, upcomingHiddenChannelIds
    case popoverFloating, audioProfiles, updateCheckEnabled
    case lastUpdateCheckAt, dismissedUpdateVersion, cachedLatestRelease
    // Legacy migration only — never encoded.
    case forceMaxVolumeEnabled
    case applyReplayGainEnabled
}
```

5. Add explicit `encode(to:)` that omits the legacy cases. Since the previous code relied on synthesized encoding, add:

```swift
public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(selectedChannelId, forKey: .selectedChannelId)
    try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
    try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
    try c.encode(volumeMode, forKey: .volumeMode)
    try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
    try c.encode(appearance, forKey: .appearance)
    try c.encode(menuBarIconStyle, forKey: .menuBarIconStyle)
    try c.encode(ambientBackgroundEnabled, forKey: .ambientBackgroundEnabled)
    try c.encode(popoverStyle, forKey: .popoverStyle)
    try c.encode(frostedUpcomingEnabled, forKey: .frostedUpcomingEnabled)
    try c.encode(bitrate, forKey: .bitrate)
    try c.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
    try c.encode(logLevel, forKey: .logLevel)
    try c.encode(verboseLoggingEnabled, forKey: .verboseLoggingEnabled)
    try c.encodeIfPresent(playerId, forKey: .playerId)
    try c.encode(upcomingRowCount, forKey: .upcomingRowCount)
    try c.encode(upcomingHiddenChannelIds, forKey: .upcomingHiddenChannelIds)
    try c.encode(popoverFloating, forKey: .popoverFloating)
    try c.encode(audioProfiles, forKey: .audioProfiles)
    try c.encode(updateCheckEnabled, forKey: .updateCheckEnabled)
    try c.encodeIfPresent(lastUpdateCheckAt, forKey: .lastUpdateCheckAt)
    try c.encodeIfPresent(dismissedUpdateVersion, forKey: .dismissedUpdateVersion)
    try c.encodeIfPresent(cachedLatestRelease, forKey: .cachedLatestRelease)
}
```

- [ ] **Step 4: Fix compile errors in AppContainer + ViewModel + Views**

After this edit, every code path that reads `settings.forceMaxVolumeEnabled` or `settings.applyReplayGainEnabled` breaks. Plan addresses these in Tasks 4 and 5; for now, use temporary computed-property bridges directly on `AppSettings` to keep build green between commits:

Add at the bottom of `AppSettings.swift`:

```swift
public extension AppSettings {
    // Transitional bridges removed in Task 5 once binder/VM/View land.
    var forceMaxVolumeEnabled: Bool {
        get { volumeMode == .forceMax }
        set {
            if newValue {
                volumeMode = .forceMax
            } else if volumeMode == .forceMax {
                volumeMode = .none
            }
        }
    }
    var applyReplayGainEnabled: Bool {
        get { volumeMode == .replayGain }
        set {
            if newValue {
                volumeMode = .replayGain
            } else if volumeMode == .replayGain {
                volumeMode = .none
            }
        }
    }
}
```

These bridges preserve the existing AppContainer + ViewModel + SettingsView call sites until they're rewritten in later tasks. The transitional bridges are deleted in Task 6.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AppSettingsVolumeModeMigrationTests`
Expected: PASS, 6 tests.

Run full Config slice: `swift test --filter Config`
Expected: PASS. If `AppSettingsCodableTests` fails on assertions reading the bools, update those assertions inline:
- `XCTAssertFalse(d.forceMaxVolumeEnabled)` → `XCTAssertEqual(d.volumeMode, .none)` (or similar based on intent).
- AudioProfile init calls already updated in Task 2. AppSettings init calls passing `forceMaxVolumeEnabled:` / `applyReplayGainEnabled:` need similar replacement.

Also run: `swift build`
Expected: no errors. If anything in `Sources/` breaks (other than via the transitional bridges), update at the call site.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Config/AppSettings.swift \
        Tests/RPPlayerTests/Config/AppSettingsVolumeModeMigrationTests.swift \
        Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift
git commit -m "feat(volume): migrate AppSettings to volumeMode enum with bridges

Adds transitional computed-property bridges so AppContainer + VM call
sites continue to compile. Bridges deleted once binder + VM + view
land in subsequent tasks."
```

---

## Task 4: SettingsViewModel surface

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelVolumeModeTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/RPPlayerTests/Shell/SettingsViewModelVolumeModeTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelVolumeModeTests: XCTestCase {
    private func makeSUT(_ settings: AppSettings = .default) -> (SettingsViewModel, StubConfigStore) {
        let store = StubConfigStore(initial: settings)
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {}
        )
        return (sut, store)
    }

    func testInitialVolumeModeMirrorsSettingsDefault() {
        let (sut, _) = makeSUT()
        XCTAssertEqual(sut.volumeMode, VolumeMode.none)
    }

    func testSetVolumeModeWritesThroughStore() async {
        let (sut, store) = makeSUT()
        await sut.setVolumeMode(.replayGain)
        XCTAssertEqual(store.settings.volumeMode, .replayGain)
    }

    func testSetVolumeModeUpdatesActiveDeviceProfile() async {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-x"
        let (sut, store) = makeSUT(initial)
        await sut.setVolumeMode(.forceMax)
        XCTAssertEqual(store.settings.audioProfiles["uid-x"]?.volumeMode, .forceMax)
    }

    func testStreamEmissionUpdatesPublishedVolumeMode() async throws {
        let (sut, store) = makeSUT()
        await sut.start()
        try? await store.update { $0.volumeMode = .forceMax }
        // Yield once to allow the AsyncStream consumer to apply on MainActor.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sut.volumeMode, .forceMax)
        await sut.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsViewModelVolumeModeTests`
Expected: FAIL — `volumeMode`/`setVolumeMode` not defined on the VM.

- [ ] **Step 3: Update SettingsViewModel**

In `Sources/RPPlayer/Shell/SettingsViewModel.swift`:

1. Replace these two `@Published` properties:
```swift
@Published private(set) var forceMaxVolumeEnabled: Bool
@Published private(set) var applyReplayGainEnabled: Bool
```
with:
```swift
@Published private(set) var volumeMode: VolumeMode
```

2. In `init`: replace
```swift
self.forceMaxVolumeEnabled = snapshot.forceMaxVolumeEnabled
self.applyReplayGainEnabled = snapshot.applyReplayGainEnabled
```
with:
```swift
self.volumeMode = snapshot.volumeMode
```

3. In `start()` inside the stream subscriber's `MainActor.run` block: replace
```swift
self.forceMaxVolumeEnabled = snapshot.forceMaxVolumeEnabled
self.applyReplayGainEnabled = snapshot.applyReplayGainEnabled
```
with:
```swift
self.volumeMode = snapshot.volumeMode
```

4. Replace the two setters `setForceMaxVolumeEnabled` + `setApplyReplayGainEnabled` with a single:

```swift
func setVolumeMode(_ value: VolumeMode) async {
    await update { s in
        s.volumeMode = value
        if let uid = s.outputDeviceUID {
            s.audioProfiles[uid, default: .safeDefault].volumeMode = value
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsViewModelVolumeModeTests`
Expected: PASS, 4 tests.

`swift build`: passes (other call sites — SettingsView — still call old setters; fixed in Task 5).

Note: SettingsView still references the deleted setter `setForceMaxVolumeEnabled` and the `forceMaxVolumeEnabled` published prop. To keep build green between commits, add two transitional VM helpers immediately above `setVolumeMode`:

```swift
// Transitional — removed in Task 5 once SettingsView lands.
var forceMaxVolumeEnabled: Bool { volumeMode == .forceMax }
var applyReplayGainEnabled: Bool { volumeMode == .replayGain }
func setForceMaxVolumeEnabled(_ value: Bool) async {
    await setVolumeMode(value ? .forceMax : .none)
}
func setApplyReplayGainEnabled(_ value: Bool) async {
    await setVolumeMode(value ? .replayGain : .none)
}
```

Run `swift build` to confirm green.

- [ ] **Step 5: Update existing SettingsViewModel tests**

Existing tests in `SettingsViewModelTests.swift` reference `sut.forceMaxVolumeEnabled` / `sut.applyReplayGainEnabled` (lines 32-33 per grep). The transitional helpers keep these passing, but they're testing the wrong layer now. Leave as-is for this task — Task 6 deletes the bridges and rewrites the assertions in one go.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelVolumeModeTests.swift
git commit -m "feat(volume): VM exposes volumeMode + setVolumeMode

Transitional compatibility shims (forceMaxVolumeEnabled / *Enabled
getters + boolean setters) retained until SettingsView lands in the
next task."
```

---

## Task 5: SettingsView UI

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`
- Test: existing `SettingsViewTests.swift` (smoke-render only; no new file)

This task has no test step beyond `swift build` + the existing SettingsView smoke test, because the relevant logic (binding → setter) is covered by Task 4's VM tests.

- [ ] **Step 1: Strip "(bit-perfect)" from Hog mode toggle label**

Find: `Toggle("Hog mode (bit-perfect)", isOn: hogModeBinding)`
Replace with: `Toggle("Hog mode", isOn: hogModeBinding)`

- [ ] **Step 2: Replace the Force Max + ReplayGain toggles with a Volume picker**

Find the block:
```swift
Toggle("Force Max Volume (for external DACs)", isOn: forceMaxVolumeBinding)
    .padding(.leading, 20)
    .disabled(!viewModel.hogModeEnabled)
Toggle(isOn: applyReplayGainEffectiveBinding) {
    HStack(spacing: 6) {
        Text("Apply ReplayGain")
        if !viewModel.forceMaxVolumeEnabled {
            HoverInfoIcon(
                text:
                    "ReplayGain is a per-track loudness adjustment encoded in the file's metadata. With it ON, the audio engine attenuates each track to match a reference loudness so songs play at similar levels.\n\nNot available when Force Max Volume is ON"
            )
        }
    }
}
.disabled(viewModel.forceMaxVolumeEnabled)
```

Replace with:
```swift
volumeRow
```

Add the `volumeRow` helper somewhere in the view (near other view helpers):

```swift
private var volumeRow: some View {
    HStack(spacing: 8) {
        Text("Volume")
        Spacer(minLength: 8)
        Picker("", selection: volumeModeBinding) {
            Text("None").tag(VolumeMode.none)
            volumeSegment(label: "ReplayGain", tooltip: replayGainTooltip).tag(VolumeMode.replayGain)
            volumeSegment(label: "Force Max", tooltip: forceMaxTooltip).tag(VolumeMode.forceMax)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private func volumeSegment(label: String, tooltip: String) -> some View {
    // Segmented picker tags must be single Views; SwiftUI's segmented style
    // only renders Text or Image — embed the tooltip via .help() on the
    // surrounding picker is not per-segment-targetable, so render Text only.
    Text(label)
}

private var replayGainTooltip: String {
    "Applies per-track loudness normalization metadata embedded by Radio Paradise. Reduces peaks; small variation track-to-track."
}

private var forceMaxTooltip: String {
    "Pins device to max volume + caps mpv at 100. Use external attenuation. Hearing damage warning. Bit-perfect when EQ is off."
}
```

**Per-segment tooltip note.** SwiftUI's `.segmented` style ignores per-tag overlays, so `HoverInfoIcon` cannot live inside a `Text(...).tag(...)`. Two options:

(a) Render two `HoverInfoIcon`s alongside the picker:
```swift
HStack(spacing: 8) {
    Text("Volume")
    Spacer(minLength: 8)
    Picker("", selection: volumeModeBinding) {
        Text("None").tag(VolumeMode.none)
        Text("ReplayGain").tag(VolumeMode.replayGain)
        Text("Force Max").tag(VolumeMode.forceMax)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    HoverInfoIcon(text: replayGainTooltip)
    HoverInfoIcon(text: forceMaxTooltip)
}
```
Less elegant (two icons floating off the right edge) but works in pure SwiftUI.

(b) Drop the segmented style and use `Menu` / `Picker(.inline)`. Loses the segmented aesthetic.

**Recommend (a)** to preserve the segmented look the user asked for. Both icons sit at the trailing edge with `.help` text on hover — `HoverInfoIcon` already renders `Image(systemName: "info.circle")` with a tooltip; placing one for ReplayGain and one for Force Max keeps the same affordance the user is used to.

- [ ] **Step 3: Add bindings + alert wiring**

The picker binding must:
1. Read `viewModel.volumeMode`
2. On `set`: if new value is `.forceMax` and current isn't `.forceMax`, set `pendingForceMaxSelection = .forceMax` and `showForceMaxConfirm = true`. Otherwise call `viewModel.setVolumeMode(newValue)` directly.
3. Force Max segment must be disabled when `!viewModel.hogModeEnabled`. SwiftUI segmented pickers don't expose per-segment `.disabled`; gate at the binding level — reject `.forceMax` transitions when hog OFF and surface a tooltip hint via `HoverInfoIcon` instead.

Add at the top of the view:
```swift
@State private var pendingForceMaxConfirm = false
```
(The existing `showForceMaxConfirm` state is reused.)

Add to SettingsView:
```swift
private var volumeModeBinding: Binding<VolumeMode> {
    Binding(
        get: { viewModel.volumeMode },
        set: { newValue in
            if newValue == .forceMax {
                guard viewModel.hogModeEnabled else { return }
                if viewModel.volumeMode != .forceMax {
                    showForceMaxConfirm = true
                    return
                }
            }
            Task { await viewModel.setVolumeMode(newValue) }
        }
    )
}
```

Update the existing alert's destructive action:
```swift
.alert("Force Max Volume", isPresented: $showForceMaxConfirm) {
    Button("Cancel", role: .cancel) {}
    Button("Continue", role: .destructive) {
        Task { await viewModel.setVolumeMode(.forceMax) }
    }
} message: {
    Text(
        "This sets the macOS output volume for the selected device to 100% and removes software volume from the signal path. Lower the volume on your DAC, amp, or headphones first to avoid hearing damage."
    )
}
```

- [ ] **Step 4: Drop the old bindings**

Find and delete:
```swift
private var forceMaxVolumeBinding: Binding<Bool> { ... }
private var applyReplayGainEffectiveBinding: Binding<Bool> { ... }
```
in `SettingsView.swift`.

- [ ] **Step 5: Build + smoke test**

Run: `swift build`
Expected: clean.

Run: `swift test --filter SettingsViewTests`
Expected: PASS (smoke-render does not exercise picker semantics).

Run full suite: `swift test`
Expected: PASS. Adjust any view-model assertion that references `forceMaxVolumeEnabled` / `applyReplayGainEnabled` if they fail — most should be passing through transitional bridges.

- [ ] **Step 6: Manual UI check**

1. `swift run RPPlayer` (or run the built `.app` from PR 15 packaging script if cached).
2. Open Settings → Output device settings.
3. Verify: "Hog mode" toggle label has no "(bit-perfect)" suffix.
4. Verify: Volume row sits below Release on Pause; picker shows None / ReplayGain / Force Max.
5. Click ReplayGain → no alert; switches immediately.
6. Click Force Max with hog OFF → no transition (segment click ignored at binding level).
7. Enable hog, click Force Max → alert fires; Continue applies, Cancel reverts.
8. Hover the two ⓘ icons → tooltips match the strings above.

If you can't run the UI, say so explicitly in the commit message.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(volume): unified Volume picker in Settings

Replaces Force Max + ReplayGain toggles with a single segmented
picker. Force Max segment ignores clicks when Hog is OFF (rather
than being visually disabled, since SwiftUI segmented pickers do
not support per-segment disabled state). Bit-perfect lingo moves
into the Force Max tooltip."
```

---

## Task 6: AppContainer binder + remove transitional bridges

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Modify: `Sources/RPPlayer/Config/AppSettings.swift` (delete bridges)
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift` (delete bridges)
- Modify: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` (rewrite assertions)
- Modify: `Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift`

- [ ] **Step 1: Rewrite the binder to read volumeMode directly**

Open `AppContainer.swift`. Find the binder Task at lines ~250-358.

Replace the loop variables:
```swift
var lastForceMax = startupProfile.forceMaxVolumeEnabled
var lastEffectiveRG = startupProfile.applyReplayGainEnabled && !startupProfile.forceMaxVolumeEnabled
```
with:
```swift
var lastForceMax = startupProfile.volumeMode == .forceMax
var lastEffectiveRG = startupProfile.volumeMode == .replayGain
```

Replace the atomic-write on device switch (lines ~265-273):
```swift
s.forceMaxVolumeEnabled = profile.forceMaxVolumeEnabled
s.applyReplayGainEnabled = profile.applyReplayGainEnabled
```
with:
```swift
s.volumeMode = profile.volumeMode
```

The force-max re-evaluation guard at line ~283:
```swift
lastForceMax = !profile.forceMaxVolumeEnabled
```
becomes:
```swift
lastForceMax = !(profile.volumeMode == .forceMax)
```

The hog OFF→ON ground-truth check at lines ~317-328:
```swift
let hogTurnedOn = settings.hogModeEnabled && !lastHog
lastHog = settings.hogModeEnabled
if hogTurnedOn, let uid = settings.outputDeviceUID, !uid.isEmpty {
    let v = await volumeController.currentVolume(deviceUID: uid)
    let isMax = (v ?? 0) >= 0.999
    if isMax != settings.forceMaxVolumeEnabled {
        try? await store.update { $0.forceMaxVolumeEnabled = isMax }
        continue
    }
}
```
becomes:
```swift
let hogTurnedOn = settings.hogModeEnabled && !lastHog
lastHog = settings.hogModeEnabled
if hogTurnedOn, let uid = settings.outputDeviceUID, !uid.isEmpty {
    let v = await volumeController.currentVolume(deviceUID: uid)
    let isMax = (v ?? 0) >= 0.999
    let isForceMax = settings.volumeMode == .forceMax
    if isForceMax && !isMax {
        try? await store.update { $0.volumeMode = .none }
        continue
    }
}
```
(Behaviour preserved: when hog flips ON but device is not at max, user is downgraded to `.none` rather than silently re-pinning. When the device IS at max, the existing mode is preserved.)

The force-max-changed branch at lines ~329-340:
```swift
if settings.forceMaxVolumeEnabled != lastForceMax {
    try? await engine.setForceMaxVolume(settings.forceMaxVolumeEnabled)
    lastForceMax = settings.forceMaxVolumeEnabled
    if settings.forceMaxVolumeEnabled,
       let uid = settings.outputDeviceUID, !uid.isEmpty {
        _ = await volumeController.setVolumeMax(deviceUID: uid)
    }
} else if settings.forceMaxVolumeEnabled, deviceChanged,
          let uid = settings.outputDeviceUID, !uid.isEmpty {
    _ = await volumeController.setVolumeMax(deviceUID: uid)
}
```
becomes:
```swift
let nowForceMax = settings.volumeMode == .forceMax
if nowForceMax != lastForceMax {
    try? await engine.setForceMaxVolume(nowForceMax)
    lastForceMax = nowForceMax
    if nowForceMax, let uid = settings.outputDeviceUID, !uid.isEmpty {
        _ = await volumeController.setVolumeMax(deviceUID: uid)
    }
} else if nowForceMax, deviceChanged,
          let uid = settings.outputDeviceUID, !uid.isEmpty {
    _ = await volumeController.setVolumeMax(deviceUID: uid)
}
```

The effective-RG block at lines ~341-345:
```swift
let effectiveRG = settings.applyReplayGainEnabled && !settings.forceMaxVolumeEnabled
if effectiveRG != lastEffectiveRG {
    try? await engine.setApplyReplayGain(effectiveRG)
    lastEffectiveRG = effectiveRG
}
```
becomes:
```swift
let effectiveRG = settings.volumeMode == .replayGain
if effectiveRG != lastEffectiveRG {
    try? await engine.setApplyReplayGain(effectiveRG)
    lastEffectiveRG = effectiveRG
}
```
(The enum encodes the mutual exclusion — `.replayGain` already implies `not .forceMax` — so the `&& !forceMax` redundancy goes away.)

The profile atomic write at lines ~347-355:
```swift
s.audioProfiles[uid] = AudioProfile(
    hogModeEnabled: s.hogModeEnabled,
    releaseHogOnPauseEnabled: s.releaseHogOnPauseEnabled,
    forceMaxVolumeEnabled: s.forceMaxVolumeEnabled,
    applyReplayGainEnabled: s.applyReplayGainEnabled,
    bitrate: s.bitrate
)
```
becomes:
```swift
s.audioProfiles[uid] = AudioProfile(
    hogModeEnabled: s.hogModeEnabled,
    releaseHogOnPauseEnabled: s.releaseHogOnPauseEnabled,
    volumeMode: s.volumeMode,
    bitrate: s.bitrate
)
```

The state-stream subscriber's volume-pin at line ~375:
```swift
if state == .playing, s.forceMaxVolumeEnabled {
```
becomes:
```swift
if state == .playing, s.volumeMode == .forceMax {
```

The safety-wipe sites at lines ~118, 124, 196, 226, 415 (`$0.forceMaxVolumeEnabled = false`):
```swift
$0.forceMaxVolumeEnabled = false
```
becomes:
```swift
$0.volumeMode = .none
```
(In the `device disappeared` path the intent is to wipe back to safe defaults; switching to `.none` does that — the legacy code only cleared force-max but left ReplayGain alone, which was arguably a bug; clearing to `.none` is the conservative tightening.)

Find every other `forceMaxVolumeEnabled`/`applyReplayGainEnabled` reference in `AppContainer.swift` (line ~173 etc.) and replace accordingly:

Line 173:
```swift
let effectiveReplayGain = startupProfile.applyReplayGainEnabled && !startupProfile.forceMaxVolumeEnabled
```
becomes:
```swift
let effectiveReplayGain = startupProfile.volumeMode == .replayGain
```

Line 176:
```swift
initialForceMaxVolume: startupProfile.forceMaxVolumeEnabled,
```
becomes:
```swift
initialForceMaxVolume: startupProfile.volumeMode == .forceMax,
```

Line 196:
```swift
if startupProfile.forceMaxVolumeEnabled, let uid = initial.outputDeviceUID, !uid.isEmpty {
```
becomes:
```swift
if startupProfile.volumeMode == .forceMax, let uid = initial.outputDeviceUID, !uid.isEmpty {
```

Run `grep -n "forceMaxVolumeEnabled\|applyReplayGainEnabled" Sources/RPPlayer/App/AppContainer.swift` again — should return zero hits before commit.

- [ ] **Step 2: Delete the transitional bridges**

In `Sources/RPPlayer/Config/AppSettings.swift`: delete the `public extension AppSettings { var forceMaxVolumeEnabled: ... ; var applyReplayGainEnabled: ... }` block added in Task 3.

In `Sources/RPPlayer/Shell/SettingsViewModel.swift`: delete the `forceMaxVolumeEnabled`, `applyReplayGainEnabled`, `setForceMaxVolumeEnabled`, `setApplyReplayGainEnabled` helpers added in Task 4.

- [ ] **Step 3: Rewrite stale tests**

`Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` lines 32-33:
```swift
XCTAssertEqual(sut.forceMaxVolumeEnabled, AppSettings.default.forceMaxVolumeEnabled)
XCTAssertEqual(sut.applyReplayGainEnabled, AppSettings.default.applyReplayGainEnabled)
```
becomes:
```swift
XCTAssertEqual(sut.volumeMode, AppSettings.default.volumeMode)
```

`Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift` lines 37-38 (JSON-string assertions referencing legacy keys):
```swift
"forceMaxVolumeEnabled": false,
"applyReplayGainEnabled": false,
```
The intent is that the encoded JSON contains both keys. Since the new encoder omits them, this test needs rewriting to assert `"volumeMode":"none"` instead. Open the file, read context, update assertion.

Run: `grep -rn "forceMaxVolumeEnabled\|applyReplayGainEnabled" Sources Tests` — should return zero hits.

- [ ] **Step 4: Build + full test run**

Run: `swift build`
Expected: clean.

Run: `swift test`
Expected: full suite PASS. Test count: previous count + Tasks 1-4 added tests (VolumeModeTests +2, AudioProfileMigrationTests +7, AppSettingsVolumeModeMigrationTests +6, SettingsViewModelVolumeModeTests +4 = +19). Subtract any deleted/renamed tests if applicable. Expected total ~399 + 19 = 418.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift \
        Sources/RPPlayer/Config/AppSettings.swift \
        Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift \
        Tests/RPPlayerTests/Config/AppSettingsUpdateFieldsTests.swift
git commit -m "feat(volume): binder reads volumeMode + drop transitional bridges

AppContainer audio settings binder now reads AppSettings.volumeMode
directly. The previous dual-bool effective-RG calculation
(applyRG && !forceMax) collapses to a single equality check since
the enum encodes mutual exclusion at the type level. Hog-OFF→ON
ground-truth check downgrades volumeMode .forceMax → .none when the
device is not at max. Transitional bool bridges from Tasks 3-4 are
removed."
```

---

## Task 7: Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: CHANGELOG entry**

Open `CHANGELOG.md`. Under `## [Unreleased]` (create the heading if absent), add:

```markdown
### Changed
- Settings → Output device settings: replaces the "Force Max Volume" + "Apply ReplayGain" toggles with a single 3-state Volume picker (`None` / `ReplayGain ⓘ` / `Force Max ⓘ`). Force Max segment ignores selection when Hog Mode is off; same destructive-confirmation alert fires on transition into Force Max. Bit-perfect lingo moves from the Hog row label to the Force Max tooltip ("Bit-perfect when EQ is off").
- AppSettings + AudioProfile: replaces `forceMaxVolumeEnabled` + `applyReplayGainEnabled` bool pair with a single `volumeMode: VolumeMode` enum (`none` / `replayGain` / `forceMax`). Legacy JSON migrates automatically on first decode (Force Max wins on conflict). Encoded JSON omits the legacy keys.
```

- [ ] **Step 2: CLAUDE.md updates**

Open `CLAUDE.md`. Find the *Audio pipeline* subsection under *Key technical decisions*. Update the **Force-Max Volume** bullet to reference the enum, and the **Apply ReplayGain** bullet to drop the `&& !forceMaxVolumeEnabled` redundancy mention since the enum encodes mutual exclusion.

Add to the PR status table at the end:
```markdown
| 34   | claude/pr34-volume-mode-picker | ⏳ | Volume picker rework: AppSettings + AudioProfile drop `forceMaxVolumeEnabled` + `applyReplayGainEnabled` bool pair in favor of single `volumeMode: VolumeMode` enum (`none` / `replayGain` / `forceMax`); JSON decode migrates legacy bools (force-max wins). SettingsView replaces two toggles with a single 3-state segmented picker; Force Max segment ignores clicks when Hog OFF; destructive-confirmation alert on transition into Force Max preserved. Hog OFF→ON ground-truth check downgrades volumeMode `.forceMax → .none` when device volume is below max. AppContainer binder reads enum directly — the dual-bool effective-RG calculation collapses to a single equality check. "(bit-perfect)" suffix removed from Hog toggle label; the claim moves into the Force Max ⓘ tooltip. |
```

Update the *Test counts by PR* section with a new bottom line:
```markdown
- After PR 34 Volume mode picker — adds `VolumeMode` enum + migration paths on `AppSettings` and `AudioProfile` (legacy `forceMaxVolumeEnabled` + `applyReplayGainEnabled` decoded into the enum at load time, written back only as `volumeMode`); `SettingsViewModel` drops two bool published vars + setters for one `volumeMode: VolumeMode` + `setVolumeMode(_:)`; SettingsView replaces two toggles with segmented `Picker`; AppContainer binder reads enum directly (effective-RG collapses to `volumeMode == .replayGain`); hog OFF→ON ground-truth check downgrades `.forceMax → .none` when device not at max. New tests: 2 enum codable, 7 AudioProfile migration, 6 AppSettings migration, 4 VM volumeMode surface. 399 → ~418.
```

(Adjust final number after Task 6 actual test count.)

- [ ] **Step 3: Run full suite a final time**

Run: `swift test`
Expected: full suite PASS.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs: PR 34 changelog + status table + audio pipeline notes"
```

---

## Self-Review Notes (during writing)

- Spec coverage: VolumeMode enum ✅; AudioProfile + AppSettings migration ✅; VM surface + setter ✅; SettingsView segmented picker ✅; Force Max alert + hog-disabled guard ✅; Hog OFF→ON ground-truth downgrade ✅; bit-perfect lingo into Force Max tooltip ✅; ReplayGain tooltip ✅; AppContainer binder ✅; legacy-key encoding stripped ✅; CHANGELOG + CLAUDE.md ✅.
- Placeholder scan: no TBD/TODO/"appropriate" left in steps. Each step shows the exact code change.
- Type consistency: `VolumeMode` enum cases (`.none / .replayGain / .forceMax`) used identically across tasks; `setVolumeMode(_:)` method name stable; transitional bridge names match between Task 3 (`AppSettings` extension) and Task 4 (`SettingsViewModel`).

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-12-volume-mode-picker.md`.**

Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
