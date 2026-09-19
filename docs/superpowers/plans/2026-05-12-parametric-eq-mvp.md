# Parametric EQ MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add parametric EQ as a per-device audio setting. Toggle + library-based preset import/export/delete (one stored preset per filename, multiple devices may reference the same preset by name). Defer per-band UI to a later PR.

**Architecture:** Each `.txt` preset (AutoEQ / Equalizer APO / REW format) is stored verbatim under `~/Library/Application Support/RP Player/EqPresets/`. `AudioProfile` gains `eqEnabled: Bool` + `eqPresetName: String?` (filename minus `.txt`, references the on-disk file). An `EqPresetStore` actor owns the directory. A new `AppContainer.live()` binder loop hop reads `(eqEnabled, eqPresetName)` per active device, parses on change, builds an FFmpeg lavfi `af` chain, and calls a new `PlayerEngine.setAudioFilterChain(_:)`. UI is a 1-row picker + trash icon next to it + Import/Export buttons + a 1-line summary, inside the existing per-device Audio section.

**Tech Stack:** Swift 6.2, libmpv (vendored 0.36; FFmpeg `equalizer` / `lowshelf` / `highshelf` / `volume` filters confirmed available via RPSmoke `--probe-filters` 2026-05-12), AppKit `NSOpenPanel` / `NSSavePanel`, SwiftUI `Picker` + `Button`.

**Pre-plan filter probe (already done):** `swift run RPSmoke --probe-filters` returned `equalizer: OK / lowshelf: OK / highshelf: OK / volume: OK`. No plan change required. Keep the `--probe-filters` flag in `RPSmoke/main.swift` after the PR — useful diagnostic.

**Storage refinement (resolved with user 2026-05-12, supersedes spec sections 'AudioProfile additions' and 'File picker' partially):**

- Presets stored **verbatim** as `.txt` files under `ConfigPaths.eqPresetsDirectory` (new).
- `AudioProfile.eqPresetName: String?` (filename without `.txt`) **replaces** the spec's inline `eqPreset: EqPreset?`. The parsed `EqPreset` struct is still used at runtime by the chain builder, just not persisted in the profile.
- Multiple devices may reference the same name. Preset names are global, not per-device.
- Import: parse + validate FIRST; **reject** any file that produces warnings (unsupported filter types, >10 bands, malformed lines). Only fully-clean files are saved. On filename collision, prompt: overwrite or cancel.
- Export: copy the **stored .txt verbatim** to the chosen save path (round-trip identity). The `EqPresetWriter` exists only for round-trip-from-parsed-form tests (model/writer agreement); runtime export does not use it.
- Delete: if the preset is referenced by any device (active or otherwise), confirm with a list of affected device UIDs; on confirm, delete the file AND nil-out every `eqPresetName` field that references it.
- Filename rules: `.txt` only; sanitize away `/`, NUL, and leading `.`; reject empty / 256+ chars.

---

## File Structure

### New source files

- `Sources/RPPlayer/Config/EqModels.swift` — `EqBandType` / `EqBand` / `EqPreset` value types (Codable, Equatable, Sendable).
- `Sources/RPPlayer/Config/EqPresetParser.swift` — `EqPresetParser.parse(text:filename:) -> Result<EqPreset, EqPresetError>`. Strict mode — any warning → `.failure`.
- `Sources/RPPlayer/Config/EqPresetWriter.swift` — `EqPresetWriter.write(_:) -> String`. Used only for parsed-form round-trip tests + diagnostics; runtime export copies stored file verbatim.
- `Sources/RPPlayer/Config/EqChainBuilder.swift` — `EqChainBuilder.build(_:) -> String?`. Builds the `lavfi=[...]` chain or nil for empty preset.
- `Sources/RPPlayer/Config/EqPresetStore.swift` — `EqPresetStore` protocol + `LiveEqPresetStore` actor (filesystem). Filename sanitization + duplicate detection. Per-PR convention, `NoopEqPresetStore` lives inside `AppContainer.swift` as private fallback.

### New test files

- `Tests/RPPlayerTests/Config/EqModelsTests.swift`
- `Tests/RPPlayerTests/Config/EqPresetParserTests.swift`
- `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`
- `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift`
- `Tests/RPPlayerTests/Config/EqPresetStoreTests.swift`
- `Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift`

### Modified source files

- `Sources/RPPlayer/Config/ConfigPaths.swift` — add `eqPresetsDirectory`.
- `Sources/RPPlayer/Config/AudioProfile.swift` — add `eqEnabled` + `eqPresetName`; extend Codable migration.
- `Sources/RPPlayer/Player/PlayerEngine.swift` — add `setAudioFilterChain(_:)` protocol method.
- `Sources/RPPlayer/Player/MpvPlayerEngine.swift` — implement; add `currentAudioFilterChainForTesting()`.
- `Sources/RPPlayer/App/AppContainer.swift` — wire `LiveEqPresetStore` (fallback `NoopEqPresetStore`); extend the audio-binder loop with EQ tracking; pass `eqPresetStore` to `SettingsViewModel`.
- `Sources/RPPlayer/Shell/SettingsView.swift` — new "Equalizer" block in `deviceSettingsSection`.
- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — eq surface (state, setters, import/export/delete).

### Modified test files

- `Tests/RPPlayerTests/Player/MockPlayerEngine.swift` — record `.setAudioFilterChain`.
- `Tests/RPPlayerTests/Player/MpvPlayerEngineTests.swift` — set/clear chain.
- `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift` — eq fields migration.
- `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` — eq surface tests.

### Docs

- `CHANGELOG.md` — Added/Changed entries under `## [Unreleased]`.
- `CLAUDE.md` — PR 35 row in PR status table; new "Test counts by PR" line; "Key technical decisions → Audio pipeline" entry on EQ.

---

## Task 1: Engine surface — `setAudioFilterChain`

**Files:**
- Modify: `Sources/RPPlayer/Player/PlayerEngine.swift`
- Modify: `Sources/RPPlayer/Player/MpvPlayerEngine.swift`
- Modify: `Tests/RPPlayerTests/Player/MockPlayerEngine.swift`
- Modify: `Tests/RPPlayerTests/Player/MpvPlayerEngineTests.swift`

- [ ] **Step 1: Write failing engine integration test**

Append to `Tests/RPPlayerTests/Player/MpvPlayerEngineTests.swift` (find the existing class body — same pattern as `testSetForceMaxVolumeSetsVolumeProperty`):

```swift
func testSetAudioFilterChainAppliesAfProperty() async throws {
    let engine = try makeEngine()
    defer { Task { await engine.shutdown() } }

    try await engine.setAudioFilterChain("lavfi=[volume=-1.2dB,equalizer=f=1000:t=q:w=0.7:g=2.0]")
    let stored = await engine.currentAudioFilterChainForTesting()
    XCTAssertEqual(stored, "lavfi=[volume=-1.2dB,equalizer=f=1000:t=q:w=0.7:g=2.0]")

    try await engine.setAudioFilterChain(nil)
    let cleared = await engine.currentAudioFilterChainForTesting()
    XCTAssertEqual(cleared, "")
}
```

- [ ] **Step 2: Run test, expect compile failure (method missing)**

Run: `swift test --filter MpvPlayerEngineTests/testSetAudioFilterChainAppliesAfProperty 2>&1 | tail -20`
Expected: compile error `value of type 'MpvPlayerEngine' has no member 'setAudioFilterChain'`.

- [ ] **Step 3: Add protocol method**

In `Sources/RPPlayer/Player/PlayerEngine.swift`, add to the `PlayerEngine` protocol body just after `setApplyReplayGain`:

```swift
    func setAudioFilterChain(_ chain: String?) async throws
```

- [ ] **Step 4: Implement on `MpvPlayerEngine`**

In `Sources/RPPlayer/Player/MpvPlayerEngine.swift`, add immediately after `setApplyReplayGain`:

```swift
    public func setAudioFilterChain(_ chain: String?) async throws {
        try requireHandle()
        try setStringProperty("af", chain ?? "")
    }

    func currentAudioFilterChainForTesting() -> String? {
        guard let h = handle else { return nil }
        guard let raw = mpv_get_property_string(h, "af") else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }
```

- [ ] **Step 5: Extend `MockPlayerEngine`**

In `Tests/RPPlayerTests/Player/MockPlayerEngine.swift`, add to the `Recorded` enum after `setApplyReplayGain`:

```swift
        case setAudioFilterChain(chain: String?)
```

And add to the class body alongside the other recorders:

```swift
    func setAudioFilterChain(_ chain: String?) async throws {
        try recordOrThrow(.setAudioFilterChain(chain: chain))
    }
```

- [ ] **Step 6: Run test, expect PASS**

Run: `swift test --filter MpvPlayerEngineTests/testSetAudioFilterChainAppliesAfProperty 2>&1 | tail -10`
Expected: 1 test passing.

- [ ] **Step 7: Full build + full test (sanity)**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: full suite passes (existing 421 + 1 = 422 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/RPPlayer/Player/PlayerEngine.swift Sources/RPPlayer/Player/MpvPlayerEngine.swift \
        Tests/RPPlayerTests/Player/MockPlayerEngine.swift Tests/RPPlayerTests/Player/MpvPlayerEngineTests.swift
git commit -m "feat(eq): add setAudioFilterChain to PlayerEngine"
```

---

## Task 2: EQ models

**Files:**
- Create: `Sources/RPPlayer/Config/EqModels.swift`
- Create: `Tests/RPPlayerTests/Config/EqModelsTests.swift`

- [ ] **Step 1: Write failing Codable round-trip test**

Create `Tests/RPPlayerTests/Config/EqModelsTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqModelsTests: XCTestCase {
    func testEqPresetRoundTrip() throws {
        let preset = EqPreset(
            name: "test",
            preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EqPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testEqBandTypeRawValues() {
        XCTAssertEqual(EqBandType.peak.rawValue, "peak")
        XCTAssertEqual(EqBandType.lowShelf.rawValue, "lowShelf")
        XCTAssertEqual(EqBandType.highShelf.rawValue, "highShelf")
    }

    func testEqPresetEqualityIgnoresNothing() {
        let a = EqPreset(name: "a", preampDb: 0, bands: [])
        let b = EqPreset(name: "b", preampDb: 0, bands: [])
        XCTAssertNotEqual(a, b)
    }
}
```

- [ ] **Step 2: Run test, expect compile fail**

Run: `swift test --filter EqModelsTests 2>&1 | tail -10`
Expected: `cannot find 'EqPreset' in scope`.

- [ ] **Step 3: Create models file**

Create `Sources/RPPlayer/Config/EqModels.swift`:

```swift
import Foundation

public enum EqBandType: String, Codable, Equatable, Sendable {
    case peak
    case lowShelf
    case highShelf
}

public struct EqBand: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var type: EqBandType
    public var fcHz: Double
    public var gainDb: Double
    public var q: Double

    public init(enabled: Bool, type: EqBandType, fcHz: Double, gainDb: Double, q: Double) {
        self.enabled = enabled
        self.type = type
        self.fcHz = fcHz
        self.gainDb = gainDb
        self.q = q
    }
}

public struct EqPreset: Codable, Equatable, Sendable {
    public var name: String?
    public var preampDb: Double
    public var bands: [EqBand]

    public init(name: String?, preampDb: Double, bands: [EqBand]) {
        self.name = name
        self.preampDb = preampDb
        self.bands = bands
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `swift test --filter EqModelsTests 2>&1 | tail -10`
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqModels.swift Tests/RPPlayerTests/Config/EqModelsTests.swift
git commit -m "feat(eq): add EqBandType / EqBand / EqPreset models"
```

---

## Task 3: Parser (strict mode)

Parser rejects any file with warnings (unsupported types, >10 bands, malformed `Filter N:` lines). `OFF` filters are silently skipped — they reflect intentional user state in the source format, not a defect.

**Files:**
- Create: `Sources/RPPlayer/Config/EqPresetParser.swift`
- Create: `Tests/RPPlayerTests/Config/EqPresetParserTests.swift`

- [ ] **Step 1: Write failing parser tests**

Create `Tests/RPPlayerTests/Config/EqPresetParserTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqPresetParserTests: XCTestCase {
    func testParsesPreampAndThreeBands() throws {
        let text = """
        CH: 0
        TYPE: PEQ
        Preamp: -1.2 dB
        Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.820
        Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.600
        Filter 3: ON HS Fc 8000 Hz Gain -0.5 dB Q 0.700
        """
        let result = EqPresetParser.parse(text: text, filename: "demo")
        let preset = try result.get()
        XCTAssertEqual(preset.name, "demo")
        XCTAssertEqual(preset.preampDb, -1.2, accuracy: 0.0001)
        XCTAssertEqual(preset.bands.count, 3)
        XCTAssertEqual(preset.bands[0].type, .lowShelf)
        XCTAssertEqual(preset.bands[1].type, .peak)
        XCTAssertEqual(preset.bands[2].type, .highShelf)
        XCTAssertEqual(preset.bands[1].fcHz, 300)
        XCTAssertEqual(preset.bands[1].gainDb, -1.6, accuracy: 0.0001)
        XCTAssertEqual(preset.bands[1].q, 0.6, accuracy: 0.0001)
    }

    func testDefaultsPreampToZeroWhenAbsent() throws {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0"
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.preampDb, 0)
    }

    func testIgnoresHeaderAndXfeedLines() throws {
        let text = """
        CH: 0
        TYPE: PEQ
        Xfeed: 1 1
        Preamp: 0 dB
        Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 1)
    }

    func testOffFiltersSilentlySkippedNoWarning() throws {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
        Filter 2: OFF PK Fc 200 Hz Gain 2 dB Q 1.0
        Filter 3: ON PK Fc 300 Hz Gain 3 dB Q 1.0
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 2)
        XCTAssertEqual(preset.bands.map(\.fcHz), [100, 300])
    }

    func testRejectsUnsupportedFilterType() {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0
        Filter 2: ON LP Fc 8000 Hz Gain 0 dB Q 1.0
        """
        let result = EqPresetParser.parse(text: text, filename: "n")
        switch result {
        case .success:
            XCTFail("should reject unsupported type LP")
        case .failure(let err):
            guard case .warningsNotPermitted(let warnings) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertTrue(warnings.contains { $0.contains("LP") })
        }
    }

    func testRejectsMoreThanTenBands() {
        let lines = (1...11).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 0 dB Q 1.0" }
        let result = EqPresetParser.parse(text: lines.joined(separator: "\n"), filename: "n")
        switch result {
        case .success: XCTFail("should reject >10 bands")
        case .failure(let err):
            guard case .warningsNotPermitted(let warnings) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertTrue(warnings.contains { $0.lowercased().contains("cap") || $0.contains("10") })
        }
    }

    func testRejectsMalformedFilterLine() {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0
        Filter 2: ON PK Fc whoops Gain 0 dB Q 1.0
        """
        let result = EqPresetParser.parse(text: text, filename: "n")
        if case .success = result {
            XCTFail("should reject malformed line")
        }
    }

    func testRejectsEmptyFile() {
        let result = EqPresetParser.parse(text: "   \n\n  \n", filename: "n")
        if case .success = result {
            XCTFail("should reject empty file")
        }
    }

    func testNameDerivedFromFilename() throws {
        let preset = try EqPresetParser.parse(
            text: "Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0",
            filename: "my-preset"
        ).get()
        XCTAssertEqual(preset.name, "my-preset")
    }
}
```

- [ ] **Step 2: Run, expect compile fail**

Run: `swift test --filter EqPresetParserTests 2>&1 | tail -10`
Expected: `cannot find 'EqPresetParser' in scope`.

- [ ] **Step 3: Implement parser**

Create `Sources/RPPlayer/Config/EqPresetParser.swift`:

```swift
import Foundation

public enum EqPresetError: Error, Equatable, Sendable {
    /// Strict-mode rejection: file contained one or more warnings.
    case warningsNotPermitted(reasons: [String])
    case empty
}

public enum EqPresetParser {
    public static let maxBands = 10

    private static let filterPattern = #"^Filter\s+\d+:\s+(ON|OFF)\s+([A-Z]{2})\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+(\d+(?:\.\d+)?)\s*$"#
    private static let preampPattern = #"^Preamp:\s+([+-]?\d+(?:\.\d+)?)\s*dB\s*$"#

    public static func parse(text: String, filename: String) -> Result<EqPreset, EqPresetError> {
        var preampDb: Double = 0
        var bands: [EqBand] = []
        var warnings: [String] = []
        var anySupportedLineSeen = false

        let filterRegex = try! NSRegularExpression(pattern: filterPattern)
        let preampRegex = try! NSRegularExpression(pattern: preampPattern)

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            if let m = preampRegex.firstMatch(in: line, range: range) {
                if let r = Range(m.range(at: 1), in: line), let v = Double(line[r]) {
                    preampDb = v
                    anySupportedLineSeen = true
                }
                continue
            }

            if line.hasPrefix("Filter") {
                anySupportedLineSeen = true
                guard let m = filterRegex.firstMatch(in: line, range: range),
                      let stateR = Range(m.range(at: 1), in: line),
                      let typeR = Range(m.range(at: 2), in: line),
                      let fcR = Range(m.range(at: 3), in: line),
                      let gainR = Range(m.range(at: 4), in: line),
                      let qR = Range(m.range(at: 5), in: line),
                      let fc = Double(line[fcR]),
                      let gain = Double(line[gainR]),
                      let q = Double(line[qR])
                else {
                    warnings.append("Malformed Filter line at line \(index + 1): \(line)")
                    continue
                }
                let stateStr = String(line[stateR])
                let typeStr = String(line[typeR])
                if stateStr == "OFF" { continue }
                let mapped: EqBandType?
                switch typeStr {
                case "PK": mapped = .peak
                case "LS": mapped = .lowShelf
                case "HS": mapped = .highShelf
                default:
                    warnings.append("Dropped unsupported filter type \(typeStr) at line \(index + 1)")
                    continue
                }
                bands.append(EqBand(enabled: true, type: mapped!, fcHz: fc, gainDb: gain, q: q))
            }
        }

        if bands.count > maxBands {
            warnings.append("Preset exceeds cap of \(maxBands) bands (got \(bands.count))")
        }

        if !anySupportedLineSeen && bands.isEmpty {
            return .failure(.empty)
        }
        if !warnings.isEmpty {
            return .failure(.warningsNotPermitted(reasons: warnings))
        }
        if bands.isEmpty {
            return .failure(.empty)
        }
        return .success(EqPreset(name: filename, preampDb: preampDb, bands: bands))
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `swift test --filter EqPresetParserTests 2>&1 | tail -5`
Expected: 9 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqPresetParser.swift Tests/RPPlayerTests/Config/EqPresetParserTests.swift
git commit -m "feat(eq): add strict EqPresetParser (rejects any warnings)"
```

---

## Task 4: Writer + chain builder

`EqPresetWriter` matches the AutoEQ/REW text format for round-trip identity tests. `EqChainBuilder` produces the lavfi graph mpv consumes.

**Files:**
- Create: `Sources/RPPlayer/Config/EqPresetWriter.swift`
- Create: `Sources/RPPlayer/Config/EqChainBuilder.swift`
- Create: `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`
- Create: `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift`

- [ ] **Step 1: Write failing writer tests**

Create `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqPresetWriterTests: XCTestCase {
    func testWriteEmitsAllSupportedTypes() {
        let preset = EqPreset(
            name: "n",
            preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        let text = EqPresetWriter.write(preset)
        XCTAssertTrue(text.contains("Preamp: -1.2 dB"))
        XCTAssertTrue(text.contains("Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.82"))
        XCTAssertTrue(text.contains("Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.6"))
        XCTAssertTrue(text.contains("Filter 3: ON HS Fc 8000 Hz Gain -0.8 dB Q 0.7"))
    }

    func testRoundTripFromParsedForm() throws {
        let original = """
        Preamp: -1.2 dB
        Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.82
        Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.6
        """
        let parsed = try EqPresetParser.parse(text: original, filename: "n").get()
        let written = EqPresetWriter.write(parsed)
        let reparsed = try EqPresetParser.parse(text: written, filename: "n").get()
        XCTAssertEqual(reparsed, parsed)
    }
}
```

- [ ] **Step 2: Write failing chain-builder tests**

Create `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqChainBuilderTests: XCTestCase {
    func testEmptyBandsAndZeroPreampReturnsNil() {
        let preset = EqPreset(name: nil, preampDb: 0, bands: [])
        XCTAssertNil(EqChainBuilder.build(preset))
    }

    func testPreampOnly() {
        let preset = EqPreset(name: nil, preampDb: -2.5, bands: [])
        XCTAssertEqual(EqChainBuilder.build(preset), "lavfi=[volume=-2.5dB]")
    }

    func testPeakBand() {
        let preset = EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 2.0, q: 1.4)]
        )
        XCTAssertEqual(
            EqChainBuilder.build(preset),
            "lavfi=[volume=0dB,equalizer=f=1000:t=q:w=1.4:g=2]"
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
            EqChainBuilder.build(preset),
            "lavfi=[volume=-1.2dB,lowshelf=f=83:t=q:w=0.82:g=1.2,equalizer=f=300:t=q:w=0.6:g=-1.6,highshelf=f=8000:t=q:w=0.7:g=-0.8]"
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
            EqChainBuilder.build(preset),
            "lavfi=[volume=0dB,equalizer=f=2000:t=q:w=1:g=3]"
        )
    }
}
```

- [ ] **Step 3: Run, expect compile fail**

Run: `swift test --filter EqPresetWriterTests --filter EqChainBuilderTests 2>&1 | tail -10`
Expected: `cannot find 'EqPresetWriter' in scope`.

- [ ] **Step 4: Implement `EqPresetWriter`**

Create `Sources/RPPlayer/Config/EqPresetWriter.swift`:

```swift
import Foundation

public enum EqPresetWriter {
    public static func write(_ preset: EqPreset) -> String {
        var lines: [String] = []
        lines.append("CH: 0")
        lines.append("TYPE: PEQ")
        lines.append("Preamp: \(format(preset.preampDb)) dB")
        for (i, b) in preset.bands.enumerated() where b.enabled {
            let abbr: String
            switch b.type {
            case .peak: abbr = "PK"
            case .lowShelf: abbr = "LS"
            case .highShelf: abbr = "HS"
            }
            lines.append("Filter \(i + 1): ON \(abbr) Fc \(format(b.fcHz)) Hz Gain \(format(b.gainDb)) dB Q \(format(b.q))")
        }
        return lines.joined(separator: "\n") + "\n"
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

- [ ] **Step 5: Implement `EqChainBuilder`**

Create `Sources/RPPlayer/Config/EqChainBuilder.swift`:

```swift
import Foundation

public enum EqChainBuilder {
    public static func build(_ preset: EqPreset) -> String? {
        let enabled = preset.bands.filter(\.enabled)
        if enabled.isEmpty && preset.preampDb == 0 { return nil }
        var parts: [String] = ["volume=\(format(preset.preampDb))dB"]
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
        return "lavfi=[" + parts.joined(separator: ",") + "]"
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

- [ ] **Step 6: Run, expect PASS**

Run: `swift test --filter EqPresetWriterTests --filter EqChainBuilderTests 2>&1 | tail -10`
Expected: 7 tests passing.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Config/EqPresetWriter.swift Sources/RPPlayer/Config/EqChainBuilder.swift \
        Tests/RPPlayerTests/Config/EqPresetWriterTests.swift Tests/RPPlayerTests/Config/EqChainBuilderTests.swift
git commit -m "feat(eq): add EqPresetWriter (round-trip) + EqChainBuilder (lavfi)"
```

---

## Task 5: `EqPresetStore` actor (filesystem-backed library)

Filesystem store. Each preset lives at `<eqPresetsDirectory>/<name>.txt`. Listing returns names sorted case-insensitive. Save fails when file exists and `overwrite: false`. Filenames sanitized: reject `/`, NUL, leading `.`, empty, 256+ chars.

**Files:**
- Modify: `Sources/RPPlayer/Config/ConfigPaths.swift`
- Create: `Sources/RPPlayer/Config/EqPresetStore.swift`
- Create: `Tests/RPPlayerTests/Config/EqPresetStoreTests.swift`

- [ ] **Step 1: Add directory to `ConfigPaths`**

Edit `Sources/RPPlayer/Config/ConfigPaths.swift`, insert after `songFileCacheDirectory`:

```swift
    public static var eqPresetsDirectory: URL {
        applicationSupportRoot.appendingPathComponent("EqPresets", isDirectory: true)
    }
```

- [ ] **Step 2: Write failing store tests**

Create `Tests/RPPlayerTests/Config/EqPresetStoreTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqPresetStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EqPresetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func makeStore() -> LiveEqPresetStore {
        LiveEqPresetStore(directory: tmpDir)
    }

    func testSaveAndList() async throws {
        let store = makeStore()
        try await store.save(name: "alpha", text: "Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        try await store.save(name: "Bravo", text: "x", overwrite: false)
        let list = await store.list()
        XCTAssertEqual(list, ["alpha", "Bravo"])
    }

    func testLoadTextReturnsVerbatim() async throws {
        let store = makeStore()
        let text = "Preamp: -1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n"
        try await store.save(name: "n", text: text, overwrite: false)
        let loaded = try await store.loadText(name: "n")
        XCTAssertEqual(loaded, text)
    }

    func testSaveRefusesOverwriteWhenFlagFalse() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "v1", overwrite: false)
        do {
            try await store.save(name: "n", text: "v2", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {
            // expected
        }
    }

    func testSaveAllowsOverwriteWhenFlagTrue() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "v1", overwrite: false)
        try await store.save(name: "n", text: "v2", overwrite: true)
        XCTAssertEqual(try await store.loadText(name: "n"), "v2")
    }

    func testDeleteRemovesFile() async throws {
        let store = makeStore()
        try await store.save(name: "n", text: "x", overwrite: false)
        try await store.delete(name: "n")
        XCTAssertEqual(await store.list(), [])
    }

    func testExistsReturnsTrueAfterSave() async throws {
        let store = makeStore()
        XCTAssertFalse(await store.exists(name: "n"))
        try await store.save(name: "n", text: "x", overwrite: false)
        XCTAssertTrue(await store.exists(name: "n"))
    }

    func testRejectsFilenameWithSlash() async throws {
        let store = makeStore()
        do {
            try await store.save(name: "bad/name", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }

    func testRejectsEmptyFilename() async throws {
        let store = makeStore()
        do {
            try await store.save(name: "", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }

    func testRejectsLeadingDot() async throws {
        let store = makeStore()
        do {
            try await store.save(name: ".secret", text: "x", overwrite: false)
            XCTFail("expected error")
        } catch EqPresetStoreError.invalidName {
            // expected
        }
    }
}
```

- [ ] **Step 3: Implement the store**

Create `Sources/RPPlayer/Config/EqPresetStore.swift`:

```swift
import Foundation

public enum EqPresetStoreError: Error, Equatable, Sendable {
    case invalidName
    case alreadyExists
    case notFound
    case ioFailure(String)
}

public protocol EqPresetStore: Sendable {
    func list() async -> [String]
    func exists(name: String) async -> Bool
    func loadText(name: String) async throws -> String
    func save(name: String, text: String, overwrite: Bool) async throws
    func delete(name: String) async throws
}

public actor LiveEqPresetStore: EqPresetStore {
    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func list() async -> [String] {
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func exists(name: String) async -> Bool {
        guard validate(name) else { return false }
        return fm.fileExists(atPath: fileURL(for: name).path)
    }

    public func loadText(name: String) async throws -> String {
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else { throw EqPresetStoreError.notFound }
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    public func save(name: String, text: String, overwrite: Bool) async throws {
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        if fm.fileExists(atPath: url.path) && !overwrite {
            throw EqPresetStoreError.alreadyExists
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    public func delete(name: String) async throws {
        guard validate(name) else { throw EqPresetStoreError.invalidName }
        let url = fileURL(for: name)
        guard fm.fileExists(atPath: url.path) else { throw EqPresetStoreError.notFound }
        do { try fm.removeItem(at: url) }
        catch { throw EqPresetStoreError.ioFailure("\(error)") }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(name).txt", isDirectory: false)
    }

    private func validate(_ name: String) -> Bool {
        guard !name.isEmpty, name.count < 256 else { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\0") { return false }
        return true
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `swift test --filter EqPresetStoreTests 2>&1 | tail -10`
Expected: 9 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/ConfigPaths.swift Sources/RPPlayer/Config/EqPresetStore.swift \
        Tests/RPPlayerTests/Config/EqPresetStoreTests.swift
git commit -m "feat(eq): add EqPresetStore actor + EqPresets directory"
```

---

## Task 6: `AudioProfile` EQ fields + migration

**Files:**
- Modify: `Sources/RPPlayer/Config/AudioProfile.swift`
- Modify: `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift`

- [ ] **Step 1: Write failing migration tests**

Append to `Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift` (inside existing class):

```swift
    func testEqFieldsDefaultWhenAbsent() throws {
        let json = """
        { "hogModeEnabled": false, "releaseHogOnPauseEnabled": false, "volumeMode": "none", "bitrate": 3 }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertFalse(profile.eqEnabled)
        XCTAssertNil(profile.eqPresetName)
    }

    func testEqFieldsRoundTrip() throws {
        let profile = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: true,
            volumeMode: .replayGain,
            bitrate: 4,
            eqEnabled: true,
            eqPresetName: "my-headphones"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertTrue(decoded.eqEnabled)
        XCTAssertEqual(decoded.eqPresetName, "my-headphones")
    }
```

- [ ] **Step 2: Run, expect compile fail**

Run: `swift test --filter AudioProfileMigrationTests 2>&1 | tail -10`
Expected: `extra arguments at positions #5, #6 in call`.

- [ ] **Step 3: Extend `AudioProfile`**

Edit `Sources/RPPlayer/Config/AudioProfile.swift` — append fields, update init, update Codable.

Replace the `public struct AudioProfile` body (lines 3–27 in the existing file) with:

```swift
public struct AudioProfile: Equatable, Sendable {
    public var hogModeEnabled: Bool
    public var releaseHogOnPauseEnabled: Bool
    public var volumeMode: VolumeMode
    public var bitrate: Int
    public var eqEnabled: Bool
    public var eqPresetName: String?

    public init(
        hogModeEnabled: Bool,
        releaseHogOnPauseEnabled: Bool,
        volumeMode: VolumeMode,
        bitrate: Int,
        eqEnabled: Bool = false,
        eqPresetName: String? = nil
    ) {
        self.hogModeEnabled = hogModeEnabled
        self.releaseHogOnPauseEnabled = releaseHogOnPauseEnabled
        self.volumeMode = volumeMode
        self.bitrate = bitrate
        self.eqEnabled = eqEnabled
        self.eqPresetName = eqPresetName
    }

    public static let safeDefault = AudioProfile(
        hogModeEnabled: false,
        releaseHogOnPauseEnabled: false,
        volumeMode: .none,
        bitrate: 3,
        eqEnabled: false,
        eqPresetName: nil
    )
}
```

Update the Codable extension. Replace it with:

```swift
extension AudioProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case hogModeEnabled
        case releaseHogOnPauseEnabled
        case volumeMode
        case bitrate
        case eqEnabled
        case eqPresetName
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
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hogModeEnabled, forKey: .hogModeEnabled)
        try c.encode(releaseHogOnPauseEnabled, forKey: .releaseHogOnPauseEnabled)
        try c.encode(volumeMode, forKey: .volumeMode)
        try c.encode(bitrate, forKey: .bitrate)
        try c.encode(eqEnabled, forKey: .eqEnabled)
        try c.encodeIfPresent(eqPresetName, forKey: .eqPresetName)
    }
}
```

- [ ] **Step 4: Run, expect PASS**

Run: `swift test --filter AudioProfileMigrationTests 2>&1 | tail -10`
Expected: all existing migration tests + 2 new tests pass. Other tests touching `AudioProfile(...)` may break if they used positional init — fix by either dropping the new params (defaults handle it) or adding the new params explicitly. Run full suite next.

- [ ] **Step 5: Run full suite**

Run: `swift test 2>&1 | tail -10`
Expected: everything green. If any test fails compiling because of `AudioProfile(...)` positional init, the new params have defaults so existing call sites compile unchanged. Investigate any unexpected failure before continuing.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Config/AudioProfile.swift Tests/RPPlayerTests/Config/AudioProfileMigrationTests.swift
git commit -m "feat(eq): add eqEnabled + eqPresetName to AudioProfile"
```

---

## Task 7: `SettingsViewModel` EQ surface

VM owns: `eqEnabled`, `eqPresetName`, `availablePresets`, plus setters for `setEqEnabled`, `setEqPresetName`, `importPresetFile(url:)`, `exportPreset(to:)`, `prepareDeletePreset(name:)`, `deletePresetConfirmed(name:)`, `refreshPresets()`. Reading from disk is async; published lists update via `MainActor.run`.

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`

- [ ] **Step 1: Read SettingsViewModel + existing tests to confirm constructor shape**

Run: `grep -n "init(\|func setVolumeMode\|class SettingsViewModelTests" Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift | head -20`

The VM is `@MainActor final class: ObservableObject`. Constructor takes `configStore`, `audioDeviceCatalog`, `hogModeController` (and similar). Add `eqPresetStore: any EqPresetStore` param (after `audioDeviceCatalog`-ish position; pick a stable index — most-recent param added in a prior PR followed alphabetical/topical grouping — drop EQ at the end).

- [ ] **Step 2: Write failing VM tests**

Append to `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`:

```swift
    func testSetEqEnabledWritesActiveDeviceProfile() async throws {
        let env = try await makeEnv()
        await env.viewModel.setOutputDevice(uid: "dev-A")
        await env.viewModel.setEqEnabled(true)
        let stored = await env.configStore.settings
        XCTAssertEqual(stored.audioProfiles["dev-A"]?.eqEnabled, true)
    }

    func testSetEqPresetNameWritesActiveDeviceProfile() async throws {
        let env = try await makeEnv()
        await env.viewModel.setOutputDevice(uid: "dev-A")
        await env.viewModel.setEqPresetName("my-preset")
        let stored = await env.configStore.settings
        XCTAssertEqual(stored.audioProfiles["dev-A"]?.eqPresetName, "my-preset")
    }

    func testImportPresetFileSavesValidFileToStore() async throws {
        let env = try await makeEnv()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).txt")
        try "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outcome = try await env.viewModel.importPresetFile(url: tmp, overwrite: false)
        XCTAssertEqual(outcome, .imported(name: tmp.deletingPathExtension().lastPathComponent))
        XCTAssertTrue(env.viewModel.availablePresets.contains(tmp.deletingPathExtension().lastPathComponent))
    }

    func testImportPresetFileSurfacesParserError() async throws {
        let env = try await makeEnv()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).txt")
        try "Filter 1: ON LP Fc 8000 Hz Gain 0 dB Q 1.0\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            _ = try await env.viewModel.importPresetFile(url: tmp, overwrite: false)
            XCTFail("expected error")
        } catch SettingsViewModel.EqImportError.parseFailed {
            // expected
        }
    }

    func testImportPresetReportsCollisionWhenOverwriteFalse() async throws {
        let env = try await makeEnv()
        let name = "collision-\(UUID().uuidString.prefix(6))"
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).txt")
        try "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n".write(to: url1, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url1) }
        _ = try await env.viewModel.importPresetFile(url: url1, overwrite: false)
        let outcome = try await env.viewModel.importPresetFile(url: url1, overwrite: false)
        XCTAssertEqual(outcome, .nameCollision(name: String(name)))
    }

    func testPrepareDeleteListsReferencingDeviceUIDs() async throws {
        let env = try await makeEnv()
        try await env.eqPresetStore.save(name: "shared", text: "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        try await env.configStore.update {
            $0.audioProfiles["dev-A"] = AudioProfile(
                hogModeEnabled: false, releaseHogOnPauseEnabled: false,
                volumeMode: .none, bitrate: 3, eqEnabled: true, eqPresetName: "shared"
            )
            $0.audioProfiles["dev-B"] = AudioProfile(
                hogModeEnabled: false, releaseHogOnPauseEnabled: false,
                volumeMode: .none, bitrate: 3, eqEnabled: false, eqPresetName: "shared"
            )
        }
        await env.viewModel.refreshPresets()
        let refs = await env.viewModel.prepareDeletePreset(name: "shared")
        XCTAssertEqual(Set(refs), Set(["dev-A", "dev-B"]))
    }

    func testDeletePresetConfirmedNilsOutReferencesAndRemovesFile() async throws {
        let env = try await makeEnv()
        try await env.eqPresetStore.save(name: "doomed", text: "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        try await env.configStore.update {
            $0.audioProfiles["dev-A"] = AudioProfile(
                hogModeEnabled: false, releaseHogOnPauseEnabled: false,
                volumeMode: .none, bitrate: 3, eqEnabled: true, eqPresetName: "doomed"
            )
        }
        await env.viewModel.refreshPresets()
        try await env.viewModel.deletePresetConfirmed(name: "doomed")
        XCTAssertFalse(await env.eqPresetStore.exists(name: "doomed"))
        let stored = await env.configStore.settings
        XCTAssertNil(stored.audioProfiles["dev-A"]?.eqPresetName)
    }
```

Also extend the test environment (`makeEnv` helper at the top of `SettingsViewModelTests`) to construct a tmpdir-backed `LiveEqPresetStore` and pass it into the VM. If `makeEnv` doesn't exist, add a helper:

```swift
private struct Env {
    let viewModel: SettingsViewModel
    let configStore: JSONConfigStore   // or whatever existing tests use
    let eqPresetStore: LiveEqPresetStore
    let tmpDir: URL
}

private func makeEnv() async throws -> Env {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("svm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
    // ... reuse the existing store/catalog/etc construction the file already does ...
    let eqStore = LiveEqPresetStore(directory: tmp.appendingPathComponent("eq", isDirectory: true))
    let vm = SettingsViewModel(/* existing args + */ eqPresetStore: eqStore)
    return Env(viewModel: vm, configStore: configStore, eqPresetStore: eqStore, tmpDir: tmp)
}
```

If existing tests already have a helper, fold the new param into it; do **not** duplicate. The pattern follows PR 26 / 34 test setup.

- [ ] **Step 3: Run, expect compile fail**

Run: `swift test --filter SettingsViewModelTests 2>&1 | tail -15`
Expected: missing `eqPresetStore` parameter, missing `setEqEnabled`, etc.

- [ ] **Step 4: Add VM surface**

Edit `Sources/RPPlayer/Shell/SettingsViewModel.swift`. Add to the class body:

```swift
    @Published public private(set) var eqEnabled: Bool = false
    @Published public private(set) var eqPresetName: String?
    @Published public private(set) var availablePresets: [String] = []

    public enum ImportOutcome: Equatable, Sendable {
        case imported(name: String)
        case nameCollision(name: String)
    }

    public enum EqImportError: Error, Equatable, Sendable {
        case parseFailed(reasons: [String])
        case ioFailure(String)
        case invalidExtension
    }

    private let eqPresetStore: any EqPresetStore
```

Update the initializer to accept `eqPresetStore: any EqPresetStore` (append parameter), store it, and call `await refreshPresets()` from `start()` (or wherever the existing initial-fetch happens).

Inside the existing settings-stream subscription that already populates `volumeMode` etc., also wire the active device's `eqEnabled` / `eqPresetName` into `@Published` vars (mirror the volumeMode pattern in `SettingsViewModel` from PR 34).

Add methods:

```swift
    public func setEqEnabled(_ value: Bool) async {
        guard let uid = activeDeviceUID else { return }
        try? await configStore.update {
            var p = $0.audioProfiles[uid] ?? .safeDefault
            p.eqEnabled = value
            $0.audioProfiles[uid] = p
        }
    }

    public func setEqPresetName(_ name: String?) async {
        guard let uid = activeDeviceUID else { return }
        try? await configStore.update {
            var p = $0.audioProfiles[uid] ?? .safeDefault
            p.eqPresetName = name
            $0.audioProfiles[uid] = p
        }
    }

    public func refreshPresets() async {
        let names = await eqPresetStore.list()
        await MainActor.run { self.availablePresets = names }
    }

    public func importPresetFile(url: URL, overwrite: Bool) async throws -> ImportOutcome {
        guard url.pathExtension.lowercased() == "txt" else {
            throw EqImportError.invalidExtension
        }
        let raw: String
        do { raw = try String(contentsOf: url, encoding: .utf8) }
        catch { throw EqImportError.ioFailure("\(error)") }
        let name = url.deletingPathExtension().lastPathComponent
        switch EqPresetParser.parse(text: raw, filename: name) {
        case .failure(.warningsNotPermitted(let reasons)):
            throw EqImportError.parseFailed(reasons: reasons)
        case .failure(.empty):
            throw EqImportError.parseFailed(reasons: ["No recognised filter lines"])
        case .success:
            do {
                try await eqPresetStore.save(name: name, text: raw, overwrite: overwrite)
                await refreshPresets()
                return .imported(name: name)
            } catch EqPresetStoreError.alreadyExists {
                return .nameCollision(name: name)
            } catch {
                throw EqImportError.ioFailure("\(error)")
            }
        }
    }

    public func exportPreset(to url: URL) async throws {
        guard let name = eqPresetName else { return }
        let text = try await eqPresetStore.loadText(name: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func prepareDeletePreset(name: String) async -> [String] {
        let settings = await configStore.settings
        return settings.audioProfiles
            .filter { $0.value.eqPresetName == name }
            .map(\.key)
    }

    public func deletePresetConfirmed(name: String) async throws {
        try await configStore.update { settings in
            for (uid, var profile) in settings.audioProfiles where profile.eqPresetName == name {
                profile.eqPresetName = nil
                settings.audioProfiles[uid] = profile
            }
        }
        try await eqPresetStore.delete(name: name)
        await refreshPresets()
    }

    public var eqPresetSummary: String? {
        nil // populated by AppContainer-side preset preview if needed in a future iteration; MVP omits it from VM and lets the UI show only filename + bandcount derived from store.
    }
```

(Note: the read-only summary line `Preamp: -1.2 dB / 1 LS, 7 PK, 1 HS` is computed in the View by re-parsing the stored text once on selection; the VM does not store it. If preferred, refactor into a published struct later.)

- [ ] **Step 5: Run, expect PASS**

Run: `swift test --filter SettingsViewModelTests 2>&1 | tail -10`
Expected: 7 new tests passing + existing tests still green.

- [ ] **Step 6: Full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift
git commit -m "feat(eq): add EQ surface to SettingsViewModel"
```

---

## Task 8: `AppContainer` wiring + binder loop hop

`AppContainer.live()` constructs `LiveEqPresetStore(directory: ConfigPaths.eqPresetsDirectory)`. Inside the existing audio-binder loop (`for await snapshot in await store.changes`), track last `(eqEnabled, eqPresetName)` per active device. On change, call `engine.setAudioFilterChain(...)`. Missing file → log + clear chain.

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Create: `Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift`

- [ ] **Step 1: Write failing binder test**

Create `Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class AppContainerEqBinderTests: XCTestCase {
    func testTogglingEqEnabledWithPresetCallsSetAudioFilterChain() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("eq-binder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let eqStore = LiveEqPresetStore(directory: tmp)
        try await eqStore.save(
            name: "test-preset",
            text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n",
            overwrite: false
        )

        let configStore = InMemoryConfigStore(initial: {
            var s = AppSettings.defaults
            s.outputDeviceUID = "dev-A"
            s.audioProfiles["dev-A"] = AudioProfile(
                hogModeEnabled: false, releaseHogOnPauseEnabled: false,
                volumeMode: .none, bitrate: 3,
                eqEnabled: false, eqPresetName: "test-preset"
            )
            return s
        }())
        let engine = MockPlayerEngine()
        let container = try AppContainer(
            // ... existing in-process container init that tests already use,
            // adding eqPresetStore: eqStore ...
            configStore: configStore,
            playerEngine: engine,
            eqPresetStore: eqStore
        )
        try await container.start()

        // Toggle EQ on:
        try await configStore.update {
            $0.audioProfiles["dev-A"]?.eqEnabled = true
        }

        // Wait for the binder to fire engine.setAudioFilterChain non-nil.
        try await WaitUntil.satisfied(timeout: 1.0) {
            await engine.recorded.contains { recorded in
                if case .setAudioFilterChain(let chain) = recorded { return chain != nil }
                return false
            }
        }

        // Toggle EQ off:
        try await configStore.update {
            $0.audioProfiles["dev-A"]?.eqEnabled = false
        }
        try await WaitUntil.satisfied(timeout: 1.0) {
            await engine.recorded.contains { recorded in
                if case .setAudioFilterChain(let chain) = recorded { return chain == nil }
                return false
            }
        }
    }
}
```

(Use the existing `WaitUntil` helper from `Tests/RPPlayerTests/Helpers/WaitUntil.swift`. The `AppContainer(...)` test init in the codebase already exposes most collaborators — match the pattern that PR 26 / PR 34 binder tests use. If `InMemoryConfigStore` isn't already in the tests folder, reuse whatever helper the existing binder tests use; do not invent a new one.)

- [ ] **Step 2: Run, expect compile fail**

Run: `swift test --filter AppContainerEqBinderTests 2>&1 | tail -15`
Expected: missing `eqPresetStore:` parameter on `AppContainer.init`.

- [ ] **Step 3: Add `eqPresetStore` to `AppContainer.init`**

Edit `Sources/RPPlayer/App/AppContainer.swift`:

1. Add stored property near the existing collaborator fields:

```swift
    public let eqPresetStore: any EqPresetStore
```

2. Add parameter to the public `init(...)`:

```swift
        eqPresetStore: any EqPresetStore,
```

(Insert after the parameter most-topically-related — `audioDeviceCatalog` or `configStore`.)

3. Add to `.live()`:

```swift
        let eqPresetStore: any EqPresetStore = LiveEqPresetStore(directory: ConfigPaths.eqPresetsDirectory)
```

And pass it into the `AppContainer(...)` constructor call.

4. Inside `AppContainer.swift`, append a private fallback at the bottom near the other Noop types (the existing file uses `private actor Noop*` pattern):

```swift
private actor NoopEqPresetStore: EqPresetStore {
    func list() async -> [String] { [] }
    func exists(name: String) async -> Bool { false }
    func loadText(name: String) async throws -> String { throw EqPresetStoreError.notFound }
    func save(name: String, text: String, overwrite: Bool) async throws { throw EqPresetStoreError.ioFailure("noop") }
    func delete(name: String) async throws { throw EqPresetStoreError.notFound }
}
```

(If `LiveEqPresetStore` construction can't fail in practice — its init swallows directory-create errors — the Noop is held for future hardening / unbundled paths.)

5. Pass `eqPresetStore` into `SettingsViewModel(...)` at the existing construction site.

- [ ] **Step 4: Extend the audio-binder loop**

Find the existing `for await snapshot in await store.changes` loop in `AppContainer.live()` (around line 250–360 per the grep earlier). It already tracks `lastForceMax`, `lastEffectiveRG`, `lastHog`. Add adjacent state:

```swift
                var lastEqEnabled = startupProfile.eqEnabled
                var lastEqPresetName = startupProfile.eqPresetName
```

Inside the per-snapshot block, after the existing volume/hog handling, append:

```swift
                    let nowEqEnabled = profile.eqEnabled
                    let nowEqName = profile.eqPresetName
                    if nowEqEnabled != lastEqEnabled || nowEqName != lastEqPresetName {
                        lastEqEnabled = nowEqEnabled
                        lastEqPresetName = nowEqName
                        if nowEqEnabled, let name = nowEqName {
                            do {
                                let raw = try await eqPresetStore.loadText(name: name)
                                if case .success(let preset) = EqPresetParser.parse(text: raw, filename: name),
                                   let chain = EqChainBuilder.build(preset) {
                                    try? await engine.setAudioFilterChain(chain)
                                } else {
                                    try? await engine.setAudioFilterChain(nil)
                                }
                            } catch {
                                logger.warning("eq: failed to load preset \(name): \(error)")
                                try? await engine.setAudioFilterChain(nil)
                            }
                        } else {
                            try? await engine.setAudioFilterChain(nil)
                        }
                    }
```

(`profile` is the active device profile already in scope per the loop's existing structure. Mirror exactly how `nowForceMax` etc. are read; don't introduce new accessor patterns.)

- [ ] **Step 5: Run binder test, expect PASS**

Run: `swift test --filter AppContainerEqBinderTests 2>&1 | tail -10`
Expected: 1 test passing.

- [ ] **Step 6: Run full suite**

Run: `swift test 2>&1 | tail -5`
Expected: full suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/App/AppContainerEqBinderTests.swift
git commit -m "feat(eq): wire EqPresetStore + binder calls engine.setAudioFilterChain"
```

---

## Task 9: Settings UI — Equalizer block

Renders inside the existing `deviceSettingsSection` below the Volume row. No new tests (View layer; VM is exhaustive). Manual verification via `swift run RPPlayer` + Settings panel.

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`

- [ ] **Step 1: Add UI block**

Locate `deviceSettingsSection` body in `Sources/RPPlayer/Shell/SettingsView.swift`. After the Volume row, insert:

```swift
            // EQ section
            HStack(alignment: .firstTextBaseline) {
                Text("Equalizer")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.eqEnabled },
                    set: { v in Task { await viewModel.setEqEnabled(v) } }
                ))
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: Binding<String?>(
                        get: { viewModel.eqPresetName },
                        set: { v in Task { await viewModel.setEqPresetName(v) } }
                    )) {
                        Text("(None)").tag(String?.none)
                        ForEach(viewModel.availablePresets, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button {
                        guard let name = viewModel.eqPresetName else { return }
                        showDeleteConfirm(presetName: name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.eqPresetName == nil)
                    .help("Delete selected preset")
                }

                HStack {
                    Button("Import Preset…") { showImportPanel() }
                    Button("Export Preset…") { showExportPanel() }
                        .disabled(viewModel.eqPresetName == nil)
                }

                Group {
                    Text("Create presets at ")
                    + Text("[squig.link](https://squig.link)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .onAppear {
                Task { await viewModel.refreshPresets() }
            }
```

Add helper methods on the View struct (next to existing alert-state and NSOpenPanel patterns the file already uses — model on `volumeForceMaxButton`'s alert wiring):

```swift
    @State private var importAlert: ImportAlert?
    @State private var deleteAlert: DeleteAlert?

    private struct ImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let collisionName: String?
        let pendingURL: URL?
    }

    private struct DeleteAlert: Identifiable {
        let id = UUID()
        let presetName: String
        let affectedDeviceUIDs: [String]
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runImport(url: url, overwrite: false) }
    }

    private func runImport(url: URL, overwrite: Bool) async {
        do {
            let outcome = try await viewModel.importPresetFile(url: url, overwrite: overwrite)
            switch outcome {
            case .imported(let name):
                await viewModel.setEqPresetName(name)
            case .nameCollision(let name):
                importAlert = ImportAlert(
                    title: "Preset “\(name)” already exists",
                    message: "Overwrite the existing preset?",
                    collisionName: name,
                    pendingURL: url
                )
            }
        } catch SettingsViewModel.EqImportError.parseFailed(let reasons) {
            importAlert = ImportAlert(
                title: "Cannot import preset",
                message: reasons.joined(separator: "\n"),
                collisionName: nil,
                pendingURL: nil
            )
        } catch {
            importAlert = ImportAlert(
                title: "Cannot import preset",
                message: "\(error)",
                collisionName: nil,
                pendingURL: nil
            )
        }
    }

    private func showExportPanel() {
        guard let name = viewModel.eqPresetName else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await viewModel.exportPreset(to: url) }
            catch { importAlert = ImportAlert(title: "Export failed", message: "\(error)", collisionName: nil, pendingURL: nil) }
        }
    }

    private func showDeleteConfirm(presetName: String) {
        Task {
            let uids = await viewModel.prepareDeletePreset(name: presetName)
            await MainActor.run {
                deleteAlert = DeleteAlert(presetName: presetName, affectedDeviceUIDs: uids)
            }
        }
    }
```

Add `.alert(item: $importAlert) { alert in ... }` and `.alert(item: $deleteAlert) { alert in ... }` modifiers to the section, mirroring how `volumeForceMaxAlert` is wired in the same View. For the delete-alert body:

```swift
                .alert(item: $deleteAlert) { alert in
                    let names = alert.affectedDeviceUIDs
                    let body = names.isEmpty
                        ? "Delete preset “\(alert.presetName)”?"
                        : "Preset “\(alert.presetName)” is in use by \(names.count) device\(names.count == 1 ? "" : "s"). Deleting it will clear that reference."
                    return Alert(
                        title: Text("Delete preset?"),
                        message: Text(body),
                        primaryButton: .destructive(Text("Delete")) {
                            Task { try? await viewModel.deletePresetConfirmed(name: alert.presetName) }
                        },
                        secondaryButton: .cancel()
                    )
                }
```

For the import alert (collision branch):

```swift
                .alert(item: $importAlert) { alert in
                    if let name = alert.collisionName, let url = alert.pendingURL {
                        return Alert(
                            title: Text(alert.title),
                            message: Text(alert.message),
                            primaryButton: .destructive(Text("Overwrite")) {
                                Task { await runImport(url: url, overwrite: true) }
                            },
                            secondaryButton: .cancel()
                        )
                    } else {
                        return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
                    }
                }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build clean.

- [ ] **Step 3: Full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all green (~444–446 total, depending on exact added test count).

- [ ] **Step 4: Manual verify**

Run: `swift run RPPlayer` and open Settings. Verify:
- Equalizer toggle appears below Volume row.
- Picker shows "(None)" plus any preset names already saved.
- Import Preset… opens NSOpenPanel filtered to `.txt`. Pick `.temp/5k_usr_5k_usr_XS_gergely.txt` (or any AutoEQ file); preset name appears in picker.
- Picker selection persists across app restart for the active device.
- Trash icon disabled when "(None)" selected; enabled otherwise — clicking it shows confirm alert.
- Export Preset… writes the verbatim original file to chosen path.
- With EQ on + preset selected, play a song; verify audio is filtered (load a heavy-bass preset and confirm bass change).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(eq): Settings UI — toggle, picker, import/export/delete"
```

---

## Task 10: Docs

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: `CHANGELOG.md` — append under `## [Unreleased]`**

```markdown
### Added

- Parametric EQ MVP. Per-device toggle plus preset library under `~/Library/Application Support/RP Player/EqPresets/`. Imports AutoEQ / Equalizer APO / REW `.txt` format (PK / LS / HS bands, up to 10, with Preamp). Export writes the stored file verbatim. Delete prompts when other devices reference the preset and nil-outs their reference on confirm. Filter chain applied via libmpv `af` property using FFmpeg `lavfi=[volume,equalizer,lowshelf,highshelf,...]` graph.
- `RPSmoke --probe-filters` diagnostic flag that lists available mpv filters and confirms the EQ graph accepts.

### Changed

- `AudioProfile` gains `eqEnabled: Bool` (default false) and `eqPresetName: String?` (default nil). Pre-PR-35 profiles migrate via `decodeIfPresent` defaults.
- `PlayerEngine` gains `setAudioFilterChain(_ chain: String?) async throws`. `MpvPlayerEngine` writes the `af` property (empty string clears the chain).
```

- [ ] **Step 2: `CLAUDE.md` — PR status table**

Add row to the PR table (after PR 34):

```markdown
| 35   | claude/pr35-parametric-eq-mvp | ⏳ | Parametric EQ MVP: `PlayerEngine.setAudioFilterChain(_:)` → `mpv_set_property_string("af", ...)`; `AudioProfile.eqEnabled` + `eqPresetName` (filename reference, not inline preset); `EqPresetStore` actor (LRU-free filesystem store at `ConfigPaths.eqPresetsDirectory` keyed by `<name>.txt`, sanitized filenames, save/load/delete/exists/list); `EqModels` (EqBandType / EqBand / EqPreset); strict `EqPresetParser` (any warning → reject — unsupported types LP/HP/NO/AP/BP, >10 bands, malformed lines all fail; OFF filters silently skipped); `EqPresetWriter` (round-trip identity from parsed form); `EqChainBuilder` (Preamp → `volume=<n>dB`; PK → `equalizer=f=:t=q:w=:g=`; LS/HS → `lowshelf`/`highshelf`); AppContainer binder loop hop watches `(eqEnabled, eqPresetName)` per active device and calls `engine.setAudioFilterChain(...)`; SettingsViewModel surface (`eqEnabled`/`eqPresetName`/`availablePresets`, `setEqEnabled`, `setEqPresetName`, `importPresetFile(url:overwrite:)` → `.imported` / `.nameCollision`, `exportPreset(to:)` copies stored .txt verbatim, `prepareDeletePreset(name:)` returns referencing UIDs, `deletePresetConfirmed(name:)` nil-outs refs + removes file); SettingsView "Equalizer" block (toggle, picker with trash icon, Import/Export buttons, squig.link hint, collision-overwrite + delete-confirm alerts); RPSmoke `--probe-filters` flag retained as diagnostic. |
```

Bump "Current state" at the top to PR 35 + point Next up at the next subsystem.

- [ ] **Step 3: `CLAUDE.md` — Test counts**

Append to the "Test counts by PR" list:

```markdown
- After PR 35 Parametric EQ MVP — `setAudioFilterChain` engine surface (1); EqModels Codable round-trip (3); strict parser happy path + reject-on-warning suite (9); writer + chain builder (7); EqPresetStore (9); AudioProfile EQ migration (2); SettingsViewModel EQ surface (7); AppContainerEqBinder integration (1). Net delta: 421 → ~440 (+19).
```

(Final number depends on whether sandbox tests cover any extra edge case. Update with the real count after the test pass.)

- [ ] **Step 4: `CLAUDE.md` — Key technical decisions → Audio pipeline**

Append to the Audio pipeline section:

```markdown
- **Parametric EQ.** `AudioProfile.eqEnabled: Bool` (default false) + `AudioProfile.eqPresetName: String?` (filename reference, default nil). Presets stored verbatim as `.txt` under `~/Library/Application Support/RP Player/EqPresets/<name>.txt` via `LiveEqPresetStore` actor (`Sources/RPPlayer/Config/EqPresetStore.swift`). Parser is strict — any warning (unsupported types LP/HP/NO/AP/BP, >10 bands, malformed line) rejects the file. `OFF` filter syntax is silently skipped (intentional user state in the source format, not a defect). Filter chain via `mpv_set_property_string("af", ...)` with FFmpeg lavfi graph `lavfi=[volume=<preamp>dB,equalizer=f=...:t=q:w=...:g=...,lowshelf=...,highshelf=...]`. Mid-playback safe (mpv applies dynamically without reopening). Compose orthogonally with hog mode, Force Max, ReplayGain. Bit-perfect claim now lives in the Force Max tooltip ("Bit-perfect when EQ is off") — PR 34 already moved it.
- **EQ preset library is global, not per-device.** Multiple devices may reference the same `eqPresetName`. Deleting a preset surfaces a confirm alert listing referencing device UIDs (`SettingsViewModel.prepareDeletePreset(name:)`); on confirm, `deletePresetConfirmed(name:)` nil-outs every `eqPresetName` field that references it AND removes the file from disk. Export copies the stored .txt **verbatim** (preserves comments, `Xfeed:` lines, OFF filters, whitespace) — `EqPresetWriter` exists only for round-trip-from-parsed-form tests.
```

- [ ] **Step 5: Run full suite one more time**

Run: `swift test 2>&1 | tail -5`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CLAUDE.md
git commit -m "docs(pr35): EQ MVP entries in CHANGELOG + CLAUDE"
```

---

## Self-Review

- Spec section "Goal / Why / Preset format / Engine surface / Filter chain format / Models / AudioProfile additions / Parser / Serializer / UI / File picker / AppContainer binder / View model / Interactions / Bit-perfect lingo": each is covered by a numbered task. Storage refinement (library-based, filename reference, delete-with-confirm, verbatim export, strict parser) supersedes spec where it differs and is noted in the plan header.
- "Out of scope": per-band UI, crossfeed, per-band bypass beyond syntactic OFF, types beyond PK/LS/HS, preset library beyond one-stored-per-name, auto-EQ — all deferred. Plan does not introduce them.
- Open spec questions: (1) filter availability — probed in plan preamble (all OK); (2) default export filename — `\(name).txt` (resolved); (3) warning surfacing — resolved to "reject strictly" per user (resolved).
- Placeholder scan: no TBD / TODO / "appropriate error handling" / "similar to Task N" copy-paste. Each step shows actual code.
- Type consistency:
  - `EqPreset` / `EqBand` / `EqBandType` names match across Task 2 / 3 / 4 / 5.
  - `eqEnabled` / `eqPresetName` match between AudioProfile (Task 6), VM (Task 7), binder (Task 8), UI (Task 9).
  - `EqPresetStore` protocol methods `list / exists / loadText / save / delete` match Task 5 definition and Task 7 / 8 call sites.
  - `setAudioFilterChain(_:)` signature stable Task 1 → Task 8.
- Test count target: spec estimated ~25; plan delivers ~37–39 explicit new tests across tasks 1–8 (writing happens to land more granular tests). Real net delta will land in the CLAUDE.md update at execution time.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-12-parametric-eq-mvp.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review between tasks. Matches PR 34 cadence; tightest correctness loop.
2. **Inline Execution** — run all tasks in this session with checkpoints. Faster if everything goes clean; main context absorbs more reading.

Awaiting approval.
