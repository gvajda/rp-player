# Parametric EQ MVP — Design Spec

> Status: Approved by user 2026-05-12. Awaiting plan + execution in a future session.
>
> This spec captures the agreed-upon design from a brainstorm session. The next session should invoke `superpowers:writing-plans` and use this spec as input to produce a task-by-task implementation plan.

## Goal

Add parametric EQ to RP Player as a per-device audio setting. MVP scope: enable toggle + preset import/export. Defer per-band UI to a later PR.

## Why

User wants parametric EQ to colour-correct their headphones (Qudelix-5K DAC + headphones). Existing presets come from squig.link / AutoEQ. The app already runs the audio path through libmpv, which links FFmpeg internally — biquad EQ filters are available with zero new dependencies.

Hog mode is the point of the app; bit-perfect is no longer a hard claim once EQ runs. User accepted the trade-off: bit-perfect language now lives only in the Force-Max Volume tooltip ("Bit-perfect when EQ is off").

## Preset format

Standard **AutoEQ / Equalizer APO / REW** parametric EQ format. Same format Qudelix-5K and squig.link publish. Example (`.temp/5k_usr_5k_usr_XS_gergely.txt`):

```
CH: 0
TYPE: PEQ
Preamp: -1.2 dB
Xfeed: 1 1
Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.820
Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.600
Filter 3: ON PK Fc 950 Hz Gain -1.9 dB Q 1.800
...
```

Lines:

- `Preamp: <gain> dB` — global gain offset, applied at chain head. Typically negative to prevent clipping after band boosts.
- `Filter N: ON {PK|LS|HS|LP|HP|NO|AP|BP} Fc <Hz> Gain <dB> Q <q>`
  - `PK` peaking, `LS` low shelf, `HS` high shelf.
  - MVP supports `PK` / `LS` / `HS` only. Unsupported types (`LP`/`HP`/`NO`/`AP`/`BP`) are silently dropped with a single warning surfaced via the existing `errors: AsyncStream<String>` (one line per dropped band).
- `CH:` / `TYPE:` / `Xfeed:` — ignored (the Qudelix-specific `Xfeed:` becomes the basis for a future crossfeed PR; ignore here).

## Implementation

### Engine surface

Add to `PlayerEngine` protocol + `MpvPlayerEngine` actor:

```swift
func setAudioFilterChain(_ chain: String?) async throws
```

Body: `mpv_set_property_string(handle, "af", chain ?? "")`. Empty string clears mpv's filter chain. Safe to call mid-playback — mpv applies dynamically without restarting the file.

### Filter chain format

Single FFmpeg lavfi graph passed verbatim to mpv:

```
lavfi=[volume=<preamp>dB,equalizer=f=<fc>:t=q:w=<q>:g=<gain>,lowshelf=f=<fc>:t=q:w=<q>:g=<gain>,highshelf=f=<fc>:t=q:w=<q>:g=<gain>,...]
```

Mapping:

- `Preamp: -1.2 dB` → `volume=-1.2dB` at chain head
- `Filter N: ON PK Fc <fc> Gain <gain> Q <q>` → `equalizer=f=<fc>:t=q:w=<q>:g=<gain>`
- `Filter N: ON LS Fc <fc> Gain <gain> Q <q>` → `lowshelf=f=<fc>:t=q:w=<q>:g=<gain>`
- `Filter N: ON HS Fc <fc> Gain <gain> Q <q>` → `highshelf=f=<fc>:t=q:w=<q>:g=<gain>`
- `OFF` filters: skip silently.

FP32 precision is fine for any preset under Fc 30 Hz with Q < 10 and gain < ±20 dB. Don't add `aformat=sample_fmts=dbl` to the chain unless extreme presets land.

### Models

New types in `Sources/RPPlayer/Config/`:

```swift
public enum EqBandType: String, Codable, Sendable {
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
}

public struct EqPreset: Codable, Equatable, Sendable {
    public var name: String?       // derived from filename on import; nil if user-edited
    public var preampDb: Double
    public var bands: [EqBand]     // capped at 10
}
```

### AudioProfile additions

```swift
public struct AudioProfile {
    // existing fields...
    public var eqEnabled: Bool       // default false
    public var eqPreset: EqPreset?   // nil until imported
}
```

JSON migration: pre-PR-36 profiles lack both fields. Custom decoder defaults `eqEnabled = false`, `eqPreset = nil`.

Load-while-disabled is allowed: importing a preset writes `eqPreset` regardless of `eqEnabled`. The engine chain is only built when both are true.

### Parser

`EqPresetParser.parse(_ text: String) -> Result<EqPreset, EqPresetError>`:

- Strip whitespace per line.
- Match `^Preamp:\s*([+-]?\d+(?:\.\d+)?)\s*dB` → `preampDb`. Default 0 if absent.
- Match `^Filter\s+\d+:\s+(ON|OFF)\s+(PK|LS|HS|LP|HP|NO|AP|BP)\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+(\d+(?:\.\d+)?)` per filter line.
- Filter to enabled + supported types only. Cap at 10 bands. Surplus + dropped-type filters emit one diagnostic line each (via the errors stream).
- Return `EqPreset(name: filename, preampDb: ..., bands: [...])`.
- Errors: malformed file, no recognisable filter lines. Surface human-readable message via `errors: AsyncStream<String>`.

### Serializer

`EqPresetWriter.write(_ preset: EqPreset) -> String`:

- Header lines: `CH: 0\nTYPE: PEQ`
- `Preamp: <preampDb> dB`
- One line per band: `Filter <N>: ON <type-abbr> Fc <fc> Hz Gain <gain> dB Q <q>` matching the input format byte-for-byte where possible (round-trip identity for previously-imported presets, modulo trailing whitespace).

### UI

New Settings section "Equalizer" below the Volume row in `deviceSettingsSection`:

```
Equalizer                        [toggle]
Create presets at squig.link.
  [Import Preset…]   [Export Preset…]
  Loaded: <filename or "None">
  Preamp: -1.2 dB
  1 LS, 7 PK, 1 HS, 1 PK   (10 bands)
```

- Toggle: `Equalizer` switch, bound to `eqEnabled` per-device.
- Hint text below toggle: `Create presets at squig.link.` with `Link` to <https://squig.link>.
- Buttons: `Import Preset…` / `Export Preset…`. Export disabled when `eqPreset == nil`.
- Read-only summary block: visible only when `eqPreset != nil`. Shows filename (if set), preamp, band-type count (e.g. `1 LS, 7 PK, 1 HS`), total band count.
- No per-band table UI in MVP. User edits presets in squig.link / REW / Equalizer APO and re-imports.

### File picker

- Import: `NSOpenPanel`, filter `.txt`. Read via `String(contentsOf:)`. Parse → if success, write to active device profile. If error, surface via errors stream.
- Export: `NSSavePanel`, filter `.txt`, default filename = `<deviceName>-eq.txt`. Write serialized preset to chosen path.

Sandbox: app is signed with hardened runtime but not sandboxed. No file-access entitlement needed.

### AppContainer binder

New binder Task watches `(audioProfiles[outputDeviceUID]?.eqEnabled, audioProfiles[outputDeviceUID]?.eqPreset)` pair. On change:

- If `eqEnabled && eqPreset != nil`: build chain string + call `engine.setAudioFilterChain(chain)`.
- Else: `engine.setAudioFilterChain(nil)` (clear filters).

The chain rebuild is independent of bitrate/device changes; it composes with existing `applyBitrateChange` (no interaction needed — `af` survives `loadfile`).

### View model

`SettingsViewModel`:

- New `@Published private(set) var eqEnabled: Bool`
- New `@Published private(set) var eqPreset: EqPreset?`
- New setters: `setEqEnabled(_:)`, `setEqPreset(_:)` (writes through to active device profile via the existing `audioProfiles[uid, default: .safeDefault]` pattern, mirroring how Volume mode works post-PR-34).

### Interactions

- **EQ + Force-Max:** both run inside mpv before AO write. Compose cleanly. Preamp typically negative (AutoEQ default) so clipping isn't a concern even with force-max.
- **EQ + ReplayGain:** both attenuate. Compose cleanly.
- **EQ + Hog mode:** orthogonal — hog only changes device-access mode, not the signal path. EQ runs in mpv's filter chain regardless.

### "Bit-perfect" lingo

Already updated in PR 34: Force-Max Volume tooltip says "Bit-perfect when EQ is off." That line is now load-bearing.

## Out of scope (deferred)

- Per-band UI (sliders, freq response graph). MVP is import/export only.
- Crossfeed (`crossfeed` lavfi filter; Qudelix's `Xfeed:` line in preset format). Separate PR. Probably 2 sliders (`strength`, `range`) bound to mpv filter args.
- Bypass for individual bands. AutoEQ presets are all-on; the `OFF` syntax is rare.
- Custom filter types beyond PK / LS / HS. Most AutoEQ presets only use these three.
- Preset library / multiple-presets-per-device. MVP is one preset per device.
- Auto-EQ-from-measurement (compute target curve in-app). Use external tools.

## Test counts target

Rough estimate of new tests:

- `EqBandType` / `EqBand` / `EqPreset` Codable round-trip: ~3
- `EqPresetParser` happy paths (PK only, mixed types, all types, preamp): ~5
- `EqPresetParser` edge cases (>10 bands cap, unsupported types dropped, empty file, malformed line, OFF filters skipped): ~5
- `EqPresetWriter` round-trip from parsed preset: ~2
- `AudioProfile` migration (eq fields default to absent → `false` / `nil`): ~2
- `MpvPlayerEngine.setAudioFilterChain` (option set, error path): ~2
- `SettingsViewModel` eq surface (toggle write, preset import write, propagation): ~4
- AppContainer binder integration (engine.setAudioFilterChain called on toggle/preset change): ~2

Total: ~25 new tests. Expect 421 → ~446.

## Open questions for execution session

- Confirm `MpvPlayerEngine` baseline build still includes the `equalizer` / `lowshelf` / `highshelf` FFmpeg filters. Quick probe: run `mpv --af=help` against the vendored `Vendor/libmpv/lib/libmpv.dylib`. Or add a tiny `--probe-filters` flag to `RPSmoke` that prints `mpv_get_property("af-list")`. Filter availability is the only hard dependency that could derail the plan.
- Decide preset filename when export target is unnamed (`EqPreset.name == nil`). Default: `<deviceName>-eq.txt`.
- Decide whether to surface unsupported-filter-type drops via the errors stream (intrusive) or via the parser's return type (callee-controlled). Recommendation: callee-controlled — return `Result<(preset: EqPreset, warnings: [String]), EqPresetError>`. UI shows warnings as a one-time alert after import.
