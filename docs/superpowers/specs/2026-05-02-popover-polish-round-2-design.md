# Popover Polish Round 2 — Design

Date: 2026-05-02 Status: Approved (design phase) Branch base: `claude/popover-visual-polish` (round 1) ff-merged into `main`, OR a new branch off the current branch HEAD. Decision deferred to plan/execution time.

## Goals

Six small UI / settings changes:

1. Play/pause button uses the SF Symbol outline variant (no filled circle).
2. Rating dropdown label shows `☆` when unrated, `★ <value>` when rated.
3. Drop the "Reset on app restart." caption under the verbose-logging toggle.
4. Add an Appearance picker (Light / Dark / System) in Settings, between Notifications and Account.
5. Restructure popover channel row: bitrate left, `@` separator, channel picker geometrically centered, "RP Player" text right of the spacer (left of the gear), footer "RP Player" line + bottom padding deleted.
6. (Skipped — centering NSMenu items not feasible without a custom popover. User explicitly skipped.)

## Non-goals

- No changes to engine, coordinator, hog mode, API, or persistence beyond the appearance setting.
- No changes to the album art, progress bar, rating menu items, or transport skip button beyond the play-button outline.
- No animation work.
- No tests for layout structural changes (smoke tests cover render-without-crash).

## Architecture

### Settings: AppearanceMode

New file `Sources/RPPlayer/Config/AppearanceMode.swift`:

```swift
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}
```

`AppSettings` gains:

```swift
public var appearance: AppearanceMode
```

Default value is `.system`. The custom decoding init in `AppSettings` (which already supplies defaults for missing fields to handle on-disk migration) decodes `appearance` as `.system` if the key is absent.

### NSApp.appearance binder

`AppContainer.live()` already wires several settings via a `store.changes` consumer. Add a new branch that writes:

```swift
switch settings.appearance {
case .system: NSApp.appearance = nil
case .light:  NSApp.appearance = NSAppearance(named: .aqua)
case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
}
```

Runs on the main thread (the existing settings binder already hops to MainActor for AppKit calls). The initial application of the persisted value happens on the first `store.changes` emission.

### SettingsView changes

`SettingsView.swift`:

- `dataSection`: remove the `if viewModel.verboseLoggingEnabled { Text("…Reset on app restart.") }` block. The toggle stays.
- New `appearanceSection`:

  ```swift
  Section("Appearance") {
      Picker("Appearance", selection: appearanceBinding) {
          Text("System").tag(AppearanceMode.system)
          Text("Light").tag(AppearanceMode.light)
          Text("Dark").tag(AppearanceMode.dark)
      }
      .pickerStyle(.menu)
  }
  ```

- Insert order in `body`:

  ```
  audioSection
  notificationsSection
  appearanceSection   // NEW
  accountSection
  dataSection
  ```

- New `appearanceBinding` mirrors the existing pattern (get from view model, set via async setter).

### SettingsViewModel changes

- New `@Published private(set) var appearance: AppearanceMode`.
- `start()` and `store.changes` consumer hydrate it from `snapshot.appearance`.
- New `func setAppearance(_ value: AppearanceMode) async` mirrors `setVerboseLoggingEnabled`.

### MiniPlayerView changes — play button outline + new channel row + drop footer

`MiniPlayerView.swift`:

**transport** — flip SF Symbol names:

```swift
Image(systemName: viewModel.isPlaying ? "pause.circle" : "play.circle")
```

(Drop the `.fill` suffix.) Everything else (size 44, `.tint` foreground, `PressOpacityButtonStyle`, accessibility) unchanged.

**channelRow** — replace with a ZStack so the picker is geometrically centered regardless of side-group widths:

```swift
private var channelRow: some View {
    ZStack {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                if let label = viewModel.currentBitrateLabel {
                    Text(label)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("@")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Text("RP Player")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Menu {
                    Button("Settings…") { viewModel.openSettings() }
                    Divider()
                    Button("Quit RP Player") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 22, height: 22)
                .accessibilityLabel("Settings and Quit")
            }
        }
        channelPicker
            .fixedSize()
    }
    .frame(width: 318)
}
```

The `ZStack` centers `channelPicker` geometrically. The outer `HStack` carries the leading bitrate group and trailing "RP Player" + gear group. If side groups grow wider than `(318 - pickerWidth) / 2`, they'll overlap the picker — at the current popover width and typical content widths this won't trigger, but it's a known constraint.

If the bitrate label is `nil` (the `if let` body short-circuits), the leading inner `HStack` is empty but `Spacer()` still keeps the trailing group flush right.

**footer + bottom padding** — delete the `footer` computed property and remove its invocation from `body`. The inner `VStack(spacing: 12)` keeps its 12pt padding so the transport row still has bottom breathing room.

### RatingMenu label change

`RatingMenu.swift`:

```swift
private var label: String {
    if let r = currentRating { return "★ \(r)" }
    return "☆"
}
```

The `.frame(minWidth: 22)` likely needs a small bump to accommodate "★ 10" — change to `.frame(minWidth: 32, alignment: .center)`.

## Tests

- `RatingMenuTests.testLabelShowsStarOutlineWhenUnrated` — render with `currentRating: nil`, assert no crash. (Smoke; the label string is a private computed property, but the existing tests already cover the three states without inspecting label contents.)
- `RatingMenuTests` — keep the existing three smoke tests; rename or note that the unrated label is now `☆` not `—`. No new assertion needed.
- `SettingsViewModelTests.testAppearanceDefaultsToSystem` — fresh view-model with default settings shows `.system`.
- `SettingsViewModelTests.testSetAppearancePersists` — set to `.dark`, await, assert the store snapshot has `.dark`.
- `AppSettingsCodableTests` (or wherever round-trip Codable tests live) — round-trip with appearance set to each value; missing-key decode defaults to `.system`. If no such tests exist for `AppSettings` yet, add one minimal Codable round-trip test in a new file `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift`.
- Existing `MiniPlayerViewTests.testHostingControllerRendersWithoutCrash` continues to cover the layout restructure.

## Manual smoke (post-implementation)

1. Open popover. Play button is now an outline circle in the tint color, no fill.
2. Press play, observe outline circle stays in same color, no blue background flash on press (PressOpacityButtonStyle still applies).
3. Channel row reads: `[bitrate] @ [channel-picker centered] ... RP Player [gear]`. Picker is geometrically centered.
4. Bottom of popover: no "RP Player" footer line; transport row sits closer to the bottom edge.
5. Rating menu label shows `☆` when no rating, `★ 7` (or whatever value) when rated. Click to open; pick a value; label updates.
6. Open Settings → Notifications still toggles. New Appearance section below it. Pick Dark — entire app, including the popover and the Settings window, switches to Dark Aqua immediately. Pick Light — switches to Aqua. Pick System — follows OS appearance.
7. Quit and relaunch. Appearance choice persists.
8. Settings → Data: enable Verbose logging. The "Reset on app restart." caption is gone. Toggle is still there and still works.

## Files touched

| Path                                                       | Change                                                                                                                          |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/RPPlayer/Config/AppearanceMode.swift`             | **New**. Enum.                                                                                                                  |
| `Sources/RPPlayer/Config/AppSettings.swift`                | Add `appearance: AppearanceMode`; init defaults; decoder default.                                                               |
| `Sources/RPPlayer/App/AppContainer.swift`                  | Settings binder writes `NSApp.appearance` on change.                                                                            |
| `Sources/RPPlayer/Shell/SettingsView.swift`                | Remove "Reset on app restart." caption; add `appearanceSection`; new binding.                                                   |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift`           | Add `appearance` published property + `setAppearance(_:)`.                                                                      |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift`              | Outline play symbols; restructured `channelRow` with ZStack + bitrate `@` separator + "RP Player" text in row; delete `footer`. |
| `Sources/RPPlayer/Shell/RatingMenu.swift`                  | Label uses `★ <n>` / `☆`; minWidth bumped.                                                                                      |
| `Tests/RPPlayerTests/Shell/SettingsViewModelTests.swift`   | Add 2 appearance tests.                                                                                                         |
| `Tests/RPPlayerTests/Config/AppSettingsCodableTests.swift` | **New** (if not present) — Codable round-trip + default.                                                                        |
| `CLAUDE.md`                                                | Bump test count; note appearance setting + outline play button + channel-row layout shift.                                      |

## Risk / open questions

- **ZStack layout overlap.** If a channel title is unusually long AND the bitrate label is wide AND we end up at a translation that lengthens "RP Player", the side groups could touch or overlap the picker. At current widths this is fine. If it becomes a problem later, switch to a Layout protocol implementation that constrains the side groups to `(318 - pickerWidth) / 2` and clips with truncation.
- `NSApp.appearance`**from a binder.** This must run on the main actor. The existing `AppContainer.live()` settings consumer already hops to `@MainActor`; this fits the existing pattern.
- **Migration of stored settings.** Users with an existing JSON config without `appearance` will decode it as `.system` (the explicit decoder default). No prompt needed.
- **SF Symbol outline variants.** `play.circle` and `pause.circle` are stable since iOS 13 / macOS 11; no version concern.
