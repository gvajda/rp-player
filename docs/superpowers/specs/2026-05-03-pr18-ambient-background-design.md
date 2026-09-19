# PR 18 — Ambient Background from Album Art — Design

Date: 2026-05-03  Status: Approved (preapproved by user, 2026-05-03)  Branch base: new branch off `main` (`claude/pr18-ambient-background`).

## Goal

Add an opt-in setting that paints the popover panel with a vertical color gradient derived from the current song's album art. The gradient's top stop matches the bottom edge of the album art (so the seam between art and panel disappears), and fades to the system `windowBackgroundColor` at the bottom of the panel. Coexists with the existing Light / Dark / System Appearance setting.

## Non-goals

- No changes to playback, coordinator, API, or persistence beyond adding one boolean field.
- No changes to album art layout, dimensions, or fetching.
- No changes to the Settings window background.
- No mesh gradient (would require macOS 15 floor).
- No blurred-art-as-background or solid-color-fill variants.
- No automatic text/control contrast adjustment — gradient bottom stop is the existing system background, so existing controls remain on a familiar surface.

## Key decisions (locked)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Interaction with existing Appearance (System/Light/Dark) | Independent toggle. Coexists with appearance. Gradient bottom stop tracks the current `windowBackgroundColor`, which already changes with light/dark. |
| 2 | Gradient style | Vertical 2-stop `LinearGradient`. |
| 3 | Top stop source | Average color of the bottom strip of the album art (~bottom 5% of pixels). Pixel-accurate match at the seam where art ends and panel begins. |
| 4 | Bottom stop | `Color(nsColor: .windowBackgroundColor)` — identical to current panel background. |
| 5 | Transition on song change | Animated `easeInOut`, ~0.4s. Driven by SwiftUI `.animation(_:value:)` on the published top-color value. |
| 6 | Sticky behavior on no-art | During the brief window between a new song's `nowPlaying` arriving and its album art loading: hold previous gradient (don't fade out). On promo block (`song.songId == "0"`), engine error (`nowPlaying` reset by errors stream), or ambient toggle OFF: fade gradient back to plain panel over the same 0.4s. |
| 7 | Setting placement | New `Toggle` in the existing `appearanceSection` of `SettingsView`, beneath the Appearance picker. |
| 8 | Default state | OFF. Existing users see no change until they opt in. |

## Architecture

### `AmbientPaletteExtractor` (new)

`Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift`

A small actor (or `final class`-with-lock — pick whichever is simpler given the call site is `MainActor`) responsible for: given an `NSImage`, return the average color of its bottom-edge strip.

```swift
import AppKit
import CoreGraphics
import SwiftUI

protocol AmbientPaletteExtracting: Sendable {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor?
}

struct ExtractedColor: Equatable, Sendable {
    let red: Double    // 0...1
    let green: Double  // 0...1
    let blue: Double   // 0...1

    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

actor AmbientPaletteExtractor: AmbientPaletteExtracting {
    func extractBottomEdgeColor(from image: NSImage) async -> ExtractedColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let height = cgImage.height
        let width = cgImage.width
        let stripHeight = max(1, height / 20)               // bottom 5%
        let stripRect = CGRect(x: 0, y: height - stripHeight, width: width, height: stripHeight)
        guard let strip = cgImage.cropping(to: stripRect) else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &bitmap,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return ExtractedColor(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0
        )
    }
}
```

Why an actor: extraction runs off the main thread (CGContext.draw on a 1×1 destination is fast — typically <1 ms — but we still don't want it on `@MainActor`). Why `Sendable` protocol with associated `ExtractedColor` value type: lets us inject a stub in tests and pass results across actor boundaries cleanly. `NSImage` is `Sendable` on macOS 14+, so passing it into the extractor is allowed.

### `AppSettings.ambientBackgroundEnabled`

Add to `AppSettings`:

```swift
public var ambientBackgroundEnabled: Bool
```

- Default: `false`.
- `init` default-arg: `ambientBackgroundEnabled: Bool = false`.
- Decoder: `try c.decodeIfPresent(Bool.self, forKey: .ambientBackgroundEnabled) ?? false`.

Existing JSON without the key decodes as `false`. No migration logic needed.

### `SettingsView` + `SettingsViewModel`

`SettingsViewModel`:

- Add `@Published private(set) var ambientBackgroundEnabled: Bool` initialized from `AppSettings.default`.
- `start()`'s config-change consumer hydrates it from `snapshot.ambientBackgroundEnabled`.
- New `func setAmbientBackgroundEnabled(_ value: Bool) async` mirroring the other setters.

`SettingsView.appearanceSection`:

```swift
private var appearanceSection: some View {
    Section("Appearance") {
        Picker("Appearance", selection: appearanceBinding) {
            Text("System").tag(AppearanceMode.system)
            Text("Light").tag(AppearanceMode.light)
            Text("Dark").tag(AppearanceMode.dark)
        }
        .pickerStyle(.menu)
        Toggle("Ambient background from album art", isOn: ambientBackgroundBinding)
    }
}
```

New `ambientBackgroundBinding` mirrors the existing pattern.

### `MiniPlayerViewModel` — gradient state

Add:

```swift
@Published private(set) var ambientTopColor: Color?   // nil = no gradient (plain panel)
@Published private(set) var ambientEnabled: Bool = false
```

Inject `paletteExtractor: any AmbientPaletteExtracting` and `configStore: any ConfigStore` (we already have what's needed via existing collaborators — see "Wiring" below for the minimal injection surface).

State transitions inside the existing `start()` and the streams it spawns:

1. **Settings stream**: subscribe to `configStore.changes` (or whichever subset already flows in). Keep `ambientEnabled = snapshot.ambientBackgroundEnabled`. When toggled OFF, also publish `ambientTopColor = nil` (animated fade-out via SwiftUI on the consumer side).
2. **`nowPlaying` updates**: when `np.song.songId == "0"` (promo block), publish `ambientTopColor = nil`. Otherwise: do NOT clear `ambientTopColor` here — wait for the new art to load.
3. **`loadArt` completion** (new behavior): after `currentArt = image` is assigned, if `ambientEnabled`, kick off `Task { let color = await extractor.extractBottomEdgeColor(from: image); await MainActor.run { self.ambientTopColor = color?.swiftUIColor } }`. This naturally implements stickiness: between the time a new song's `nowPlaying` arrives and when its art loads, `ambientTopColor` retains the previous song's color.
4. **Errors stream**: when an error message is published (existing behavior already sets `nowPlaying = nil`), also publish `ambientTopColor = nil`.

Cache: keep a small `[String: ExtractedColor]` map keyed by `coverPath` to avoid re-extracting when the same cover re-emits (defense in depth — `MiniPlayerViewModel.lastLoadedCoverPath` already short-circuits art reloads, but a per-song extracted-color memoization is essentially free and protects against future refactors). Optional polish; can be added or skipped without affecting design.

### `MiniPlayerView` — gradient layer

Apply the gradient as a `.background()` on the outer container (the `VStack(spacing: 0)` inside `body`):

```swift
var body: some View {
    VStack(spacing: 0) {
        // ... existing content ...
    }
    .frame(width: 342)
    .background(ambientBackground)
    .animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)
    .task { await viewModel.start() }
}

private var ambientBackground: some View {
    LinearGradient(
        colors: [
            viewModel.ambientTopColor ?? Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .windowBackgroundColor)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
```

When `ambientTopColor` is `nil`, both stops are `windowBackgroundColor` → gradient is a flat color identical to the popover's existing base background. When set, the top stop becomes the extracted color and the gradient fades to the system color toward the bottom. The `.animation(_:value:)` modifier crossfades the top color between values, including transitions to/from `nil`.

The popover's outer `windowBackgroundColor` wrap (in `PopoverController.init`) stays as is. The gradient sits in front of it and either covers it identically (ambient off) or replaces it visually (ambient on). No structural change to `PopoverController`.

### Wiring (`AppContainer`)

`AppContainer.live()` constructs `AmbientPaletteExtractor()` and passes it into `MiniPlayerViewModel`'s init.

`MiniPlayerViewModel.init` gains:

- `paletteExtractor: any AmbientPaletteExtracting`
- `configStore: any ConfigStore`

`start()` adds a subscription to `await configStore.changes` (which is multi-subscriber-safe per CLAUDE.md / `JSONConfigStore`'s contract). On each emission, hydrate `ambientEnabled = snapshot.ambientBackgroundEnabled`; when transitioning to `false`, also publish `ambientTopColor = nil`.

This mirrors how `SettingsViewModel` already consumes `configStore.changes`. Adding the same dependency to `MiniPlayerViewModel` is the symmetric move and avoids inventing an ad-hoc `AsyncStream<Bool>` plumbing layer.

Test seam: `AppContainer.init(...)` already accepts injected collaborators. Add `paletteExtractor` as another parameter with a `NoopAmbientPaletteExtractor` fallback (returns `nil` always) declared `private` at the bottom of `AppContainer.swift` next to the other `Noop*` types.

## Tests

| File | Tests |
|---|---|
| `Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift` (new) | (a) red-bottom fixture image extracts ~RGB(1, 0, 0); (b) blue-top/red-bottom fixture extracts ~RGB(1, 0, 0) (sampling lower strip, not whole image); (c) all-gray image extracts ~RGB(0.5, 0.5, 0.5); (d) zero-size or non-decodable input returns nil. Build fixtures in-memory via `NSImage` + `NSBitmapImageRep` — no on-disk fixtures needed. |
| `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift` (new) | (a) ambient OFF, art loads → `ambientTopColor` stays nil; (b) ambient ON, art loads → `ambientTopColor` becomes extracted color; (c) ambient ON, transition to promo block (`songId == "0"`) → `ambientTopColor` becomes nil; (d) ambient ON, mid-track new song before art loads → `ambientTopColor` retains previous value (sticky); (e) ambient ON, error from coordinator → `ambientTopColor` becomes nil; (f) ambient ON → toggle off via config update → `ambientTopColor` becomes nil. Use a stub `AmbientPaletteExtractor` returning a deterministic color, and the existing `InMemoryConfigStore` test double pattern. |
| `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` (extend) | (a) `ambientBackgroundEnabled` defaults to `false`; (b) `setAmbientBackgroundEnabled(true)` persists. |
| `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` (extend if exists, else new) | (a) round-trip with `ambientBackgroundEnabled = true`; (b) decode JSON without the key → defaults to `false`. |

Existing `MiniPlayerViewTests.testHostingControllerRendersWithoutCrash` already covers that the gradient layer doesn't break rendering (with `ambientTopColor` nil at construction time).

Expected new test count: **272 + ~12 = ~284** (give or take depending on parameterization). CLAUDE.md will be bumped to the actual count after implementation.

## Manual smoke (post-implementation)

1. Open Settings → Appearance. New "Ambient background from album art" toggle is below the Appearance picker. Default OFF.
2. Toggle ON. Open the popover. The panel below the album art picks up the bottom-edge color of the art and fades down to the system background. Seam between art and gradient is invisible.
3. Wait for next song. As art crossfades, gradient top color crossfades smoothly to the new song's bottom-edge color (~0.4s).
4. Tune to a promo block (any channel, around the breaks). Gradient fades back to plain panel during the promo. New song after promo: gradient comes back.
5. Disconnect output device (or trigger an engine error). Error message appears in popover; gradient fades out.
6. Toggle ambient OFF in Settings while playing. Gradient fades out to plain panel within 0.4s. Toggle back ON: gradient fades in.
7. Switch Appearance to Dark. Gradient bottom stop follows — gradient now fades into the dark window background. Ambient still works.
8. Quit and relaunch with ambient ON. Setting persists; gradient appears as soon as art loads on first song.

## Files touched

| Path | Change |
|---|---|
| `Sources/RPPlayer/Shell/AmbientPaletteExtractor.swift` | **New.** Actor + `Sendable` `ExtractedColor` value type + protocol. |
| `Sources/RPPlayer/Config/AppSettings.swift` | Add `ambientBackgroundEnabled: Bool`; init defaults; decoder default. |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | Add `ambientBackgroundEnabled` published property + `setAmbientBackgroundEnabled(_:)` + hydrate from config stream. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | Add `Toggle` to `appearanceSection`; new binding. |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | Add `ambientTopColor`, `ambientEnabled`; inject `paletteExtractor` + `configStore`; subscribe to settings; extract color after art load; clear on promo / error / disable. |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift` | Add `.background(ambientBackground)` + `.animation(.easeInOut(duration: 0.4), value: viewModel.ambientTopColor)`. |
| `Sources/RPPlayer/App/AppContainer.swift` | Construct `AmbientPaletteExtractor`; thread into `MiniPlayerViewModel` init. Add `NoopAmbientPaletteExtractor` fallback to private declarations at bottom. |
| `Tests/RPPlayerTests/Shell/AmbientPaletteExtractorTests.swift` | **New.** ~4 tests. |
| `Tests/RPPlayerTests/Shell/MiniPlayerViewModelAmbientTests.swift` | **New.** ~6 tests covering state transitions. |
| `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift` | Extend. ~2 tests. |
| `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` | Extend (or new). ~2 tests. |
| `CLAUDE.md` | Bump test count; add PR 18 entry; document ambient gradient pattern (top stop = bottom-edge color, bottom stop = `windowBackgroundColor`, sticky during track-art-load, fades on promo/error/disable). |

## Risk / open questions

- **Color extraction performance.** Drawing a CGImage strip into a 1×1 destination is fast (sub-millisecond on typical hardware) and runs off the main thread inside the actor. No animation of the extraction itself; only the resulting Color value participates in the SwiftUI animation. Acceptable.
- **Light albums on Light mode.** A nearly-white album bottom edge produces a near-`windowBackgroundColor` top stop → gradient becomes effectively invisible. That's the intended graceful failure mode (ambient effect just disappears for that song). Not a bug.
- **Dark albums on Light mode (and vice versa).** The top stop matches the art bottom edge regardless of system appearance. The bottom stop is the system background. So a black album on Light mode produces a strong black-to-white gradient — visually striking but consistent with what the user opted into. Text/controls still sit on the bottom (which is `windowBackgroundColor`) so legibility is preserved.
- **Promo block detection.** Tied to `song.songId == "0"`. This signal already gates the "Open Song in Browser" menu entry, so it's load-bearing already; we're not introducing a new fragile check. If RP ever changes promo encoding, both behaviors break together and the fix is one place.
- **Animation reentrancy.** Rapid song advances (e.g., user mashes Skip) may trigger overlapping color extractions. SwiftUI's animation handles only the final published value; in-flight extractor tasks for stale songs will still complete and overwrite — guard by checking `viewModel.lastLoadedCoverPath == cover` before publishing the extracted color. Plan should call this out as a small piece of the VM logic.
- **Test image fixtures.** Build them in-memory in the test (small `NSBitmapImageRep`-backed `NSImage`) so no on-disk fixtures are added to the test bundle.
- **PopoverController unaffected.** No structural change to `PopoverController`. The existing `windowBackgroundColor` wrap remains in place; the gradient sits inside MiniPlayerView's layout and replaces it visually when ambient is on.
