# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode via libmpv). Source of truth: `docs/DESIGN.md`.

---

## PR status

| PR | Branch | Status | Contents |
|----|--------|--------|----------|
| 1 | merged to main | ✅ | Scaffold, AppLogger, RotatingFileSink, AppSettings, ConfigStore |
| 2 | merged to main | ✅ | RpApiClient, ApiModels, CookieProvider, StubURLProtocol, fixtures |
| 3 | merged to main | ✅ | KeychainStore, KeychainCookieProvider, LoginWindowController |
| 4 | merged to main | ✅ | AudioDeviceCatalog |
| 5a | merged to main | ✅ | libmpv vendoring + RPSmoke CLI |
| 5b | merged to main | ✅ | PlayerEngine (libmpv Swift actor) |
| 6 | merged to main | ✅ | PlaybackCoordinator |
| 7 | merged to main | ✅ | AppKit shell (NSStatusItem + borderless NSPanel hosting placeholder) |
| 8 | merged to main | ✅ | MiniPlayerView (SwiftUI) + AppDelegate real-graph wiring |
| 9 | merged to main | ✅ | NotificationCoordinator + AlbumArtCache + album art in MiniPlayerView |
| 10 | merged to main | ✅ | SettingsView + rating row + KeychainCookieProvider + login flow |
| 11  | merged to main | ✅      | AppContainer composition root + App/Edit main menu                    |
| 12 | pending | ⬜ | Distribution CI workflow |

PR 9 shipped scope: `LiveAlbumArtCache` actor (on-disk LRU at `ConfigPaths.albumArtCacheDirectory`, 20 files / 10 MB, SHA-256 keys, in-flight de-dup, validates `NSImage(data:)` before persisting), `LiveNotificationService` actor (wraps `UNUserNotificationCenter` behind `UNUserNotificationCenterProtocol`), `NotificationCoordinator` (`@MainActor final class` subscribing to `nowPlayingUpdates`, posts via service, respects `AppSettings.notificationsEnabled`, looks up channel title via API). `MiniPlayerView` displays cover art via `Image(nsImage:)` when available, falling back to the SF Symbol placeholder. Panel background switched to a SwiftUI `Color(nsColor: .windowBackgroundColor)` so Light/Dark appearance changes are honored. `PlaybackCoordinatorError: LocalizedError` so error banners read as prose. `LiveNotificationService` is bundle-gated in `AppContainer.live()` — `swift run` (no main bundle proxy) gets a `NoopNotificationService`; production `.app` bundles get the real one. Out of scope (deferred): rating row (PR 10), settings link/window (PR 10), `AppContainer` composition root (PR 11), main-menu/`Cmd-Q` (PR 11), `LSUIElement` Info.plist (PR 12).

PR 10 shipped scope: SettingsView + SettingsWindowController + RatingRow + LoginWindowController integration + KeychainCookieProvider swap + ConfigStore→engine bridge for hog mode + output device. Round-1 smoke fixed sign-in propagation (closure not windowWillClose), folder paths (logs under Application Support, single "Show application data" button), pause→resume distinction, FLAC labels, segmented rating row. Round-2 fixed file-sink wiring (`AppLogger.fileBacked` factory targeting `ConfigPaths.logsDirectory`), hog-mode AO state machine (`LibmpvPlayerEngine` recomputes `audio-device` between `coreaudio_exclusive` and `coreaudio` based on hog flag, exposed via `currentAudioDeviceForTesting`), widened cookie filter (`LoginWindowController.rpCookieString` forwards every `radioparadise.com` cookie once the three auth cookies validate), and added `LiveRpApiClient.get` diagnostics (cookie-name list + 500-char body preview on non-2xx). Round-3 added shared-mode fallback (`LivePlaybackCoordinator` traps mpv's `Failed to initialize audio driver 'coreaudio_exclusive'` / `hardware format not supported`, calls `setHogMode(false)` once per `play()` and replays the current block) and 401 keychain auto-clear (`MiniPlayerViewModel.rate` catches `RpApiError.invalidResponse(statusCode: 401, _)` and surfaces "Logged out — sign in again to rate."). Round-4 UX added persisted hog fallback (`LivePlaybackCoordinator.init(onHogModeFallback:)`; `AppContainer.live()` writes `ConfigStore.hogModeEnabled = false` when fallback fires, so the Settings toggle reflects it), username display (`KeychainAuth.currentUsername` parses `C_username`; `SettingsView.accountSection` reads "Signed in as **<name>**"), and the new `StartupAuthProbe.run(api:auth:onCleared:)` which validates stored auth via `api/auth-state` on launch — clears keychain on anonymous response or 401, leaves cookie alone on transient network errors. Open follow-ups recorded in `docs/superpowers/plans/2026-04-30-pr10-settings-rating.md`: hog-mode-on-USB-DAC investigation deferred (other apps achieve bit-perfect on the same DAC; suspected mpv format-negotiation timing — see plan §"Remaining open follow-ups"), DESIGN.md §7 fallback toast, settings panel auth refresh after login window. Test count: 127 → 172 (+45).

---

## Workflow conventions (locked)

- **Plan cadence:** just-in-time — write plan for next PR, get approval, execute, repeat.
- **Execution:** `superpowers:subagent-driven-development` (fresh subagent per task, spec + quality review after each).
- **Worktrees:** sibling-directory pattern — `/Users/gergely/git/rp-player-pr04`, etc.
- **Merge strategy:** fast-forward only (`git merge --ff-only`) to main after all reviews pass.
- **Test command:** `swift test`
- **Build command:** `swift build`

---

## Key technical decisions (non-obvious, not in code)

- `kSecUseDataProtectionKeychain: true` causes `errSecMissingEntitlement (-34018)` in unsigned `swift test` processes on macOS 26 beta (Darwin 25.3.0). Do not add it until the app is codesigned.
- `WKHTTPCookieStoreObserver` callbacks are not `@MainActor` — always call `getAllCookies(_:)` (completion-handler form, macOS 13 compat) on the delivery thread before hopping to `@MainActor`. Do not capture `WKHTTPCookieStore` across actor boundaries.
- `ConfigStore.changes` is an actor-isolated `async` property (not `nonisolated`) — registration is synchronous within actor isolation to eliminate a race window.
- `JSONDecoder.rpDecoder` is a shared `static let` (snake_case → camelCase). Use it for all RP API decodes.
- Query items in `LiveRpApiClient` are sorted alphabetically — `StubURLProtocol` test URLs must match this order.
- `GetBlock.chan` is `String` (live API returns `"0"`, not `Int`). `GetBlock.endEvent` is `String?` (same reason).
- `SongInfo.songId` has a custom `init(from:)` that handles both `Int` and `String` JSON values.
- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). The public `client.h` is pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`). Reported API version: 2.1. Refreshing the dylibs requires updating both the binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `RPSmoke` and `RPPlayerTests` link libmpv with two `@loader_path`-relative rpaths baked in (3-deep for executables, 6-deep for xctest bundles). No `DYLD_LIBRARY_PATH` is needed for `swift test` or `swift run RPSmoke`. Production `.app` packaging (PR 12) will install dylibs under `Contents/Frameworks/` and use a single `@loader_path/../Frameworks` rpath instead.
- All vendored dylibs use `@rpath/<name>.dylib` install names so a single rpath into `Vendor/libmpv/lib/` resolves the entire transitive graph. Verify after refresh: `otool -D Vendor/libmpv/lib/*.dylib` — every line after the path must read `@rpath/<name>.dylib`. If a future upstream rebuild ships absolute or `@executable_path/...` install names, the rpath approach silently breaks; rewrite via `install_name_tool -id` before committing.
- `LibmpvPlayerEngine` runs a single detached event-pump task that calls `mpv_wait_event` with a 0.5s timeout in a loop. The pump exits when `mpv_terminate_destroy` triggers `MPV_EVENT_SHUTDOWN` or when the actor cancels the task. Shutdown ordering is `mpv_wakeup → await pumpTask → mpv_terminate_destroy → emit synthetic .shutdown → finish continuations` because `mpv_terminate_destroy` does not reliably wake an in-flight `mpv_wait_event` on the same handle. mpv's client API is thread-safe except for `mpv_wait_event` (only one thread at a time) — the pump is the only caller.
- `LibmpvPlayerEngine` cannot start its detached pump task from inside `init` because Swift 6.2 strict concurrency forbids capturing `self` (even `[weak self]`) into a `Task.detached` closure during a non-isolated init. Bootstrap pattern: `init` schedules `Task { await self.startPump() }` (an unstructured Task on the actor's executor), and `startPump()` then spawns the detached pump. The handle is wrapped in a private `HandleBox: @unchecked Sendable` to cross the detached-task boundary.
- `LivePlaybackCoordinator` triggers the next-block prefetch when `currentSongIndex == orderedSongs.count - 1` AND `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The 10-second window matches DESIGN.md §5.6 and gives the network round-trip plenty of margin before EOF. Only one prefetch per block (guarded by `prefetchedBlock == nil && prefetchTask == nil`).
- `LivePlaybackCoordinator.play(channelId:)` issues the cue tune-in by waiting for `PlayerEvent.fileLoaded`, then calling `engine.seek(to: cueSeconds)`. The cue seek is bypassed for prefetch-driven block swaps and for skip-forward-past-last-song — both intentionally start the new block from offset 0.
- `LivePlaybackCoordinator` lazy-subscribes to `PlayerEngine.events` from inside `play()` via `await ensureEventSubscription()`, NOT from `init`. This is deterministic: by the time `play()` issues the engine command, the actor has already registered an `events` continuation, so events fired by the engine cannot race ahead of the subscription. The init-time `Task { ... }` bootstrap pattern was rejected here because subscription order matters.
- The shell uses `NSApp.setActivationPolicy(.accessory)` set at runtime (not `LSUIElement` in an Info.plist) because SPM executable targets do not ship an Info.plist. PR 12 introduces the real `.app` bundle and may move this into `LSUIElement`; until then the runtime call is the only way to suppress the Dock icon.
- The PR 7 menu-bar popup is a borderless `NSPanel` (style `[.borderless, .nonactivatingPanel]`, level `.statusBar`), NOT an `NSPopover`. The plan originally specified `NSPopover`; smoke testing on macOS 26 (Darwin 25.3.0) showed the bubble arrow rendering on top of the status item icon and `.transient` dismissal failing for `.accessory`-policy apps until the panel was clicked. The borderless `NSPanel` gives full positioning control (panel top is aligned to `buttonWindow.frame.minY`, not the button frame, so the panel sits flush with the menu bar without a 2–3 px gap) and uses an `NSEvent.addGlobalMonitorForEvents` global click monitor for outside-click dismissal. Rounded corners are drawn on the content view's layer (`cornerRadius = 10`, `masksToBounds = true`) with the panel itself transparent (`isOpaque = false`, `backgroundColor = .clear`) so the rounded shape shows through and the system shadow follows it.
- `PopoverController` is a non-`final` class (not a struct) only so tests can override `isShown`. The shell otherwise has no protocol abstractions — PR 11 confirmed the designated `AppContainer.init(...)` parameters are sufficient as the test seam; no protocol layer was added.
- `swift test --parallel` currently fails on `KeychainStoreTests.testSaveOverwritesExisting` with `errSecDuplicateItem (-25299)` — multiple test processes race on the same keychain account. Pre-existing (visible since PR 3); not introduced by PR 7. Workaround: use serial `swift test`. Proper fix is to scope each test to a unique keychain account namespace; deferred until it actually blocks something.
- `MiniPlayerViewModel` is `@MainActor final class: ObservableObject`, NOT `@Observable`. The view model spawns its coordinator-subscription `Task` from `start()` (called by `MiniPlayerView`'s `.task` modifier on first appear), not from `init` — same Swift-6.2 rule that constrains `LivePlaybackCoordinator`'s pump bootstrap. (Switching to `@Observable` is now possible after PR 9 bumped the deployment target to macOS 14; defer the migration until a real reason to touch this code surfaces.)
- Deployment target was bumped to `.macOS(.v14)` in PR 9. `NSImage: Sendable` requires macOS 14, and `LiveAlbumArtCache.inFlight: [String: Task<NSImage?, Never>]` produces unrejectable Sendable warnings on `.v13`. The user runs macOS 26, so the higher floor is comfortable. macOS 13 support can be reinstated if needed by routing the cache through `Data` and re-decoding per consumer.
- `MiniPlayerViewModel.selectChannel(_:)` guards rapid double-calls with an `inFlightChannelId` token: if a second `selectChannel` lands before the first awaited `coordinator.changeChannel(to:)` resolves, the late completion short-circuits and the second selection wins. Without this, optimistic-UI rollback on the first call would erase the user's pending choice. Tested via `testSelectChannelSecondCallSupersedesFirst`.
- `AppDelegate.applicationWillTerminate` blocks the terminate path on `coordinator.shutdown()` via `DispatchGroup.wait(timeout: 2.0)` with the awaiting work spawned via `Task.detached`. The `Task.detached` is load-bearing: `applicationWillTerminate` runs on the main thread, and a non-detached `Task { @MainActor in await shutdown() }` would never start because main is parked in `group.wait`. The 2 s cap matches the libmpv pump shutdown budget.
- `AppContainer` (in `Sources/RPPlayer/App/`) is the composition root. `AppContainer.init(...)` is the test seam — pass stub collaborators directly. `AppContainer.live() throws` does the production wiring (`JSONConfigStore`, `LibmpvPlayerEngine`, `KeychainCookieProvider`, etc.) and returns the assembled graph. `AppDelegate.init(containerFactory:)` defaults to `{ try .live() }`; tests override with stub-built containers. The `Noop*` fallback types live as `private` declarations at the bottom of `AppContainer.swift` because that's where `live()` consumes them.
- `AppContainer.live()` swallows every recoverable construction error (libmpv init failure → `NoopPlayerEngine`, JSON config open failure → `NoopConfigStore`, album-art cache directory failure → `NoopAlbumArtCache`). The `throws` on `live()` is reserved for future non-recoverable cases. `AppDelegate.applicationDidFinishLaunching` calls `preconditionFailure` if `live()` throws — that's correct for the current zero-throwing reality.
- `AppContainer.runOnLaunchTasks()` fans out via `withTaskGroup` so the two startup work items (notification authorization request + `StartupAuthProbe.run`) run concurrently. Sequential execution would block `StartupAuthProbe` behind `UNUserNotificationCenter`'s first-launch permission dialog on a bundled `.app`.
- `PopoverController(rootView:)` takes an `AnyView`, not a generic `<RootView: View>`. The popover is the only construction site and the panel's `contentView: NSView?` already erases through AppKit, so generic propagation buys nothing while complicating the call site.
- The popover installs both a global mouse-down monitor (outside-click dismissal) and a local key-down monitor (Esc) on `show(relativeTo:)`. Esc is the keycode 53 constant `PopoverController.escapeKeyCode`. The local monitor is process-wide — when PR 9 introduces a text field inside the popover or PR 10 ships `SettingsView` in a separate window, gate the monitor on `event.window === panel` (or install only while the popover is key) so Esc isn't hijacked.
- `LivePlaybackCoordinator.getBlock(... info: true)` is required everywhere. With `info: false` the live API returns `song: null` and omits `image_base`, both required by the `GetBlock` model. The fixture-driven coordinator tests didn't catch this because `MockRpApiClient.getBlock` ignores `info` and returns synthetic `GetBlock` values. PR 8 surfaced and fixed the bug at all three callsites (initial play, channel change, prefetch).
- `NoopPlayerEngine` (private struct in `AppDelegate.swift`) is a `PlayerEngine` shim that throws a captured init error from every action method and yields an immediately-finished events stream. It keeps the menu-bar shell up so the user can see the error banner if `LibmpvPlayerEngine.init` throws (missing dylib, audio-device contention).
- `LiveAlbumArtCache` keys files by SHA-256(coverPath) + ".jpg", not by `songId`. Multiple songs share an album, so song-keyed cache would re-download the same JPEG. Cap is 20 files / 10 MB; eviction runs on every successful write and removes oldest by `contentModificationDate`. In-flight de-dup via a `coverPath → Task<NSImage?, Never>` map prevents duplicate downloads when two callers race. Response bodies are validated with `NSImage(data:)` before persisting so a 200 with non-image bytes (HTML error page, partial body) does not poison the cache.
- `LiveNotificationService.init(center:)` has NO default argument. The previous default `= UNUserNotificationCenter.current()` evaluated eagerly at the call site and `current()` throws an `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") on macOS 26 inside unbundled processes (`swift run RPPlayer`). `AppContainer.live()` constructs `LiveNotificationService(center: UNUserNotificationCenter.current())` only when `Bundle.main.bundleIdentifier != nil`, otherwise it uses `NoopNotificationService`. PR 12 ships the `.app` bundle and the real path lights up.
- `NotificationCoordinator` is `@MainActor final class` (not an actor) because it bridges `nowPlayingUpdates` to AppKit / UserNotifications types that are main-thread anchored. The subscription `Task` is spawned in `start()`, mirroring `MiniPlayerViewModel`. The `for await` body checks `Task.isCancelled` before processing each emission so `stop()` reliably drops in-flight events. Configuration (notifications-enabled flag, channel title, on-disk file URL) is injected as `@Sendable` async closures so production wires them to live `JSONConfigStore` / `RpApiClient` / cache reads while tests substitute lightweight stubs.
- The popover's panel background was migrated from a `cgColor` snapshot on `panel.contentView.layer` to a SwiftUI `Color(nsColor: .windowBackgroundColor)` background applied via `.background(...)` on the wrapped root view. Layer-side `cornerRadius = 10` and `masksToBounds = true` stay because `NSPanel`'s system shadow needs a non-clear hosting view to derive its shape. Light/Dark appearance toggles now re-render the popover without recomposing the layer.
- `PlaybackCoordinatorError: LocalizedError` provides clean `errorDescription` strings for all five cases (`notPlaying`, `channelNotFound`, `blockHasNoSongs`, `engineError`, `underlying`). The view model surfaces `error.localizedDescription`, which now picks up these strings instead of Swift's default `engineError(message: "...")`-style print.

---

## Comment policy (strict)

- No comments unless the WHY is non-obvious (hidden constraint, workaround, subtle invariant).
- No multi-line docstrings. Single `//` line max.
- Code/commit/PR text: write normal English.

---

## Test counts by PR

- After PR 1: 13 tests
- After PR 2: 18 tests
- After PR 3: 35 tests
- After PR 4: 47 tests
- After PR 5a: 48 tests
- After PR 5b: 67 tests
- After PR 6: 93 tests
- After PR 7: 101 tests
- After PR 8: 111 tests
- After PR 9: 127 tests
- After PR 10: 172 tests
- After PR 11: 184 tests

---

## Plan files

All plans live in `docs/superpowers/plans/`. Written just-in-time before each PR's execution.
