# EQ Preset Picker Switch While Editing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the EQ preset picker safe to change while the edit panel is open: clean edits reseed atomically; dirty edits trigger a 4-option warning (Keep editing / Discard / Save / Save as…).

**Architecture:** New `requestPresetSwitch(to:)` entry point on `SettingsViewModel` routes through dirty check. Published `pendingPresetSwitch` drives a `.alert` on `eqSection`. Resolution methods (`resolvePendingSwitchDiscard/Save/SaveAs` + `cancelPendingSwitch`) drive the switch. `saveEditAs` is refactored to expose a write-only helper so the save-as resolution can land the picker on the user's target rather than the new save-as name.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest. Project root `/Users/gergely/git/rp-player`. Test runner: `swift test`.

**Spec:** `docs/superpowers/specs/2026-05-23-eq-picker-switch-while-editing-design.md`

---

## File map

| File | Change |
| --- | --- |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | Add `PendingPresetSwitch` struct, `pendingPresetSwitch` published, `requestPresetSwitch`, `performSwitch`, `resolvePendingSwitch{Discard,Save,SaveAs}`, `cancelPendingSwitch`. Refactor `saveEditAs` to extract `writePresetFile(name:)` helper. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | Picker `set` routes to `requestPresetSwitch`. Add `.alert` + save-as sheet on `eqSection`. |
| `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift` | Add the 13 new tests listed in the spec. |
| `CHANGELOG.md` | Entry under `## [Unreleased]` → `Fixed` + `Changed`. |
| `docs/pr-history.md` | New PR-43 row + deferred items if any. |
| `docs/test-counts.md` | Append new test count line. |
| `CLAUDE.md` | Refresh *Current state* block. |

---

## Task 1: `PendingPresetSwitch` type + published state + cancel

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing test for cancel behavior.**

Append to `SettingsViewModelEqEditTests.swift` (above the closing `}` of the class):

```swift
func testCancelPendingSwitchClearsPendingWithoutTouchingEditor() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-2)

    // Seed a pending switch directly so this task tests only cancel.
    vm._setPendingPresetSwitchForTesting(SettingsViewModel.PendingPresetSwitch(target: "beta"))
    XCTAssertNotNil(vm.pendingPresetSwitch)

    vm.cancelPendingSwitch()
    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertNotNil(vm.editingPreset)
    XCTAssertEqual(vm.eqPresetName, "alpha")
}
```

- [ ] **Step 2: Run test, verify failure.**

```bash
swift test --filter SettingsViewModelEqEditTests/testCancelPendingSwitchClearsPendingWithoutTouchingEditor
```

Expected: FAIL (type and methods don't exist).

- [ ] **Step 3: Add type + state + cancel in `SettingsViewModel.swift`.**

Locate the published EQ block ending at line 54 (`@Published public private(set) var crossfeedFeedDb: Double = 6.0`). Insert after `public var editingIsNew: Bool { editingOriginalName == nil }` (line 50):

```swift
public struct PendingPresetSwitch: Equatable, Sendable {
    public let target: String?
    public init(target: String?) { self.target = target }
}

@Published public private(set) var pendingPresetSwitch: PendingPresetSwitch?
```

Then locate `public func cancelEdit() async {` (around line 576) and insert directly before it:

```swift
public func cancelPendingSwitch() {
    logger?.debug("cancelPendingSwitch")
    pendingPresetSwitch = nil
}

#if DEBUG
internal func _setPendingPresetSwitchForTesting(_ value: PendingPresetSwitch?) {
    pendingPresetSwitch = value
}
#endif
```

- [ ] **Step 4: Re-run test, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testCancelPendingSwitchClearsPendingWithoutTouchingEditor
```

Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): add PendingPresetSwitch state + cancelPendingSwitch"
```

---

## Task 2: Extract `writePresetFile` helper, refactor `saveEditAs`

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift:652-667`

- [ ] **Step 1: Run existing save-as test to baseline pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testSaveEditAsPersistsAndSwitchesPicker
```

Expected: PASS (existing behavior; if no exact test name matches, run the broader filter `swift test --filter SettingsViewModelEqEditTests` and note which save-as cases pass).

- [ ] **Step 2: Replace `saveEditAs` body to call new helper.**

In `SettingsViewModel.swift`, replace lines 652-667 (current `saveEditAs(name:)`) with:

```swift
public func saveEditAs(name: String) async throws {
    let trimmed = try await writePresetFile(name: name)
    await setEqPresetName(trimmed)
    await reloadParsedPreset()
    await MainActor.run {
        self.editingPreset = nil
        self.editingOriginalName = nil
        self.editingDirty = false
    }
}

/// Writes the current editingPreset to disk under `name`. Does NOT change
/// the picker selection, reload parsed state, or clear the editor. Returns
/// the trimmed name actually used. Throws EqPresetStoreError.alreadyExists
/// if the file already exists, .invalidName on bad input.
private func writePresetFile(name: String) async throws -> String {
    guard let preset = editingPreset else { throw EqPresetStoreError.invalidName }
    editingPushTask?.cancel(); editingPushTask = nil
    let trimmed = String(name.prefix(30))
    let text = EqPresetWriter.write(preset)
    try await eqPresetStore.save(name: trimmed, text: text, overwrite: false)
    await eqEditingOverride.set(nil)
    await refreshPresets()
    return trimmed
}
```

- [ ] **Step 3: Run full EQ-edit test file to verify no regressions.**

```bash
swift test --filter SettingsViewModelEqEditTests
```

Expected: PASS — all existing tests still green.

- [ ] **Step 4: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift
git commit -m "refactor(eq): extract writePresetFile helper from saveEditAs"
```

---

## Task 3: `performSwitch(to:)` internal helper

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

`performSwitch` is private; we test it via `requestPresetSwitch` paths in later tasks. This task implements and unit-tests the public surface that *exercises* it (clean editor reseed).

- [ ] **Step 1: Add failing test for clean-editor reseed.**

Append to `SettingsViewModelEqEditTests.swift`:

```swift
func testRequestPresetSwitchEditorCleanReseedsToTarget() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    // beta has different bands so we can distinguish.
    try await eqStore.save(
        name: "beta",
        text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain -2 dB Q 0.7\nFilter 2: ON PK Fc 8000 Hz Gain 4 dB Q 1.4\n",
        overwrite: false
    )
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    XCTAssertEqual(vm.editingPreset?.bands.count, 1)
    XCTAssertFalse(vm.editingDirty)

    await vm.requestPresetSwitch(to: "beta")
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertEqual(vm.eqPresetName, "beta")
    XCTAssertEqual(vm.editingOriginalName, "beta")
    XCTAssertEqual(vm.editingPreset?.bands.count, 2)
    XCTAssertEqual(vm.editingPreset?.preampDb, -3)
    XCTAssertFalse(vm.editingDirty)
    let pushed = await override.snapshot()
    XCTAssertEqual(pushed?.bands.count, 2)
}
```

- [ ] **Step 2: Run test, verify failure.**

```bash
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchEditorCleanReseedsToTarget
```

Expected: FAIL (`requestPresetSwitch` undefined).

- [ ] **Step 3: Add `performSwitch` and `requestPresetSwitch` (clean + closed paths only).**

In `SettingsViewModel.swift`, add immediately above `public func beginEditCurrent()` (around line 554):

```swift
public func requestPresetSwitch(to target: String?) async {
    logger?.debug("requestPresetSwitch target=\(target ?? "<nil>")")
    if pendingPresetSwitch != nil {
        logger?.debug("requestPresetSwitch ignored: pending switch active")
        return
    }
    if target == eqPresetName {
        return
    }
    if editingPreset == nil {
        await setEqPresetName(target)
        return
    }
    if !editingDirty {
        await performSwitch(to: target)
        return
    }
    await MainActor.run {
        self.pendingPresetSwitch = PendingPresetSwitch(target: target)
    }
}

private func performSwitch(to target: String?) async {
    await setEqPresetName(target)
    if target == nil {
        await cancelEdit()
        return
    }
    await reloadParsedPreset()
    await MainActor.run {
        guard let preset = self.parsedEqPreset else {
            // Broken/missing preset file — close editor, no error toast.
            self.editingPreset = nil
            self.editingOriginalName = nil
            self.editingDirty = false
            return
        }
        self.editingPreset = preset
        self.editingOriginalName = target
        self.editingDirty = false
    }
    if editingPreset == nil {
        await eqEditingOverride.set(nil)
    } else {
        await eqEditingOverride.set(editingPreset)
    }
}
```

- [ ] **Step 4: Re-run test, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchEditorCleanReseedsToTarget
```

Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): add requestPresetSwitch + performSwitch for clean editor"
```

---

## Task 4: Editor-closed + same-target + bypass-clean paths

**Files:**

- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add three failing tests.**

Append:

```swift
func testRequestPresetSwitchEditorClosedSetsPresetWithoutDialog() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()

    await vm.requestPresetSwitch(to: "beta")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(vm.eqPresetName, "beta")
    XCTAssertNil(vm.editingPreset)
    XCTAssertNil(vm.pendingPresetSwitch)
}

func testRequestPresetSwitchSameTargetIsNoop() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-5)
    XCTAssertTrue(vm.editingDirty)

    await vm.requestPresetSwitch(to: "alpha")
    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertTrue(vm.editingDirty)
    XCTAssertEqual(vm.editingPreset?.preampDb, -5)
}

func testRequestPresetSwitchEditorCleanToBypassClosesEditor() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    XCTAssertNotNil(vm.editingPreset)

    await vm.requestPresetSwitch(to: nil)
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.eqPresetName)
    XCTAssertNil(vm.editingPreset)
    XCTAssertNil(vm.editingOriginalName)
    XCTAssertNil(vm.pendingPresetSwitch)
    let pushed = await override.snapshot()
    XCTAssertNil(pushed)
}
```

- [ ] **Step 2: Run all three, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchEditorClosedSetsPresetWithoutDialog
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchSameTargetIsNoop
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchEditorCleanToBypassClosesEditor
```

Expected: all PASS (logic from Task 3 already covers these branches).

- [ ] **Step 3: Commit.**

```bash
git add Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "test(eq): cover requestPresetSwitch closed/same/bypass branches"
```

---

## Task 5: Dirty-editor pending state

**Files:**

- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing test for dirty → pending state.**

Append:

```swift
func testRequestPresetSwitchEditorDirtySetsPendingSwitch() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-7)
    XCTAssertTrue(vm.editingDirty)

    await vm.requestPresetSwitch(to: "beta")

    XCTAssertEqual(vm.pendingPresetSwitch, SettingsViewModel.PendingPresetSwitch(target: "beta"))
    XCTAssertEqual(vm.eqPresetName, "alpha")             // not committed yet
    XCTAssertEqual(vm.editingOriginalName, "alpha")
    XCTAssertEqual(vm.editingPreset?.preampDb, -7)       // edits intact
    XCTAssertTrue(vm.editingDirty)
}

func testRequestPresetSwitchWhilePendingActiveIsIgnored() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
    try await eqStore.save(name: "gamma", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 2000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-3)

    await vm.requestPresetSwitch(to: "beta")
    XCTAssertEqual(vm.pendingPresetSwitch?.target, "beta")

    await vm.requestPresetSwitch(to: "gamma")
    XCTAssertEqual(vm.pendingPresetSwitch?.target, "beta")  // unchanged
}
```

- [ ] **Step 2: Run both, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchEditorDirtySetsPendingSwitch
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchWhilePendingActiveIsIgnored
```

Expected: PASS (Task 3 implementation already covers both).

- [ ] **Step 3: Commit.**

```bash
git add Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "test(eq): cover dirty pending + ignored-while-pending branches"
```

---

## Task 6: Resolve via Discard

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing test.**

Append:

```swift
func testResolvePendingSwitchDiscardSwapsAndClearsPending() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.9\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-9)
    await vm.requestPresetSwitch(to: "beta")
    XCTAssertNotNil(vm.pendingPresetSwitch)

    await vm.resolvePendingSwitchDiscard()
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertEqual(vm.eqPresetName, "beta")
    XCTAssertEqual(vm.editingOriginalName, "beta")
    XCTAssertEqual(vm.editingPreset?.preampDb, -3)
    XCTAssertFalse(vm.editingDirty)
}
```

- [ ] **Step 2: Run test, verify failure.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchDiscardSwapsAndClearsPending
```

Expected: FAIL (`resolvePendingSwitchDiscard` undefined).

- [ ] **Step 3: Add resolver.**

In `SettingsViewModel.swift`, add directly below `public func cancelPendingSwitch()` (the method added in Task 1):

```swift
public func resolvePendingSwitchDiscard() async {
    logger?.debug("resolvePendingSwitchDiscard")
    guard let pending = pendingPresetSwitch else { return }
    await MainActor.run { self.pendingPresetSwitch = nil }
    await performSwitch(to: pending.target)
}
```

- [ ] **Step 4: Re-run test, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchDiscardSwapsAndClearsPending
```

Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): add resolvePendingSwitchDiscard"
```

---

## Task 7: Resolve via Save

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing tests.**

Append:

```swift
func testResolvePendingSwitchSaveWritesOriginalThenSwaps() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.9\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-8)
    await vm.requestPresetSwitch(to: "beta")

    try await vm.resolvePendingSwitchSave()
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertEqual(vm.eqPresetName, "beta")
    XCTAssertEqual(vm.editingOriginalName, "beta")
    XCTAssertEqual(vm.editingPreset?.preampDb, -3)

    // Original alpha was saved with the dirty preamp before switching.
    let alphaText = try await eqStore.loadText(name: "alpha")
    XCTAssertTrue(alphaText.contains("Preamp: -8") || alphaText.contains("Preamp: -8.0"))
}

func testResolvePendingSwitchSaveNewPresetIsNoop() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    await vm.beginNewPreset()
    await vm.setEditingPreamp(-2)
    // Seed pending switch (UI button should be disabled for editingIsNew,
    // but VM must defend).
    vm._setPendingPresetSwitchForTesting(SettingsViewModel.PendingPresetSwitch(target: "anything"))

    try await vm.resolvePendingSwitchSave()
    // pendingPresetSwitch unchanged; editor untouched.
    XCTAssertNotNil(vm.pendingPresetSwitch)
    XCTAssertNotNil(vm.editingPreset)
    XCTAssertTrue(vm.editingIsNew)
}
```

- [ ] **Step 2: Run tests, verify failure.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveWritesOriginalThenSwaps
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveNewPresetIsNoop
```

Expected: FAIL (`resolvePendingSwitchSave` undefined).

- [ ] **Step 3: Add resolver.**

Directly below `resolvePendingSwitchDiscard()`:

```swift
public func resolvePendingSwitchSave() async throws {
    logger?.debug("resolvePendingSwitchSave")
    guard let pending = pendingPresetSwitch else { return }
    guard editingOriginalName != nil else {
        // No original to save to (new preset). UI disables the Save
        // button; if we got here, treat as no-op rather than throwing.
        return
    }
    try await saveEdit()
    await MainActor.run { self.pendingPresetSwitch = nil }
    await performSwitch(to: pending.target)
}
```

- [ ] **Step 4: Re-run tests, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveWritesOriginalThenSwaps
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveNewPresetIsNoop
```

Expected: PASS.

There's a subtlety: `saveEdit()` clears `editingPreset` / `editingOriginalName` (lines 645-649 of current code). After that, `performSwitch` will see a closed editor and just call `setEqPresetName(target)` — leaving the editor closed.

The spec says editor should stay open and reseed to target. To match that, `performSwitch` must work with `editingPreset == nil`. Update `performSwitch` to re-open the editor when called with `editingPreset == nil` (the post-save state):

- [ ] **Step 5: Patch `performSwitch` to re-open editor after save path.**

Replace the body of `performSwitch(to:)` (added in Task 3) with:

```swift
private func performSwitch(to target: String?) async {
    await setEqPresetName(target)
    if target == nil {
        await cancelEdit()
        return
    }
    await reloadParsedPreset()
    await MainActor.run {
        guard let preset = self.parsedEqPreset else {
            self.editingPreset = nil
            self.editingOriginalName = nil
            self.editingDirty = false
            return
        }
        self.editingPreset = preset
        self.editingOriginalName = target
        self.editingDirty = false
    }
    if editingPreset == nil {
        await eqEditingOverride.set(nil)
    } else {
        await eqEditingOverride.set(editingPreset)
    }
}
```

(This is identical to the Task 3 body — it already re-opens the editor on the target preset unconditionally. No code change needed if Task 3 was followed exactly. If the re-run in Step 4 already passes, skip this step.)

- [ ] **Step 6: Re-run all EQ tests for regressions.**

```bash
swift test --filter SettingsViewModelEqEditTests
```

Expected: all PASS.

- [ ] **Step 7: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): add resolvePendingSwitchSave"
```

---

## Task 8: Resolve via Save As (picker lands on target)

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`
- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing tests.**

Append:

```swift
func testResolvePendingSwitchSaveAsWritesNewNameThenSwapsToTarget() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    try await eqStore.save(name: "beta", text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.9\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-6)
    await vm.requestPresetSwitch(to: "beta")

    try await vm.resolvePendingSwitchSaveAs(name: "alpha-copy")
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.pendingPresetSwitch)
    // Picker lands on the original target, NOT on the save-as name.
    XCTAssertEqual(vm.eqPresetName, "beta")
    XCTAssertEqual(vm.editingOriginalName, "beta")
    XCTAssertEqual(vm.editingPreset?.preampDb, -3)
    XCTAssertTrue(vm.availablePresets.contains("alpha-copy"))

    // alpha-copy on disk reflects the dirty preamp.
    let copyText = try await eqStore.loadText(name: "alpha-copy")
    XCTAssertTrue(copyText.contains("Preamp: -6") || copyText.contains("Preamp: -6.0"))
}

func testResolvePendingSwitchSaveAsSwitchesToBypassIfTargetWasNil() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await savePresetFile(eqStore, name: "alpha")
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.reloadParsedPreset()
    await vm.beginEditCurrent()
    await vm.setEditingPreamp(-4)
    await vm.requestPresetSwitch(to: nil)   // target Bypass

    try await vm.resolvePendingSwitchSaveAs(name: "saved-copy")
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertNil(vm.pendingPresetSwitch)
    XCTAssertNil(vm.eqPresetName)
    XCTAssertNil(vm.editingPreset)
    XCTAssertTrue(vm.availablePresets.contains("saved-copy"))
}
```

- [ ] **Step 2: Run tests, verify failure.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveAsWritesNewNameThenSwapsToTarget
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveAsSwitchesToBypassIfTargetWasNil
```

Expected: FAIL.

- [ ] **Step 3: Add resolver.**

Directly below `resolvePendingSwitchSave()`:

```swift
public func resolvePendingSwitchSaveAs(name: String) async throws {
    logger?.debug("resolvePendingSwitchSaveAs name=\(name)")
    guard let pending = pendingPresetSwitch else { return }
    _ = try await writePresetFile(name: name)
    await MainActor.run { self.pendingPresetSwitch = nil }
    await performSwitch(to: pending.target)
}
```

- [ ] **Step 4: Re-run tests, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveAsWritesNewNameThenSwapsToTarget
swift test --filter SettingsViewModelEqEditTests/testResolvePendingSwitchSaveAsSwitchesToBypassIfTargetWasNil
```

Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "feat(eq): add resolvePendingSwitchSaveAs targeting user-picked preset"
```

---

## Task 9: New-preset dirty pending state coverage

**Files:**

- Test: `Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift`

- [ ] **Step 1: Add failing test.**

Append:

```swift
func testRequestPresetSwitchNewPresetDirtySetsPendingSwitch() async throws {
    let eqStore = LiveEqPresetStore(directory: tmpDir)
    try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
    let override = EqEditingOverride()
    let vm = makeVM(eqStore: eqStore, override: override)
    await vm.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    await vm.refreshPresets()
    await vm.beginNewPreset()
    await vm.setEditingPreamp(-2)
    XCTAssertTrue(vm.editingIsNew)
    XCTAssertTrue(vm.editingDirty)

    await vm.requestPresetSwitch(to: "beta")

    XCTAssertEqual(vm.pendingPresetSwitch?.target, "beta")
    XCTAssertTrue(vm.editingIsNew)              // not switched yet
    XCTAssertEqual(vm.editingPreset?.preampDb, -2)
}
```

- [ ] **Step 2: Run, verify pass.**

```bash
swift test --filter SettingsViewModelEqEditTests/testRequestPresetSwitchNewPresetDirtySetsPendingSwitch
```

Expected: PASS (logic already covers this — `editingIsNew` doesn't change the pending-state branch).

- [ ] **Step 3: Commit.**

```bash
git add Tests/RPPlayerTests/Shell/SettingsViewModelEqEditTests.swift
git commit -m "test(eq): cover new-preset dirty pending switch"
```

---

## Task 10: Run full test suite, record count

**Files:**

- None (verification only).

- [ ] **Step 1: Run entire suite.**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests PASS. Note the total test count printed (e.g., `Executed N tests`).

- [ ] **Step 2: If anything fails outside `SettingsViewModelEqEditTests`, investigate.**

The view layer hasn't been wired yet, so view-related tests for the picker (if any in `SettingsViewTests.swift`) might still assert old behavior. Read the failure carefully — do NOT loosen unrelated tests. If a test in `SettingsViewTests.swift` calls `setEqPresetName` directly via the picker binding, that path is unchanged for closed-editor; only the binding closure changes in Task 11. If a failure persists, document the breakage and fix as part of Task 11.

- [ ] **Step 3: No commit; this is a checkpoint.**

---

## Task 11: View wiring — picker uses `requestPresetSwitch`; alert + save-as sheet

**Files:**

- Modify: `Sources/RPPlayer/Shell/SettingsView.swift:266-278` (picker binding); add `.alert` + sheet to `eqSection`.

This task has no unit tests — SwiftUI alert presentation isn't easily testable in this codebase, and there are no existing tests for the picker binding wiring. Verify via manual smoke test in Step 4.

- [ ] **Step 1: Update picker binding.**

In `SettingsView.swift`, replace lines 266-278 (the `Picker` block inside `eqSection`):

```swift
Picker(
    "",
    selection: Binding<String?>(
        get: { viewModel.eqPresetName },
        set: { v in Task { await viewModel.requestPresetSwitch(to: v) } }
    )
) {
    Text("None (Bypass)").tag(String?.none)
    ForEach(viewModel.availablePresets, id: \.self) { name in
        Text(name).tag(Optional(name))
    }
}
.labelsHidden()
.frame(maxWidth: 180)
```

(Only the `set:` line changes: `setEqPresetName` → `requestPresetSwitch`.)

- [ ] **Step 2: Add `@State` for save-as sheet and alert wiring.**

At the top of the `struct SettingsView` body (where other `@State` lives — find via `grep -n "@State" Sources/RPPlayer/Shell/SettingsView.swift | head -10`), add:

```swift
@State private var pendingSaveAsName: String = ""
@State private var pendingShowSaveAsSheet: Bool = false
@State private var pendingSaveAsError: String?
@State private var savingAsInProgress: Bool = false
```

The `savingAsInProgress` flag prevents the alert's `isPresented` binding setter from cancelling the pending switch when the alert auto-dismisses after the "Save as new preset…" button tap. Without this flag, SwiftUI's auto-dismiss-after-button-action would clear `pendingPresetSwitch` in the VM before the sheet's OK handler can use it.

- [ ] **Step 3: Attach alert + sheet to `eqSection`.**

In `SettingsView.swift`, modify the `eqSection` return block. After the existing `.onAppear { ... }` at line 342-347, add chained modifiers:

```swift
.alert(
    "Unsaved EQ changes",
    isPresented: Binding<Bool>(
        get: { viewModel.pendingPresetSwitch != nil && !savingAsInProgress },
        set: { newValue in
            // Only cancel the pending switch when the alert is dismissing
            // for a non-save-as reason (Esc, click outside on macOS).
            if !newValue && !savingAsInProgress {
                viewModel.cancelPendingSwitch()
            }
        }
    )
) {
    Button("Keep editing", role: .cancel) {
        viewModel.cancelPendingSwitch()
    }
    Button("Discard changes", role: .destructive) {
        Task { await viewModel.resolvePendingSwitchDiscard() }
    }
    Button("Save as new preset…") {
        // Set the gate BEFORE SwiftUI auto-dismisses the alert so the
        // dismissal doesn't clear pendingPresetSwitch.
        savingAsInProgress = true
        pendingSaveAsName = viewModel.editingOriginalName.map { "\($0)-copy" } ?? "Untitled"
        pendingSaveAsError = nil
        pendingShowSaveAsSheet = true
    }
    Button("Save changes") {
        Task {
            do {
                try await viewModel.resolvePendingSwitchSave()
            } catch {
                // Silent on alert; surface via console only — same as
                // existing failure paths in the eq editor.
            }
        }
    }
    .disabled(viewModel.editingIsNew)
} message: {
    if viewModel.editingIsNew {
        Text("You have an unsaved new preset draft. Choose what to do before switching.")
    } else {
        Text("You have unsaved changes to \"\(viewModel.editingOriginalName ?? "the preset")\". Choose what to do before switching.")
    }
}
.sheet(
    isPresented: $pendingShowSaveAsSheet,
    onDismiss: { savingAsInProgress = false }
) {
    VStack(alignment: .leading, spacing: 12) {
        Text("Save preset as").font(.headline)
        TextField(
            "Preset name",
            text: Binding<String>(
                get: { pendingSaveAsName },
                set: { v in pendingSaveAsName = String(v.prefix(30)) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 280)
        if let err = pendingSaveAsError {
            Text(err).foregroundStyle(.red).font(.caption)
        }
        HStack {
            Spacer()
            Button("Cancel") {
                viewModel.cancelPendingSwitch()
                pendingShowSaveAsSheet = false
                pendingSaveAsError = nil
            }
            Button("OK") {
                let name = pendingSaveAsName
                Task {
                    do {
                        try await viewModel.resolvePendingSwitchSaveAs(name: name)
                        pendingShowSaveAsSheet = false
                    } catch EqPresetStoreError.alreadyExists {
                        pendingSaveAsError = "Name already used. Pick another."
                    } catch EqPresetStoreError.invalidName {
                        pendingSaveAsError = "Use 1–30 characters; no slashes or leading dot."
                    } catch {
                        pendingSaveAsError = "Failed to save: \(error)"
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pendingSaveAsName.isEmpty)
        }
    }
    .padding(16)
}
```

- [ ] **Step 4: Build and smoke-test manually.**

```bash
swift build
swift run RPPlayer  # if a runnable target exists; otherwise launch via Xcode
```

In the running app:

1. Open Settings, enable EQ, pick preset `A`, click Edit pencil. Without changing anything, change picker to `B`. **Expected:** editor reseeds to `B` instantly, no dialog.
2. Pick `A`, edit a band gain, then change picker to `B`. **Expected:** alert "Unsaved EQ changes" with 4 buttons.
3. Click "Keep editing". **Expected:** picker snaps back to `A`, edits intact.
4. Repeat → click "Discard changes". **Expected:** picker on `B`, editor shows `B`'s values, no edits.
5. Repeat → click "Save changes". **Expected:** `A` updated on disk with the edit, picker on `B`, editor shows `B`.
6. Repeat → click "Save as new preset…", type a name, click OK. **Expected:** new preset created with the edits, picker lands on `B`, editor shows `B`.
7. Click `+` to create new preset, modify preamp, change picker to `A`. **Expected:** alert appears; "Save changes" greyed; Save as… and Discard work.
8. With editor open on `A`, pick "None (Bypass)" clean. **Expected:** editor closes, picker on None.

If any step diverges from expected, fix before continuing.

- [ ] **Step 5: Commit.**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(eq): wire picker dirty-switch alert + save-as sheet"
```

---

## Task 12: Final full-suite run

**Files:**

- None.

- [ ] **Step 1: Run all tests.**

```bash
swift test 2>&1 | tail -5
```

Record the total test count for `docs/test-counts.md`.

- [ ] **Step 2: If failures, fix.** No commit until green.

- [ ] **Step 3: Build release-mode to surface any warnings.**

```bash
swift build -c release 2>&1 | tail -20
```

Expected: no errors. Warnings acceptable if pre-existing (compare against `main`).

---

## Task 13: Documentation updates

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `CHANGELOG.md`.**

Under the existing `## [Unreleased]` section, add (creating `### Fixed` / `### Changed` if not present):

```markdown
### Fixed
- EQ preset picker now prompts before discarding unsaved edits in the editor panel. Previously, changing the picker while editing silently left the editor showing the old preset's values, and Save would overwrite the wrong file.

### Changed
- Changing the EQ preset picker while the editor is open with no unsaved changes now reseeds the editor with the newly-picked preset's values. With unsaved changes, a warning offers Keep editing / Discard / Save / Save as new preset.
```

- [ ] **Step 2: Update `docs/pr-history.md`.**

Add a new row to the status table with PR number, branch, brief summary, test count. Match the format of existing rows by reading the top of the file first.

```bash
head -30 docs/pr-history.md
```

Insert the new row above the existing rows (or per existing chronological convention).

- [ ] **Step 3: Update `docs/test-counts.md`.**

```bash
tail -5 docs/test-counts.md
```

Append a new line with the post-PR test count and the PR identifier, matching existing format.

- [ ] **Step 4: Update `CLAUDE.md` *Current state* block.**

Replace the *Last merged (pending)* paragraph with a description of this PR. Update *Next up* to TBD. Keep wording terse — match the style of the existing block.

- [ ] **Step 5: Commit docs.**

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md CLAUDE.md
git commit -m "docs(pr43): changelog + pr-history + test-counts + CLAUDE.md"
```

---

## Task 14: Branch ready for merge

- [ ] **Step 1: Show final git log.**

```bash
git log --oneline main..HEAD
```

Expect commits for: PendingPresetSwitch, writePresetFile refactor, requestPresetSwitch, branch coverage tests, resolveDiscard, resolveSave, resolveSaveAs, new-preset test, view wiring, docs.

- [ ] **Step 2: Confirm tests still green.**

```bash
swift test 2>&1 | tail -5
```

- [ ] **Step 3: Hand off to user.** Do not merge or push without explicit user instruction. Report:
  - Branch name
  - Commit count
  - Test count delta
  - Anything that needed deviating from the plan
