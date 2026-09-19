# PR 36 — Crossfeed for headphone listening

**Date:** 2026-05-13
**Author:** Brainstorm session (Claude + Gergely)
**Status:** Design approved; ready for plan.

## Goal

Per-device Bauer-style crossfeed via the ffmpeg `crossfeed` filter, so headphone listeners can soften hard-panned stereo without leaving the app. Default OFF. Composes orthogonally with the parametric EQ (PR 35) and Volume Mode (PR 34) in a single `mpv af` filter chain.

## Non-goals

- Headphone auto-detection (no reliable CoreAudio signal; opt-in per device).
- Per-EQ-preset crossfeed (lives in `AudioProfile`, not in EQ `.txt` files; Qudelix `Xfeed:` lines remain ignored).
- Exposing `slope` / `level_in` / `level_out` — ffmpeg defaults are fine.
- Meier-style or Linkwitz-style crossfeed (ffmpeg ships Bauer only).
- A/B switch or compare-with-bypass UX.

## Background

PR 35 (parametric EQ MVP) merged 2026-05-12. Vendored libmpv is `audio-encodersgpl` (since `0712bdb`); `crossfeed` filter confirmed via `strings Vendor/libmpv/lib/libavfilter.dylib`. No further binary swap needed.

ffmpeg's `crossfeed` filter is Bauer-style only (BS2B-derived). Options:

| Option | Range | Default | Exposed in UI? |
|---|---|---|---|
| `strength` | 0.0–1.0 | 0.2 | YES |
| `range` | 0.0–1.0 | 0.5 | YES |
| `slope` | — | 0.5 | no (ffmpeg default) |
| `level_in` | — | 0.9 | no |
| `level_out` | — | 0.9 | no |

EQ binder (`AppContainer.runEqBinder` + `applyEqState`) is the reuse template. Crossfeed extends — not parallel-runs — the same binder, because mpv's `af` property is a single string and concurrent writes race.

## Architecture

### Filter chain order

**Preamp → EQ bands → Crossfeed.**

Preamp stays at head (AutoEQ headroom semantics preserved: prevents EQ peak clipping). Crossfeed appended at tail; operates on the equalized signal, which is what a headphone listener actually hears.

Concrete example with both EQ and crossfeed on:

```
lavfi=[
  volume=volume=-6dB,
  equalizer=f=1000:t=q:w=1:g=3,
  lowshelf=f=80:t=q:w=0.7:g=2,
  highshelf=f=8000:t=q:w=0.7:g=-1,
  crossfeed=strength=0.4:range=0.5
]
```

### Data model

#### `AudioProfile` additions (flat fields)

```swift
// Sources/RPPlayer/Config/AudioProfile.swift
public var crossfeedEnabled: Bool       // default false
public var crossfeedStrength: Double    // default 0.2,  clamped 0.0...1.0
public var crossfeedRange: Double       // default 0.5,  clamped 0.0...1.0
```

- `safeDefault` extended with `(false, 0.2, 0.5)`.
- `init(...)` gains three params with defaults so existing call sites compile unchanged.
- Mirrors PR 35's `eqEnabled` + `eqPresetName` flat-field pattern.

#### `AppSettings` (unchanged)

PR 35's `eqEnabled` / `eqPresetName` live ONLY on `AudioProfile`, NOT on `AppSettings`. PR 36 follows the same pattern: crossfeed fields are per-device only. The write-back loop in `AppContainer` (currently passes `existing.eqEnabled` / `existing.eqPresetName` through `AudioProfile.init` to preserve EQ across volume / hog / bitrate changes) gains three more `existing.crossfeed*` passthroughs — no `AppSettings` shape change required.

#### Codable migration

- Three new `CodingKeys` entries on `AudioProfile`.
- `init(from:)` adds `decodeIfPresent ?? <default>` for each — identical shape to PR 35's `eqEnabled` / `eqPresetName` migration.
- No legacy field collision; these are brand new.
- Existing per-device profiles missing these keys decode to `(false, 0.2, 0.5)` — disabled at the toggle level so audible behavior unchanged on upgrade.
- Encoders always write the new keys.

### Builders

#### `EqChainBuilder.buildParts` (signature change)

```swift
// Sources/RPPlayer/Config/EqChainBuilder.swift
public enum EqChainBuilder {
    public static func buildParts(_ preset: EqPreset) -> [String]
}
```

- Returns the lavfi part list (`["volume=volume=-6dB", "equalizer=...", ...]`), not the full `"lavfi=[...]"` string.
- Returns `[]` when no enabled bands AND preamp == 0.
- Caller wraps in `lavfi=[...]` at the binder.
- Previous `build(_:) -> String?` is removed; sole production caller and ~8 test sites updated.

#### `CrossfeedFilterBuilder` (NEW)

```swift
// Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift
public enum CrossfeedFilterBuilder {
    public static func buildPart(strength: Double, range: Double) -> String {
        let s = format(strength.clamped(to: 0.0...1.0))
        let r = format(range.clamped(to: 0.0...1.0))
        return "crossfeed=strength=\(s):range=\(r)"
    }

    private static func format(_ v: Double) -> String { /* same as EqChainBuilder.format */ }
}
```

- Always returns a non-empty fragment; "should I include it?" is the binder's decision based on `crossfeedEnabled`.
- Internal clamp is defense-in-depth; the UI already clamps via `Stepper(in: 0.0...1.0)`.

### Binder

#### Rename + signature extension

`AppContainer.runEqBinder` → `runAudioFilterBinder`. `applyEqState` → `applyAudioFilterState`.

```swift
internal static func runAudioFilterBinder(
    store: any ConfigStore,
    engine: any PlayerEngine,
    eqPresetStore: any EqPresetStore,
    initialProfile: AudioProfile
) async
```

State diff key becomes a 5-tuple:

```swift
struct AudioFilterKey: Equatable {
    let eqEnabled: Bool
    let eqPresetName: String?
    let crossfeedEnabled: Bool
    let crossfeedStrength: Double
    let crossfeedRange: Double
}
```

Loop yields when the key changes — eliminates redundant `setAudioFilterChain` writes when only volume / hog / bitrate flip.

#### `applyAudioFilterState` flow

1. EQ enabled AND preset loads OK → `eqParts = EqChainBuilder.buildParts(preset)`. Else `eqParts = []`.
2. Crossfeed enabled → `cfPart = CrossfeedFilterBuilder.buildPart(strength:range:)`. Else `cfPart = nil`.
3. If `eqParts.isEmpty && cfPart == nil` → `engine.setAudioFilterChain(nil)`.
4. Else → `lavfi=[\(eqParts + [cfPart].compactMap { $0 }).joined(separator: ","))]` → `engine.setAudioFilterChain(...)`.

Existing EQ-only failure modes (file missing, parse warning, cache-miss) still call `setAudioFilterChain(nil)` when crossfeed is also off; when crossfeed is on, fall through to a crossfeed-only chain.

#### Profile write-back patch

The volume / hog binder loop currently has a per-iteration profile write-back that threads `eqEnabled` + `eqPresetName` through `AudioProfile.init` so non-EQ settings changes don't silently wipe EQ state. Extend with `crossfeedEnabled` + `crossfeedStrength` + `crossfeedRange` for the same defensive reason. (PR 35's `Key technical decisions` note already calls this pattern out; PR 36 just adds three more fields to the passthrough.)

### Settings UI

#### Row placement

New "Crossfeed" row in `deviceSettingsSection`, directly **below** the EQ row. Inline-row layout matching the post-PR-35 EQ row.

#### Row layout

```
Crossfeed  ⓘ   Strength [0.20 ▴▾]   Range [0.50 ▴▾]   [Toggle]
```

- "Crossfeed" label leading.
- Single `HoverInfoIcon` (ⓘ) for the row — combined tooltip.
- Two numeric stepper composites (custom view `ClampedNumericField`), each ~56–72pt wide.
- Trailing `Toggle` bound to `viewModel.crossfeedEnabled`.
- Numeric fields **disabled** (greyed) when toggle is OFF. No full row collapse — keeps layout stable; matches the EQ collapse pattern at the field level only.

#### `ClampedNumericField` (new internal view)

```swift
// Sources/RPPlayer/Settings/Components/ClampedNumericField.swift
struct ClampedNumericField: View {
    @Binding var value: Double          // source of truth (clamped, valid)
    let range: ClosedRange<Double>      // 0.0...1.0
    let step: Double                    // 0.05
    let defaultValue: Double            // 0.20 or 0.50

    @State private var rawText: String  // user-typed string
    @State private var isInvalid: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $rawText)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onChange(of: rawText) { newText in
                    if let parsed = parse(newText), range.contains(parsed) {
                        value = parsed
                        isInvalid = false
                    } else {
                        isInvalid = true
                    }
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused && isInvalid {
                        // Snap back to last valid value (current binding).
                        rawText = format(value)
                        isInvalid = false
                    }
                }
                .onChange(of: value) { newValue in
                    if !focused { rawText = format(newValue) }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(isInvalid ? 0.85 : 0), lineWidth: 1.5)
                        .animation(.easeInOut(duration: 0.15), value: isInvalid)
                )

            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
        .onAppear { rawText = format(value) }
    }

    private func parse(_ s: String) -> Double? {
        // Locale-aware via NumberFormatter; fallback dot-as-decimal.
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        return f.number(from: s)?.doubleValue ?? Double(s)
    }

    private func format(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
```

Validation rules:

- Bind `TextField` to `@State rawText`, NOT directly to `Double` — direct binding would silently revert and we'd lose the red-glow signal.
- `.onChange(of: rawText)`: parse → check `range.contains(...)` → if valid, write to `value` and clear `isInvalid`. If invalid, only set `isInvalid = true`.
- `.onChange(of: focused)` to `false`: if `isInvalid`, snap `rawText` back to last valid `value` and clear `isInvalid`. Default value (`0.20` / `0.50`) is the seed only at first appearance — after that, "last valid" wins, so a user who tweaked to 0.40 and then types garbage gets 0.40 back, not 0.20.
- Red glow: `.overlay(RoundedRectangle.stroke(.red.opacity(isInvalid ? 0.85 : 0)))` + `.animation(.easeInOut(0.15))`.
- Stepper always writes valid values (mpv-side clamp; `Stepper(in:)` enforces range and step); `.onChange(of: value)` keeps `rawText` in sync only when not focused (avoid stomping the user's mid-edit input).

#### Tooltip (single ⓘ for the row)

`HoverInfoIcon` already supports multi-line via `\n`. Copy:

```
Crossfeed simulates a small amount of acoustic leakage between
the left and right channels — only useful for headphones, where
hard-panned stereo can feel unnaturally separated.

Strength (0.0–1.0): how much signal crosses to the opposite ear.
  Default 0.20. Higher = stronger spatial blend.
Range (0.0–1.0): high-frequency rolloff of the crossfed signal.
  Default 0.50. Lower = darker / more natural at higher strengths.

Bauer-style (BS2B). No effect on speaker output; safe to leave
off for non-headphone devices.
```

#### `SettingsViewModel` surface

```swift
// Sources/RPPlayer/Settings/SettingsViewModel.swift
@Published private(set) var crossfeedEnabled: Bool
@Published private(set) var crossfeedStrength: Double
@Published private(set) var crossfeedRange: Double

func setCrossfeedEnabled(_ value: Bool) async
func setCrossfeedStrength(_ value: Double) async   // caller clamped via Stepper/range
func setCrossfeedRange(_ value: Double) async      // caller clamped via Stepper/range
```

Setters write to active device's `AudioProfile` entry — same pattern as `setEqEnabled` / `setEqPresetName`.

## Tests

Target: 462 → ~484 (+22).

| Area | New tests | Coverage |
|---|---|---|
| `CrossfeedFilterBuilder` | 3 | Defaults format; non-default values format with `.4f`-trim; out-of-range clamping. |
| `AudioProfile` migration | 4 | Defaults when keys absent; round-trip encode/decode; existing EQ-only profiles unchanged across PR 36 upgrade; legacy bool→VolumeMode (PR 34) migration still works. |
| `EqChainBuilder.buildParts` | 2 | Returns array (was string); empty array when no bands + zero preamp. |
| `AppContainerAudioFilterBinder` (renamed) | 6 | (1) EQ only → chain has EQ parts only. (2) Crossfeed only → chain is `lavfi=[crossfeed=...]`. (3) Both → chain has EQ then crossfeed in order. (4) Both off → `setAudioFilterChain(nil)`. (5) Profile write-back preserves crossfeed across non-crossfeed changes. (6) Device switch loads target device's crossfeed state. |
| `SettingsViewModel` surface | 6 | 3 published-prop initial values; 3 setters write through to active `AudioProfile`. |
| `ClampedNumericField` validation | 1 | Out-of-range or unparseable text → `isInvalid == true` and `value` unchanged; in-range writes through and clears `isInvalid`. (VM-level helper or Swift Testing snapshot.) |

## Risks

- **mpv filter availability.** `crossfeed` confirmed via `strings`. Extend `RPSmoke --probe-filters` (already in tree) to assert `crossfeed` present; fails loudly on a future libmpv refresh that drops it.
- **Numeric input locale.** `NumberFormatter(locale: .current)` parses "0,20" on German locales; double-fallback `Double(s)` covers dot-only input. Test with `.environment(\.locale, Locale(identifier: "de_DE"))`.
- **`EqChainBuilder.buildParts` rename ripples.** Production callers: 1 (binder). Test sites: ~8 (existing EQ chain-builder tests). All rewrites trivial — strip `lavfi=[...]` wrapper from expected strings and switch to array-equality.

## File touch list (estimated)

| Path | Action |
|---|---|
| `Sources/RPPlayer/Config/AudioProfile.swift` | +3 fields, Codable migration. |
| `Sources/RPPlayer/Config/EqChainBuilder.swift` | `build` → `buildParts` signature change. |
| `Sources/RPPlayer/Config/CrossfeedFilterBuilder.swift` | NEW. |
| `Sources/RPPlayer/App/AppContainer.swift` | Rename binder, extend snapshot diff, write-back patch. |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | +3 published, +3 setters. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | New Crossfeed row. |
| `Sources/RPPlayer/Shell/ClampedNumericField.swift` | NEW. |
| `Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift` | NEW. |
| `Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift` | NEW. |
| `Tests/RPPlayerTests/Config/EqChainBuilderTests.swift` | UPDATE — signature change. |
| `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift` | RENAME + extend. |
| `Tests/RPPlayerTests/Shell/SettingsViewModelCrossfeedTests.swift` | NEW. |
| `Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift` | NEW. |
| `Sources/RPSmoke/main.swift` (probe-filters) | Add `crossfeed` to expected-filter list. |
| `CHANGELOG.md` | `## [Unreleased]` entry under `Added`. |
| `CLAUDE.md` | PR 36 row in status table; *Test counts by PR* entry; *Key technical decisions* update for chain order + crossfeed. |

## Out of scope (deferred)

- Headphone auto-detection.
- Per-EQ-preset crossfeed.
- Exposing `slope` / `level_in` / `level_out`.
- A/B compare-with-bypass switch.
