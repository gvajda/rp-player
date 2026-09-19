# Liquid Glass + Frosted Window — Design Spec

**Date:** 2026-05-05
**Status:** Approved (brainstorming phase)
**Target PR:** TBD (next implementation cycle)

## Goal

Add two opt-in Appearance toggles to RP Player:

1. **Liquid Glass** — applies Apple's `.glassEffect()` (macOS 26+) to the mini-player popover and past-song popover. Refracts the desktop behind the floating window plus any layered backgrounds (ambient gradient, system colors).
2. **Frosted (Upcoming Program)** — applies an `NSVisualEffectView` blur material to the Upcoming Program window background. Works on macOS 14+ floor.

Two independent settings, both default `false`. Reactive on toggle flip, no app restart.

## Non-goals

- Glass on Settings/Login windows (Apple guidance: glass is for navigation layer, not content windows).
- Glass intensity slider, variant picker (`.regular` vs `.clear`), or tinted glass — pick `.regular` shape `RoundedRectangle(cornerRadius: 10)` in implementation; revisit only if user feedback warrants.
- Custom animation transitions when toggling — SwiftUI's implicit property animations are sufficient.
- Bumping deployment target above macOS 14. Liquid Glass code paths are runtime-gated `if #available(macOS 26.0, *)`.

## Architecture

### macOS support strategy

- **Floor preserved at macOS 14.** Glass code paths gated `if #available(macOS 26.0, *)` everywhere they're applied. Frosted code path uses `NSVisualEffectView` (macOS 10.10+, well below floor).
- **Settings UI behavior on macOS <26:** Liquid Glass toggle rendered with `.disabled(true)` and a `.caption` footnote "Requires macOS 26 or later". Storage of the bool persists regardless — if the user upgrades, prior toggle state takes effect immediately on next view build.
- **Frosted toggle is always enabled** (no version gating).

### Data flow

```
SettingsView
   │ Toggle flip
   ▼
ConfigStore.update { $0.liquidGlassEnabled / $0.frostedUpcomingEnabled = newValue }
   │ JSON persistence
   │ store.changes AsyncStream
   ▼
MiniPlayerViewModel / PastSongViewModel       UpcomingWindowController (or UpcomingProgramViewModel)
   │ subscription extended in start()           │ subscription added at construction
   ▼                                            ▼
Published prop liquidGlassEnabled            Reads frostedUpcomingEnabled live
   │                                            │ Installs/removes NSVisualEffectView
   ▼                                            │ as content-view subview index 0
MiniPlayerView / PastSongView                   ▼
   │ .modifier(LiquidGlassBackgroundIfEnabled)  Window background reactive
   ▼
SwiftUI view tree composes:
  [bottom] system windowBackgroundColor (gated off when glass ON)
  [mid]    AmbientGradientBackground (when ambient ON, layered below glass)
  [top]    Content
  [outer]  .glassEffect(in: RoundedRectangle(cornerRadius: 10)) when glass ON
```

### Composition order in popovers

When **both** Liquid Glass and Ambient are on, the layering top-to-bottom is:
1. Glass effect modifier (outermost — refracts everything below + desktop behind window).
2. Content.
3. Ambient gradient (album-art-derived).
4. Desktop wallpaper / windows behind the panel (refracted through glass).

The opaque `windowBackgroundColor` fill currently rendered as the popover base must be **gated off** when Liquid Glass is ON. Otherwise the glass refracts an opaque grey instead of ambient/desktop content.

## Components

### New files

#### `Sources/RPPlayer/Shell/Components/LiquidGlassBackground.swift`

SwiftUI `ViewModifier` plus an `IfEnabled` wrapper that bakes the `#available` and the toggle check.

```swift
import SwiftUI

struct LiquidGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }
}

struct LiquidGlassBackgroundIfEnabled: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(LiquidGlassBackground())
        } else {
            content
        }
    }
}
```

The shape parameter is fixed to `RoundedRectangle(cornerRadius: 10)` to match the existing popover panel's content-view layer corner radius. If a future PR adopts `GlassEffectContainer` for grouped glass elements, the modifier can be extended; not needed for the single-surface use case.

#### `Sources/RPPlayer/Shell/Components/FrostedWindowBackground.swift`

`NSViewRepresentable` wrapping `NSVisualEffectView`. Material `.hudWindow` selected by default — `.popover` is also a candidate but `.hudWindow` matches the dark-mode-friendly card aesthetic of the upcoming window. Decide visually during implementation; either is one-line change.

```swift
import SwiftUI
import AppKit

struct FrostedWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
```

### Modified files

#### `Sources/RPPlayer/Settings/AppSettings.swift`

Add two `Bool` fields with `false` defaults:

```swift
public var liquidGlassEnabled: Bool = false
public var frostedUpcomingEnabled: Bool = false
```

Add corresponding `CodingKeys` entries. Decoder should fall back to the default for missing keys (existing pattern via `decodeIfPresent`).

#### `Sources/RPPlayer/Settings/SettingsView.swift`

Append two toggles in the existing `appearanceSection` Form section, below the Ambient toggle. Order: System/Light/Dark picker → Ambient → Liquid Glass → Frosted.

```swift
Toggle("Liquid Glass", isOn: $settings.liquidGlassEnabled)
    .disabled(!isLiquidGlassAvailable)
if !isLiquidGlassAvailable {
    Text("Requires macOS 26 or later")
        .font(.caption)
        .foregroundStyle(.secondary)
}

Toggle("Frosted Upcoming Program window", isOn: $settings.frostedUpcomingEnabled)
```

`isLiquidGlassAvailable` computed via `if #available(macOS 26.0, *) { true } else { false }` at view-build time.

#### `Sources/RPPlayer/Shell/MiniPlayerView.swift`

- Apply `LiquidGlassBackgroundIfEnabled` modifier on the root content (outermost).
- Gate the existing opaque `windowBackgroundColor` fill on `!viewModel.liquidGlassEnabled`.
- Existing `AmbientGradientBackground` stays where it is (layers below glass naturally given outer modifier order).

#### `Sources/RPPlayer/Shell/Components/PastSongView.swift`

Mirror the mini-player wiring: same modifier on root, same gating of opaque fill.

#### `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` and `PastSongViewModel.swift`

Add published prop `liquidGlassEnabled: Bool = false`. Extend the `store.changes` subscription in `start()` to update it.

#### `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift`

Subscribe to `store.changes` at construction. On `frostedUpcomingEnabled` change:
- ON: insert `NSHostingView(rootView: FrostedWindowBackground())` as the window's `contentView`'s subview at index 0, with autoresizing to fill.
- OFF: remove the inserted subview.

Cards render above the inserted view automatically (subview index 0 is the bottom).

#### `Sources/RPPlayer/Shell/PopoverController.swift`

No code change required — panel already has `isOpaque=false`, `backgroundColor=.clear`, content view layer with `cornerRadius=10`, `masksToBounds=true`. Foundation is glass-ready.

#### `Sources/RPPlayer/App/AppContainer.swift`

Wire the two new settings into VM published props via the existing settings binder pattern (mirrors how `ambientBackgroundEnabled` is wired).

## Edge cases

- **Glass + corner radius:** explicit `RoundedRectangle(cornerRadius: 10)` shape param on `.glassEffect(...)` — default capsule would clip incorrectly.
- **Glass + opaque background:** must gate the popover's `windowBackgroundColor` fill OFF when glass is ON. Otherwise glass refracts opaque grey.
- **Frosted + light/dark mode:** `NSVisualEffectView` materials are appearance-aware automatically. Respects `NSApp.appearance` set by the existing System/Light/Dark picker. No extra wiring.
- **macOS upgrade mid-session:** Settings view reads availability at view-build time. After OS upgrade, app restart picks up new availability and stored toggle takes effect.
- **Live toggle on Upcoming window while window is open:** subscription pattern means the `NSVisualEffectView` insertion/removal happens reactively. Test manually that no flicker / no card-rerender.
- **Concurrency:** all UI changes on `@MainActor` (existing pattern). No new concurrency primitives.

## Testing

### Unit tests (added)

- **`Tests/RPPlayerTests/Settings/AppSettingsTests.swift`** — round-trip encode/decode of `liquidGlassEnabled` and `frostedUpcomingEnabled` with default values. Old config.json (without new keys) decodes with `false` defaults (back-compat).
- **`Tests/RPPlayerTests/Shell/MiniPlayerViewModelTests.swift`** — `store.changes` updates `liquidGlassEnabled` published prop (mirror of existing ambient test).
- **`Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift`** — same as above for past-song VM.
- **`Tests/RPPlayerTests/Shell/Components/LiquidGlassBackgroundTests.swift`** — smoke test that the modifier compiles and returns a non-empty body on both branches of the `#available` check.

Estimated test delta: +6 to +8. Target total: ~351-353 (was 345).

### Manual verification

On macOS 26:
- Liquid Glass toggle ON for mini-player popover → glass refracts wallpaper.
- Liquid Glass + Ambient both ON → glass refracts ambient gradient + wallpaper layered.
- Glass OFF → reverts cleanly to current opaque/ambient look.
- Past-song popover gets matching glass appearance.
- Light/Dark/System Appearance picker still works under glass.
- Frosted Upcoming ON → window blurs background; cards remain readable.
- Settings UI: Liquid Glass toggle enabled (we're on 26).

On macOS 14/15/25 (if available):
- Liquid Glass toggle disabled with caption.
- Frosted toggle works; Upcoming window gets blur.
- Toggle state persists across app restarts.

Visual correctness validated manually; no automated UI snapshot tests planned (would require macOS 26 CI runner).

## Open questions for implementation phase

- **Glass material variant:** `.regular` vs `.clear`. Default to `.regular` per Apple guidance for opaque-ish navigation surfaces. Revisit if visual feedback during implementation suggests `.clear` reads better against ambient gradients.
- **Frosted material:** `.hudWindow` vs `.popover` for the Upcoming Program window. Both reasonable; pick during impl after eyeballing.
- **GlassEffectContainer:** present API supports grouping glass surfaces for unified refraction. Not needed for single-popover use case in this PR. Revisit if a future PR glasses multiple grouped elements.

## Acceptance criteria

- Two new bool fields persist in `config.json`, default `false`, back-compat with existing config files.
- Liquid Glass toggle:
  - On macOS 26+: enabled, applies `.glassEffect(in: RoundedRectangle(cornerRadius: 10))` to mini-player and past-song popovers when ON.
  - On macOS <26: disabled with caption; toggle state still persists.
- Frosted toggle: always enabled; ON installs `NSVisualEffectView` as Upcoming window background subview at index 0.
- Ambient gradient renders below glass when both ON (composition order verified manually).
- Both toggles live-update without app restart.
- Test suite passes (~351-353).
- README Appearance section updated with one sentence covering the two toggles.
