# EQ preset picker switch while editing — design

**Date:** 2026-05-23
**Scope:** Settings → Equalizer section. Behavior when the preset picker is changed while the edit panel is open.

---

## Problem

Today the preset picker is always live, even while `EqEditPanel` is open:

- Changing the picker updates `eqPresetName` in the audio profile, which causes `parsedEqPreset` to reload from disk. But `editingPreset` (the in-flight editor draft) is **not** touched — it stays seeded from whatever preset was loaded when the user clicked the pencil.
- `editingOriginalName` is also unchanged. So **`saveEdit()` would overwrite the originally-edited preset**, not the one the picker now shows. The UI silently lies about what "Save" will do.
- There is no warning if the editor has unsaved changes (`editingDirty == true`).

User-visible symptoms:

1. Open editor on preset `A`, change picker to `B`. Editor still shows `A`'s values. Confusing.
2. Same scenario, then click Save — writes to `A` while picker shows `B`. Wrong file.
3. Edit `A`, change picker to `B` → unsaved edits to `A` silently lost on next reload.

## Goal

1. **Clean editor** (no edits made): picker change reseeds the editor with the newly-picked preset.
2. **Dirty editor** (`editingDirty == true`): block the switch with a modal warning. Offer 4 resolutions:
   - **Cancel switch** (keep editing, picker stays on current).
   - **Save** (write edits to `editingOriginalName`, then switch).
   - **Save As…** (write edits under a new name, then switch picker to the user's pick).
   - **Discard changes** (drop edits, then switch).
3. **Bypass picked** (`None (Bypass)`): same dirty check, then close the editor and clear the preset.
4. **New-preset edit** (`editingIsNew == true`): same 4 buttons, but **Save** is disabled (greyed) because there's no original to save to.
5. Post-resolution: editor stays open, reseeded with the target preset's values.

---

## Behavior matrix

| Editor state | Picker target | Action |
| --- | --- | --- |
| Closed | any | Existing path — just call `setEqPresetName`. |
| Open, clean | preset `T` | Switch atomically: `setEqPresetName(T)` + reseed editor to `T`. No dialog. |
| Open, clean | `None (Bypass)` | Switch + close editor. No dialog. |
| Open, dirty | preset `T` | Show dialog. On resolution, perform switch + reseed editor to `T`. |
| Open, dirty | `None (Bypass)` | Show dialog. On resolution, perform switch + close editor. |
| Open, new + dirty | preset `T` | Show dialog with Save disabled. On resolution, switch + reseed (or close on Bypass). |

"Reseed editor" = update `editingPreset`, `editingOriginalName`, set `editingDirty=false`, push to `eqEditingOverride`.

After a "Save As…" resolution, the picker lands on **the user's target preset** `T`, not on the save-as name. The save-as is treated as a side action to preserve the user's work.

---

## Components

### `SettingsViewModel` additions

```swift
// Wrapper so we can distinguish "no pending switch" from "pending switch to nil (Bypass)".
public struct PendingPresetSwitch: Equatable, Sendable {
    public let target: String?       // nil = None (Bypass)
}

@Published public private(set) var pendingPresetSwitch: PendingPresetSwitch?
```

New / changed methods:

```swift
/// Picker entry point. Routes through dirty check when the editor is open.
/// Replaces direct calls to setEqPresetName(_:) from the picker binding.
public func requestPresetSwitch(to target: String?) async

/// Resolves an active pendingPresetSwitch by discarding edits.
public func resolvePendingSwitchDiscard() async

/// Resolves by saving edits to editingOriginalName, then switching.
/// Returns the same errors saveEdit() does today.
public func resolvePendingSwitchSave() async throws

/// Resolves by saving edits under `name`, then switching picker to the
/// originally-requested target. Existing saveEditAs() switches the picker
/// to `name`; this variant must NOT — picker goes to pendingPresetSwitch.target.
public func resolvePendingSwitchSaveAs(name: String) async throws

/// Cancels the pending switch (Keep editing).
public func cancelPendingSwitch()
```

Internal flow for `requestPresetSwitch(to:)`:

```text
if editingPreset == nil:
    setEqPresetName(target); return
if !editingDirty:
    performSwitch(to: target)   // see below
    return
pendingPresetSwitch = PendingPresetSwitch(target: target)
// View shows dialog; resolution methods drive the rest.
```

Internal `performSwitch(to:)`:

```text
setEqPresetName(target)
if target == nil:
    cancelEdit()                // closes editor, clears override
    return
reloadParsedPreset()
// Copy parsedEqPreset into editingPreset, refresh editingOriginalName,
// editingDirty = false, push to eqEditingOverride.
```

### `saveEditAs` refactor

Today's `saveEditAs(name:)` does:

1. Write file.
2. **`setEqPresetName(name)`** ← switches picker to the new save-as name.
3. Reload parsed, clear editor.

We need a variant that does (1) and (3) only — no picker change — so the caller decides where the picker lands. Two options:

- **Option A:** Add a `switchPickerToSaved: Bool` parameter (default `true`, preserving current call sites).
- **Option B:** Extract the file-write into a private helper, call from both `saveEditAs` and `resolvePendingSwitchSaveAs`.

**Recommend Option B** — clearer call sites, fewer booleans. The existing public `saveEditAs(name:)` keeps its current behavior for the regular "Save As…" button in the footer.

### `SettingsView` changes

- Replace the picker's `set` closure:

  ```swift
  set: { v in Task { await viewModel.requestPresetSwitch(to: v) } }
  ```

  (was `setEqPresetName`)

- Add a confirmation alert bound to `viewModel.pendingPresetSwitch != nil`. Place it on `eqSection` (not on `EqEditPanel` — needs to survive `editingPreset` changes, and `EqEditPanel` only renders while editing).

  ```swift
  .alert("Unsaved EQ changes", isPresented: <pendingBinding>) {
      Button("Keep editing", role: .cancel) { viewModel.cancelPendingSwitch() }
      Button("Discard changes", role: .destructive) {
          Task { await viewModel.resolvePendingSwitchDiscard() }
      }
      Button("Save as…") {
          // open name sheet, on confirm call resolvePendingSwitchSaveAs(name:)
      }
      Button("Save") {
          Task {
              try? await viewModel.resolvePendingSwitchSave()
          }
      }
      .disabled(viewModel.editingIsNew)
  } message: {
      Text("You have unsaved changes to \"\(viewModel.editingOriginalName ?? "the new preset")\". Choose what to do before switching.")
  }
  ```

  Note: SwiftUI `.alert` button disabled state on macOS is supported in macOS 14+.

- "Save as…" path: reuse the existing name-sheet pattern from `EqEditPanel.nameSheet`. Easiest is to lift the sheet up to `eqSection` (or a small wrapper view that owns both the alert and the save-as sheet). Default name suggestion: `"\(editingOriginalName ?? "Untitled")-copy"`.

---

## Data flow

```text
User picks T in popover Picker
  └─> SettingsView binding.set
       └─> SettingsViewModel.requestPresetSwitch(to: T)
            ├─ editor closed                   → setEqPresetName(T)            (no dialog)
            ├─ editor clean                    → performSwitch(to: T)          (no dialog)
            └─ editor dirty                    → pendingPresetSwitch = ...
                 └─> SettingsView .alert appears
                      ├─ "Keep editing"        → cancelPendingSwitch()
                      ├─ "Discard changes"     → resolvePendingSwitchDiscard
                      │     └─> performSwitch(to: pendingPresetSwitch.target)
                      ├─ "Save"                → resolvePendingSwitchSave
                      │     ├─ saveEdit()
                      │     └─ performSwitch(to: pendingPresetSwitch.target)
                      └─ "Save as…"            → open name sheet
                           └─> resolvePendingSwitchSaveAs(name:)
                                ├─ saveEditAsFile(name)            (write only)
                                └─ performSwitch(to: pendingPresetSwitch.target)
```

In all resolution paths, the final step is `pendingPresetSwitch = nil`.

---

## Edge cases

1. **Picker change while a `pendingPresetSwitch` alert is already up.**
   Bound picker is gated on `viewModel.eqPresetName` (committed value), so the visible picker should snap back to the current preset until the alert resolves. To be safe, ignore further `requestPresetSwitch` calls while a pending switch exists (early return; log).

2. **`reloadParsedPreset` returns `nil`** (file missing/corrupted) on the new target.
   `performSwitch` commits `setEqPresetName(target)` regardless. If `parsedEqPreset` is still `nil` after reload, just call `cancelEdit()` to close the editor — no toast or inline error. This matches today's behavior: a broken preset shows no parsed values and the Edit pencil is already disabled, so the next interaction (clicking Edit again) is the natural recovery point.

3. **Editor on a NEW preset (`editingIsNew == true`)**, user picks a preset.
   Dirty by definition once anything is touched (and may be dirty even with empty bands if preamp moved). Dialog opens with Save disabled. Save As… and Discard work as normal. On Discard: drop the draft (which has no on-disk file), set picker to target, reseed editor with target's values, set `editingOriginalName = target`, `editingIsNew` becomes `false` (because `editingOriginalName != nil`).

4. **Bypass while dirty.**
   Same alert. On resolution other than Cancel, picker goes to `nil` and editor closes (`cancelEdit()` after save path completes). Save-as still saves the work first.

5. **User picks the SAME preset that's currently selected** (no-op).
   `requestPresetSwitch` should compare `target == eqPresetName` and return early — no alert, no reseed.

---

## Tests (`SettingsViewModelTests`)

Add cases:

- `requestPresetSwitch_editorClosed_setsPresetWithoutDialog`
- `requestPresetSwitch_editorClean_swapsEditorValuesWithoutDialog`
- `requestPresetSwitch_editorClean_toBypass_closesEditor`
- `requestPresetSwitch_editorDirty_setsPendingSwitch`
- `requestPresetSwitch_sameTarget_noOp`
- `resolvePendingSwitchDiscard_swapsAndClearsPending`
- `resolvePendingSwitchSave_writesOriginalThenSwaps`
- `resolvePendingSwitchSaveAs_writesNewNameThenSwapsToTarget` (asserts picker lands on `target`, NOT on `name`)
- `resolvePendingSwitchSaveAs_keepsExistingPresetsList` (refresh present)
- `cancelPendingSwitch_clearsPendingWithoutSwap`
- `requestPresetSwitch_whilePendingActive_isIgnored`
- `requestPresetSwitch_newPresetDirty_setsPendingSwitch` (editingIsNew path)
- `resolvePendingSwitchSave_newPreset_isNoop` (no original → no-op; UI button should be disabled, but VM must defend)

UI/integration: no separate UI tests planned; the SwiftUI alert wiring is verified by visual smoke during the PR's manual check.

---

## Out of scope

- Rewording or restyling unrelated EQ dialogs (`saveAlert`, `sharedSaveConfirm`).
- Persisting in-flight `editingPreset` across app restart.
- Auto-save / draft snapshots.
- Confirming on Cancel button (`EqEditPanel` footer Cancel) — separate concern, not requested.

---

## Files touched

- `Sources/RPPlayer/Shell/SettingsViewModel.swift` — new methods, `pendingPresetSwitch` published state, internal helpers, `saveEditAs` refactor.
- `Sources/RPPlayer/Shell/SettingsView.swift` — picker binding routes through `requestPresetSwitch`; alert + save-as sheet attached to `eqSection`.
- `Sources/RPPlayer/Shell/EqEditPanel.swift` — no functional change (existing Save/Save As/Cancel keep working as before).
- `Tests/RPPlayerTests/SettingsViewModelTests.swift` — new cases listed above.
- `CHANGELOG.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md` per project workflow.

---

## Risks

- SwiftUI `.alert` with 4 buttons on macOS renders all buttons in a horizontal row at the bottom of the alert; ordering convention is destructive on the left, default action on the right. Verify the layout looks acceptable; if it crowds, fall back to `confirmationDialog` (acts as a sheet-like menu on macOS).
- `requestPresetSwitch` must be idempotent against the SwiftUI Picker firing the binding repeatedly during rapid UI changes. The `pendingPresetSwitch != nil` early return handles this.
- Tests that drive `setEqPresetName` directly remain valid — `setEqPresetName` stays as-is for internal use and external callers (CLI / tests).
