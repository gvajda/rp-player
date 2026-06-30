# EQ Preset Editor — Design

**Date:** 2026-05-21
**Status:** Approved-pending-spec-review
**Branch (planned):** `claude/eq-preset-editor`

## Goal

Replace the read-only EQ preset *view* panel with an *edit* panel that lets users create, modify, rename, and save presets directly inside the Settings UI. File-based shared storage at `~/Library/Application Support/RP Player/EqPresets/<name>.txt` is preserved; presets remain referenced by name from `AudioProfile.eqPresetName`, so a preset edit affects every output device pointing at that filename.

## Scope

- New: per-band editor (type, frequency, gain, Q) and preamp editor.
- New: create-new preset entry point (`+` button).
- New: rename preset (sheet, launched from inside the edit panel).
- New: live audio preview while editing (in-memory override channel, not via disk).
- Changed: parser + writer round-trip disabled (`OFF`) filter rows.
- Removed: the read-only "eye" details view (replaced by edit panel).
- Out of scope: undo/redo, multi-preset comparison, A/B preview, graphical frequency-response plot.

## User-visible behavior

### Picker row

```
Equalizer ⓘ   [Picker: <preset> ▾]   [+]  [✎ edit]  [🗑]  [⬇ import]  [⬆ export]   [toggle]
```

- `[+]` — always enabled while EQ is on; opens edit panel with empty draft (preamp 0, no bands).
- `[✎ edit]` — disabled when picker = None (Bypass). Opens edit panel populated from the selected preset.
- `[🗑]`, `[⬇ import]`, `[⬆ export]` — disabled while editing (panel open) to avoid foot-guns. Existing behavior otherwise.
- The previous `[eye]` view-details button is removed.

### Edit panel (collapses below picker row when active)

```
┌─ Editing: <originalName or "Untitled"> ──────────────────────────────────┐
│  Preamp:  [  0.0 ⇅ ]  dB                                                  │
│                                                                            │
│  Bands (3 / 10):                                                          │
│  ┌──────────────┬──────────────┬─────────────┬────────────┬─────┐         │
│  │ Type         │ Frequency    │ Gain        │ Q          │     │         │
│  ├──────────────┼──────────────┼─────────────┼────────────┼─────┤         │
│  │ [Peak    ▾]  │ [  1000 ⇅] Hz│ [ +3.0 ⇅] dB│ [ 1.00 ⇅]  │ 🗑 │         │
│  │ [Low Shelf▾] │ [   100 ⇅] Hz│ [ -2.0 ⇅] dB│ [ 0.70 ⇅]  │ 🗑 │         │
│  │ [Bypass   ▾] │ [  5000 ⇅] Hz│ [ +1.5 ⇅] dB│ [ 1.20 ⇅]  │ 🗑 │         │
│  └──────────────┴──────────────┴─────────────┴────────────┴─────┘         │
│  [ + Add band ]    (disabled at 10)                                       │
│                                                                            │
│  ─────────────────────────────────────────────────────────────────────    │
│  [ Cancel ]                  [ Rename… ]  [ Save As… ]  [ Save ]          │
└────────────────────────────────────────────────────────────────────────────┘
```

Layout: SwiftUI `Grid` (macOS 13+) for column-aligned rows. Header row uses `.gridColumnAlignment(.leading)`.

Numeric inputs: `TextField` + `Stepper`. Pattern reuse: existing crossfeed custom fields (`SettingsView.crossfeedCustomFields`).

### Filter type dropdown

Options: `Bypass`, `Peak`, `Low Shelf`, `High Shelf`.

`Bypass` selection sets `EqBand.enabled = false`. The previously-selected type (`peak` / `lowShelf` / `highShelf`) is preserved internally so that flipping back from Bypass restores the prior type. On serialize, the band still gets a `Filter N: OFF <TYPE>` line with whatever type is stored.

### Ranges + validation

| Field | Range | Step |
|---|---|---|
| Preamp | −30.0 … +10.0 dB | 0.1 |
| Frequency (fc) | 20 … 20000 Hz | 1 (integer) |
| Gain | −24.0 … +24.0 dB | 0.1 |
| Q | 0.1 … 10.0 | 0.1 |

UI steppers clamp to range. Out-of-range typed input clamps on `onSubmit`. The on-disk parser stays lenient — imported files outside these ranges are accepted as-is; first edit clamps the offending band.

### Live apply

Edits hit the audio pipeline immediately via an in-memory override channel (see Architecture). Mutations are debounced ~100 ms to coalesce rapid stepper changes. `Save` and `Save As` persist to disk and clear the override; the binder then reloads from disk and produces an identical filter chain (no audible glitch). `Cancel` clears the override and reverts audio to the on-disk preset.

### Save / Save As / Rename / Cancel

| Button | Enabled when | Action |
|---|---|---|
| Cancel | Always | Discards draft. Clears override. Closes panel. |
| Rename… | `!editingIsNew` | Opens rename sheet. |
| Save As… | Always | Opens Save-As sheet (new name TextField, max 30 chars). |
| Save | `!editingIsNew && editingDirty` | Overwrites the original file with current draft. Clears override. Closes panel. |

Name input fields cap at 30 characters via `onChange` clamp. Disallowed chars (`/`, `\0`, leading `.`) rejected with inline error.

### Sheet error handling

Inline error inside the sheet (do not close):
- `invalidName` — "Use 1–30 characters; no slashes or leading dot."
- `alreadyExists` — "Name already used. Pick another."

Alert + close sheet:
- `ioFailure` — "Failed to save preset: <reason>".

## Architecture

```
SettingsView.eqSection
  ├ Picker row  [+] [✎] [🗑] [⬇] [⬆] [toggle]
  └ EqEditPanel  (when SettingsViewModel.editingPreset != nil)

SettingsViewModel  (existing, +~150 LOC)
  ├ Existing: eqEnabled, eqPresetName, parsedEqPreset, availablePresets, importPresetFile…
  ├ NEW state: editingPreset, editingOriginalName, editingDirty
  └ NEW methods: beginEditCurrent, beginNewPreset, cancelEdit,
                 setEditingPreamp, setEditingBand, addEditingBand, removeEditingBand,
                 saveEdit, saveEditAs, renamePreset

EqEditingOverride  (NEW actor — small side-channel)
  ├ set(_ preset: EqPreset?)
  ├ snapshot() -> EqPreset?
  └ changes: AsyncStream<EqPreset?>

AppContainer.runAudioFilterBinder  (modified)
  └ merges ConfigStore.changes + EqEditingOverride.changes;
    when override is set and eq is enabled, applies override.bands instead of loading from disk.

EqPresetStore  +rename(from:to:) async throws
EqPresetParser  preserves OFF rows
EqPresetWriter  emits OFF rows
EqChainBuilder  unchanged (already filters .enabled before building lavfi parts)
```

### Why a side-channel for live apply

The audio filter binder is keyed off `AudioFilterKey { eqEnabled, eqPresetName, crossfeed* }` and resolves preset *content* by reading the file via `EqPresetStore.loadText(name:)`. To preview in-memory edits without writing to disk on every keystroke (which would break Cancel-reverts and force-publish edits to all devices sharing the preset), we need a path that lets the binder consume an in-memory preset.

`EqEditingOverride` is a per-app singleton actor with one `EqPreset?` slot and an `AsyncStream`. `runAudioFilterBinder` is augmented to:

1. Subscribe to both config snapshots and override changes.
2. On either event, recompute the chain using the current profile **plus** the current override.
3. When override is non-nil and the active profile has `eqEnabled == true`, use `override.bands` and `override.preampDb` to build the lavfi parts. Skip the disk read.
4. When override is nil, fall through to existing disk-load behavior.

`AudioFilterKey` gains a generation counter (or a hash of the override) so the equality check still triggers rebuilds on override mutations.

## Data model + serialization changes

### EqBand (unchanged)

Already has `enabled: Bool` + `type: EqBandType` + `fcHz/gainDb/q`. No schema change.

### EqPresetParser

Replace:

```swift
if stateStr == "OFF" { continue }
```

with:

```swift
// keep both ON and OFF rows; "enabled" reflects the state
```

Result:

```swift
bands.append(EqBand(
    enabled: stateStr == "ON",
    type: mapped!,
    fcHz: fc, gainDb: gain, q: q
))
```

Disabled bands still count toward the 10-band cap (`maxBands = 10`). Malformed-line warnings and rejection rules unchanged.

### EqPresetWriter

Replace:

```swift
for (i, b) in preset.bands.filter(\.enabled).enumerated() { ... ON ... }
```

with:

```swift
for (i, b) in preset.bands.enumerated() {
    let state = b.enabled ? "ON" : "OFF"
    // emit "Filter N: <state> <abbr> Fc … Gain … Q …"
}
```

Index numbering is sequential over ALL bands (enabled and disabled), so an enabled band at slot 2 followed by a disabled band at slot 3 round-trips correctly.

### EqChainBuilder (unchanged)

Already filters `enabled` before building lavfi parts, so disabled bands continue to be excluded from the active filter chain.

## EqPresetStore — rename API + name cap

### Protocol addition

```swift
public protocol EqPresetStore: Sendable {
    // existing…
    func rename(from: String, to: String) async throws
}
```

### Validation

`validate(_ name:)` change: `name.count <= 30` (was `< 256`). Also still rejects empty, leading `.`, and `/` or `\0`. Applies to `save`, `loadText`, `exists`, `delete`, and the new `rename`.

Migration: none. Project is pre-release; no shipped presets exceed 30 chars in practice. The import path truncates incoming filenames longer than 30 chars before calling `save`.

### LiveEqPresetStore.rename

```swift
public func rename(from: String, to: String) async throws {
    // validate both sides
    guard validate(from) else { throw .invalidName }
    guard validate(to) else { throw .invalidName }
    let src = fileURL(for: from)
    let dst = fileURL(for: to)
    guard fm.fileExists(atPath: src.path) else { throw .notFound }
    if from == to { return }   // no-op same-name
    guard !fm.fileExists(atPath: dst.path) else { throw .alreadyExists }
    do {
        try fm.moveItem(at: src, to: dst)
        logger?.info("EqPresetStore.rename from=\(from) to=\(to)")
    } catch {
        throw .ioFailure("\(error)")
    }
}
```

No overwrite flag — rename never silently clobbers another preset. User resolves manually.

`NoopEqPresetStore.rename` stub throws `.notFound`.

## SettingsViewModel additions

### State (all `@MainActor`, all `@Published`)

```swift
@Published public private(set) var editingPreset: EqPreset?
@Published public private(set) var editingOriginalName: String?
@Published public private(set) var editingDirty: Bool = false
// derived: editingIsNew = editingOriginalName == nil
```

### Methods

```swift
func beginEditCurrent() async         // requires eqPresetName + parsedEqPreset; copies into editingPreset, pushes override
func beginNewPreset() async           // editingPreset = EqPreset(name:nil, preampDb:0, bands:[]); pushes override
func cancelEdit() async               // clears edit state + override

func setEditingPreamp(_ db: Double) async
func setEditingBand(at idx: Int, _ band: EqBand) async
func addEditingBand() async           // appends EqBand(enabled:true, type:.peak, fcHz:1000, gainDb:0, q:1.0); cap 10
func removeEditingBand(at idx: Int) async

func saveEdit() async throws          // requires !editingIsNew; writer+store.save(overwrite:true); clears override
func saveEditAs(name: String) async throws  // store.save(name:, overwrite:false); switches eqPresetName to new name; clears override
func renamePreset(from: String, to: String) async throws  // see Flows below
```

All mutating methods set `editingDirty = true` and push the new draft to `EqEditingOverride` (debounced ~100 ms via `Task` cancellation pattern, modeled on the existing crossfeed-fcut Task in this same file).

## Flows

### Edit existing → Save
1. User clicks `[✎]`. `beginEditCurrent()` copies `parsedEqPreset` into `editingPreset`, sets `editingOriginalName`, pushes to override.
2. Each mutation → debounced override update → binder rebuilds chain live.
3. `Save` → `EqPresetWriter.write(editingPreset)` → `store.save(name: originalName, text:, overwrite: true)`. Clears override; binder reloads from disk (identical content, no audible glitch).
4. `refreshPresets`; `reloadParsedPreset`; close panel.

### Edit existing → Save As
1. Same as above until the sheet.
2. Sheet OK → `store.save(name: newName, overwrite: false)`. On `alreadyExists` → keep sheet open, show inline error.
3. On success → override cleared, `setEqPresetName(newName)` switches the active picker, panel closes.
4. Original file untouched; profiles referencing the original stay on the original.

### New preset (`[+]`)
1. `beginNewPreset()` → `editingPreset` is empty, `editingOriginalName == nil`. Override pushed (no bands → no EQ effect; preamp still applies).
2. `Save` button disabled (no name to overwrite). User must `Save As…`.
3. `Cancel` discards draft.

### Rename
1. User clicks `Rename…` inside edit panel → sheet opens with current name pre-filled.
2. Sheet OK with target name `to`:
   - Validate (length 1..30, allowed chars).
   - If `to == from` → close sheet (no-op).
   - `configStore.update`: for every profile with `eqPresetName == from`, set to `to`.
   - `store.rename(from:, to:)`. If throws `.alreadyExists` → roll back profile updates (set back to `from`), surface inline error in sheet.
   - On success: set `editingOriginalName = to`; sheet closes; panel stays open with new name in header.

### Cancel
- Clear `editingPreset`, `editingOriginalName`, `editingDirty`. `override.set(nil)`. Binder reloads disk preset. Panel closes.

### Closing the Settings window while editing
- Implicit `cancelEdit()` — draft discarded; safe (audio reverts to disk).

## Errors

| Path | Error | UI surface |
|---|---|---|
| `Save` (overwrite) | `ioFailure` | Alert "Failed to save preset: \(reason)". Edit mode persists. |
| `Save As` | `alreadyExists` | Inline error in sheet. |
| `Save As` | `invalidName` | Inline error in sheet. |
| `Save As` | `ioFailure` | Alert; sheet closes. |
| `Rename` | `alreadyExists` / `invalidName` | Inline error in sheet. |
| `Rename` | `ioFailure` | Alert; sheet closes; profile refs rolled back. |
| Live-apply override push | n/a (in-memory) | Silent. |

## Testing

### Unit tests

**EqPresetParserTests** (+ ~2 cases):
- OFF row preserved as `enabled: false` with type retained.
- Mixed ON / OFF order round-trips through parser → writer → parser.

**EqPresetWriterTests** (+ ~2 cases):
- Disabled band emits `Filter N: OFF <TYPE> …`.
- Index numbering sequential over ALL bands (no skip for disabled rows).

**EqPresetStoreTests** (+ ~6 cases):
- rename happy path.
- rename `invalidName` (source bad).
- rename `invalidName` (dest bad).
- rename `notFound`.
- rename `alreadyExists`.
- rename same-name no-op.
- save with 31-char name → `invalidName`.

**SettingsViewModelEqEditTests** (NEW file, ~12 cases):
- `beginEditCurrent` copies parsed preset into editing state.
- `beginNewPreset` yields empty draft.
- Any mutation sets `editingDirty = true`.
- `addEditingBand` caps at 10.
- `removeEditingBand` decrements + clamps index.
- `saveEdit` overwrites file + clears override.
- `saveEditAs` creates new file + switches `eqPresetName` + clears override.
- `saveEditAs` collision throws `alreadyExists`.
- `renamePreset` updates all profiles + renames file.
- `renamePreset` rollback on store failure.
- `cancelEdit` clears state + override.
- Debounced override push — final value only after rapid mutations.

**AppContainerAudioFilterBinderTests** (+ ~3 cases):
- Override set → binder applies override preset (not disk).
- Override cleared → binder reverts to disk-loaded preset.
- Override changes while EQ is disabled → applied filter chain stays empty (no EQ parts emitted), regardless of override state.

### Smoke

No new `RPSmoke` probe in this PR — defer unless a regression is found post-merge.

## Documentation deltas (must ship with PR)

- `CHANGELOG.md` — *Added:* per-preset edit panel; rename support; in-app preset creation. *Changed:* parser/writer round-trip disabled bands. *Removed:* read-only details view (eye button). Name length capped to 30 chars.
- `docs/pr-history.md` — new PR row.
- `docs/test-counts.md` — append new count.
- `docs/architecture.md` — note the **EQ editing override channel** (non-obvious side-channel that bypasses ConfigStore for live audio).
- `CLAUDE.md` — refresh *Current state* block (last merged + next up).
- `README.md` — screenshot + brief feature note.

## Open questions

None at design time. Implementation-time decisions to confirm in the plan:

- Exact placement of the `EqEditingOverride` actor (`AppContainer` extension vs new file in `Sources/RPPlayer/Config/`).
- Whether the debounce uses an `AsyncStream` throttle or a simple `Task.sleep` cancellation pattern (the latter matches existing crossfeed-fcut code).
