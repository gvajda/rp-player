# EQ Preset Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the read-only EQ preset *view* panel with an *edit* panel that lets users create, modify, rename, and save presets directly in Settings, while preserving file-based shared storage and adding in-memory live preview.

**Architecture:** Extend `SettingsViewModel` with edit state and methods (V1). A new `EqEditingOverride` actor carries the in-memory draft to the audio filter binder, which now merges config snapshots with override state. `EqPresetParser`/`EqPresetWriter` are upgraded to round-trip disabled (`OFF`) rows so the `Bypass` filter-type option is honored across save/load. `EqPresetStore` gains `rename(from:to:)` and a 30-char name cap. UI gains a `[+]` (new) button, `[✎ edit]` button (replaces eye), and an inline edit panel with grid-aligned bands, plus rename / save-as sheets.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 14), async/await, AsyncStream, libmpv lavfi chain (existing). XCTest with `@MainActor` view-model tests.

**Reference spec:** [docs/superpowers/specs/2026-05-21-eq-preset-editor-design.md](../specs/2026-05-21-eq-preset-editor-design.md)

---

## File Structure

### Created
- `Sources/RPPlayer/Config/EqEditingOverride.swift` — actor exposing the editing draft + `AsyncStream<EqPreset?>` (~60 LOC).
- `Sources/RPPlayer/Shell/EqEditPanel.swift` — SwiftUI view rendering the edit panel grid + footer buttons (~250 LOC).
- `Tests/RPPlayerTests/Config/EqEditingOverrideTests.swift`
- `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

### Modified
- `Sources/RPPlayer/Config/EqPresetParser.swift` — preserve OFF rows.
- `Sources/RPPlayer/Config/EqPresetWriter.swift` — emit OFF rows.
- `Sources/RPPlayer/Config/EqPresetStore.swift` — `rename` API, 30-char cap, `NoopEqPresetStore.rename`.
- `Sources/RPPlayer/App/AppContainer.swift` — `runAudioFilterBinder` merges override; container constructs + injects `EqEditingOverride`.
- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — new edit state, methods, override dep, import-name truncation.
- `Sources/RPPlayer/Shell/SettingsView.swift` — picker row buttons (`[+]`, `[✎ edit]`, remove eye), embed `EqEditPanel`, sheet plumbing.
- `Tests/RPPlayerTests/Config/EqPresetParserTests.swift`
- `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`
- `Tests/RPPlayerTests/Config/EqPresetStoreTests.swift`
- `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`
- `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift` — stub override holder for view-model tests.
- `CHANGELOG.md`, `docs/pr-history.md`, `docs/test-counts.md`, `docs/architecture.md`, `CLAUDE.md`, `README.md`.

---

## Task 1: Parser preserves OFF filter rows

**Files:**
- Modify: `Sources/RPPlayer/Config/EqPresetParser.swift:55-67`
- Test:   `Tests/RPPlayerTests/Config/EqPresetParserTests.swift`

- [ ] **Step 1: Add failing parser test for OFF preservation**

Append to `EqPresetParserTests`:

```swift
func testOffFilterPreservedAsDisabledBand() throws {
    let text = """
    Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
    Filter 2: OFF LS Fc 200 Hz Gain 2 dB Q 0.7
    Filter 3: ON HS Fc 300 Hz Gain 3 dB Q 0.5
    """
    let preset = try EqPresetParser.parse(text: text, filename: "n").get()
    XCTAssertEqual(preset.bands.count, 3)
    XCTAssertEqual(preset.bands[0].enabled, true)
    XCTAssertEqual(preset.bands[1].enabled, false)
    XCTAssertEqual(preset.bands[1].type, .lowShelf)
    XCTAssertEqual(preset.bands[1].fcHz, 200)
    XCTAssertEqual(preset.bands[1].gainDb, 2)
    XCTAssertEqual(preset.bands[1].q, 0.7, accuracy: 0.0001)
    XCTAssertEqual(preset.bands[2].enabled, true)
}
```

Also **delete or replace** the existing test `testOffFiltersSilentlySkippedNoWarning` (lines 45-54) — its expectation is now wrong. Replace its body with the new contract:

```swift
func testOffFiltersKeptInOrderWithDisabledFlag() throws {
    let text = """
    Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
    Filter 2: OFF PK Fc 200 Hz Gain 2 dB Q 1.0
    Filter 3: ON PK Fc 300 Hz Gain 3 dB Q 1.0
    """
    let preset = try EqPresetParser.parse(text: text, filename: "n").get()
    XCTAssertEqual(preset.bands.count, 3)
    XCTAssertEqual(preset.bands.map(\.fcHz), [100, 200, 300])
    XCTAssertEqual(preset.bands.map(\.enabled), [true, false, true])
}
```

- [ ] **Step 2: Run tests, confirm new ones fail**

Run: `swift test --filter EqPresetParserTests`
Expected: both new tests fail with `XCTAssertEqual failed: ("2") is not equal to ("3")` (current parser drops OFF rows, so band count is 2 not 3).

- [ ] **Step 3: Modify parser to keep OFF rows**

Edit `Sources/RPPlayer/Config/EqPresetParser.swift`. Replace the block at lines 55-67:

```swift
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
```

with:

```swift
let stateStr = String(line[stateR])
let typeStr = String(line[typeR])
let mapped: EqBandType?
switch typeStr {
case "PK": mapped = .peak
case "LS": mapped = .lowShelf
case "HS": mapped = .highShelf
default:
    warnings.append("Dropped unsupported filter type \(typeStr) at line \(index + 1)")
    continue
}
bands.append(EqBand(
    enabled: stateStr == "ON",
    type: mapped!,
    fcHz: fc, gainDb: gain, q: q
))
```

The `empty` rejection at the bottom of `parse()` still triggers when *all* lines fail to produce a band (so all-OFF files don't sneak past as empty — they'll yield disabled bands and pass).

- [ ] **Step 4: Run all parser tests, confirm pass**

Run: `swift test --filter EqPresetParserTests`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqPresetParser.swift Tests/RPPlayerTests/Config/EqPresetParserTests.swift
git commit -m "feat(eq): parser preserves OFF filter rows as disabled bands"
```

---

## Task 2: Writer emits OFF rows + sequential numbering

**Files:**
- Modify: `Sources/RPPlayer/Config/EqPresetWriter.swift:4-19`
- Test:   `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`

- [ ] **Step 1: Replace existing writer tests with OFF-aware variants**

Edit `Tests/RPPlayerTests/Config/EqPresetWriterTests.swift`. Replace the body of `testFilterNumberingCompactsOverDisabledBands` (lines 34-48) — its name and assertions are now wrong — with:

```swift
func testDisabledBandEmittedAsOff() {
    let preset = EqPreset(
        name: nil,
        preampDb: 0,
        bands: [
            EqBand(enabled: false, type: .peak, fcHz: 100, gainDb: 0, q: 1),
            EqBand(enabled: true,  type: .peak, fcHz: 200, gainDb: 0, q: 1),
            EqBand(enabled: true,  type: .peak, fcHz: 300, gainDb: 0, q: 1),
        ]
    )
    let text = EqPresetWriter.write(preset)
    XCTAssertTrue(text.contains("Filter 1: OFF PK Fc 100 Hz Gain 0 dB Q 1"), "got:\n\(text)")
    XCTAssertTrue(text.contains("Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1"),  "got:\n\(text)")
    XCTAssertTrue(text.contains("Filter 3: ON PK Fc 300 Hz Gain 0 dB Q 1"),  "got:\n\(text)")
}

func testRoundTripPreservesDisabledBand() throws {
    let preset = EqPreset(
        name: nil,
        preampDb: -1,
        bands: [
            EqBand(enabled: true,  type: .peak,     fcHz: 100, gainDb: 1,   q: 1),
            EqBand(enabled: false, type: .lowShelf, fcHz: 200, gainDb: 2,   q: 0.7),
            EqBand(enabled: true,  type: .highShelf, fcHz: 300, gainDb: 0.5, q: 0.5),
        ]
    )
    let written = EqPresetWriter.write(preset)
    let reparsed = try EqPresetParser.parse(text: written, filename: "n").get()
    XCTAssertEqual(reparsed.bands, preset.bands)
    XCTAssertEqual(reparsed.preampDb, preset.preampDb, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run writer tests, confirm new ones fail**

Run: `swift test --filter EqPresetWriterTests`
Expected: `testDisabledBandEmittedAsOff` and `testRoundTripPreservesDisabledBand` fail (writer currently filters out disabled bands).

- [ ] **Step 3: Update writer**

Edit `Sources/RPPlayer/Config/EqPresetWriter.swift`. Replace lines 4-19 (the `write` function) with:

```swift
public static func write(_ preset: EqPreset) -> String {
    var lines: [String] = []
    lines.append("CH: 0")
    lines.append("TYPE: PEQ")
    lines.append("Preamp: \(format(preset.preampDb)) dB")
    for (i, b) in preset.bands.enumerated() {
        let abbr: String
        switch b.type {
        case .peak: abbr = "PK"
        case .lowShelf: abbr = "LS"
        case .highShelf: abbr = "HS"
        }
        let state = b.enabled ? "ON" : "OFF"
        lines.append("Filter \(i + 1): \(state) \(abbr) Fc \(format(b.fcHz)) Hz Gain \(format(b.gainDb)) dB Q \(format(b.q))")
    }
    return lines.joined(separator: "\n") + "\n"
}
```

- [ ] **Step 4: Run all writer + parser tests, confirm pass**

Run: `swift test --filter EqPreset`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqPresetWriter.swift Tests/RPPlayerTests/Config/EqPresetWriterTests.swift
git commit -m "feat(eq): writer emits OFF rows with sequential filter numbering"
```

---

## Task 3: EqPresetStore — rename API + 30-char name cap

**Files:**
- Modify: `Sources/RPPlayer/Config/EqPresetStore.swift`
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift:526-532` (`NoopEqPresetStore`)
- Test:   `Tests/RPPlayerTests/Config/EqPresetStoreTests.swift`

- [ ] **Step 1: Add failing rename + cap tests**

Append to `EqPresetStoreTests`:

```swift
func testRenameMovesFile() async throws {
    let store = makeStore()
    try await store.save(name: "alpha", text: "v1", overwrite: false)
    try await store.rename(from: "alpha", to: "beta")
    let names = await store.list()
    XCTAssertEqual(names, ["beta"])
    let text = try await store.loadText(name: "beta")
    XCTAssertEqual(text, "v1")
}

func testRenameSameNameIsNoOp() async throws {
    let store = makeStore()
    try await store.save(name: "n", text: "v", overwrite: false)
    try await store.rename(from: "n", to: "n")
    let text = try await store.loadText(name: "n")
    XCTAssertEqual(text, "v")
}

func testRenameThrowsNotFound() async throws {
    let store = makeStore()
    do {
        try await store.rename(from: "missing", to: "anything")
        XCTFail("expected error")
    } catch EqPresetStoreError.notFound {
        // expected
    }
}

func testRenameThrowsAlreadyExists() async throws {
    let store = makeStore()
    try await store.save(name: "a", text: "1", overwrite: false)
    try await store.save(name: "b", text: "2", overwrite: false)
    do {
        try await store.rename(from: "a", to: "b")
        XCTFail("expected error")
    } catch EqPresetStoreError.alreadyExists {
        // expected
    }
    let a = try await store.loadText(name: "a")
    let b = try await store.loadText(name: "b")
    XCTAssertEqual(a, "1")
    XCTAssertEqual(b, "2")
}

func testRenameInvalidNameRejectedBothSides() async throws {
    let store = makeStore()
    try await store.save(name: "ok", text: "x", overwrite: false)
    do {
        try await store.rename(from: "ok", to: "bad/name")
        XCTFail("expected error")
    } catch EqPresetStoreError.invalidName {}
    do {
        try await store.rename(from: "bad/name", to: "ok2")
        XCTFail("expected error")
    } catch EqPresetStoreError.invalidName {}
}

func testSaveRejectsNameOverThirtyChars() async throws {
    let store = makeStore()
    let n31 = String(repeating: "a", count: 31)
    do {
        try await store.save(name: n31, text: "x", overwrite: false)
        XCTFail("expected error")
    } catch EqPresetStoreError.invalidName {}
}

func testSaveAllowsExactlyThirtyChars() async throws {
    let store = makeStore()
    let n30 = String(repeating: "a", count: 30)
    try await store.save(name: n30, text: "x", overwrite: false)
    let exists = await store.exists(name: n30)
    XCTAssertTrue(exists)
}
```

- [ ] **Step 2: Run store tests, confirm new ones fail**

Run: `swift test --filter EqPresetStoreTests`
Expected: rename tests fail (method missing — compile error); cap tests fail (current cap is 255).

- [ ] **Step 3: Tighten validate cap and add `rename` to protocol + LiveEqPresetStore**

Edit `Sources/RPPlayer/Config/EqPresetStore.swift`.

Replace the `private func validate(_ name:)` (lines 114-119) with:

```swift
private func validate(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 30 else { return false }
    if name.hasPrefix(".") { return false }
    if name.contains("/") || name.contains("\0") { return false }
    return true
}
```

Add the `rename` method to the protocol (after `func delete(name: String) async throws`):

```swift
func rename(from: String, to: String) async throws
```

Add the implementation inside `actor LiveEqPresetStore` (after the `delete` method):

```swift
public func rename(from: String, to: String) async throws {
    logger?.debug("EqPresetStore.rename from=\(from) to=\(to)")
    guard validate(from) else {
        logger?.warn("EqPresetStore.rename rejected from=\(from) reason=invalidName")
        throw EqPresetStoreError.invalidName
    }
    guard validate(to) else {
        logger?.warn("EqPresetStore.rename rejected to=\(to) reason=invalidName")
        throw EqPresetStoreError.invalidName
    }
    let src = fileURL(for: from)
    let dst = fileURL(for: to)
    guard fm.fileExists(atPath: src.path) else {
        logger?.warn("EqPresetStore.rename from=\(from) reason=notFound")
        throw EqPresetStoreError.notFound
    }
    if from == to { return }
    if fm.fileExists(atPath: dst.path) {
        logger?.info("EqPresetStore.rename to=\(to) skipped reason=alreadyExists")
        throw EqPresetStoreError.alreadyExists
    }
    do {
        try fm.moveItem(at: src, to: dst)
        logger?.info("EqPresetStore.rename from=\(from) to=\(to) moved")
    } catch {
        logger?.error("EqPresetStore.rename ioFailure=\(error)")
        throw EqPresetStoreError.ioFailure("\(error)")
    }
}
```

- [ ] **Step 4: Add `rename` stub to NoopEqPresetStore**

Edit `Sources/RPPlayer/Shell/SettingsViewModel.swift:526-532` (`NoopEqPresetStore`). After the `delete` stub, add:

```swift
func rename(from: String, to: String) async throws { throw EqPresetStoreError.notFound }
```

- [ ] **Step 5: Build to catch any other conformers**

Run: `swift build`
Expected: compiles. If any other types conform to `EqPresetStore` (search with `grep -rn "EqPresetStore" Tests/`), add the same `rename` stub.

- [ ] **Step 6: Run store tests, confirm pass**

Run: `swift test --filter EqPresetStoreTests`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Config/EqPresetStore.swift Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Config/EqPresetStoreTests.swift
git commit -m "feat(eq): EqPresetStore.rename + 30-char name cap"
```

---

## Task 4: EqEditingOverride actor

**Files:**
- Create: `Sources/RPPlayer/Config/EqEditingOverride.swift`
- Create: `Tests/RPPlayerTests/Config/EqEditingOverrideTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/RPPlayerTests/Config/EqEditingOverrideTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class EqEditingOverrideTests: XCTestCase {
    func testInitialSnapshotIsNil() async {
        let holder = EqEditingOverride()
        let snap = await holder.snapshot()
        XCTAssertNil(snap)
    }

    func testSetThenSnapshotReturnsValue() async {
        let holder = EqEditingOverride()
        let preset = EqPreset(name: nil, preampDb: -2, bands: [
            EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 3, q: 1)
        ])
        await holder.set(preset)
        let snap = await holder.snapshot()
        XCTAssertEqual(snap, preset)
    }

    func testChangesStreamYieldsUpdates() async throws {
        let holder = EqEditingOverride()
        let stream = await holder.changes
        let collector = Task<[EqPreset?], Never> {
            var collected: [EqPreset?] = []
            for await value in stream {
                collected.append(value)
                if collected.count == 3 { break }
            }
            return collected
        }
        // give the subscriber a moment to register
        try await Task.sleep(nanoseconds: 20_000_000)
        let p1 = EqPreset(name: nil, preampDb: 0, bands: [])
        let p2 = EqPreset(name: nil, preampDb: -1, bands: [])
        await holder.set(p1)
        await holder.set(p2)
        await holder.set(nil)
        let out = await collector.value
        XCTAssertEqual(out, [p1, p2, nil])
    }

    func testMultipleSubscribersAllReceiveValues() async throws {
        let holder = EqEditingOverride()
        let s1 = await holder.changes
        let s2 = await holder.changes
        async let c1: EqPreset? = {
            for await v in s1 { return v }
            return nil
        }()
        async let c2: EqPreset? = {
            for await v in s2 { return v }
            return nil
        }()
        try await Task.sleep(nanoseconds: 20_000_000)
        let p = EqPreset(name: nil, preampDb: 1, bands: [])
        await holder.set(p)
        let (r1, r2) = await (c1, c2)
        XCTAssertEqual(r1, p)
        XCTAssertEqual(r2, p)
    }
}
```

- [ ] **Step 2: Run tests, confirm fail**

Run: `swift test --filter EqEditingOverrideTests`
Expected: compile error — `EqEditingOverride` does not exist.

- [ ] **Step 3: Create the actor**

Create `Sources/RPPlayer/Config/EqEditingOverride.swift`:

```swift
import Foundation

public actor EqEditingOverride {
    private var current: EqPreset?
    private var continuations: [UUID: AsyncStream<EqPreset?>.Continuation] = [:]

    public init() {}

    public func set(_ preset: EqPreset?) {
        current = preset
        for (_, c) in continuations { c.yield(preset) }
    }

    public func snapshot() -> EqPreset? { current }

    public var changes: AsyncStream<EqPreset?> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `swift test --filter EqEditingOverrideTests`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Config/EqEditingOverride.swift Tests/RPPlayerTests/Config/EqEditingOverrideTests.swift
git commit -m "feat(eq): EqEditingOverride actor with AsyncStream changes"
```

---

## Task 5: AppContainer audio filter binder consumes override

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift:690-756` (`runAudioFilterBinder`, `applyAudioFilterState`, `AudioFilterKey`)
- Test:   `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`

- [ ] **Step 1: Add failing binder tests**

Append to `AppContainerAudioFilterBinderTests`. Use the same stub pattern (`StubConfigStore`, `MockPlayerEngine`, `waitUntil`) used by existing tests:

```swift
func testOverridePresetTakesPrecedenceOverDiskFile() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await eqStore.save(
        name: "disk-preset",
        text: "Filter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.0\n",
        overwrite: false
    )
    let override = EqEditingOverride()
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: true, eqPresetName: "disk-preset"
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let task = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            override: override,
            initialProfile: initialProfile
        )
    }
    defer { task.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call {
                return chain?.contains("Gain 6 dB") == false && chain?.contains("equalizer") == true
            }
            return false
        }
    }, timeout: 1.0)

    // push an override with a different gain
    let editingPreset = EqPreset(
        name: nil,
        preampDb: 0,
        bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: -12, q: 1)]
    )
    await override.set(editingPreset)
    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call {
                return chain?.contains("g=-12") ?? false
            }
            return false
        }
    }, timeout: 1.0)
}

func testClearingOverrideRevertsToDiskPreset() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await eqStore.save(
        name: "p",
        text: "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n",
        overwrite: false
    )
    let override = EqEditingOverride()
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: true, eqPresetName: "p"
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    await override.set(EqPreset(
        name: nil, preampDb: 0,
        bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: -6, q: 1)]
    ))

    let task = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            override: override,
            initialProfile: initialProfile
        )
    }
    defer { task.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call { return chain?.contains("g=-6") ?? false }
            return false
        }
    }, timeout: 1.0)

    await override.set(nil)
    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call { return chain?.contains("g=3") ?? false }
            return false
        }
    }, timeout: 1.0)
}

func testOverrideIgnoredWhenEqDisabled() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    let override = EqEditingOverride()
    let initialProfile = AudioProfile(
        hogModeEnabled: false, releaseHogOnPauseEnabled: false,
        volumeMode: .none, bitrate: 3,
        eqEnabled: false, eqPresetName: nil
    )
    var initialSettings = AppSettings.default
    initialSettings.outputDeviceUID = "dev-A"
    initialSettings.audioProfiles["dev-A"] = initialProfile
    let configStore = StubConfigStore(initial: initialSettings)
    let engine = MockPlayerEngine()

    let task = Task {
        await AppContainer.runAudioFilterBinder(
            store: configStore,
            engine: engine,
            eqPresetStore: eqStore,
            override: override,
            initialProfile: initialProfile
        )
    }
    defer { task.cancel() }

    try await waitUntil({
        let calls = await engine.recordedCalls()
        return calls.contains { call in
            if case .setAudioFilterChain(let chain) = call { return chain == nil }
            return false
        }
    }, timeout: 1.0)

    let priorCount = await engine.recordedCalls().count
    await override.set(EqPreset(
        name: nil, preampDb: 0,
        bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 12, q: 1)]
    ))
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterCount = await engine.recordedCalls().count
    // No new chain emitted: override has no effect when EQ is off
    XCTAssertEqual(priorCount, afterCount)
}
```

Also update the **existing** two passing tests' calls to `runAudioFilterBinder` to pass `override: EqEditingOverride()` — search for `runAudioFilterBinder(` in the file and add the new parameter to each call site.

- [ ] **Step 2: Run binder tests, confirm new ones fail**

Run: `swift test --filter AppContainerAudioFilterBinderTests`
Expected: compile errors — `override` argument unknown.

- [ ] **Step 3: Modify binder to merge override stream**

Edit `Sources/RPPlayer/App/AppContainer.swift`. Replace `runAudioFilterBinder` (lines 690-708) with:

```swift
internal static func runAudioFilterBinder(
    store: any ConfigStore,
    engine: any PlayerEngine,
    eqPresetStore: any EqPresetStore,
    override: EqEditingOverride,
    initialProfile: AudioProfile
) async {
    var currentProfile = initialProfile
    var currentOverride: EqPreset? = await override.snapshot()
    await applyAudioFilterState(
        engine: engine,
        store: eqPresetStore,
        profile: currentProfile,
        override: currentOverride
    )

    let configStream = await store.changes
    let overrideStream = await override.changes

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await snapshot in configStream {
                let uid = snapshot.outputDeviceUID
                let next = uid.flatMap { snapshot.audioProfiles[$0] } ?? AudioProfile.safeDefault
                await applyIfChanged(
                    engine: engine,
                    store: eqPresetStore,
                    nextProfile: next,
                    nextOverride: await override.snapshot(),
                    prevProfile: &currentProfile,
                    prevOverride: &currentOverride
                )
            }
        }
        group.addTask {
            for await preset in overrideStream {
                await applyIfChanged(
                    engine: engine,
                    store: eqPresetStore,
                    nextProfile: currentProfile,
                    nextOverride: preset,
                    prevProfile: &currentProfile,
                    prevOverride: &currentOverride
                )
            }
        }
    }
}
```

**Note on the in-out captures:** Swift's structured concurrency rejects `inout` captures across task boundaries; the two child tasks instead must share state through a `MainActor`-bound box or an actor. To keep the diff small, wrap mutable state in a tiny local actor:

```swift
private actor _BinderState {
    var profile: AudioProfile
    var override: EqPreset?
    init(profile: AudioProfile, override: EqPreset?) { self.profile = profile; self.override = override }
    func updateProfile(_ p: AudioProfile) -> (changed: Bool, prev: AudioProfile) {
        let prev = profile
        let changed = !(p == prev)
        profile = p
        return (changed, prev)
    }
    func updateOverride(_ o: EqPreset?) -> Bool {
        let changed = o != override
        override = o
        return changed
    }
    func snapshot() -> (AudioProfile, EqPreset?) { (profile, override) }
}
```

Final `runAudioFilterBinder`:

```swift
internal static func runAudioFilterBinder(
    store: any ConfigStore,
    engine: any PlayerEngine,
    eqPresetStore: any EqPresetStore,
    override: EqEditingOverride,
    initialProfile: AudioProfile
) async {
    let state = _BinderState(profile: initialProfile, override: await override.snapshot())
    let (p0, o0) = await state.snapshot()
    await applyAudioFilterState(engine: engine, store: eqPresetStore, profile: p0, override: o0)

    let configStream = await store.changes
    let overrideStream = await override.changes

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await snapshot in configStream {
                let uid = snapshot.outputDeviceUID
                let next = uid.flatMap { snapshot.audioProfiles[$0] } ?? AudioProfile.safeDefault
                let (changed, _) = await state.updateProfile(next)
                if changed {
                    let (p, o) = await state.snapshot()
                    await applyAudioFilterState(engine: engine, store: eqPresetStore, profile: p, override: o)
                }
            }
        }
        group.addTask {
            for await preset in overrideStream {
                let changed = await state.updateOverride(preset)
                if changed {
                    let (p, o) = await state.snapshot()
                    await applyAudioFilterState(engine: engine, store: eqPresetStore, profile: p, override: o)
                }
            }
        }
    }
}
```

Replace `applyAudioFilterState` (lines 710-738) with a signature that accepts an override:

```swift
internal static func applyAudioFilterState(
    engine: any PlayerEngine,
    store: any EqPresetStore,
    profile: AudioProfile,
    override: EqPreset?
) async {
    var parts: [String] = []
    if profile.eqEnabled {
        if let override {
            parts = EqChainBuilder.buildParts(override)
        } else if let name = profile.eqPresetName {
            do {
                let raw = try await store.loadText(name: name)
                if case .success(let preset) = EqPresetParser.parse(text: raw, filename: name) {
                    parts = EqChainBuilder.buildParts(preset)
                }
            } catch {
                // File missing or unreadable → EQ contributes nothing. Crossfeed may still apply below.
            }
        }
    }
    if profile.crossfeedEnabled {
        parts.append(CrossfeedFilterBuilder.buildPart(
            profile: profile.crossfeedProfile,
            fcut: profile.crossfeedFcut,
            feedDb: profile.crossfeedFeedDb
        ))
    }
    if parts.isEmpty {
        try? await engine.setAudioFilterChain(nil)
    } else {
        try? await engine.setAudioFilterChain("lavfi=[" + parts.joined(separator: ",") + "]")
    }
}
```

`AudioFilterKey` struct (lines 740-756) becomes unused — **delete it**. Equality is now handled per-field inside `_BinderState`. Search the test file for any remaining `AudioFilterKey` references and replace with direct profile comparisons (likely none, but check).

Add `_BinderState` as a private file-level actor near `runAudioFilterBinder` in `AppContainer.swift` (alongside the other internal helpers).

- [ ] **Step 4: Update call sites of `runAudioFilterBinder`**

Search for `runAudioFilterBinder(` in `Sources/RPPlayer/App/AppContainer.swift` (one production call site near line 336). Add a new local `let eqOverride = EqEditingOverride()` near where the eq store is constructed and pass `override: eqOverride` to the binder. Hold the instance on the container (see Task 7 for storage; for now declare it as a `let` local). This will be cleaned up properly in Task 7.

Run: `swift build`
Expected: compiles. If not, fix any straggling references.

- [ ] **Step 5: Run binder tests, confirm pass**

Run: `swift test --filter AppContainerAudioFilterBinderTests`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift
git commit -m "feat(eq): audio filter binder merges EqEditingOverride stream"
```

---

## Task 6: SettingsViewModel — edit state, methods, override wiring

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Modify: `Tests/RPPlayerTests/Shell/SettingsTestStubs.swift`
- Create: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Examine existing SettingsViewModel init + test stubs**

Run: `grep -n "init(\|configStore\|eqPresetStore" Sources/RPPlayer/Shell/SettingsViewModel.swift | head -20`
Run: `cat Tests/RPPlayerTests/Shell/SettingsTestStubs.swift`

Note the dependency injection pattern (defaulted parameters). We'll follow the same shape for `EqEditingOverride`.

- [ ] **Step 2: Write failing view-model tests**

Create `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelEqEditTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-eq-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func savePresetFile(_ store: LiveEqPresetStore, name: String) async throws {
        try await store.save(
            name: name,
            text: "Preamp: -1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n",
            overwrite: false
        )
    }

    private func makeVM(eqStore: any EqPresetStore, override: EqEditingOverride) -> SettingsViewModel {
        var initial = AppSettings.default
        initial.outputDeviceUID = "dev-A"
        initial.audioProfiles["dev-A"] = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "alpha"
        )
        let configStore = StubConfigStore(initial: initial)
        return SettingsViewModel(
            configStore: configStore,
            deviceCatalog: StubAudioDeviceCatalog(),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {},
            eqPresetStore: eqStore,
            eqEditingOverride: override
        )
    }

    func testBeginEditCurrentCopiesParsedPresetIntoEditingState() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()

        XCTAssertEqual(vm.editingOriginalName, "alpha")
        XCTAssertNotNil(vm.editingPreset)
        XCTAssertEqual(vm.editingPreset?.bands.count, 1)
        XCTAssertFalse(vm.editingDirty)
        let pushed = await override.snapshot()
        XCTAssertNotNil(pushed)
    }

    func testBeginNewPresetYieldsEmptyDraft() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        XCTAssertNil(vm.editingOriginalName)
        XCTAssertEqual(vm.editingPreset?.bands.count, 0)
        XCTAssertEqual(vm.editingPreset?.preampDb, 0)
        XCTAssertFalse(vm.editingDirty)
    }

    func testSetEditingPreampMarksDirtyAndPushesOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-4)
        try await Task.sleep(nanoseconds: 150_000_000) // wait out debounce
        XCTAssertEqual(vm.editingPreset?.preampDb, -4)
        XCTAssertTrue(vm.editingDirty)
        let snap = await override.snapshot()
        XCTAssertEqual(snap?.preampDb, -4)
    }

    func testAddEditingBandCapsAtTen() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        for _ in 0..<12 { await vm.addEditingBand() }
        XCTAssertEqual(vm.editingPreset?.bands.count, 10)
    }

    func testRemoveEditingBandDropsRow() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        await vm.addEditingBand()
        await vm.addEditingBand()
        await vm.removeEditingBand(at: 0)
        XCTAssertEqual(vm.editingPreset?.bands.count, 1)
    }

    func testSaveEditPersistsAndClearsOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-7)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await vm.saveEdit()
        let snap = await override.snapshot()
        XCTAssertNil(snap)
        let onDisk = try await eqStore.loadText(name: "alpha")
        XCTAssertTrue(onDisk.contains("Preamp: -7 dB"))
        XCTAssertNil(vm.editingPreset)
    }

    func testSaveAsCreatesNewFileAndSwitchesActivePreset() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-2)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await vm.saveEditAs(name: "alpha-copy")
        let names = await eqStore.list()
        XCTAssertEqual(names.sorted(), ["alpha", "alpha-copy"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha-copy")
    }

    func testSaveAsCollisionThrowsAndKeepsEditing() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await savePresetFile(eqStore, name: "beta")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        do {
            try await vm.saveEditAs(name: "beta")
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {}
        XCTAssertNotNil(vm.editingPreset)
        let snap = await override.snapshot()
        XCTAssertNotNil(snap)
    }

    func testRenameUpdatesProfilesAndStore() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        try await vm.renamePreset(from: "alpha", to: "alpha2")
        let names = await eqStore.list()
        XCTAssertEqual(names, ["alpha2"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha2")
        XCTAssertEqual(vm.editingOriginalName, "alpha2")
    }

    func testRenameCollisionRollsBackProfileRefs() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await savePresetFile(eqStore, name: "beta")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        do {
            try await vm.renamePreset(from: "alpha", to: "beta")
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {}
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha")
    }

    func testCancelEditClearsStateAndOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-10)
        try await Task.sleep(nanoseconds: 150_000_000)
        await vm.cancelEdit()
        XCTAssertNil(vm.editingPreset)
        XCTAssertFalse(vm.editingDirty)
        let snap = await override.snapshot()
        XCTAssertNil(snap)
    }

    func testDebounceCoalescesRapidEdits() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        for v in [-1.0, -2.0, -3.0, -4.0, -5.0] {
            await vm.setEditingPreamp(v)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let snap = await override.snapshot()
        XCTAssertEqual(snap?.preampDb, -5)
    }
}
```

- [ ] **Step 3: Add `eqEditingOverride` to `SettingsViewModel` init + add edit state and methods**

Edit `Sources/RPPlayer/Shell/SettingsViewModel.swift`.

In the `@Published` block (after `parsedEqPreset` declaration around line 46), add:

```swift
@Published public private(set) var editingPreset: EqPreset?
@Published public private(set) var editingOriginalName: String?
@Published public private(set) var editingDirty: Bool = false
public var editingIsNew: Bool { editingOriginalName == nil }
```

After `private var presetsRefreshTask` near line 79, add:

```swift
private let eqEditingOverride: EqEditingOverride
private var editingPushTask: Task<Void, Never>?
private static let editingDebounceNs: UInt64 = 100_000_000
```

In the `init(...)` parameter list (around line 81), add a defaulted parameter:

```swift
eqEditingOverride: EqEditingOverride = EqEditingOverride(),
```

In the init body (after `self.eqPresetStore = eqPresetStore`), store it:

```swift
self.eqEditingOverride = eqEditingOverride
```

Add a private helper near the other private helpers (e.g., right above `private func update(...)` at line 521):

```swift
private func pushOverrideDebounced() {
    editingPushTask?.cancel()
    let preset = editingPreset
    editingPushTask = Task { [weak self, override = eqEditingOverride] in
        try? await Task.sleep(nanoseconds: Self.editingDebounceNs)
        if Task.isCancelled { return }
        await override.set(preset)
        _ = self
    }
}

private func defaultEditingBand() -> EqBand {
    EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 0, q: 1.0)
}
```

Add the public edit API as new methods at the end of the class (just before the closing brace, before the private `NoopEqPresetStore`):

```swift
public func beginEditCurrent() async {
    logger?.debug("beginEditCurrent")
    guard let preset = parsedEqPreset, let name = eqPresetName else { return }
    await MainActor.run {
        self.editingPreset = preset
        self.editingOriginalName = name
        self.editingDirty = false
    }
    await eqEditingOverride.set(preset)
}

public func beginNewPreset() async {
    logger?.debug("beginNewPreset")
    let empty = EqPreset(name: nil, preampDb: 0, bands: [])
    await MainActor.run {
        self.editingPreset = empty
        self.editingOriginalName = nil
        self.editingDirty = false
    }
    await eqEditingOverride.set(empty)
}

public func cancelEdit() async {
    logger?.debug("cancelEdit")
    editingPushTask?.cancel()
    editingPushTask = nil
    await MainActor.run {
        self.editingPreset = nil
        self.editingOriginalName = nil
        self.editingDirty = false
    }
    await eqEditingOverride.set(nil)
}

public func setEditingPreamp(_ db: Double) async {
    await MainActor.run {
        guard self.editingPreset != nil else { return }
        let clamped = min(10.0, max(-30.0, db))
        self.editingPreset?.preampDb = clamped
        self.editingDirty = true
    }
    pushOverrideDebounced()
}

public func setEditingBand(at index: Int, _ band: EqBand) async {
    await MainActor.run {
        guard var preset = self.editingPreset, index >= 0, index < preset.bands.count else { return }
        let clamped = EqBand(
            enabled: band.enabled,
            type: band.type,
            fcHz: min(20000, max(20, band.fcHz)),
            gainDb: min(24, max(-24, band.gainDb)),
            q: min(10.0, max(0.1, band.q))
        )
        preset.bands[index] = clamped
        self.editingPreset = preset
        self.editingDirty = true
    }
    pushOverrideDebounced()
}

public func addEditingBand() async {
    await MainActor.run {
        guard var preset = self.editingPreset, preset.bands.count < EqPresetParser.maxBands else { return }
        preset.bands.append(self.defaultEditingBand())
        self.editingPreset = preset
        self.editingDirty = true
    }
    pushOverrideDebounced()
}

public func removeEditingBand(at index: Int) async {
    await MainActor.run {
        guard var preset = self.editingPreset, index >= 0, index < preset.bands.count else { return }
        preset.bands.remove(at: index)
        self.editingPreset = preset
        self.editingDirty = true
    }
    pushOverrideDebounced()
}

public func saveEdit() async throws {
    guard let preset = editingPreset, let name = editingOriginalName else {
        return
    }
    editingPushTask?.cancel(); editingPushTask = nil
    let text = EqPresetWriter.write(preset)
    try await eqPresetStore.save(name: name, text: text, overwrite: true)
    await eqEditingOverride.set(nil)
    await refreshPresets()
    if eqPresetName == name { await reloadParsedPreset() }
    await MainActor.run {
        self.editingPreset = nil
        self.editingOriginalName = nil
        self.editingDirty = false
    }
}

public func saveEditAs(name: String) async throws {
    guard let preset = editingPreset else { return }
    editingPushTask?.cancel(); editingPushTask = nil
    let trimmed = String(name.prefix(30))
    let text = EqPresetWriter.write(preset)
    try await eqPresetStore.save(name: trimmed, text: text, overwrite: false)
    await eqEditingOverride.set(nil)
    await refreshPresets()
    await setEqPresetName(trimmed)
    await reloadParsedPreset()
    await MainActor.run {
        self.editingPreset = nil
        self.editingOriginalName = nil
        self.editingDirty = false
    }
}

public func renamePreset(from: String, to: String) async throws {
    let trimmed = String(to.prefix(30))
    if trimmed == from { return }
    try await configStore.update { settings in
        for (uid, var profile) in settings.audioProfiles where profile.eqPresetName == from {
            profile.eqPresetName = trimmed
            settings.audioProfiles[uid] = profile
        }
    }
    do {
        try await eqPresetStore.rename(from: from, to: trimmed)
    } catch {
        try? await configStore.update { settings in
            for (uid, var profile) in settings.audioProfiles where profile.eqPresetName == trimmed {
                profile.eqPresetName = from
                settings.audioProfiles[uid] = profile
            }
        }
        throw error
    }
    await refreshPresets()
    await MainActor.run {
        if self.editingOriginalName == from { self.editingOriginalName = trimmed }
    }
}
```

Also update `importPresetFile` (around line 470) so the basename is truncated to 30 chars before save:

Find the line:
```swift
let name = url.deletingPathExtension().lastPathComponent
```
Replace with:
```swift
let name = String(url.deletingPathExtension().lastPathComponent.prefix(30))
```

- [ ] **Step 4: Update `SettingsTestStubs.swift` if needed**

The current stubs likely don't reference `eqEditingOverride`. The new VM tests construct one inline. **Confirm nothing else breaks** by running:

Run: `swift build`
Expected: builds.

- [ ] **Step 5: Run new VM tests**

Run: `swift test --filter SettingsViewModelEqEditTests`
Expected: all green.

- [ ] **Step 6: Run full Shell test set**

Run: `swift test --filter Shell`
Expected: green (no regression in existing `SettingsViewModelTests`, `SettingsViewModelCrossfeedTests`, etc.).

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): SettingsViewModel edit state, save/save-as/rename, override push"
```

---

## Task 7: AppContainer wiring — construct + inject EqEditingOverride

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift` (several call sites)

- [ ] **Step 1: Add `EqEditingOverride` instance to the container build path**

Run: `grep -n "runAudioFilterBinder\|SettingsViewModel(" Sources/RPPlayer/App/AppContainer.swift`
Expected: identifies the call site at line ~336 (binder) and the SettingsViewModel constructions at ~441, ~452, ~476, ~631.

Find the block that constructs `eqPresetStore` (search `LiveEqPresetStore(directory:`). Right after it, add:

```swift
let eqEditingOverride = EqEditingOverride()
```

This must be in a scope visible to *both* the `runAudioFilterBinder` call and the `SettingsViewModel(...)` construction.

- [ ] **Step 2: Pass the same instance to the binder and the view model**

In the `runAudioFilterBinder(...)` call (already updated in Task 5 to take `override:`), pass the new `eqEditingOverride` instead of a freshly-constructed one.

In every `SettingsViewModel(...)` construction in this file, add `eqEditingOverride: eqEditingOverride,` as a named parameter (before `logger:`).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: green.

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: all green (502 + new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(eq): wire EqEditingOverride through AppContainer to view model + binder"
```

---

## Task 8: SettingsView — picker row buttons + edit panel + sheets

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift` (eq section + new alert/sheet plumbing)
- Create: `Sources/RPPlayer/Shell/EqEditPanel.swift`

This task is UI-heavy with no unit-test pressure (existing `SettingsViewTests` is shallow — see line counts). Test by running the app and exercising the flow. Commit each substep separately so a failure is easy to bisect.

- [ ] **Step 1: Create `EqEditPanel.swift` with the grid view**

Create `Sources/RPPlayer/Shell/EqEditPanel.swift`:

```swift
import SwiftUI

struct EqEditPanel: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showSaveAsSheet = false
    @State private var showRenameSheet = false
    @State private var saveAsName = ""
    @State private var renameTarget = ""
    @State private var sheetError: String?
    @State private var saveAlert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preset = viewModel.editingPreset {
                header(preset)
                preampRow(preset)
                bandsGrid(preset)
                Button {
                    Task { await viewModel.addEditingBand() }
                } label: {
                    Label("Add band", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(preset.bands.count >= 10)

                Divider()

                footer(preset)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 4)
        .sheet(isPresented: $showSaveAsSheet) {
            nameSheet(
                title: "Save preset as",
                initialValue: saveAsName,
                onConfirm: { name in
                    do {
                        try await viewModel.saveEditAs(name: name)
                        showSaveAsSheet = false
                    } catch EqPresetStoreError.alreadyExists {
                        sheetError = "Name already used. Pick another."
                    } catch EqPresetStoreError.invalidName {
                        sheetError = "Use 1–30 characters; no slashes or leading dot."
                    } catch {
                        sheetError = nil
                        saveAlert = "Failed to save preset: \(error)"
                        showSaveAsSheet = false
                    }
                }
            )
        }
        .sheet(isPresented: $showRenameSheet) {
            nameSheet(
                title: "Rename preset",
                initialValue: renameTarget,
                onConfirm: { name in
                    guard let from = viewModel.editingOriginalName else {
                        showRenameSheet = false
                        return
                    }
                    do {
                        try await viewModel.renamePreset(from: from, to: name)
                        showRenameSheet = false
                    } catch EqPresetStoreError.alreadyExists {
                        sheetError = "Name already used. Pick another."
                    } catch EqPresetStoreError.invalidName {
                        sheetError = "Use 1–30 characters; no slashes or leading dot."
                    } catch {
                        sheetError = nil
                        saveAlert = "Failed to rename preset: \(error)"
                        showRenameSheet = false
                    }
                }
            )
        }
        .alert("Save failed", isPresented: Binding(get: { saveAlert != nil }, set: { if !$0 { saveAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveAlert ?? "")
        }
    }

    private func header(_ preset: EqPreset) -> some View {
        HStack {
            Text("Editing: \(viewModel.editingOriginalName ?? "Untitled")")
                .font(.headline)
            if viewModel.editingDirty {
                Text("(unsaved)").foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
        }
    }

    private func preampRow(_ preset: EqPreset) -> some View {
        HStack {
            Text("Preamp:")
            Stepper(
                value: Binding(
                    get: { preset.preampDb },
                    set: { v in Task { await viewModel.setEditingPreamp(v) } }
                ),
                in: -30...10,
                step: 0.1
            ) {
                Text(String(format: "%+.1f dB", preset.preampDb)).monospacedDigit()
            }
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private func bandsGrid(_ preset: EqPreset) -> some View {
        if preset.bands.isEmpty {
            Text("No bands. Click + Add band to start.").foregroundStyle(.secondary).font(.caption)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Text("Frequency").font(.caption).foregroundStyle(.secondary)
                    Text("Gain").font(.caption).foregroundStyle(.secondary)
                    Text("Q").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 16, height: 1)
                }
                ForEach(Array(preset.bands.enumerated()), id: \.offset) { idx, band in
                    bandRow(idx: idx, band: band)
                }
            }
        }
    }

    private func bandRow(idx: Int, band: EqBand) -> some View {
        GridRow {
            Picker(
                "",
                selection: Binding(
                    get: { typeMenuValue(for: band) },
                    set: { newValue in
                        Task {
                            let updated = applyTypeMenu(newValue, to: band)
                            await viewModel.setEditingBand(at: idx, updated)
                        }
                    }
                )
            ) {
                Text("Bypass").tag(BandTypeMenu.bypass)
                Text("Peak").tag(BandTypeMenu.peak)
                Text("Low Shelf").tag(BandTypeMenu.lowShelf)
                Text("High Shelf").tag(BandTypeMenu.highShelf)
            }
            .labelsHidden()
            .frame(maxWidth: 130)

            Stepper(
                value: Binding(
                    get: { Double(Int(band.fcHz)) },
                    set: { v in
                        var b = band
                        b.fcHz = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: 20...20000,
                step: 1
            ) {
                Text(String(format: "%5.0f Hz", band.fcHz)).monospacedDigit()
            }
            .frame(maxWidth: 150)

            Stepper(
                value: Binding(
                    get: { band.gainDb },
                    set: { v in
                        var b = band
                        b.gainDb = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: -24...24,
                step: 0.1
            ) {
                Text(String(format: "%+5.1f dB", band.gainDb)).monospacedDigit()
            }
            .frame(maxWidth: 150)

            Stepper(
                value: Binding(
                    get: { band.q },
                    set: { v in
                        var b = band
                        b.q = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: 0.1...10.0,
                step: 0.1
            ) {
                Text(String(format: "%4.2f", band.q)).monospacedDigit()
            }
            .frame(maxWidth: 130)

            Button {
                Task { await viewModel.removeEditingBand(at: idx) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func footer(_ preset: EqPreset) -> some View {
        HStack {
            Button("Cancel") {
                Task { await viewModel.cancelEdit() }
            }
            Spacer()
            Button("Rename…") {
                renameTarget = viewModel.editingOriginalName ?? ""
                sheetError = nil
                showRenameSheet = true
            }
            .disabled(viewModel.editingIsNew)

            Button("Save As…") {
                saveAsName = viewModel.editingOriginalName.map { "\($0)-copy" } ?? "Untitled"
                sheetError = nil
                showSaveAsSheet = true
            }

            Button("Save") {
                Task {
                    do {
                        try await viewModel.saveEdit()
                    } catch {
                        saveAlert = "Failed to save preset: \(error)"
                    }
                }
            }
            .disabled(viewModel.editingIsNew || !viewModel.editingDirty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func nameSheet(
        title: String,
        initialValue: String,
        onConfirm: @escaping @Sendable (String) async -> Void
    ) -> some View {
        let binding = Binding<String>(
            get: { saveAsName.isEmpty ? renameTarget : saveAsName },
            set: { v in
                let capped = String(v.prefix(30))
                if showSaveAsSheet { saveAsName = capped } else { renameTarget = capped }
            }
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Preset name", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onAppear {
                    if showSaveAsSheet { saveAsName = initialValue }
                    else { renameTarget = initialValue }
                }
            if let err = sheetError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showSaveAsSheet = false
                    showRenameSheet = false
                    sheetError = nil
                }
                Button("OK") {
                    let name = showSaveAsSheet ? saveAsName : renameTarget
                    Task { await onConfirm(name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((showSaveAsSheet ? saveAsName : renameTarget).isEmpty)
            }
        }
        .padding(16)
    }

    private enum BandTypeMenu: Hashable { case bypass, peak, lowShelf, highShelf }

    private func typeMenuValue(for band: EqBand) -> BandTypeMenu {
        if !band.enabled { return .bypass }
        switch band.type {
        case .peak: return .peak
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        }
    }

    private func applyTypeMenu(_ menu: BandTypeMenu, to band: EqBand) -> EqBand {
        var b = band
        switch menu {
        case .bypass:
            b.enabled = false
        case .peak:
            b.enabled = true
            b.type = .peak
        case .lowShelf:
            b.enabled = true
            b.type = .lowShelf
        case .highShelf:
            b.enabled = true
            b.type = .highShelf
        }
        return b
    }
}
```

Run: `swift build`
Expected: green.

```bash
git add Sources/RPPlayer/Shell/EqEditPanel.swift
git commit -m "feat(eq): EqEditPanel SwiftUI view with grid bands + save/save-as/rename"
```

- [ ] **Step 2: Update SettingsView picker row + remove eye button**

Edit `Sources/RPPlayer/Shell/SettingsView.swift`.

Around lines 281-316, the current row has Delete / Eye / Import / Export buttons. Replace the **Eye** button block (lines 292-299) with two buttons (`+` and `✎ edit`):

```swift
Button {
    Task { await viewModel.beginNewPreset() }
} label: {
    Image(systemName: "plus")
}
.buttonStyle(.borderless)
.disabled(viewModel.editingPreset != nil)
.help("Create new preset")

Button {
    Task { await viewModel.beginEditCurrent() }
} label: {
    Image(systemName: "pencil")
}
.buttonStyle(.borderless)
.disabled(viewModel.eqPresetName == nil || viewModel.editingPreset != nil)
.help("Edit selected preset")
```

Disable the existing Delete, Import, and Export buttons while editing — add `.disabled(viewModel.editingPreset != nil)` to each (or extend their existing `.disabled` conditions).

Remove the local `@State private var showEqDetails` and any references to it.

Replace the `if viewModel.eqEnabled, showEqDetails, let preset = viewModel.parsedEqPreset` block (around line 329) with:

```swift
if viewModel.eqEnabled, viewModel.editingPreset != nil {
    EqEditPanel(viewModel: viewModel)
}
```

Delete the `eqDetailsView`/`eqBandLine` helper functions (lines 341-373) — they're no longer used. Keep `eqTooltip`.

Run: `swift build`
Expected: green (unused-symbol warnings OK; remove them).

- [ ] **Step 3: Manual smoke**

Run: `swift build && swift run RPPlayer` (or launch from Xcode if that's the project preference).

Smoke checklist:
- Open Settings.
- With an imported preset selected, click `[✎]`. Panel opens.
- Edit preamp via stepper — audio responds within ~100ms.
- Add a band → 1000 Hz / 0 dB / Q 1.0 default.
- Pick `Bypass` on a band → it drops out of audio.
- Click `Save` → panel closes; file on disk reflects changes.
- Reopen, click `Save As…` with a new name → new preset appears in picker, active.
- Open `Rename…` → rename to a fresh name → all references update.
- Click `Cancel` after edits → audio reverts; no disk changes.
- Click `+` → empty panel opens; `Save` button disabled; `Save As…` works.

- [ ] **Step 4: Run full test suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(eq): replace view-details with edit panel; add new/edit buttons"
```

---

## Task 9: Documentation deltas

**Files:**
- Modify: `CHANGELOG.md`, `docs/pr-history.md`, `docs/test-counts.md`, `docs/architecture.md`, `CLAUDE.md`, `README.md`

- [ ] **Step 1: Count tests + update `docs/test-counts.md`**

Run: `swift test 2>&1 | grep "Executed.*tests" | tail -1`
Note the new total. Append a line to `docs/test-counts.md`:

```
2026-05-21: <NEW_TOTAL> tests — EQ preset editor (PR 39)
```

- [ ] **Step 2: `CHANGELOG.md` — add entries under `## [Unreleased]`**

```markdown
### Added
- EQ preset editor — create, edit, rename, and save presets directly in Settings.
- Live audio preview while editing via in-memory override channel.

### Changed
- EQ parser and writer round-trip disabled (`OFF`) filter rows.
- Preset filenames capped at 30 characters; longer import filenames are truncated.

### Removed
- Read-only EQ preset details view (eye icon) — replaced by the edit panel.
```

- [ ] **Step 3: `docs/pr-history.md` — new PR row**

Add a row to the table under the existing format (match the existing column shape).

If a Deferred section exists at the bottom, no entries from this PR go there.

- [ ] **Step 4: `docs/architecture.md` — note the override channel**

Add a short subsection (after the existing audio-filter binder notes if any) describing why `EqEditingOverride` exists: file-based EQ storage is shared across devices via `AudioProfile.eqPresetName`, so live preview cannot write to disk on every keystroke without affecting other devices. The override actor lets the binder consume an in-memory draft.

- [ ] **Step 5: `CLAUDE.md` — refresh *Current state* block**

Replace the "Last merged" line with the new PR's summary; set "Next up" back to `TBD`.

- [ ] **Step 6: `README.md` — feature note + screenshot placeholder**

Add a brief line about preset editing under the EQ feature description. If the README has screenshots, add a placeholder `<!-- screenshot: eq editor TBD -->` so the maintainer remembers to capture one.

- [ ] **Step 7: Final build + tests**

Run: `swift build && swift test`
Expected: green.

- [ ] **Step 8: Commit docs**

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md docs/architecture.md CLAUDE.md README.md
git commit -m "docs(eq): preset editor PR documentation"
```

---

## Out of Scope (do NOT include in this PR)

- Undo / redo inside the edit panel.
- Frequency-response graph or A/B preview.
- Drag-to-reorder bands.
- Smoke probe (`RPSmoke --probe-eq-edit-roundtrip`) — deferred.
- Snapshot/PNG tests for the edit panel — Swift Package + SwiftUI snapshot tooling is not yet wired up in this repo.

## Final Verification

- [ ] `swift build` — clean.
- [ ] `swift test` — all green; total ≥ 502 + new tests.
- [ ] Manual UI smoke (Task 8 Step 3) passes.
- [ ] All six doc files updated.
- [ ] One commit per task (parser, writer, store, override actor, binder, view-model, wiring, panel, settings-view, docs).
