# PR 11 — AppContainer composition root + App/Edit main menu

**Date:** 2026-05-01 **Branch target:** new sibling worktree for `claude/<slug>` against `main` (`9e32ec8` … `a1b936e` after PR 10 ff-merge). **Status:** spec, awaiting user review before plan generation.

---

## Goal

Promote the temporary `AppDelegate.realBootstrap` static function into a dedicated `AppContainer` type that owns the long-lived dependency graph (per `docs/DESIGN.md` §3 / §15.3 / §6.1). Add the macOS App + Edit main-menu pair that PR 9 deferred so `Cmd-Q` and text-field shortcuts (`Cmd-X/C/V/A`) work correctly inside the popover, login window, and Settings window. No protocol abstractions for shell collaborators (`PopoverController`, `StatusItemController`) — designated `init` parameters are the test seam.

Out of scope: distribution `.app` bundling, `LSUIElement` Info.plist (PR 12); the deferred hog-mode-on-DAC investigation (recorded in `docs/superpowers/plans/2026-04-30-pr10-settings-rating.md` §"Remaining open follow-ups").

---

## Files added / moved

| Path                                                 | Status   | Purpose                                                                                               |
| ---------------------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------- |
| `Sources/RPPlayer/App/AppContainer.swift`            | new      | Composition root: owns dependencies, exposes view models / window controllers, has `shutdown()`       |
| `Sources/RPPlayer/App/MainMenuBuilder.swift`         | new      | Builds the `NSMenu` with App + Edit submenus                                                          |
| `Sources/RPPlayer/Shell/AppDelegate.swift`           | modified | Slims to ~80 lines: holds `AppContainer`, installs main menu, manages status item / popover lifecycle |
| `Tests/RPPlayerTests/App/AppContainerTests.swift`    | new      | Designated init wiring + `live()` smoke                                                               |
| `Tests/RPPlayerTests/App/MainMenuBuilderTests.swift` | new      | Menu structure: two submenus, expected items + selectors + key equivalents                            |
| `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`   | modified | Migrate from `bootstrap: () -> Bootstrap` to `containerFactory: () -> AppContainer`                   |
| `CLAUDE.md`                                          | modified | Mark PR 11 merged, post-PR-11 test count, update PR 11 / `Bootstrap` references                       |

The current `AppDelegate.Bootstrap` nested struct is **removed**. `AppContainer` owns the same fields directly. The current `AppDelegate.realBootstrap` static func is removed; its logic moves into `AppContainer.live()`.

The `App/` folder is new. Both new source files plus their test counterparts go under `App/`.

---

## `AppContainer` shape

```swift
@MainActor
public final class AppContainer {
    public let viewModel: MiniPlayerViewModel
    public let notificationCoordinator: NotificationCoordinator
    public let settingsViewModel: SettingsViewModel
    public let settingsWindowController: SettingsWindowController
    public let loginWindowController: LoginWindowController

    private let coordinatorShutdown: @Sendable () async -> Void
    private let onLaunchTasks: [@Sendable () async -> Void]

    /// Designated init — used directly by tests with stub collaborators. Production goes through `live()`.
    public init(
        viewModel: MiniPlayerViewModel,
        notificationCoordinator: NotificationCoordinator,
        settingsViewModel: SettingsViewModel,
        settingsWindowController: SettingsWindowController,
        loginWindowController: LoginWindowController,
        coordinatorShutdown: @escaping @Sendable () async -> Void,
        onLaunchTasks: [@Sendable () async -> Void] = []
    )

    /// Production composition root. Builds JSONConfigStore, LibmpvPlayerEngine,
    /// LiveAlbumArtCache, LiveRpApiClient, KeychainCookieProvider, etc., then calls
    /// the designated init. Mirrors today's `realBootstrap` body.
    public static func live() throws -> AppContainer

    /// Fires after AppDelegate finishes launching: notification authorization
    /// request + StartupAuthProbe. Tests can pass an empty array to suppress.
    public func runOnLaunchTasks() async

    /// Mirrors today's `Bootstrap.coordinatorShutdown`. AppDelegate's
    /// `applicationWillTerminate` blocks the terminate path on this.
    public func shutdown() async
}
```

`AppContainer` exists strictly to **own** wiring. It does not gain any new responsibilities (no menu construction, no status item ownership). Status item + popover stay in `AppDelegate` because they need `NSApplication` lifecycle hooks the container has no business with.

The `onLaunchTasks` array preserves today's two post-launch fire-and-forget Tasks (notification authorization + `StartupAuthProbe.run`). They live as closures in `live()` so the test path can construct an `AppContainer` with `[]` and avoid hitting `UNUserNotificationCenter` / `RpApiClient` from a unit test.

---

## `MainMenuBuilder` shape

```swift
public enum MainMenuBuilder {
    @MainActor
    public static func build(appName: String = ProcessInfo.processInfo.processName) -> NSMenu
}
```

Returned `NSMenu` has two top-level items, each with a submenu:

### App submenu (title = appName)

| Title             | Selector                        | Key equivalent |
| ----------------- | ------------------------------- | -------------- |
| `About <appName>` | `orderFrontStandardAboutPanel:` | —              |
| *(separator)*     |                                 |                |
| `Hide <appName>`  | `hide:`                         | `⌘H`           |
| `Hide Others`     | `hideOtherApplications:`        | `⌥⌘H`          |
| `Show All`        | `unhideAllApplications:`        | —              |
| *(separator)*     |                                 |                |
| `Quit <appName>`  | `terminate:`                    | `⌘Q`           |

### Edit submenu

| Title         | Selector     | Key equivalent |
| ------------- | ------------ | -------------- |
| `Undo`        | `undo:`      | `⌘Z`           |
| `Redo`        | `redo:`      | `⇧⌘Z`          |
| *(separator)* |              |                |
| `Cut`         | `cut:`       | `⌘X`           |
| `Copy`        | `copy:`      | `⌘C`           |
| `Paste`       | `paste:`     | `⌘V`           |
| `Select All`  | `selectAll:` | `⌘A`           |

All items have `target = nil` so AppKit routes through the responder chain. `NSText` / `NSTextView` already implement these selectors, so login + settings text fields gain proper editing shortcuts automatically.

`AppDelegate.applicationDidFinishLaunching(_:)` calls `NSApp.mainMenu = MainMenuBuilder.build()` once on first launch. Activation policy stays `.accessory`. The macOS menu bar will show the two submenus only when the app is the frontmost (i.e., when the user opens the login or Settings window — which already activates as regular). The `.accessory` popover never shows the menu bar; that's expected, and Cmd-Q still routes via the menu when login or settings is key.

Standard `NSApp.servicesMenu` / `NSApp.windowsMenu` / `NSApp.helpMenu` stay unset — `Window` / `Help` / `Format` / `View` are explicit YAGNI for this utility.

---

## `AppDelegate` slim-down

After PR 11 the lifecycle becomes:

```swift
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let containerFactory: @MainActor () throws -> AppContainer
    private var container: AppContainer?
    private var statusItem: StatusItemController?
    private var popover: PopoverController?

    public init(containerFactory: @escaping @MainActor () throws -> AppContainer = { try .live() })

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenuBuilder.build()
        let container: AppContainer
        do { container = try containerFactory() } catch {
            // Same construction-error handling as today: keep the app up,
            // but show an error banner via the existing NoopPlayerEngine path
            // (see CLAUDE.md row 76). The factory closure must catch its own
            // libmpv-init errors and return a NoopPlayerEngine-backed container.
            preconditionFailure("AppContainer construction failed: \(error)")
        }
        self.container = container
        self.popover = PopoverController(rootView: AnyView(MiniPlayerView(viewModel: container.viewModel)))
        self.statusItem = StatusItemController(popover: popover!)
        Task { await container.runOnLaunchTasks() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // CLAUDE.md row 71 pattern: DispatchGroup + Task.detached + .wait(timeout: 2.0)
        guard let container else { return }
        let group = DispatchGroup()
        group.enter()
        Task.detached { await container.shutdown(); group.leave() }
        _ = group.wait(timeout: .now() + 2.0)
    }
}
```

The construction-error branch above is intentionally `preconditionFailure` rather than today's silent `NoopPlayerEngine` fallback. Today's fallback only handles `LibmpvPlayerEngine.init` throwing — the rest of `realBootstrap` cannot fail. After moving wiring into `live()`, `live()` itself becomes `throws`, and the only producer is the libmpv init. The `live()` factory keeps the existing `NoopPlayerEngine` swap so it does NOT propagate that error; other unexpected throws (e.g., `JSONConfigStore.init` failing on a malformed file) DO propagate, and `preconditionFailure` is correct for those. This is a behavior-preserving move, not a regression.

---

## Test plan

### `AppContainerTests`

1. `testDesignatedInitExposesInjectedCollaborators` — pass stub view models / window controllers / shutdown closure; verify accessors return the same refs and `shutdown()` invokes the closure.
2. `testRunOnLaunchTasksAwaitsAllInjectedClosures` — pass two stub closures that flip flags; assert both fire.
3. `testRunOnLaunchTasksWithEmptyArrayReturnsImmediately` — passes if no crash; covers the test-construction default.

`AppContainer.live()` is intentionally **not** unit-tested directly — it touches libmpv, the keychain, `JSONConfigStore`, and `UNUserNotificationCenter.current()`. Smoke testing the running app covers it. Adding a `live()` test would require introducing protocol abstractions that the user explicitly ruled out for this PR.

### `MainMenuBuilderTests`

1. `testReturnedMenuHasAppAndEditSubmenus` — top-level item count == 2, titles match `appName` and `"Edit"`.
2. `testAppMenuContainsQuitWithTerminateSelector` — find `Quit RP Player` item; selector == `Selector(("terminate:"))`; key equivalent == `"q"` with command modifier.
3. `testAppMenuContainsAboutAndHide` — three more items as specified plus correct separators between sections.
4. `testEditMenuContainsStandardEditSelectors` — find Cut/Copy/Paste/Select All; selectors match `cut:` / `copy:` / `paste:` / `selectAll:`; targets all nil; key equivalents are the standard set.
5. `testEditMenuContainsUndoRedoBlock` — first two items are Undo/Redo with selectors `undo:` / `redo:` and key equivalents `⌘Z` / `⇧⌘Z`.

### `AppDelegateTests` (migrated)

- Existing `testApplicationDidFinishLaunchingCreatesStatusItemControllerAndViewModel` — keep, swap `bootstrap:` for `containerFactory:`. Stub container constructed via designated init using existing `MockPlaybackCoordinator` / `MockRpApiClient` / `StubKeychainAuth` / `StubAudioDeviceCatalog` / etc.
- Existing `testApplicationWillTerminateInvokesShutdown` — keep, point at `container.shutdown()` via the closure passed to designated init.
- New `testApplicationDidFinishLaunchingInstallsMainMenu` — after launch, `NSApp.mainMenu` is non-nil and has the two expected submenus.

Existing test stubs (`StubKeychainAuth`, `StubConfigStore`, `StubAudioDeviceCatalog`, `MockPlaybackCoordinator`, `MockRpApiClient`, `MockNotificationService`, `StubAlbumArtCache`) all stay. No new stubs needed.

---

## Migration order (sketch — actual plan lives in PR 11 implementation plan)

The `superpowers:writing-plans` skill turns this design into a stepwise plan. Sketch:

1. Create `Sources/RPPlayer/App/AppContainer.swift` with designated init only; do **not** delete `AppDelegate.realBootstrap` yet. Tests passing.
2. Add `AppContainer.live()` that contains the body of today's `realBootstrap`. `realBootstrap` becomes a one-liner forwarder.
3. Migrate `AppDelegate` to hold `AppContainer` instead of `Bootstrap`; migrate `AppDelegateTests` to `containerFactory` injection. Delete `Bootstrap` struct + `realBootstrap`.
4. Add `MainMenuBuilder` + tests. Wire into `applicationDidFinishLaunching`.
5. Update `CLAUDE.md` (PR row, test count, technical-decisions notes), delete the now-stale "PR 11 (`AppContainer`) is the right place to introduce them" note.

Test count expected to land at ~177–180 (3 container tests + 5 menu tests + 1 menu install test, minus zero deletions).

---

## Risks / open questions

- **Menu visibility on**`.accessory`: when the popover is the only frontmost UI, the menu bar doesn't show. Cmd-Q routing through the responder chain still works in that mode (`NSApp.terminate` listens regardless of menu visibility). Verified in PR 7 smoke; the menu items are added so that **when** login or Settings is the frontmost window, Cmd-X/C/V work. Worth a sanity check during PR 11 smoke that copy-paste in the Settings text field for "Output device override" or the login form's password field works.
- `live()`**failure modes**: if a non-libmpv dependency throws during construction (e.g., keychain access denied for the first time on a new machine), today's behavior is the same crash that `preconditionFailure` would produce. PR 11 keeps that. PR 12's distribution work is the right place to install a proper "graceful start-up" failure dialog if that becomes a concern.
- `AppContainer`**placement**: `Sources/RPPlayer/App/` is new. Make sure SPM's source-file globbing picks it up — `Package.swift` should not have an explicit `sources:` list for the executable target (current state: implicit globbing). If a manual list is in place, add `App` to it.
