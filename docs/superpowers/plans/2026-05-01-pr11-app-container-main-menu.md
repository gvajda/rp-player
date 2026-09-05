# PR 11 — AppContainer + App/Edit main menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the temporary `AppDelegate.realBootstrap` static factory into a dedicated `@MainActor final class AppContainer` (new `Sources/RPPlayer/App/`), and add the macOS App + Edit main menu so `Cmd-Q` and standard text-field shortcuts work in the popover, login, and Settings windows.

**Architecture:** `AppContainer` owns all long-lived dependencies, exposes view models / window controllers as `let` properties, has `shutdown()` and `runOnLaunchTasks()` lifecycle methods. Designated `init` takes raw deps for tests; `static func live() throws` is the production composition root. `AppDelegate` slims to about 80 lines and holds an `AppContainer` plus the AppKit-only `StatusItemController` + `PopoverController`. A tiny `MainMenuBuilder` enum builds the `NSMenu`. No new protocol abstractions for shell collaborators — the designated init is the test seam.

**Tech Stack:** Swift 6.2 strict concurrency, AppKit (`NSMenu` / `NSApp.mainMenu`), SwiftUI hosted via `NSHostingView`, XCTest. Builds + tests via `swift build` / `swift test`. Existing libmpv vendoring stays untouched.

**Spec:** `docs/superpowers/specs/2026-05-01-pr11-app-container-main-menu-design.md`.

---

## Pre-flight: worktree + branch

- [ ] **Step P.1: Create a sibling worktree on a new branch off `main`**

Use `superpowers:using-git-worktrees` (preferred). If invoking that skill is unavailable, the equivalent command from the main checkout is:

```bash
git -C /Users/gergely/git/rp-player worktree add ../rp-player-pr11 -b claude/pr11-app-container main
```

The remainder of the plan assumes the working directory is the new worktree (`/Users/gergely/git/rp-player-pr11` or whichever path the skill picks). All file paths below are repo-relative.

- [ ] **Step P.2: Verify the baseline tests pass before touching anything**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 172 tests, with 0 failures (0 unexpected) in N.NNN seconds`. If the count differs, stop and reconcile with the latest `main` test count noted in `CLAUDE.md` before continuing.

---

## Task 1: Create `AppContainer` skeleton with designated init

**Goal:** Land the new type at `Sources/RPPlayer/App/AppContainer.swift` with only the designated init, the `let` properties, `shutdown()`, and `runOnLaunchTasks()`. No `live()` yet, no AppDelegate changes yet. Drive it from tests.

**Files:**
- Create: `Sources/RPPlayer/App/AppContainer.swift`
- Test: `Tests/RPPlayerTests/App/AppContainerTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Write the file at `Tests/RPPlayerTests/App/AppContainerTests.swift`:

```swift
import XCTest
@testable import RPPlayer

private actor ShutdownFlag {
    private(set) var fired = false
    func mark() { fired = true }
}

private actor LaunchTaskCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
final class AppContainerTests: XCTestCase {
    private func makeStubContainer(
        coordinatorShutdown: @escaping @Sendable () async -> Void = {},
        onLaunchTasks: [@Sendable () async -> Void] = []
    ) -> (AppContainer, MockPlaybackCoordinator, MiniPlayerViewModel, SettingsViewModel) {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let service = MockNotificationService()
        let auth = StubKeychainAuth()
        let configStore = StubConfigStore(initial: .default)
        let deviceCatalog = StubAudioDeviceCatalog(initial: [])
        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator, api: api, initialChannelId: 0,
            albumArtCache: cache, auth: auth, openSettings: { }
        )
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator, cache: cache, service: service,
            notificationsEnabled: { false },
            channelTitle: { _ in nil },
            cachedFileURL: { _ in nil }
        )
        let settingsViewModel = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { }, openApplicationData: { }
        )
        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        let loginWindowController = LoginWindowController(keychainAuth: auth)
        let container = AppContainer(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: coordinatorShutdown,
            onLaunchTasks: onLaunchTasks
        )
        return (container, coordinator, viewModel, settingsViewModel)
    }

    func testDesignatedInitExposesInjectedCollaborators() async throws {
        let (container, _, viewModel, settingsViewModel) = makeStubContainer()
        XCTAssertTrue(container.viewModel === viewModel)
        XCTAssertTrue(container.settingsViewModel === settingsViewModel)
        XCTAssertNotNil(container.notificationCoordinator)
        XCTAssertNotNil(container.settingsWindowController)
        XCTAssertNotNil(container.loginWindowController)
    }

    func testShutdownInvokesInjectedClosure() async throws {
        let flag = ShutdownFlag()
        let (container, _, _, _) = makeStubContainer(
            coordinatorShutdown: { await flag.mark() }
        )

        await container.shutdown()

        let fired = await flag.fired
        XCTAssertTrue(fired)
    }

    func testRunOnLaunchTasksAwaitsAllInjectedClosures() async throws {
        let counter = LaunchTaskCounter()
        let (container, _, _, _) = makeStubContainer(
            onLaunchTasks: [
                { await counter.increment() },
                { await counter.increment() },
            ]
        )

        await container.runOnLaunchTasks()

        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testRunOnLaunchTasksWithEmptyArrayReturnsImmediately() async throws {
        let (container, _, _, _) = makeStubContainer(onLaunchTasks: [])
        await container.runOnLaunchTasks()
    }
}
```

- [ ] **Step 1.2: Run the tests and verify they fail at compile**

```bash
swift test --filter AppContainerTests 2>&1 | tail -15
```

Expected: build error — `cannot find 'AppContainer' in scope`. That's the right RED.

- [ ] **Step 1.3: Create `AppContainer` skeleton**

Write `Sources/RPPlayer/App/AppContainer.swift`:

```swift
import Foundation

@MainActor
public final class AppContainer {
    public let viewModel: MiniPlayerViewModel
    public let notificationCoordinator: NotificationCoordinator
    public let settingsViewModel: SettingsViewModel
    public let settingsWindowController: SettingsWindowController
    public let loginWindowController: LoginWindowController

    private let coordinatorShutdown: @Sendable () async -> Void
    private let onLaunchTasksClosures: [@Sendable () async -> Void]

    public init(
        viewModel: MiniPlayerViewModel,
        notificationCoordinator: NotificationCoordinator,
        settingsViewModel: SettingsViewModel,
        settingsWindowController: SettingsWindowController,
        loginWindowController: LoginWindowController,
        coordinatorShutdown: @escaping @Sendable () async -> Void,
        onLaunchTasks: [@Sendable () async -> Void] = []
    ) {
        self.viewModel = viewModel
        self.notificationCoordinator = notificationCoordinator
        self.settingsViewModel = settingsViewModel
        self.settingsWindowController = settingsWindowController
        self.loginWindowController = loginWindowController
        self.coordinatorShutdown = coordinatorShutdown
        self.onLaunchTasksClosures = onLaunchTasks
    }

    public func shutdown() async {
        await coordinatorShutdown()
    }

    public func runOnLaunchTasks() async {
        for task in onLaunchTasksClosures {
            await task()
        }
    }
}
```

- [ ] **Step 1.4: Run the tests and verify GREEN**

```bash
swift test --filter AppContainerTests 2>&1 | tail -10
```

Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 1.5: Run the full suite to confirm no regressions**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 176 tests, with 0 failures` (172 baseline + 4 new).

- [ ] **Step 1.6: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/App/AppContainerTests.swift
git commit -m "$(cat <<'EOF'
feat(pr11): AppContainer skeleton with designated init

Adds @MainActor final class AppContainer at Sources/RPPlayer/App/.
Designated init is the test seam (live() factory comes next).
Owns view models, window controllers, plus shutdown() and
runOnLaunchTasks() lifecycle hooks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `AppContainer.live()` factory by lifting `realBootstrap`

**Goal:** Move the body of `AppDelegate.realBootstrap` into `AppContainer.live()` while keeping `AppDelegate` fully working via a one-line forwarder. The `Noop*` helper types currently file-scoped in `AppDelegate.swift` move alongside.

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`

This task is a pure code lift — no behavior change, no new tests. Verification is the existing 176 tests staying green.

- [ ] **Step 2.1: Move the `Noop*` helper types from `AppDelegate.swift` to `AppContainer.swift`**

In `Sources/RPPlayer/App/AppContainer.swift`, append at the bottom (below the class):

```swift
import AppKit

// Fallback when JSONConfigStore fails to open so SettingsViewModel still constructs.
final class NoopConfigStore: ConfigStore {
    var settings: AppSettings { .default }
    var changes: AsyncStream<AppSettings> { AsyncStream { $0.finish() } }
    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {}
}

struct NoopNotificationService: NotificationService {
    func requestAuthorization() async throws -> Bool { false }
    func notify(title: String, subtitle: String, attachmentURL: URL?) async throws {}
}

struct NoopAlbumArtCache: AlbumArtCache {
    func image(for coverPath: String) async -> NSImage? { nil }
}

struct NoopPlayerEngine: PlayerEngine {
    let error: Error
    var events: AsyncStream<PlayerEvent> { AsyncStream { $0.finish() } }
    func play(url: URL) async throws { throw error }
    func pause() async throws { throw error }
    func resume() async throws { throw error }
    func stop() async throws { throw error }
    func seek(to seconds: Double) async throws { throw error }
    func setHogMode(_ enabled: Bool) async throws { throw error }
    func setOutputDevice(uid: String?) async throws { throw error }
    func shutdown() async {}
}
```

The visibility is `internal` (no `private` keyword) so `AppContainer.live()` can use them. They're not declared `public` — outside the module they remain invisible.

In `Sources/RPPlayer/Shell/AppDelegate.swift`, **delete** the four `private` Noop type declarations at the bottom of the file (lines that begin `private final class NoopConfigStore`, `private struct NoopNotificationService`, `private struct NoopAlbumArtCache`, `private struct NoopPlayerEngine`).

- [ ] **Step 2.2: Add `AppContainer.live()` containing the `realBootstrap` body**

In `Sources/RPPlayer/App/AppContainer.swift`, add the static factory after the designated `init` (before `shutdown()`). Top of the file already has `import Foundation`; add `import AppKit` and `import UserNotifications` at the top alongside it.

```swift
import AppKit
import Foundation
import UserNotifications

// (existing class definition stays here)

extension AppContainer {
    public static func live() throws -> AppContainer {
        let logger = AppLogger.fileBacked(category: "shell", directory: ConfigPaths.logsDirectory)
        let configURL = ConfigPaths.configFile
        let initial = Self.loadSettings(from: configURL)
        let store: JSONConfigStore?
        do {
            store = try JSONConfigStore(url: configURL)
        } catch {
            logger.error("Failed to open config store: \(error.localizedDescription)")
            store = nil
        }

        let keychainAuth = KeychainCookieProvider()
        let api = LiveRpApiClient(cookieProvider: keychainAuth, logger: logger)

        let imageBaseURL = URL(string: "https://img.radioparadise.com/")!
        let cache: any AlbumArtCache
        do {
            cache = try LiveAlbumArtCache(
                directory: ConfigPaths.albumArtCacheDirectory,
                baseURL: imageBaseURL,
                logger: logger
            )
        } catch {
            logger.error("Failed to open album art cache: \(error.localizedDescription)")
            cache = NoopAlbumArtCache()
        }

        let engine: any PlayerEngine
        do {
            engine = try LibmpvPlayerEngine()
        } catch {
            engine = NoopPlayerEngine(error: error)
        }

        let coordinator = LivePlaybackCoordinator(
            api: api,
            engine: engine,
            logger: logger,
            bitrate: initial.bitrate,
            onHogModeFallback: { [store] in
                guard let store else { return }
                try? await store.update { $0.hogModeEnabled = false }
            }
        )

        if let store {
            Task { [engine] in
                let stream = await store.changes
                for await settings in stream {
                    try? await engine.setHogMode(settings.hogModeEnabled)
                    try? await engine.setOutputDevice(uid: settings.outputDeviceUID)
                }
            }
        }

        let deviceCatalog = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())

        let notificationService: any NotificationService =
            Bundle.main.bundleIdentifier != nil
                ? LiveNotificationService(center: UNUserNotificationCenter.current())
                : NoopNotificationService()

        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: notificationService,
            notificationsEnabled: { [store] in
                guard let store else { return false }
                return await store.settings.notificationsEnabled
            },
            channelTitle: { [api] channelId in
                guard let channels = try? await api.listChannels() else { return nil }
                return channels.first(where: { Int($0.chan) == channelId })?.title
            },
            cachedFileURL: { [cache] coverPath in
                await cache.fileURL(for: coverPath)
            }
        )

        let loginWindowController = LoginWindowController(keychainAuth: keychainAuth)

        let settingsViewModel = SettingsViewModel(
            configStore: store ?? NoopConfigStore(),
            deviceCatalog: deviceCatalog,
            auth: keychainAuth,
            openLoginWindow: { [loginWindowController] in loginWindowController.show() },
            openApplicationData: {
                try? FileManager.default.createDirectory(
                    at: ConfigPaths.applicationSupportRoot, withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(ConfigPaths.applicationSupportRoot)
            }
        )

        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)

        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: initial.selectedChannelId,
            albumArtCache: cache,
            auth: keychainAuth,
            openSettings: { [settingsWindowController] in settingsWindowController.show() },
            persistChannelId: { id in
                guard let store else { return }
                try? await store.update { $0.selectedChannelId = id }
            }
        )

        let onLaunchTasks: [@Sendable () async -> Void] = [
            { _ = try? await notificationService.requestAuthorization() },
            { @Sendable @MainActor in
                await StartupAuthProbe.run(api: api, auth: keychainAuth) {
                    viewModel.refreshAuthState()
                    settingsViewModel.refreshAuthState()
                }
            }
        ]

        return AppContainer(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: { await coordinator.shutdown() },
            onLaunchTasks: onLaunchTasks
        )
    }

    private static func loadSettings(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }
}
```

Note: `live()` is declared `throws` even though the body currently swallows every constructor error. Future-proofing — if `JSONConfigStore` ever propagates instead of being recovered with `NoopConfigStore`, the signature won't change. The `throws` also matches the spec's `AppDelegate.containerFactory: () throws -> AppContainer` shape. The body has no `try` of an error that escapes; Swift will warn that "no calls to throwing functions occur within 'try' expression" — that's expected and harmless. If the warning is too noisy, change `try await store.update` inside `onHogModeFallback` to non-`try?` and propagate, but for round-1 keep the current behavior verbatim.

- [ ] **Step 2.3: Forward `realBootstrap` to `AppContainer.live()`**

In `Sources/RPPlayer/Shell/AppDelegate.swift`, replace the body of `private static func realBootstrap()` with:

```swift
private static func realBootstrap() -> Bootstrap {
    let container: AppContainer
    do {
        container = try AppContainer.live()
    } catch {
        // Same behavior as today's libmpv catch path: keep the menu-bar shell up.
        // AppContainer.live() already swallows every recoverable error itself; this
        // only fires if we add a new throwing dependency without a fallback.
        preconditionFailure("AppContainer.live() failed: \(error)")
    }
    return Bootstrap(
        viewModel: container.viewModel,
        notificationCoordinator: container.notificationCoordinator,
        settingsViewModel: container.settingsViewModel,
        settingsWindowController: container.settingsWindowController,
        loginWindowController: container.loginWindowController,
        coordinatorShutdown: { await container.shutdown() }
    )
}
```

`AppDelegate.loadSettings(from:)` is no longer referenced — delete it from `AppDelegate.swift`.

Note: the `runOnLaunchTasks` from `live()` are NOT yet hooked up. They fire during the `live()` body via the existing `Task { ... }` blocks IN today's `realBootstrap` — which we just removed. That means until Task 3, the post-launch authorization request and StartupAuthProbe never fire. **Task 3 wires `runOnLaunchTasks()` into `AppDelegate.applicationDidFinishLaunching`.** Don't ship just Task 2 — finish through Task 3 in one go.

Actually correction — re-read the lifted body above. The old in-line `Task { ... }` blocks were removed when copying. The new `live()` returns `onLaunchTasks` so they can be invoked later. To keep behavior unchanged after Task 2 alone, fire them inside `realBootstrap` immediately after constructing the container:

In `Sources/RPPlayer/Shell/AppDelegate.swift`, update the forwarder:

```swift
private static func realBootstrap() -> Bootstrap {
    let container: AppContainer
    do {
        container = try AppContainer.live()
    } catch {
        preconditionFailure("AppContainer.live() failed: \(error)")
    }
    Task { await container.runOnLaunchTasks() }
    return Bootstrap(
        viewModel: container.viewModel,
        notificationCoordinator: container.notificationCoordinator,
        settingsViewModel: container.settingsViewModel,
        settingsWindowController: container.settingsWindowController,
        loginWindowController: container.loginWindowController,
        coordinatorShutdown: { await container.shutdown() }
    )
}
```

This keeps Task 2 a pure-refactor, behavior-preserving step.

- [ ] **Step 2.4: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 176 tests, with 0 failures`. (The 4 AppContainer tests from Task 1 + the 172 baseline.)

- [ ] **Step 2.5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift Sources/RPPlayer/Shell/AppDelegate.swift
git commit -m "$(cat <<'EOF'
refactor(pr11): lift realBootstrap body into AppContainer.live()

Pure code move. AppDelegate.realBootstrap is now a one-line forwarder
that builds the container, kicks off runOnLaunchTasks(), and wraps the
result in the legacy Bootstrap struct. Bootstrap will go away in the
next commit.

Noop* helper types move from AppDelegate.swift to AppContainer.swift
where the live() factory uses them.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Switch `AppDelegate` to hold `AppContainer`; delete `Bootstrap` + `realBootstrap`

**Goal:** Replace the legacy `Bootstrap` struct with direct `AppContainer` ownership inside `AppDelegate`. Migrate `AppDelegateTests` to the new `containerFactory` injection point.

**Files:**
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift`
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`

- [ ] **Step 3.1: Migrate `AppDelegateTests.setUp` to construct `AppContainer` directly**

Replace the body of `setUp()` in `Tests/RPPlayerTests/Shell/AppDelegateTests.swift`. The current implementation builds an `AppDelegate.Bootstrap` from stubs; the new implementation builds an `AppContainer` from the same stubs and passes a closure that returns it.

```swift
override func setUp() async throws {
    delegate = AppDelegate(containerFactory: {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let cache = StubAlbumArtCache()
        let service = MockNotificationService()
        let auth = StubKeychainAuth()
        let configStore = StubConfigStore(initial: .default)
        let deviceCatalog = StubAudioDeviceCatalog(initial: [])
        let viewModel = MiniPlayerViewModel(
            coordinator: coordinator,
            api: api,
            initialChannelId: 0,
            albumArtCache: cache,
            auth: auth,
            openSettings: { }
        )
        let notificationCoordinator = NotificationCoordinator(
            coordinator: coordinator,
            cache: cache,
            service: service,
            notificationsEnabled: { false },
            channelTitle: { _ in nil },
            cachedFileURL: { _ in nil }
        )
        let settingsViewModel = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        let settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        let loginWindowController = LoginWindowController(keychainAuth: auth)
        return AppContainer(
            viewModel: viewModel,
            notificationCoordinator: notificationCoordinator,
            settingsViewModel: settingsViewModel,
            settingsWindowController: settingsWindowController,
            loginWindowController: loginWindowController,
            coordinatorShutdown: { await coordinator.shutdown() },
            onLaunchTasks: []
        )
    })
}
```

The `testApplicationWillTerminateInvokesShutdown` test currently inspects the `coordinator` captured by the bootstrap closure. After the migration, the coordinator is captured by the closure local to `setUp`, but test methods need access to it. Hoist it: change the test class to keep a `coordinator: MockPlaybackCoordinator!` instance var that `setUp` populates *before* it builds the `containerFactory`:

```swift
@MainActor
final class AppDelegateTests: XCTestCase {
    var delegate: AppDelegate!
    var coordinator: MockPlaybackCoordinator!

    override func setUp() async throws {
        coordinator = MockPlaybackCoordinator()
        let coordinator = self.coordinator!
        delegate = AppDelegate(containerFactory: {
            let api = MockRpApiClient()
            // ... rest of the stubs as above ...
            return AppContainer(
                viewModel: viewModel,
                // ...
                coordinatorShutdown: { await coordinator.shutdown() },
                onLaunchTasks: []
            )
        })
    }

    override func tearDown() async throws {
        delegate = nil
        coordinator = nil
    }

    // Existing test bodies use `await coordinator.recordedCalls()` etc. — unchanged.
}
```

The local `let coordinator = self.coordinator!` binding inside `setUp` is so the `containerFactory` closure captures a **non-optional** `MockPlaybackCoordinator` (Swift's `@Sendable` checker dislikes capturing implicitly-unwrapped optionals).

- [ ] **Step 3.2: Run the tests — expect failure (`Bootstrap` / `containerFactory` mismatches)**

```bash
swift test --filter AppDelegateTests 2>&1 | tail -15
```

Expected: build error along the lines of `extra argument 'containerFactory' in call` or `'AppDelegate.Bootstrap' is private` — the `AppDelegate` API hasn't been changed yet.

- [ ] **Step 3.3: Migrate `AppDelegate` to hold `AppContainer`**

Open `Sources/RPPlayer/Shell/AppDelegate.swift` and rewrite the class. The full file should look like this after the edit:

```swift
import AppKit
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let containerFactory: @MainActor () throws -> AppContainer
    private var container: AppContainer?
    private var statusItem: StatusItemController?
    private var popover: PopoverController?

    public init(containerFactory: @escaping @MainActor () throws -> AppContainer = { try .live() }) {
        self.containerFactory = containerFactory
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let container: AppContainer
        do {
            container = try containerFactory()
        } catch {
            preconditionFailure("AppContainer.live() failed: \(error)")
        }
        self.container = container

        let popover = PopoverController(
            rootView: AnyView(MiniPlayerView(viewModel: container.viewModel))
        )
        self.popover = popover
        self.statusItem = StatusItemController(popover: popover)

        Task { await container.runOnLaunchTasks() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        guard let container else { return }
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            await container.shutdown()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }
}
```

Compare this against the previous file:
- `Bootstrap` nested struct: **deleted**.
- `realBootstrap` static func: **deleted** (logic now in `AppContainer.live()`).
- `loadSettings(from:)`: **deleted** (also moved into `AppContainer`).
- `init(bootstrap:)`: **renamed** to `init(containerFactory:)`.
- The `Noop*` helpers were moved out in Task 2.

The two `var statusItem:` / `var popover:` fields plus their construction inside `applicationDidFinishLaunching` are unchanged in spirit — they're moved out of the now-deleted `bootstrap`-result wrapper. Verify by reading the previous version's `applicationDidFinishLaunching` and confirming the new version preserves every NSApp-level call.

If the previous `applicationDidFinishLaunching` had additional code beyond what's shown above (e.g. a notification observer, a window restoration flag), preserve it inside the new method. Re-run `git diff Sources/RPPlayer/Shell/AppDelegate.swift` to spot drift.

- [ ] **Step 3.4: Run `AppDelegateTests`, verify GREEN**

```bash
swift test --filter AppDelegateTests 2>&1 | tail -10
```

Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 3.5: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 176 tests, with 0 failures`.

- [ ] **Step 3.6: Commit**

```bash
git add Sources/RPPlayer/Shell/AppDelegate.swift Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git commit -m "$(cat <<'EOF'
refactor(pr11): AppDelegate holds AppContainer; delete Bootstrap

AppDelegate now owns an AppContainer directly. The legacy nested
Bootstrap struct, realBootstrap static func, and loadSettings helper
are gone. Tests use the new containerFactory injection point with the
same set of stubs.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `MainMenuBuilder` + wire into `AppDelegate`

**Goal:** Build the App + Edit menus and install them in `applicationDidFinishLaunching`. Standard text-field shortcuts (`Cmd-X/C/V/A`, `Cmd-Z/⇧Z`) start working in any frontmost window. `Cmd-Q` continues to route through `NSApp.terminate(_:)`.

**Files:**
- Create: `Sources/RPPlayer/App/MainMenuBuilder.swift`
- Create: `Tests/RPPlayerTests/App/MainMenuBuilderTests.swift`
- Modify: `Sources/RPPlayer/Shell/AppDelegate.swift` (one-line `NSApp.mainMenu = ...`)
- Modify: `Tests/RPPlayerTests/Shell/AppDelegateTests.swift` (assert main menu installed)

- [ ] **Step 4.1: Write the failing tests for `MainMenuBuilder`**

Write `Tests/RPPlayerTests/App/MainMenuBuilderTests.swift`:

```swift
import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class MainMenuBuilderTests: XCTestCase {
    func testReturnedMenuHasAppAndEditSubmenus() {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        XCTAssertEqual(menu.items.count, 2)
        let titles = menu.items.compactMap { $0.submenu?.title }
        XCTAssertEqual(titles, ["RP Player", "Edit"])
    }

    func testAppMenuContainsQuitWithTerminateSelector() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let quit = try XCTUnwrap(appMenu.items.first(where: { $0.title == "Quit RP Player" }))
        XCTAssertEqual(quit.action, Selector(("terminate:")))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertTrue(quit.keyEquivalentModifierMask.contains(.command))
    }

    func testAppMenuContainsAboutHideShowAll() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        let titles = appMenu.items.map { $0.title }
        XCTAssertTrue(titles.contains("About RP Player"))
        XCTAssertTrue(titles.contains("Hide RP Player"))
        XCTAssertTrue(titles.contains("Hide Others"))
        XCTAssertTrue(titles.contains("Show All"))
    }

    func testEditMenuContainsStandardEditSelectors() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let editMenu = try XCTUnwrap(menu.items.last?.submenu)
        func find(_ title: String) -> NSMenuItem? {
            editMenu.items.first(where: { $0.title == title })
        }
        XCTAssertEqual(find("Cut")?.action, Selector(("cut:")))
        XCTAssertEqual(find("Copy")?.action, Selector(("copy:")))
        XCTAssertEqual(find("Paste")?.action, Selector(("paste:")))
        XCTAssertEqual(find("Select All")?.action, Selector(("selectAll:")))

        XCTAssertEqual(find("Cut")?.keyEquivalent, "x")
        XCTAssertEqual(find("Copy")?.keyEquivalent, "c")
        XCTAssertEqual(find("Paste")?.keyEquivalent, "v")
        XCTAssertEqual(find("Select All")?.keyEquivalent, "a")
    }

    func testEditMenuContainsUndoRedoBlock() throws {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        let editMenu = try XCTUnwrap(menu.items.last?.submenu)
        let undo = try XCTUnwrap(editMenu.items.first(where: { $0.title == "Undo" }))
        let redo = try XCTUnwrap(editMenu.items.first(where: { $0.title == "Redo" }))
        XCTAssertEqual(undo.action, Selector(("undo:")))
        XCTAssertEqual(undo.keyEquivalent, "z")
        XCTAssertTrue(undo.keyEquivalentModifierMask.contains(.command))

        XCTAssertEqual(redo.action, Selector(("redo:")))
        XCTAssertEqual(redo.keyEquivalent, "z")
        XCTAssertTrue(redo.keyEquivalentModifierMask.contains([.command, .shift]))
    }

    func testAllItemTargetsAreNilForResponderChainRouting() {
        let menu = MainMenuBuilder.build(appName: "RP Player")
        for top in menu.items {
            for item in top.submenu?.items ?? [] {
                if item.isSeparatorItem { continue }
                XCTAssertNil(item.target, "\(item.title) should have nil target so AppKit routes via responder chain")
            }
        }
    }
}
```

- [ ] **Step 4.2: Run the tests, verify RED**

```bash
swift test --filter MainMenuBuilderTests 2>&1 | tail -10
```

Expected: build error — `cannot find 'MainMenuBuilder' in scope`.

- [ ] **Step 4.3: Implement `MainMenuBuilder`**

Write `Sources/RPPlayer/App/MainMenuBuilder.swift`:

```swift
import AppKit

public enum MainMenuBuilder {
    @MainActor
    public static func build(appName: String = ProcessInfo.processInfo.processName) -> NSMenu {
        let menubar = NSMenu(title: "MainMenu")
        menubar.addItem(buildAppMenuItem(appName: appName))
        menubar.addItem(buildEditMenuItem())
        return menubar
    }

    @MainActor
    private static func buildAppMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: appName)

        submenu.addItem(plain(
            title: "About \(appName)",
            action: Selector(("orderFrontStandardAboutPanel:"))
        ))
        submenu.addItem(.separator())

        submenu.addItem(plain(
            title: "Hide \(appName)",
            action: Selector(("hide:")),
            keyEquivalent: "h"
        ))
        let hideOthers = plain(
            title: "Hide Others",
            action: Selector(("hideOtherApplications:")),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        submenu.addItem(hideOthers)
        submenu.addItem(plain(
            title: "Show All",
            action: Selector(("unhideAllApplications:"))
        ))
        submenu.addItem(.separator())

        submenu.addItem(plain(
            title: "Quit \(appName)",
            action: Selector(("terminate:")),
            keyEquivalent: "q"
        ))

        item.submenu = submenu
        return item
    }

    @MainActor
    private static func buildEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Edit")

        submenu.addItem(plain(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        ))
        let redo = plain(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu.addItem(redo)
        submenu.addItem(.separator())

        submenu.addItem(plain(title: "Cut",   action: Selector(("cut:")),   keyEquivalent: "x"))
        submenu.addItem(plain(title: "Copy",  action: Selector(("copy:")),  keyEquivalent: "c"))
        submenu.addItem(plain(title: "Paste", action: Selector(("paste:")), keyEquivalent: "v"))
        submenu.addItem(plain(
            title: "Select All",
            action: Selector(("selectAll:")),
            keyEquivalent: "a"
        ))

        item.submenu = submenu
        return item
    }

    @MainActor
    private static func plain(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        return item
    }
}
```

- [ ] **Step 4.4: Run tests, verify GREEN**

```bash
swift test --filter MainMenuBuilderTests 2>&1 | tail -10
```

Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 4.5: Wire `MainMenuBuilder.build()` into `AppDelegate.applicationDidFinishLaunching`**

In `Sources/RPPlayer/Shell/AppDelegate.swift`, inside `applicationDidFinishLaunching(_:)`, immediately after `NSApp.setActivationPolicy(.accessory)`, add:

```swift
NSApp.mainMenu = MainMenuBuilder.build()
```

The full method becomes:

```swift
public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.mainMenu = MainMenuBuilder.build()

    let container: AppContainer
    do {
        container = try containerFactory()
    } catch {
        preconditionFailure("AppContainer.live() failed: \(error)")
    }
    self.container = container

    let popover = PopoverController(
        rootView: AnyView(MiniPlayerView(viewModel: container.viewModel))
    )
    self.popover = popover
    self.statusItem = StatusItemController(popover: popover)

    Task { await container.runOnLaunchTasks() }
}
```

- [ ] **Step 4.6: Add a test that `applicationDidFinishLaunching` installs the main menu**

Append to `Tests/RPPlayerTests/Shell/AppDelegateTests.swift` (inside the existing class):

```swift
func testApplicationDidFinishLaunchingInstallsMainMenu() async throws {
    NSApp.mainMenu = nil
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    let menu = try XCTUnwrap(NSApp.mainMenu)
    XCTAssertEqual(menu.items.count, 2)
    XCTAssertEqual(menu.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("About ") })?.title.hasPrefix("About"), true)
}
```

The `NSApp.mainMenu = nil` reset at the top of the test isolates this case from other tests in the same XCTest run that may have left a menu installed.

- [ ] **Step 4.7: Run tests, verify GREEN**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 183 tests, with 0 failures` (176 baseline + 6 menu builder + 1 menu install test).

- [ ] **Step 4.8: Commit**

```bash
git add Sources/RPPlayer/App/MainMenuBuilder.swift Tests/RPPlayerTests/App/MainMenuBuilderTests.swift Sources/RPPlayer/Shell/AppDelegate.swift Tests/RPPlayerTests/Shell/AppDelegateTests.swift
git commit -m "$(cat <<'EOF'
feat(pr11): App + Edit main menu

Adds MainMenuBuilder.build() returning an NSMenu with App and Edit
submenus. AppDelegate.applicationDidFinishLaunching installs it.
Cmd-Q routes via terminate:, text fields gain Cmd-X/C/V/A and
Cmd-Z/⇧Z via the responder chain (target = nil).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update `CLAUDE.md` + final verification

**Goal:** Refresh the project status doc to mark PR 11 merged, record the new test count, and replace the obsolete notes about `realBootstrap` / `Bootstrap`.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 5.1: Update the PR table row**

Open `CLAUDE.md`. Change the line that begins `| 11  | pending` to:

```
| 11  | merged to main | ✅      | AppContainer composition root + App/Edit main menu                    |
```

- [ ] **Step 5.2: Add the post-PR-11 test count**

Find the test-count list (under `## Test counts by PR`). After the `- After PR 10: 172 tests` line, add:

```
- After PR 11: 183 tests
```

- [ ] **Step 5.3: Update the technical-decisions notes**

Find the bullet that begins `- AppDelegate.realBootstrap is the temporary composition root for PR 8.` and replace it with:

```
- `AppContainer` (in `Sources/RPPlayer/App/`) is the composition root. `AppContainer.init(...)` is the test seam — pass stub collaborators directly. `AppContainer.live() throws` does the production wiring (`JSONConfigStore`, `LibmpvPlayerEngine`, `KeychainCookieProvider`, etc.) and returns the assembled graph. `AppDelegate.init(containerFactory:)` defaults to `{ try .live() }`; tests override with stub-built containers. The `Noop*` fallback types live in `AppContainer.swift` because that's where `live()` consumes them.
- `AppContainer.live()` swallows every recoverable construction error (libmpv init failure → `NoopPlayerEngine`, JSON config open failure → `NoopConfigStore`, album-art cache directory failure → `NoopAlbumArtCache`). The `throws` on `live()` is reserved for future non-recoverable cases. `AppDelegate.applicationDidFinishLaunching` calls `preconditionFailure` if `live()` throws — that's correct for the current zero-throwing reality.
```

Find the bullet that begins `- PopoverController is a non-final class (not a struct) only so tests can override isShown. The shell otherwise has no protocol abstractions — PR 11 (AppContainer) is the right place to introduce them if real dependencies need to be mocked.` and rewrite the trailing sentence to reflect the decision:

```
- `PopoverController` is a non-`final` class (not a struct) only so tests can override `isShown`. The shell otherwise has no protocol abstractions — PR 11 confirmed the designated `AppContainer.init(...)` parameters are sufficient as the test seam; no protocol layer was added.
```

- [ ] **Step 5.4: Update the PR 9 / PR 10 narrative paragraphs if they reference `realBootstrap`**

Run:

```bash
grep -n 'realBootstrap\|Bootstrap struct\|`Bootstrap`' CLAUDE.md
```

For every match, replace `realBootstrap` with `AppContainer.live()` (or remove the reference if the surrounding sentence reads better that way). The PR 9 paragraph has one such reference (`LiveNotificationService is bundle-gated in realBootstrap`) — change to `LiveNotificationService is bundle-gated in AppContainer.live()`.

The PR 10 paragraph mentions `realBootstrap writes ConfigStore.hogModeEnabled = false` — change to `AppContainer.live() writes ConfigStore.hogModeEnabled = false`.

- [ ] **Step 5.5: Run the full suite one more time**

```bash
swift test 2>&1 | tail -3
```

Expected: `Executed 183 tests, with 0 failures`.

- [ ] **Step 5.6: Build the executable to confirm no link warnings**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!` with no new warnings about unused symbols (the deleted `realBootstrap` / `Bootstrap` should be fully gone — `grep -n realBootstrap Sources/` should return zero hits).

- [ ] **Step 5.7: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(pr11): mark PR 11 merged, record AppContainer + main menu

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Final smoke (run before merging to main)

- [ ] **Step S.1: Run the app and exercise the menu**

```bash
swift run RPPlayer
```

Expected behaviors:
- Status item appears in the menu bar.
- Open Settings → click in the "Output device override" or login-window text field → confirm `Cmd-V` paste, `Cmd-A` select-all, `Cmd-X` cut work.
- Press `Cmd-Q` from the Settings or login window → app terminates within ~2 seconds (the `applicationWillTerminate` shutdown timeout).
- Status-item click still toggles the popover.

Any unexpected behavior is a smoke-fail and goes into a "round-1 smoke" section of the spec / a follow-up plan.

- [ ] **Step S.2: Fast-forward merge to `main`**

From `/Users/gergely/git/rp-player`:

```bash
git -C /Users/gergely/git/rp-player merge --ff-only claude/pr11-app-container
```

Expected: clean fast-forward. If the merge isn't fast-forward, stop — `main` has moved and the branch needs to be rebased before merge.

- [ ] **Step S.3: Verify post-merge state**

```bash
cd /Users/gergely/git/rp-player
swift test 2>&1 | tail -3
git log --oneline -8
```

Expected: 183 tests pass, the last 5 commits on `main` are the Task-1..Task-5 commits in order.

---

## Self-review

**Spec coverage:**
- "Files added / moved" → all listed in Tasks 1, 2, 3, 4 with explicit `Create` / `Modify` annotations. ✓
- "AppContainer shape" with designated init + `live()` + `runOnLaunchTasks()` + `shutdown()` → Tasks 1 and 2. ✓
- "MainMenuBuilder shape" with App + Edit submenus → Task 4. ✓
- "AppDelegate slim-down" → Task 3 + Task 4 (menu install). ✓
- "Test plan" — every named test in the spec (4 AppContainer tests + 5 menu tests + 1 menu install test = 10) appears in this plan. The 6th `MainMenuBuilderTests` (`testAllItemTargetsAreNilForResponderChainRouting`) is a bonus added during planning to lock in the responder-chain wiring; it's a strict superset of the spec. ✓
- "Migration order" sketch from the spec → Tasks 1..5 mirror it in order. ✓

**Placeholder scan:** no "TBD", "TODO", "implement later", "similar to Task N" patterns. Every code block contains the actual Swift it expects.

**Type / signature consistency:** `containerFactory: @MainActor () throws -> AppContainer` appears identically in `AppDelegate.init`, `applicationDidFinishLaunching`, and `setUp()`. `coordinatorShutdown: @Sendable () async -> Void` appears identically in the designated init signature, `live()` body, and the `setUp` stub. `MainMenuBuilder.build(appName:)` signature matches between definition and tests.
