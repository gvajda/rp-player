# Update Checker — Design Spec

**Date:** 2026-05-08
**Status:** Approved (brainstorming complete)
**Target PR:** PR 29 (post-PR-28)

## Goal

Notify the user when a newer GitHub release of RP Player is available, without auto-updating. The app is unsigned for distribution (no Sparkle, no notarization), so the feature is *informational + redirect-to-download* only.

## Non-goals

- No automatic download or installation. The user clicks through to a `.dmg` in their browser.
- No Sparkle integration. Revisit when notarized.
- No status-bar icon badge. The popover-button + menu-item surfaces are deliberately low-key.
- No system notifications. The popover and menu surfaces are sufficient and avoid noise.

## User-visible behavior

### Popover button

- Default: the popover's `channelRow` shows plain `Text("RP Player")` (current behavior).
- When an update is available AND the user has not dismissed it for the current latest version: the text is replaced by a button labeled `Update Available` with a trailing `arrow.up.forward.square` SF Symbol, wrapped in a thin rounded outline (`RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5), lineWidth: 1)`, ~3pt horizontal padding). Same font size and weight as the original "RP Player" text.
- Click → opens the Update panel AND records this version as button-dismissed. Button reverts to plain "RP Player" until a strictly higher version is detected.

### Menu item

- In the popover's hamburger menu, between `About RP Player` and `Quit RP Player`.
- Static label `Update Available…` (trailing ellipsis signals it opens a panel, per macOS HIG).
- Visible only while `state == .available` (regardless of button-dismissal). Sticky until the running app version matches or exceeds the latest release version.
- Click → opens the Update panel. Does NOT toggle button-dismissal.

### Update panel

- Window-level `NSPanel` (~420pt wide), centered. Esc + outside-click both dismiss.
- Header: `RP Player vX.Y available` (title) + `Released <relative date>` (subtitle).
- Body: first ~5 lines of the GitHub release `body` rendered via `Text(AttributedString(markdown:))` with truncation ellipsis if longer.
- Footer caption: `You can come back to this from the menu → Update Available.`
- Buttons (left → right):
  - `[Later]` — closes panel.
  - `[View Full Notes]` — opens `release.html_url` in browser; closes panel.
  - `[Download DMG]` — primary/default; opens `release.assets[].browser_download_url` (first asset matching `*.dmg`) in browser, which triggers a download; closes panel. **Hidden** if no `.dmg` asset is present on the release (CI lag, asset-name change).

### Settings UI

New section in `SettingsView`, placed after the support section and before Output Device:

```text
Updates
  [×] Check for updates automatically
       Daily, while the app is running.

  [Check Now]   Last checked: 3 hours ago
                Current version: v0.4.1 (up to date)
```

When an update is available, the version line becomes:

```text
                v0.5.0 available — open Update Available menu
```

If the latest check failed, status line shows `Last checked: never` (or the last successful relative time, since failures don't update `lastUpdateCheckAt`).

## Architecture

### `UpdateChecker` actor

Path: `Sources/RPPlayer/Updates/UpdateChecker.swift`.

```swift
protocol UpdateChecking: Sendable {
    func start() async
    func checkNow() async
    func dismissCurrentForButton() async
    var stateUpdates: AsyncStream<UpdateState> { get async }
    var currentState: UpdateState { get async }
}

actor UpdateChecker: UpdateChecking {
    init(
        currentVersion: SemVer,
        repoOwner: String,
        repoName: String,
        urlSession: URLSession,
        configStore: any ConfigStore,
        clock: @escaping @Sendable () -> Date
    )
}
```

Responsibilities:

- Maintains `currentState: UpdateState` and a multi-subscriber `AsyncStream<UpdateState>` (same pattern as `ConfigStore.changes`, `LivePlaybackCoordinator.errors`, `coordinator.stateUpdates` — per-call continuation, seeded with current state, finished on `shutdown`).
- `start()` is called once from `AppContainer.live()` post-launch:
  1. Loads `cachedLatestRelease` + `lastUpdateCheckAt` + `dismissedUpdateVersion` from `ConfigStore`. Synthesizes initial state from cache if present.
  2. If `updateCheckEnabled == false`, exits without scheduling.
  3. Issues an immediate startup check (1× `checkNow`).
  4. Spawns a 1h-tick Task that calls `checkNow` whenever `clock() - lastUpdateCheckAt >= 24h`.
- `checkNow()` performs:
  1. `GET https://api.github.com/repos/{owner}/{repo}/releases/latest` with `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
  2. Decode `GitHubRelease` (subset). Reject if `prerelease == true || draft == true` (treat as `.upToDate`).
  3. Parse `tag_name` to `SemVer` (strip leading `v`). Reject malformed tags (silent log, no state change).
  4. Compare to `currentVersion`. If equal/lower → `.upToDate(now)`. If higher → `.available(release, dismissedFromButton: ...)` where `dismissedFromButton = (dismissedUpdateVersion == release.tagName)`.
  5. On success: write `lastUpdateCheckAt = now`, `cachedLatestRelease = release` (when available, else `nil`).
  6. On failure (network, decode, HTTP 4xx/5xx): log only. Do NOT update `lastUpdateCheckAt`.
- `dismissCurrentForButton()` writes `dismissedUpdateVersion = currentRelease.tagName` and re-emits state with `dismissedFromButton = true`.
- Subscribes to `configStore.changes`: when `updateCheckEnabled` flips false, stops the 1h ticker and clears `cachedLatestRelease` + the in-memory state to `.unknown`. When it flips true, kicks off `start()` semantics again.

### Types

```swift
struct SemVer: Sendable, Equatable, Comparable, Codable {
    let major: Int
    let minor: Int
    let patch: Int

    static func parse(_ raw: String) -> SemVer?  // strips "v" prefix; ignores "-prerelease" suffix
}

struct ReleaseInfo: Sendable, Equatable, Codable {
    let tagName: String           // e.g. "v0.5.0"
    let version: SemVer
    let publishedAt: Date
    let body: String
    let htmlUrl: URL
    let dmgAssetUrl: URL?         // first asset with name matching "*.dmg"
}

enum UpdateState: Sendable, Equatable {
    case unknown                                  // initial, or feature disabled
    case upToDate(checkedAt: Date)
    case available(ReleaseInfo, dismissedFromButton: Bool)
}
```

### `AppSettings` additions

```swift
var updateCheckEnabled: Bool                  // default true
var lastUpdateCheckAt: Date?                  // nil until first success
var dismissedUpdateVersion: String?           // tagName of last button-dismissed; auto-stale when latest > dismissed
var cachedLatestRelease: ReleaseInfo?         // last successful fetch; restores UI state across restarts
```

Migration: missing keys decode to defaults (existing `JSONConfigStore` behavior). No schema bump.

### Composition root wiring (`AppContainer.live()`)

```swift
let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

let updateChecker: any UpdateChecking
if let raw = bundleVersion, let semver = SemVer.parse(raw) {
    updateChecker = UpdateChecker(
        currentVersion: semver,
        repoOwner: "gvajda",
        repoName: "rp-player",
        urlSession: .shared,
        configStore: configStore,
        clock: { Date() }
    )
} else {
    updateChecker = NoopUpdateChecker()  // dev `swift run`: feature inert
}

await container.runOnLaunchTasks { ... existing items ...; await updateChecker.start() }
```

`MiniPlayerViewModel` and the menu builder both subscribe to `updateChecker.stateUpdates`. `SettingsViewModel` gets `updateChecker` as a stored property (for `checkNow()`) and reads its `currentState` for status-line display.

### View model integration

**`MiniPlayerViewModel`**:

- New `@Published var updateButtonVisible: Bool` — true iff `state == .available && !dismissedFromButton`.
- New `@Published var updateAvailableForMenu: ReleaseInfo?` — set iff `state == .available`. Drives menu-item visibility independent of button dismissal.
- New `openUpdatePanel()` — invokes injected `@MainActor () -> Void` closure (set late by `AppDelegate`, same late-binding pattern as `showPopoverIfNeeded`). Closure also calls `updateChecker.dismissCurrentForButton()` so the button dismissal happens whether the panel close path is `[Later]`, `[View Full Notes]`, `[Download DMG]`, Esc, or outside-click.

**`SettingsViewModel`**:

- New `setUpdateCheckEnabled(_: Bool)`, `checkNow()`.
- Status line bindings: `lastCheckedRelative: String`, `currentVersionLine: String` (e.g. `"v0.4.1 (up to date)"`, `"v0.5.0 available — open Update Available menu"`).

### `UpdatePanelController`

`@MainActor final class`. Constructed by `AppDelegate` after `AppContainer.live()` returns. Builds a borderless `NSPanel` (`level = .floating`, `styleMask = [.titled, .closable]`, ~420×320). Hosts `UpdatePanelView` (SwiftUI). Window is centered on `NSScreen.main` on first show. Esc handler + outside-click monitor (same pattern as `PopoverController`) close the panel and call `updateChecker.dismissCurrentForButton()`.

The panel is reusable: when re-opened with a different `ReleaseInfo`, the SwiftUI host's content is swapped via `NSHostingView` `rootView` reassignment (same pattern as `PopoverController.present(rootView:relativeTo:)` from PR 23's shared popover refactor).

## Error handling

| Failure | Behavior |
| --- | --- |
| Network unreachable / DNS / TLS / timeout | Silent. `AppLogger.debug("update check failed: \(error)")`. `lastUpdateCheckAt` unchanged so next 1h tick retries. |
| HTTP 403 with `X-RateLimit-Remaining: 0` | Silent. (60/hr unauth limit; 24h cadence is nowhere near.) |
| HTTP 404 / empty `assets` / no releases | `state = .upToDate(now)`. (PR 20 published several tags, won't happen in practice.) |
| Malformed `tag_name` (not parseable as SemVer) | Silent log. `state` unchanged. `lastUpdateCheckAt` NOT updated (treat as failure). |
| Latest release marked `prerelease == true` or `draft == true` | Treated as `.upToDate(now)`. |
| Asset list missing `.dmg` | `ReleaseInfo.dmgAssetUrl == nil`. Update panel hides the `[Download DMG]` button. `[View Full Notes]` remains. |
| `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")` is nil (dev `swift run`) | `NoopUpdateChecker` injected. Feature entirely inert. |
| Toggle flips OFF | Stop 1h ticker. Clear `cachedLatestRelease`. State → `.unknown`. (So re-enabling later starts fresh, no stale "available" claim.) |

## Testing

New file `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`. Uses `StubURLProtocol` for HTTP; `StubConfigStore` for persistence; injected clock for time travel.

**SemVer parsing/comparison**:

- `SemVer.parse("v0.5.2")` → `(0, 5, 2)`.
- `SemVer.parse("0.5.2")` → `(0, 5, 2)`.
- `SemVer.parse("v0.5.2-beta")` → `(0, 5, 2)` (suffix stripped).
- `SemVer.parse("garbage")` → `nil`.
- `SemVer(0, 5, 2) < SemVer(0, 5, 10)` (numeric compare, not lex).
- `SemVer(1, 0, 0) > SemVer(0, 99, 99)`.

**API decode**:

- Real GitHub release JSON fixture in `Tests/RPPlayerTests/Fixtures/Updates/release_latest.json`. Captured via `gh api repos/gvajda/rp-player/releases/latest`.
- Fixture variants: `release_latest_prerelease.json` (filtered out), `release_latest_no_dmg.json` (only `.zip` asset), `release_latest_multi_asset.json` (mixes `.dmg` + `.zip` → picks dmg).

**State transitions**:

- current=0.4.1, latest=0.5.0, dismissed=nil → `.available(_, dismissedFromButton: false)`.
- Same with `dismissedUpdateVersion = "v0.5.0"` → `.available(_, dismissedFromButton: true)`.
- current=0.4.1, latest=0.6.0, `dismissedUpdateVersion = "v0.5.0"` → `.available(_, dismissedFromButton: false)` (auto-reset on higher version).
- current=0.5.0, latest=0.5.0 → `.upToDate(now)`.
- current=0.5.0, latest=0.4.9 → `.upToDate(now)`.

**Schedule**:

- 23h since `lastUpdateCheckAt`, 1h tick fires → no network call.
- 25h → fires.
- Toggle off → no network on `start()`, no 1h tick.

**Failure paths**:

- Network error → state unchanged, `lastUpdateCheckAt` unchanged.
- HTTP 500 → state unchanged, `lastUpdateCheckAt` unchanged.
- Malformed `tag_name` → state unchanged, `lastUpdateCheckAt` unchanged.

**Asset selection**:

- `release_latest_multi_asset.json` (dmg + zip) → `dmgAssetUrl` is the dmg URL.
- `release_latest_no_dmg.json` → `dmgAssetUrl == nil`.

**Settings ViewModel** (`SettingsViewModelTests`):

- Toggle persists to `ConfigStore`.
- `checkNow()` invokes `updateChecker.checkNow()`.
- Status line text formats correctly for each `UpdateState` case.

**MiniPlayer ViewModel** (`MiniPlayerViewModelTests`):

- State `.available(_, dismissedFromButton: false)` → `updateButtonVisible == true`.
- `openUpdatePanel()` triggers the injected closure AND flips `dismissedFromButton` (via injected dismiss spy).
- State `.available(_, dismissedFromButton: true)` → `updateButtonVisible == false` but `updateAvailableForMenu != nil` (menu still shows).

**Estimated +18 tests.** New count target: 384 + 18 = 402.

## Files touched

New:

- `Sources/RPPlayer/Updates/UpdateChecker.swift`
- `Sources/RPPlayer/Updates/UpdateCheckerTypes.swift` (SemVer, ReleaseInfo, UpdateState, GitHubRelease decode model)
- `Sources/RPPlayer/Updates/NoopUpdateChecker.swift`
- `Sources/RPPlayer/Shell/UpdatePanelController.swift`
- `Sources/RPPlayer/Shell/UpdatePanelView.swift`
- `Tests/RPPlayerTests/Updates/UpdateCheckerTests.swift`
- `Tests/RPPlayerTests/Fixtures/Updates/release_latest.json` + variants

Modified:

- `Sources/RPPlayer/Settings/AppSettings.swift` — add 4 fields.
- `Sources/RPPlayer/Settings/SettingsView.swift` — new Updates section.
- `Sources/RPPlayer/Settings/SettingsViewModel.swift` — toggle setter, checkNow, status-line bindings.
- `Sources/RPPlayer/App/AppContainer.swift` — wire `UpdateChecker` (or `NoopUpdateChecker`) + run start() in `runOnLaunchTasks`.
- `Sources/RPPlayer/App/AppDelegate.swift` — construct `UpdatePanelController`, late-bind `MiniPlayerViewModel.openUpdatePanel`, route hamburger menu item.
- `Sources/RPPlayer/Shell/MiniPlayerView.swift` — replace `Text("RP Player")` with conditional update button.
- `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` — `updateButtonVisible`, `updateAvailableForMenu`, `openUpdatePanel`, subscription to `updateChecker.stateUpdates`.
- `Tests/RPPlayerTests/MiniPlayerViewModelTests.swift` — add update-button + menu cases.
- `Tests/RPPlayerTests/SettingsViewModelTests.swift` — add toggle + checkNow + status-line cases.

## Open questions

None.
