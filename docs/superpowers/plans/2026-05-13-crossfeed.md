# PR 36 — Crossfeed for headphone listening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-device Bauer-style crossfeed via the ffmpeg `crossfeed` filter, composed orthogonally with the parametric EQ from PR 35 inside a single `mpv af` filter chain.

**Architecture:** Per-device `AudioProfile` gains three flat fields (`crossfeedEnabled`, `crossfeedStrength`, `crossfeedRange`). The existing EQ binder is renamed to `runAudioFilterBinder` and now diff-tracks a 5-tuple; `EqChainBuilder.build` is split so it returns an array of filter parts, and a new `CrossfeedFilterBuilder.buildPart(strength:range:)` produces a single `crossfeed=...` fragment. The binder concatenates the EQ parts and the crossfeed part (in that order: preamp → EQ bands → crossfeed) and wraps them in `lavfi=[...]`. UI lives in `SettingsView` as a new inline row matching the post-PR-35 EQ row layout, with two custom `ClampedNumericField` stepper-inputs and a single `HoverInfoIcon` tooltip.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, libmpv 0.36 (`audio-encodersgpl` variant — `crossfeed` filter confirmed present), XCTest, `@testable import RPPlayer`.

**Spec:** `docs/superpowers/specs/2026-05-13-crossfeed.md`.

**Tests delta target:** 462 → ~484 (+22 new functional tests).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift` | Build the single `crossfeed=strength=...:range=...` lavfi fragment. Pure function; no state. |
| `Sources/RPPlayer/Shell/ClampedNumericField.swift` | SwiftUI view: numeric `TextField` + native `Stepper`, range/step clamping, red-glow invalid state, snap-back on focus loss. |
| `Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift` | Builder format + clamping tests. |
| `Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift` | New-field defaults + round-trip + preserves PR-34 / PR-35 migration paths. |
| `Tests/RPPlayerTests/Shell/SettingsViewModelCrossfeedTests.swift` | VM published-prop initial values + setter writethrough. |
| `Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift` | Helper-level validation logic (parse + clamp + last-valid snap-back). |

### Renamed files

| Old | New |
|---|---|
| `Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift` | `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift` |

### Modified files

| Path | Change |
|---|---|
| `Sources/RPPlayer/Config/AudioProfile.swift` | +3 fields (`crossfeedEnabled` / `crossfeedStrength` / `crossfeedRange`), `safeDefault` extended, Codable `init(from:)` + `encode(to:)` extended. |
| `Sources/RPPlayer/Config/EqChainBuilder.swift` | Rename `build(_:) -> String?` → `buildParts(_:) -> [String]`. Drop the `lavfi=[...]` wrapper; caller wraps now. |
| `Sources/RPPlayer/App/AppContainer.swift` | Rename `runEqBinder` → `runAudioFilterBinder` and `applyEqState` → `applyAudioFilterState`. Extend snapshot diff to 5-tuple. Builder now concatenates EQ + crossfeed parts. Profile write-back gains 3 `existing.crossfeed*` passthroughs. |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | +3 `@Published` props + 3 setters. Start-stream block reads crossfeed from active profile. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | New "Crossfeed" row in `deviceSettingsSection`, directly after EQ row. |
| `Sources/RPSmoke/main.swift` | Add `("crossfeed", "lavfi=[crossfeed=strength=0.2:range=0.5]")` to the `probes` array. |
| `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift` | Switch from `build` (returns `String?`) to `buildParts` (returns `[String]`). All 6 existing tests rewritten. |
| `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift` | Renamed class. Existing 2 tests retained + adjusted for new builder API. 4 new tests added for crossfeed paths. |
| `CHANGELOG.md` | New entry under `## [Unreleased]` → `### Added`. |
| `CLAUDE.md` | PR 36 row in status table; new entry in *Test counts by PR*; *Key technical decisions* updates for chain order + crossfeed. |

---

## Task ordering rationale

Bottom-up TDD: pure builders first (no dependencies), then data model (Codable migration), then composition root (binder), then VM, then UI, then docs. Each task ends with a green `swift test` + a commit. Branch is `claude/pr36-crossfeed`.

---

### Task 1: Create feature branch

**Files:**
- No code changes.

- [ ] **Step 1: Create branch off main**

```bash
git checkout -b claude/pr36-crossfeed main
```

- [ ] **Step 2: Verify clean tree + correct base**

```bash
git status
git log --oneline -1
```

Expected: `working tree clean`, HEAD on the PR 35 merge commit (`8f2bff0` or later — verify against `git log main --oneline -1`).

---

### Task 2: CrossfeedFilterBuilder — failing test

**Files:**
- Create: `Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift
import XCTest
@testable import RPPlayer

final class CrossfeedFilterBuilderTests: XCTestCase {
    func testDefaultsFormat() {
        let part = CrossfeedFilterBuilder.buildPart(strength: 0.2, range: 0.5)
        XCTAssertEqual(part, "crossfeed=strength=0.2:range=0.5")
    }

    func testNonDefaultValuesUseTrimmedFractions() {
        let part = CrossfeedFilterBuilder.buildPart(strength: 0.45, range: 0.875)
        XCTAssertEqual(part, "crossfeed=strength=0.45:range=0.875")
    }

    func testOutOfRangeValuesAreClamped() {
        // Defense-in-depth: UI's Stepper already clamps, but builder must too.
        let low = CrossfeedFilterBuilder.buildPart(strength: -0.5, range: -2.0)
        XCTAssertEqual(low, "crossfeed=strength=0:range=0")

        let high = CrossfeedFilterBuilder.buildPart(strength: 1.5, range: 99.0)
        XCTAssertEqual(high, "crossfeed=strength=1:range=1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter CrossfeedFilterBuilderTests 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'CrossfeedFilterBuilder' in scope`.

---

### Task 3: CrossfeedFilterBuilder — implementation

**Files:**
- Create: `Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift`

- [ ] **Step 1: Implement builder**

```swift
// Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift
import Foundation

public enum CrossfeedFilterBuilder {
    public static func buildPart(strength: Double, range: Double) -> String {
        let s = format(clamp(strength))
        let r = format(clamp(range))
        return "crossfeed=strength=\(s):range=\(r)"
    }

    private static func clamp(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return min(1.0, max(0.0, v))
    }

    private static func format(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(v)) }
        let s = String(format: "%.4f", v)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
```

The `format` helper mirrors `EqChainBuilder.format` byte-for-byte so the chain has consistent number formatting throughout. (Don't try to dedupe yet — splitting into a shared formatter is yagni at one duplication.)

- [ ] **Step 2: Run tests to verify they pass**

```bash
swift test --filter CrossfeedFilterBuilderTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift \
        Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift
git commit -m "feat(crossfeed): CrossfeedFilterBuilder for lavfi fragment"
```

---

### Task 4: EqChainBuilder.buildParts — rewrite existing tests

**Files:**
- Modify: `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift`

- [ ] **Step 1: Rewrite all 6 tests against the new array-returning signature**

Replace the file body with:

```swift
import XCTest
@testable import RPPlayer

final class EqChainBuilderTests: XCTestCase {
    func testEmptyBandsAndZeroPreampReturnsEmptyArray() {
        let preset = EqPreset(name: nil, preampDb: 0, bands: [])
        XCTAssertEqual(EqChainBuilder.buildParts(preset), [])
    }

    func testPreampOnly() {
        let preset = EqPreset(name: nil, preampDb: -2.5, bands: [])
        XCTAssertEqual(EqChainBuilder.buildParts(preset), ["volume=volume=-2.5dB"])
    }

    func testPeakBand() {
        let preset = EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 2.0, q: 1.4)]
        )
        XCTAssertEqual(
            EqChainBuilder.buildParts(preset),
            ["volume=volume=0dB", "equalizer=f=1000:t=q:w=1.4:g=2"]
        )
    }

    func testMixedBands() {
        let preset = EqPreset(
            name: nil, preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        XCTAssertEqual(
            EqChainBuilder.buildParts(preset),
            [
                "volume=volume=-1.2dB",
                "lowshelf=f=83:t=q:w=0.82:g=1.2",
                "equalizer=f=300:t=q:w=0.6:g=-1.6",
                "highshelf=f=8000:t=q:w=0.7:g=-0.8",
            ]
        )
    }

    func testDisabledBandsSkipped() {
        let preset = EqPreset(
            name: nil, preampDb: 0,
            bands: [
                EqBand(enabled: false, type: .peak, fcHz: 1000, gainDb: 2, q: 1),
                EqBand(enabled: true, type: .peak, fcHz: 2000, gainDb: 3, q: 1),
            ]
        )
        XCTAssertEqual(
            EqChainBuilder.buildParts(preset),
            ["volume=volume=0dB", "equalizer=f=2000:t=q:w=1:g=3"]
        )
    }

    func testNegativePreampUsesExplicitKeyValue() {
        let preset = EqPreset(
            name: nil, preampDb: -1.2,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 0, q: 1)]
        )
        let parts = EqChainBuilder.buildParts(preset)
        XCTAssertEqual(parts, ["volume=volume=-1.2dB", "equalizer=f=1000:t=q:w=1:g=0"])
        // The explicit `volume=volume=` form is required because ffmpeg's lavfi
        // graph parser treats positional values starting with `-` as ambiguous
        // with flag syntax. Keep this as a regression guard.
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (builder not yet refactored)**

```bash
swift test --filter EqChainBuilderTests 2>&1 | tail -20
```

Expected: compile failure — `cannot find 'buildParts' in scope` (or similar).

---

### Task 5: EqChainBuilder.buildParts — refactor implementation

**Files:**
- Modify: `Sources/RPPlayer/Config/EqChainBuilder.swift`
- Modify: `Sources/RPPlayer/App/AppContainer.swift` (one caller site — line ~627 in `applyEqState`)

- [ ] **Step 1: Rewrite EqChainBuilder**

Replace the file body with:

```swift
import Foundation

public enum EqChainBuilder {
    public static func buildParts(_ preset: EqPreset) -> [String] {
        let enabled = preset.bands.filter(\.enabled)
        if enabled.isEmpty && preset.preampDb == 0 { return [] }
        var parts: [String] = ["volume=volume=\(format(preset.preampDb))dB"]
        for b in enabled {
            switch b.type {
            case .peak:
                parts.append("equalizer=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            case .lowShelf:
                parts.append("lowshelf=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            case .highShelf:
                parts.append("highshelf=f=\(format(b.fcHz)):t=q:w=\(format(b.q)):g=\(format(b.gainDb))")
            }
        }
        return parts
    }

    private static func format(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(v)) }
        let s = String(format: "%.4f", v)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
```

- [ ] **Step 2: Update the single caller in AppContainer.applyEqState**

In `Sources/RPPlayer/App/AppContainer.swift`, locate the `case .success(let preset):` line inside `applyEqState` (around line 627) and replace its body:

```swift
case .success(let preset):
    let parts = EqChainBuilder.buildParts(preset)
    if parts.isEmpty {
        try? await engine.setAudioFilterChain(nil)
    } else {
        try? await engine.setAudioFilterChain("lavfi=[" + parts.joined(separator: ",") + "]")
    }
```

(This caller will be replaced wholesale in Task 8 when the binder rewrites; the interim version keeps the build green between tasks.)

- [ ] **Step 3: Run all EqChainBuilder tests to verify they pass**

```bash
swift test --filter EqChainBuilderTests 2>&1 | tail -10
```

Expected: 6 tests pass.

- [ ] **Step 4: Run full suite to confirm no other site broke**

```bash
swift test 2>&1 | tail -5
```

Expected: 462 tests pass (no new tests yet; the `EqChainBuilderTests` count is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqChainBuilder.swift \
        Sources/RPPlayer/App/AppContainer.swift \
        Tests/RPPlayerTests/Config/EqChainBuilderTests.swift
git commit -m "refactor(eq): EqChainBuilder.build -> buildParts (array return)"
```

---

### Task 6: AudioProfile crossfeed fields — failing test

**Files:**
- Create: `Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift
import XCTest
@testable import RPPlayer

final class AudioProfileCrossfeedMigrationTests: XCTestCase {
    func testDefaultsWhenKeysAbsent() throws {
        let json = """
        {
            "hogModeEnabled": true,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "none",
            "bitrate": 4
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
    }

    func testRoundTrip() throws {
        let original = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: false,
            volumeMode: .replayGain,
            bitrate: 3,
            eqEnabled: true,
            eqPresetName: "my-preset",
            crossfeedEnabled: true,
            crossfeedStrength: 0.35,
            crossfeedRange: 0.65
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testExistingEqOnlyProfileUnchangedAfterUpgrade() throws {
        // Simulates a profile saved by PR 35 (no crossfeed keys yet).
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "forceMax",
            "bitrate": 4,
            "eqEnabled": true,
            "eqPresetName": "harman"
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertTrue(profile.eqEnabled)
        XCTAssertEqual(profile.eqPresetName, "harman")
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
        XCTAssertEqual(profile.volumeMode, .forceMax)
    }

    func testLegacyBoolMigrationStillWorks() throws {
        // PR 34 migration path: legacy forceMaxVolumeEnabled bool with no volumeMode.
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": false,
            "forceMaxVolumeEnabled": true,
            "applyReplayGainEnabled": true,
            "bitrate": 3
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(profile.volumeMode, .forceMax)
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter AudioProfileCrossfeedMigrationTests 2>&1 | tail -20
```

Expected: compile failure — `extra arguments at positions #6, #7, #8 in call` (or similar) for `AudioProfile.init` because the three new fields don't exist yet.

---

### Task 7: AudioProfile crossfeed fields — implementation

**Files:**
- Modify: `Sources/RPPlayer/Config/AudioProfile.swift`

- [ ] **Step 1: Replace the file body with the extended struct**

```swift
import Foundation

public struct AudioProfile: Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var volumeMode: VolumeMode
    public var bitrate: Int
    public var eqEnabled: Bool
    public var eqPresetName: String?
    public var crossfeedEnabled: Bool
    public var crossfeedStrength: Double
    public var crossfeedRange: Double

    public init(
        hogModeEnabled: Bool,
        releaseHogOnPauseEnabled: Bool,
        volumeMode: VolumeMode,
        bitrate: Int,
        eqEnabled: Bool = false,
        eqPresetName: String? = nil,
        crossfeedEnabled: Bool = false,
        crossfeedStrength: Double = 0.2,
        crossfeedRange: Double = 0.5
    ) {
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.volumeMode = volumeMode
        self.bitrate = bitrate
        self.eqEnabled = eqEnabled
        self.eqPresetName = eqPresetName
        self.crossfeedEnabled = crossfeedEnabled
        self.crossfeedStrength = crossfeedStrength
        self.crossfeedRange = crossfeedRange
    }

    public static let safeDefault = AudioProfile(
        hogModeEnabled: false,
        releaseHogOnPauseEnabled: false,
        volumeMode: .none,
        bitrate: 3,
        eqEnabled: false,
        eqPresetName: nil,
        crossfeedEnabled: false,
        crossfeedStrength: 0.2,
        crossfeedRange: 0.5
    )
}

extension AudioProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case hogModeEnabled
        case releaseHogOnPauseEnabled
        case volumeMode
        case bitrate
        case eqEnabled
        case eqPresetName
        case crossfeedEnabled
        case crossfeedStrength
        case crossfeedRange
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
        self.eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? false
        self.eqPresetName = try c.decodeIfPresent(String.self, forKey: .eqPresetName)
        self.crossfeedEnabled = try c.decodeIfPresent(Bool.self, forKey: .crossfeedEnabled) ?? false
        self.crossfeedStrength = try c.decodeIfPresent(Double.self, forKey: .crossfeedStrength) ?? 0.2
        self.crossfeedRange = try c.decodeIfPresent(Double.self, forKey: .crossfeedRange) ?? 0.5
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
        try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
        try c.encode(volumeMode, forKey: .volumeMode)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encode(eqEnabled, forKey: .eqEnabled)
        try c.encodeIfPresent(eqPresetName, forKey: .eqPresetName)
        try c.encode(crossfeedEnabled, forKey: .crossfeedEnabled)
        try c.encode(crossfeedStrength, forKey: .crossfeedStrength)
        try c.encode(crossfeedRange, forKey: .crossfeedRange)
    }
}
```

- [ ] **Step 2: Run new migration tests to verify they pass**

```bash
swift test --filter AudioProfileCrossfeedMigrationTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 3: Run full suite to confirm no regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: 466 tests pass (462 baseline + 4 new). All existing `AudioProfile` users compile because the three new init params have defaults.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Config/AudioProfile.swift \
        Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift
git commit -m "feat(crossfeed): AudioProfile crossfeed fields + Codable migration"
```

---

### Task 8: Rename EQ binder tests → AudioFilter binder tests

**Files:**
- Rename: `Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift` → `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`

- [ ] **Step 1: Git-rename the file**

```bash
git mv Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift \
       Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift
```

- [ ] **Step 2: Update the class name + retained `runEqBinder` references**

Replace `final class AppContainerEqBinderTests` with `final class AppContainerAudioFilterBinderTests` at line 5. Replace both `AppContainer.runEqBinder(` invocations (lines ~39 and ~99) with `AppContainer.runAudioFilterBinder(` — same parameter list.

Use this single Edit pattern:

```
old: final class AppContainerEqBinderTests: XCTestCase {
new: final class AppContainerAudioFilterBinderTests: XCTestCase {
```

Then two more edits, one per `runEqBinder` call:

```
old: await AppContainer.runEqBinder(
new: await AppContainer.runAudioFilterBinder(
```

(The body of the call remains the same — same param names: `store:`, `engine:`, `eqPresetStore:`, `initialProfile:`.)

- [ ] **Step 3: Run tests to verify they fail because runAudioFilterBinder doesn't exist yet**

```bash
swift test --filter AppContainerAudioFilterBinderTests 2>&1 | tail -10
```

Expected: compile failure — `type 'AppContainer' has no member 'runAudioFilterBinder'`.

---

### Task 9: Rename binder + extend for crossfeed — implementation

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

This is the largest single change in the PR. The binder is renamed, the snapshot diff key becomes a 5-tuple, and the chain-building function consumes both EQ and crossfeed state.

- [ ] **Step 1: Replace `runEqBinder` + `applyEqState` with `runAudioFilterBinder` + `applyAudioFilterState`**

Locate the existing `internal static func runEqBinder(...)` and `internal static func applyEqState(...)` block in `AppContainer.swift` (around lines 592–634) and replace it with:

```swift
internal static func runAudioFilterBinder(
    store: any ConfigStore,
    engine: any PlayerEngine,
    eqPresetStore: any EqPresetStore,
    initialProfile: AudioProfile
) async {
    var last = AudioFilterKey(profile: initialProfile)
    await applyAudioFilterState(engine: engine, store: eqPresetStore, key: last)

    for await snapshot in await store.changes {
        let uid = snapshot.outputDeviceUID
        let profile = uid.flatMap { snapshot.audioProfiles[$0] } ?? AudioProfile.safeDefault
        let next = AudioFilterKey(profile: profile)
        if next != last {
            last = next
            await applyAudioFilterState(engine: engine, store: eqPresetStore, key: next)
        }
    }
}

internal static func applyAudioFilterState(
    engine: any PlayerEngine,
    store: any EqPresetStore,
    key: AudioFilterKey
) async {
    var parts: [String] = []
    if key.eqEnabled, let name = key.eqPresetName {
        do {
            let raw = try await store.loadText(name: name)
            if case .success(let preset) = EqPresetParser.parse(text: raw, filename: name) {
                parts = EqChainBuilder.buildParts(preset)
            }
        } catch {
            // File missing or unreadable → EQ contributes nothing. Crossfeed may still apply below.
        }
    }
    if key.crossfeedEnabled {
        parts.append(CrossfeedFilterBuilder.buildPart(
            strength: key.crossfeedStrength,
            range: key.crossfeedRange
        ))
    }
    if parts.isEmpty {
        try? await engine.setAudioFilterChain(nil)
    } else {
        try? await engine.setAudioFilterChain("lavfi=[" + parts.joined(separator: ",") + "]")
    }
}

internal struct AudioFilterKey: Equatable {
    let eqEnabled: Bool
    let eqPresetName: String?
    let crossfeedEnabled: Bool
    let crossfeedStrength: Double
    let crossfeedRange: Double

    init(profile: AudioProfile) {
        self.eqEnabled = profile.eqEnabled
        self.eqPresetName = profile.eqPresetName
        self.crossfeedEnabled = profile.crossfeedEnabled
        self.crossfeedStrength = profile.crossfeedStrength
        self.crossfeedRange = profile.crossfeedRange
    }
}
```

Removal note: the previous `applyEqState` had `engine.setAudioFilterChain(EqChainBuilder.build(preset))`. Task 5 already changed that to `buildParts` + interim wrapping; this task replaces the wrapping logic entirely. Drop the interim wrapper code from `applyEqState`.

- [ ] **Step 2: Update the binder spawn site**

Find the `Task { [engine, eqPresetStore, store] in ... AppContainer.runEqBinder(...)` block (around line 411–418 of `AppContainer.swift`). Replace `runEqBinder` with `runAudioFilterBinder`. Param list is unchanged.

```swift
Task { [engine, eqPresetStore, store] in
    await AppContainer.runAudioFilterBinder(
        store: store,
        engine: engine,
        eqPresetStore: eqPresetStore,
        initialProfile: startupProfile
    )
}
```

- [ ] **Step 3: Run renamed binder tests to verify they pass**

```bash
swift test --filter AppContainerAudioFilterBinderTests 2>&1 | tail -10
```

Expected: 2 tests pass (the existing EQ-only paths still work — crossfeed defaults to off so no new behavior triggers).

- [ ] **Step 4: Run full suite to confirm no regressions**

```bash
swift test 2>&1 | tail -5
```

Expected: 466 tests pass (no test count change — renames don't add tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift \
        Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift
git commit -m "refactor(audio): runEqBinder -> runAudioFilterBinder, key tuple"
```

---

### Task 10: Profile write-back patch — preserve crossfeed across non-crossfeed changes

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

The volume / hog binder has a per-iteration write-back that reconstructs the active `AudioProfile` from top-level settings + existing EQ fields. After Task 7 the `AudioProfile.init` signature has three additional crossfeed params; without an explicit passthrough they would silently default to `(false, 0.2, 0.5)` whenever the user toggles volume mode or hog mode — wiping any crossfeed state the user set.

- [ ] **Step 1: Patch the write-back constructor**

Locate the `s.audioProfiles[uid] = AudioProfile(...)` block in `AppContainer.swift` (around lines 360–368 — inside the `Task { [hogController, volumeController, store] ... }` loop). Replace the constructor call with:

```swift
let existing = s.audioProfiles[uid] ?? AudioProfile.safeDefault
s.audioProfiles[uid] = AudioProfile(
    hogModeEnabled: s.hogModeEnabled,
    releaseHogOnPauseEnabled: s.releaseHogOnPauseEnabled,
    volumeMode: s.volumeMode,
    bitrate: s.bitrate,
    eqEnabled: existing.eqEnabled,
    eqPresetName: existing.eqPresetName,
    crossfeedEnabled: existing.crossfeedEnabled,
    crossfeedStrength: existing.crossfeedStrength,
    crossfeedRange: existing.crossfeedRange
)
```

- [ ] **Step 2: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 466 tests still pass.

(The behavior change is exercised end-to-end in Task 11's new binder tests; no dedicated unit for this passthrough — it's defensive plumbing.)

---

### Task 11: Crossfeed binder paths — new tests

**Files:**
- Modify: `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`

Add four new tests to the renamed test class. They drive the binder through crossfeed-only, both-on, both-off, and crossfeed-preservation-across-volume-change scenarios.

- [ ] **Step 1: Append the new tests**

Insert these four methods just before the closing `}` of `final class AppContainerAudioFilterBinderTests`:

```swift
func testCrossfeedOnlyEmitsCrossfeedChain() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: false, eqPresetName: nil,
        crossfeedEnabled: true,
        crossfeedStrength: 0.35,
        crossfeedRange: 0.55
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let binderTask = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            initialProfile: initialProfile
        )
    }
    defer { binderTask.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call {
                return chain == "lavfi=[crossfeed=strength=0.35:range=0.55]"
            }
            return false
        }
    }, timeout: 1.0)
}

func testEqAndCrossfeedEmitCombinedChainInOrder() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await eqStore.save(
        name: "combo-preset",
        text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n",
        overwrite: false
    )
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: true, eqPresetName: "combo-preset",
        crossfeedEnabled: true,
        crossfeedStrength: 0.4,
        crossfeedRange: 0.5
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let binderTask = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            initialProfile: initialProfile
        )
    }
    defer { binderTask.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        // Expected order: preamp (volume) → EQ band → crossfeed.
        let expected = "lavfi=[volume=volume=0dB,equalizer=f=1000:t=q:w=1:g=2,crossfeed=strength=0.4:range=0.5]"
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call { return chain == expected }
            return false
        }
    }, timeout: 1.0)
}

func testBothOffClearsChain() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: false, eqPresetName: nil,
        crossfeedEnabled: false,
        crossfeedStrength: 0.2,
        crossfeedRange: 0.5
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let binderTask = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            initialProfile: initialProfile
        )
    }
    defer { binderTask.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call { return chain == nil }
            return false
        }
    }, timeout: 1.0)
}

func testStrengthChangeRewritesChain() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: false, eqPresetName: nil,
        crossfeedEnabled: true,
        crossfeedStrength: 0.2,
        crossfeedRange: 0.5
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let binderTask = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            initialProfile: initialProfile
        )
    }
    defer { binderTask.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call {
                return chain == "lavfi=[crossfeed=strength=0.2:range=0.5]"
            }
            return false
        }
    }, timeout: 1.0)

    try await configStore.update {
        $0.audioProfiles["dev-A"]?.crossfeedStrength = 0.6
    }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call {
                return chain == "lavfi=[crossfeed=strength=0.6:range=0.5]"
            }
            return false
        }
    }, timeout: 1.0)
}
```

- [ ] **Step 2: Run new binder tests to verify they pass**

```bash
swift test --filter AppContainerAudioFilterBinderTests 2>&1 | tail -10
```

Expected: 6 tests pass (2 existing + 4 new).

- [ ] **Step 3: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 470 tests pass (466 + 4 new).

- [ ] **Step 4: Commit**

```bash
git add Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift
git commit -m "test(crossfeed): binder paths for crossfeed-only and combined chain"
```

---

### Task 12: SettingsViewModel surface — failing test

**Files:**
- Create: `Tests/RPPlayerTests/Shell/SettingsViewModelCrossfeedTests.swift`

- [ ] **Step 1: Write failing tests**

Use the existing `SettingsTestStubs.swift` helpers (already in `Tests/RPPlayerTests/Shell/`). The pattern below mirrors `SettingsViewModelTests.swift` and `SettingsViewModelVolumeModeTests.swift`.

```swift
// Tests/RPPlayerTests/Shell/SettingsViewModelCrossfeedTests.swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelCrossfeedTests: XCTestCase {
    private func makeVM(initial: AppSettings) -> (SettingsViewModel, StubConfigStore) {
        let store = StubConfigStore(initial: initial)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubAudioDeviceCatalog(),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {},
            listChannels: { [] },
            updateChecker: NoopUpdateChecker(),
            eqPresetStore: NoopEqPresetStore(),
            logger: nil
        )
        return (vm, store)
    }

    func testInitialPropsReflectActiveProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = AudioProfile(
            hogModeEnabled: false,
            releaseHogOnPauseEnabled: false,
            volumeMode: .none,
            bitrate: 3,
            eqEnabled: false,
            eqPresetName: nil,
            crossfeedEnabled: true,
            crossfeedStrength: 0.35,
            crossfeedRange: 0.65
        )
        let (vm, _) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        try await waitUntil({ await vm.crossfeedEnabled == true }, timeout: 1.0)
        XCTAssertEqual(vm.crossfeedStrength, 0.35, accuracy: 1e-9)
        XCTAssertEqual(vm.crossfeedRange, 0.65, accuracy: 1e-9)
    }

    func testSetCrossfeedEnabledWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let (vm, store) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        await vm.setCrossfeedEnabled(true)
        let s = await store.settings
        XCTAssertTrue(s.audioProfiles["dev-A"]?.crossfeedEnabled ?? false)
    }

    func testSetCrossfeedStrengthWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let (vm, store) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        await vm.setCrossfeedStrength(0.45)
        let s = await store.settings
        XCTAssertEqual(s.audioProfiles["dev-A"]?.crossfeedStrength ?? 0, 0.45, accuracy: 1e-9)
    }

    func testSetCrossfeedRangeWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let (vm, store) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        await vm.setCrossfeedRange(0.75)
        let s = await store.settings
        XCTAssertEqual(s.audioProfiles["dev-A"]?.crossfeedRange ?? 0, 0.75, accuracy: 1e-9)
    }

    func testSettersClampOutOfRangeInput() async throws {
        // UI's Stepper(in: 0.0...1.0) should already prevent this, but the VM
        // is the last write-through guard — keep the value in range regardless.
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let (vm, store) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        await vm.setCrossfeedStrength(1.7)
        await vm.setCrossfeedRange(-0.3)
        let s = await store.settings
        XCTAssertEqual(s.audioProfiles["dev-A"]?.crossfeedStrength ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.audioProfiles["dev-A"]?.crossfeedRange ?? 0, 0.0, accuracy: 1e-9)
    }

    func testSettersAreNoOpWithoutSelectedDevice() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = nil
        let (vm, store) = makeVM(initial: settings)
        await vm.start()
        defer { Task { await vm.stop() } }

        await vm.setCrossfeedEnabled(true)
        await vm.setCrossfeedStrength(0.4)
        await vm.setCrossfeedRange(0.6)
        let s = await store.settings
        XCTAssertTrue(s.audioProfiles.isEmpty)
    }
}
```

If `NoopEqPresetStore` isn't yet available in `SettingsTestStubs.swift`, search for the constructor pattern used by `SettingsViewModelTests` and reuse the same approach (likely `LiveEqPresetStore(directory: <tmp>)` with a per-test temp dir). The intent here is to construct the VM at all — the EQ preset store is irrelevant to these tests.

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter SettingsViewModelCrossfeedTests 2>&1 | tail -10
```

Expected: compile failure — `value of type 'SettingsViewModel' has no member 'crossfeedEnabled'`.

---

### Task 13: SettingsViewModel surface — implementation

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`

- [ ] **Step 1: Add three `@Published` properties next to the existing EQ props**

Locate the EQ-prop block (lines ~29–31) and append three lines:

```swift
@Published public private(set) var eqEnabled: Bool = false
@Published public private(set) var eqPresetName: String?
@Published public private(set) var availablePresets: [String] = []
@Published public private(set) var crossfeedEnabled: Bool = false
@Published public private(set) var crossfeedStrength: Double = 0.2
@Published public private(set) var crossfeedRange: Double = 0.5
```

- [ ] **Step 2: Sync from the active profile in `start()`**

Locate the line `self.eqPresetName = profile?.eqPresetName` (around line 138) and append three lines:

```swift
self.eqEnabled = profile?.eqEnabled ?? false
self.eqPresetName = profile?.eqPresetName
self.crossfeedEnabled = profile?.crossfeedEnabled ?? false
self.crossfeedStrength = profile?.crossfeedStrength ?? 0.2
self.crossfeedRange = profile?.crossfeedRange ?? 0.5
```

- [ ] **Step 3: Add three setters next to `setEqEnabled` / `setEqPresetName`**

Locate `public func setEqPresetName` (around line 341) and add immediately after its closing `}`:

```swift
public func setCrossfeedEnabled(_ value: Bool) async {
    logger?.debug("setCrossfeedEnabled value=\(value)")
    await update { s in
        guard let uid = s.outputDeviceUID else { return }
        var p = s.audioProfiles[uid] ?? .safeDefault
        p.crossfeedEnabled = value
        s.audioProfiles[uid] = p
    }
}

public func setCrossfeedStrength(_ value: Double) async {
    let clamped = min(1.0, max(0.0, value))
    logger?.debug("setCrossfeedStrength value=\(clamped)")
    await update { s in
        guard let uid = s.outputDeviceUID else { return }
        var p = s.audioProfiles[uid] ?? .safeDefault
        p.crossfeedStrength = clamped
        s.audioProfiles[uid] = p
    }
}

public func setCrossfeedRange(_ value: Double) async {
    let clamped = min(1.0, max(0.0, value))
    logger?.debug("setCrossfeedRange value=\(clamped)")
    await update { s in
        guard let uid = s.outputDeviceUID else { return }
        var p = s.audioProfiles[uid] ?? .safeDefault
        p.crossfeedRange = clamped
        s.audioProfiles[uid] = p
    }
}
```

- [ ] **Step 4: Run new VM tests to verify they pass**

```bash
swift test --filter SettingsViewModelCrossfeedTests 2>&1 | tail -10
```

Expected: 6 tests pass.

- [ ] **Step 5: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 476 tests pass (470 + 6).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift \
        Tests/RPPlayerTests/Shell/SettingsViewModelCrossfeedTests.swift
git commit -m "feat(crossfeed): SettingsViewModel published props + setters"
```

---

### Task 14: ClampedNumericField — failing test

**Files:**
- Create: `Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift`

The full SwiftUI view can't be exercised directly in XCTest — there's no headless renderer that fires `.onChange` and focus events. Instead, factor the parsing + clamping + snap-back logic into a tiny `ClampedNumericFieldLogic` helper struct that the view consumes; test the helper.

- [ ] **Step 1: Write failing tests for the helper**

```swift
// Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift
import XCTest
@testable import RPPlayer

final class ClampedNumericFieldTests: XCTestCase {
    func testParseValidDotFormat() {
        let r = ClampedNumericFieldLogic.parse("0.40", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(r, 0.40, accuracy: 1e-9)
    }

    func testParseValidCommaFormatLocale() {
        let r = ClampedNumericFieldLogic.parse("0,40", locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(r, 0.40, accuracy: 1e-9)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(ClampedNumericFieldLogic.parse("abc", locale: Locale(identifier: "en_US")))
        XCTAssertNil(ClampedNumericFieldLogic.parse("", locale: Locale(identifier: "en_US")))
    }

    func testValidityCheckRespectsClosedRange() {
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(0.0, in: 0.0...1.0))
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(0.5, in: 0.0...1.0))
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(1.0, in: 0.0...1.0))
        XCTAssertFalse(ClampedNumericFieldLogic.isValid(-0.01, in: 0.0...1.0))
        XCTAssertFalse(ClampedNumericFieldLogic.isValid(1.01, in: 0.0...1.0))
    }

    func testFormatTwoDecimalPlaces() {
        XCTAssertEqual(ClampedNumericFieldLogic.format(0.4), "0.40")
        XCTAssertEqual(ClampedNumericFieldLogic.format(0.0), "0.00")
        XCTAssertEqual(ClampedNumericFieldLogic.format(1.0), "1.00")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ClampedNumericFieldTests 2>&1 | tail -10
```

Expected: compile failure — `cannot find 'ClampedNumericFieldLogic' in scope`.

---

### Task 15: ClampedNumericField — implementation

**Files:**
- Create: `Sources/RPPlayer/Shell/ClampedNumericField.swift`

- [ ] **Step 1: Implement the helper + the view**

```swift
// Sources/RPPlayer/Shell/ClampedNumericField.swift
import SwiftUI

internal enum ClampedNumericFieldLogic {
    static func parse(_ raw: String, locale: Locale = .current) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        if let n = f.number(from: trimmed)?.doubleValue { return n }
        // Dot-as-decimal fallback for users typing the canonical form in any locale.
        return Double(trimmed)
    }

    static func isValid(_ v: Double, in range: ClosedRange<Double>) -> Bool {
        !v.isNaN && range.contains(v)
    }

    static func format(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}

struct ClampedNumericField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let isEnabled: Bool

    @State private var rawText: String = ""
    @State private var isInvalid: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $rawText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .disabled(!isEnabled)
                .onChange(of: rawText) { newText in
                    guard let parsed = ClampedNumericFieldLogic.parse(newText),
                          ClampedNumericFieldLogic.isValid(parsed, in: range) else {
                        isInvalid = true
                        return
                    }
                    isInvalid = false
                    if parsed != value { value = parsed }
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused && isInvalid {
                        rawText = ClampedNumericFieldLogic.format(value)
                        isInvalid = false
                    }
                }
                .onChange(of: value) { newValue in
                    if !focused {
                        rawText = ClampedNumericFieldLogic.format(newValue)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(isInvalid ? 0.85 : 0), lineWidth: 1.5)
                        .animation(.easeInOut(duration: 0.15), value: isInvalid)
                        .allowsHitTesting(false)
                )

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .disabled(!isEnabled)
        }
        .onAppear { rawText = ClampedNumericFieldLogic.format(value) }
    }
}
```

- [ ] **Step 2: Run helper tests to verify they pass**

```bash
swift test --filter ClampedNumericFieldTests 2>&1 | tail -10
```

Expected: 5 tests pass.

- [ ] **Step 3: Run full suite**

```bash
swift test 2>&1 | tail -5
```

Expected: 481 tests pass (476 + 5).

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/ClampedNumericField.swift \
        Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift
git commit -m "feat(ui): ClampedNumericField stepper input + parse/clamp helper"
```

---

### Task 16: SettingsView crossfeed row

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

This task has no unit test — SwiftUI view rendering is exercised manually. Run the app at the end of the task and confirm the row renders + interacts as designed.

- [ ] **Step 1: Locate the EQ row inside `deviceSettingsSection`**

Open `Sources/RPPlayer/Shell/SettingsView.swift` and search for the EQ row. It's wrapped in a section that contains the EQ toggle + preset picker. The row format will look approximately like:

```swift
HStack {
    Text("Equalizer")
    ...
    Toggle("", isOn: ...)
}
```

The Crossfeed row sits **directly below** it inside the same `Section`.

- [ ] **Step 2: Add the Crossfeed row**

Add this block immediately after the EQ row's closing tag:

```swift
HStack(spacing: 8) {
    Text("Crossfeed")
        .frame(minWidth: 80, alignment: .leading)
    HoverInfoIcon(
        text: """
        Crossfeed simulates a small amount of acoustic leakage between \
        the left and right channels — only useful for headphones, where \
        hard-panned stereo can feel unnaturally separated.

        Strength (0.0–1.0): how much signal crosses to the opposite ear.
          Default 0.20. Higher = stronger spatial blend.
        Range (0.0–1.0): high-frequency rolloff of the crossfed signal.
          Default 0.50. Lower = darker / more natural at higher strengths.

        Bauer-style (BS2B). No effect on speaker output; safe to leave \
        off for non-headphone devices.
        """
    )

    Spacer().frame(width: 8)

    Text("Strength")
        .font(.caption)
    ClampedNumericField(
        value: Binding(
            get: { viewModel.crossfeedStrength },
            set: { newValue in Task { await viewModel.setCrossfeedStrength(newValue) } }
        ),
        range: 0.0...1.0,
        step: 0.05,
        isEnabled: viewModel.crossfeedEnabled
    )

    Text("Range")
        .font(.caption)
    ClampedNumericField(
        value: Binding(
            get: { viewModel.crossfeedRange },
            set: { newValue in Task { await viewModel.setCrossfeedRange(newValue) } }
        ),
        range: 0.0...1.0,
        step: 0.05,
        isEnabled: viewModel.crossfeedEnabled
    )

    Spacer()

    Toggle("", isOn: Binding(
        get: { viewModel.crossfeedEnabled },
        set: { newValue in Task { await viewModel.setCrossfeedEnabled(newValue) } }
    ))
    .labelsHidden()
}
```

If `HoverInfoIcon`'s init signature differs from `HoverInfoIcon(text:)` in this codebase (e.g., it might be `HoverInfoIcon(message:)` or `HoverInfoIcon(_:)`), match the EQ row's existing usage exactly — open `SettingsView.swift`, find the EQ row's HoverInfoIcon, and use the same labelled argument.

- [ ] **Step 3: Verify `swift build` compiles cleanly**

```bash
swift build 2>&1 | tail -10
```

Expected: no errors. Warnings from the unchanged code are acceptable.

- [ ] **Step 4: Manual UX check — run the app**

Build a `.app` and launch (or `swift run RPPlayer` for an unbundled smoke):

```bash
./scripts/make-app.sh && open ./build/RPPlayer.app
```

(If `make-app.sh` doesn't exist or fails, `swift run RPPlayer` is acceptable for this manual check — Now Playing / notifications require the bundled .app but Settings UI does not.)

Steps to verify in the running app:
1. Open Settings.
2. Select an output device.
3. Confirm the Crossfeed row appears below the Equalizer row.
4. Confirm "Strength" + "Range" stepper inputs default to `0.20` and `0.50` respectively, and the toggle is off.
5. Click the toggle on; confirm the numeric inputs become editable (not greyed).
6. Click ▴ on Strength; value rises 0.05 per click, clamped at 1.00.
7. Click ▾ on Range; value drops 0.05 per click, clamped at 0.00.
8. Type `0.45` into Strength; on Tab/click-away, the field commits to `0.45`.
9. Type `xyz` into Strength; the field gains a red glow. Tab away; field snaps back to the last valid value (`0.45`), red glow disappears.
10. Type `2.5` into Range; field shows red glow (out of range). Tab away; field snaps back to last valid.
11. Hover over the ⓘ; tooltip shows the multi-line copy.
12. Switch to a second output device; confirm Strength / Range reflect that device's stored values (or defaults on first selection).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(crossfeed): Settings row with stepper inputs + tooltip"
```

---

### Task 17: RPSmoke probe-filters — add crossfeed

**Files:**
- Modify: `Sources/RPSmoke/main.swift`

- [ ] **Step 1: Extend the probes array**

Locate the `probes` array around line 148:

```swift
let probes: [(String, String)] = [
    ("equalizer", "lavfi=[equalizer=f=1000:t=q:w=1:g=0]"),
    ("lowshelf",  "lavfi=[lowshelf=f=100:t=q:w=0.7:g=0]"),
    ("highshelf", "lavfi=[highshelf=f=8000:t=q:w=0.7:g=0]"),
    ("volume",    "lavfi=[volume=0dB]"),
]
```

Replace with:

```swift
let probes: [(String, String)] = [
    ("equalizer", "lavfi=[equalizer=f=1000:t=q:w=1:g=0]"),
    ("lowshelf",  "lavfi=[lowshelf=f=100:t=q:w=0.7:g=0]"),
    ("highshelf", "lavfi=[highshelf=f=8000:t=q:w=0.7:g=0]"),
    ("volume",    "lavfi=[volume=0dB]"),
    ("crossfeed", "lavfi=[crossfeed=strength=0.2:range=0.5]"),
]
```

- [ ] **Step 2: Run the probe**

```bash
swift run RPSmoke --probe-filters 2>&1 | tail -20
```

Expected: line `  crossfeed: OK` appears in the output (alongside `equalizer: OK`, etc.).

- [ ] **Step 3: Commit**

```bash
git add Sources/RPSmoke/main.swift
git commit -m "chore(smoke): probe crossfeed filter in --probe-filters"
```

---

### Task 18: Documentation — CHANGELOG + CLAUDE.md

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add CHANGELOG entry**

Open `CHANGELOG.md`. Under `## [Unreleased]` / `### Added`, append:

```markdown
- Per-device crossfeed for headphone listening: Bauer-style (BS2B) via ffmpeg `crossfeed` filter, with strength + range stepper inputs in Settings. Composes with EQ in chain order Preamp → EQ → Crossfeed. Default OFF; tooltip explains use case and parameters.
```

(If no `### Added` subsection exists yet under `## [Unreleased]`, create one.)

- [ ] **Step 2: Add PR 36 row to the PR status table in `CLAUDE.md`**

Open `CLAUDE.md` and locate the `## PR status` table. Append after the PR 35 row:

```markdown
| 36   | claude/pr36-crossfeed | ⏳ | Crossfeed for headphone listening: per-device `crossfeedEnabled` + `crossfeedStrength` + `crossfeedRange` on `AudioProfile` (default off / 0.2 / 0.5); new `CrossfeedFilterBuilder.buildPart(strength:range:)` produces `crossfeed=strength=...:range=...` lavfi fragment; `EqChainBuilder.build` split into `buildParts(_:) -> [String]` so the binder can concatenate EQ + crossfeed; `AppContainer.runEqBinder` + `applyEqState` renamed to `runAudioFilterBinder` + `applyAudioFilterState` with a 5-tuple `AudioFilterKey` snapshot diff; chain order Preamp → EQ → Crossfeed (preamp stays at head to preserve AutoEQ headroom semantics); `SettingsViewModel` gains 3 published props + 3 setters with 0.0…1.0 clamping; new `ClampedNumericField` SwiftUI view (TextField + native Stepper with red-glow on invalid input + snap-back to last valid on focus-loss) used by SettingsView's new "Crossfeed" row directly below the EQ row; single `HoverInfoIcon` tooltip covers both strength and range semantics + headphones-only note; `RPSmoke --probe-filters` extended with `crossfeed` assertion. No `AppSettings` top-level mirror (per-device only, same shape as EQ). 484 tests (462 baseline + 22 new + 6 EqChainBuilder test rewrites that don't change count). |
```

- [ ] **Step 3: Add a *Test counts by PR* entry**

Locate the *Test counts by PR* section and append:

```markdown
- After PR 36 Crossfeed for headphone listening — `CrossfeedFilterBuilder` (3); `AudioProfile` crossfeed migration (4); EqChainBuilder.buildParts signature rewrite (6 existing rewritten, no count change); `AppContainerAudioFilterBinder` (4 new crossfeed paths added; existing 2 EQ-only tests retained = 6 total); `SettingsViewModel` crossfeed surface (6); `ClampedNumericFieldLogic` (5). 462 → 484 (+22).
```

- [ ] **Step 4: Update *Key technical decisions* — audio pipeline / chain order entry**

Find the "Audio pipeline" subsection in *Key technical decisions*. After the "Parametric EQ." paragraph, insert a new "Crossfeed." paragraph:

```markdown
- **Crossfeed.** `AudioProfile.crossfeedEnabled: Bool` (default false) + `AudioProfile.crossfeedStrength: Double` (default 0.2) + `AudioProfile.crossfeedRange: Double` (default 0.5). Per-device only (no `AppSettings` top-level mirror — same shape as EQ). Filter chain order is locked at **Preamp → EQ bands → Crossfeed**: preamp stays at head to preserve AutoEQ headroom semantics (negative gain prevents EQ peak clipping); crossfeed sits at the tail so it operates on the equalized signal. `EqChainBuilder.build` was split into `buildParts(_:) -> [String]` (no `lavfi=[...]` wrapper) so `AppContainer.applyAudioFilterState` can concatenate EQ parts + the single crossfeed fragment from `CrossfeedFilterBuilder.buildPart(strength:range:)` into one `mpv af` write. The binder (renamed `runEqBinder` → `runAudioFilterBinder`) diffs a 5-tuple `AudioFilterKey` (eqEnabled / eqPresetName / crossfeedEnabled / crossfeedStrength / crossfeedRange) — only re-applies on a real change. The volume/hog binder's per-iteration profile write-back now threads `existing.crossfeedEnabled` / `existing.crossfeedStrength` / `existing.crossfeedRange` through `AudioProfile.init` (alongside the existing `existing.eqEnabled` / `existing.eqPresetName` passthrough) so non-crossfeed settings changes don't silently wipe crossfeed state. ffmpeg's `crossfeed` filter is Bauer-style only (BS2B-derived); `slope` / `level_in` / `level_out` are not exposed (defaults are fine). UI is two `ClampedNumericField` stepper inputs (TextField + native Stepper, red-glow on invalid parse / out-of-range, snap-back to last valid value on focus loss) plus a single `HoverInfoIcon` tooltip; the numeric fields are `.disabled(!viewModel.crossfeedEnabled)` so the row collapses to a label + tooltip + toggle when off. No headphone auto-detection — the user opts in per device.
```

- [ ] **Step 5: Verify no build break**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs(pr36): CHANGELOG + CLAUDE.md crossfeed entries"
```

---

### Task 19: Final verification

- [ ] **Step 1: Run full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: 484 tests pass (462 baseline + 22 new). The pre-existing `MpvPlayerEngineTests/testPositionUpdatesArriveDuringPlayback` network flake may still occasionally fail — confirm that's the only failure if any.

- [ ] **Step 2: Build the universal `.app`**

```bash
./scripts/make-app.sh 2>&1 | tail -10
```

Expected: `.app` bundle written under `./build/`.

- [ ] **Step 3: Manual end-to-end smoke**

Launch the .app and run through this checklist with real audio playing on a USB DAC or headphone amp:

1. Set EQ off + crossfeed off → mpv `af` should be empty. Verify via:
   ```bash
   # In a separate terminal while the app is playing.
   echo '{ "command": ["get_property", "af"] }' | nc -U /tmp/mpvsocket
   ```
   (Only works if `input-ipc-server` is set; this is a nice-to-have probe, not a hard gate.)
2. Enable crossfeed at default 0.2 / 0.5. Audible: hard-panned stereo (e.g. classic rock with drums hard-left) feels more centered.
3. Increase strength to 0.6 — effect deepens.
4. Increase range to 0.8 — crossfed signal gets brighter (less HF rolloff).
5. Enable EQ on top of crossfeed; confirm both apply (e.g. an obvious +6 dB peak at 1 kHz is audible).
6. Toggle device to built-in speakers; verify the speaker output's crossfeed profile is independent (likely off by default).
7. Quit and relaunch; verify the per-device crossfeed state persists.

- [ ] **Step 4: Open PR**

```bash
git push -u origin claude/pr36-crossfeed
gh pr create --title "feat(crossfeed): per-device Bauer crossfeed for headphone listening" --body "$(cat <<'EOF'
## Summary
- Per-device crossfeed via ffmpeg `crossfeed` filter, composed orthogonally with EQ (chain order: Preamp → EQ → Crossfeed)
- Strength + Range stepper inputs in Settings with red-glow invalid-state + snap-back-to-last-valid
- Single ⓘ tooltip covers semantics + headphones-only note; default OFF

## Test plan
- [ ] `swift test` — 484 tests pass (462 baseline + 22 new)
- [ ] `swift run RPSmoke --probe-filters` reports `crossfeed: OK`
- [ ] Manual: toggle on at default 0.2/0.5 on headphones; hard-panned stereo audibly centers
- [ ] Manual: EQ + crossfeed simultaneously both apply (visible in mpv `af` if probed)
- [ ] Manual: per-device persistence survives quit/relaunch and device switch

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**1. Spec coverage check** — every section of the spec maps to at least one task:

| Spec section | Task(s) |
|---|---|
| Goal / non-goals | Plan header; non-goals stay as constraints. |
| Background (filter table, defaults) | Task 3 (`CrossfeedFilterBuilder` defaults 0.2 / 0.5). |
| Filter chain order | Task 9 (binder concat order: EQ parts then crossfeed). Task 11 test `testEqAndCrossfeedEmitCombinedChainInOrder` enforces it. |
| `AudioProfile` additions | Task 6 (tests) + Task 7 (impl). |
| `AppSettings` — unchanged | No task (intentional). |
| Codable migration | Task 6 (tests) + Task 7 (impl). |
| `EqChainBuilder.buildParts` | Task 4 (tests) + Task 5 (impl + caller update). |
| `CrossfeedFilterBuilder` | Task 2 (tests) + Task 3 (impl). |
| Binder rename + signature | Task 8 (tests rename) + Task 9 (impl rename + new key + builder concat). |
| `applyAudioFilterState` flow (1-4) | Task 9. |
| Profile write-back patch | Task 10. |
| Settings UI row placement + layout | Task 16. |
| `ClampedNumericField` view + validation rules | Task 14 (tests) + Task 15 (impl). |
| Tooltip copy | Task 16 (verbatim insertion). |
| `SettingsViewModel` surface | Task 12 (tests) + Task 13 (impl). |
| Tests (target +22) | Tasks 2, 6, 11, 12, 14 add tests; Task 4 rewrites existing; running counts in each task end-state. |
| Risks → mpv filter availability | Task 17 (RPSmoke probe). |
| Risks → locale parsing | Task 14 (de_DE-locale test). |
| Risks → EqChainBuilder rename ripples | Task 5. |
| File touch list | Mirrored 1:1 in plan's File Structure section. |
| Out of scope | No tasks (intentional). |
| Docs updates | Task 18. |

No gaps.

**2. Placeholder scan** — no "TBD", no "TODO", no "implement later", no "similar to Task N", every code block self-contained.

**3. Type consistency** —

- `AudioProfile` init signature in Task 7 (`crossfeedEnabled: Bool = false, crossfeedStrength: Double = 0.2, crossfeedRange: Double = 0.5`) matches every call site in later tasks (Tasks 10, 11, 13 reference these param names; Task 11 tests use the same Double values).
- `CrossfeedFilterBuilder.buildPart(strength:range:)` signature is identical in Task 3, Task 9 (binder usage), Task 11 (test expectations), Task 17 (probe string).
- `EqChainBuilder.buildParts(_:) -> [String]` is consistent across Tasks 4 / 5 / 9 / 11.
- `AudioFilterKey` struct defined in Task 9, referenced only by Task 9 internals — no external dependents.
- `ClampedNumericFieldLogic` static methods used by Task 14 (tests) match Task 15 (impl) exactly: `parse(_:locale:)`, `isValid(_:in:)`, `format(_:)`.
- `runAudioFilterBinder` parameter labels (`store:engine:eqPresetStore:initialProfile:`) match Task 8 (tests) and Task 9 (impl).

No mismatches found.

**4. Scope check** — single PR, ~22 new tests, 6 production files touched, 5 test files touched, 2 docs. Well-bounded.
