# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

---

## Current state

- Last merged: **PR 12** (smoke fixes + UI polish — rp.ico icon, Layout E, live bitrate, cue-via-loadfile-start, direct CoreAudio hog mode, verbose logging toggle). 213 tests passing on `main`.
- Next: **PR 13** — distribution CI workflow + `.app` bundling.

### Open bugs from PR 12 smoke

Recorded in detail at `docs/notes/pr12-outstanding-2026-05-01.md`. Pick up before starting PR 13 unless the user defers.

1. **Bitrate runtime propagation broken.** Settings change persists to disk but `LivePlaybackCoordinator` keeps using the old bitrate even after a channel change. Static analysis ruled out the obvious causes (multi-subscriber race on `store.changes`, immutable field, cached call site, channel-change path, API URL construction). Most likely cause is the `AppContainer.live()` settings binder Task not running at all OR a subtle ordering issue. **Recommended next step:** add `logger.debug` at the top of the binder body in `AppContainer.live()` and at the head of `LivePlaybackCoordinator.setBitrate(_:)`, run with verbose logging ON, change the bitrate picker, see what fires.
2. **Song / metadata offset still desyncs.** Cue-via-`loadfile <url> replace start=<seconds>` fix landed in commit `0a9bf13` but the user still reports a metadata-vs-audio offset. Need fresh repro with verbose logs to determine whether mpv's `time-pos` after the load actually reflects the cue offset or something else.

---

## PR status

| PR  | Branch         | Status | Contents                                                                |
| --- | -------------- | ------ | ----------------------------------------------------------------------- |
| 1   | merged to main | ✅      | Scaffold, AppLogger, RotatingFileSink, AppSettings, ConfigStore         |
| 2   | merged to main | ✅      | RpApiClient, ApiModels, CookieProvider, StubURLProtocol, fixtures       |
| 3   | merged to main | ✅      | KeychainStore, KeychainCookieProvider, LoginWindowController            |
| 4   | merged to main | ✅      | AudioDeviceCatalog                                                      |
| 5a  | merged to main | ✅      | libmpv vendoring + RPSmoke CLI                                          |
| 5b  | merged to main | ✅      | PlayerEngine (libmpv Swift actor)                                       |
| 6   | merged to main | ✅      | PlaybackCoordinator                                                     |
| 7   | merged to main | ✅      | AppKit shell (NSStatusItem + borderless NSPanel hosting placeholder)    |
| 8   | merged to main | ✅      | MiniPlayerView (SwiftUI) + AppDelegate real-graph wiring                |
| 9   | merged to main | ✅      | NotificationCoordinator + AlbumArtCache + album art in MiniPlayerView   |
| 10  | merged to main | ✅      | SettingsView + rating row + KeychainCookieProvider + login flow         |
| 11  | merged to main | ✅      | AppContainer composition root + App/Edit main menu                      |
| 12  | merged to main | ✅      | Smoke fixes + UI polish (rp.ico, Layout E, live bitrate, cue, hog mode) |
| 13  | pending        | ⬜      | Distribution CI workflow                                                |

---

## Workflow conventions (locked)

- **Plan cadence:** just-in-time — write plan for next PR, get approval, execute, repeat.
- **Execution:** `superpowers:subagent-driven-development` (fresh subagent per task, spec + quality review after each).
- **Branches:** feature branches off `main` (e.g. `claude/pr13-distribution`). Work happens on the branch directly in the main checkout — no separate worktree directory. Push to GitHub via `git push -u origin <branch>` if remote sync is desired.
- **Merge strategy:** fast-forward only (`git merge --ff-only`) to main after all reviews pass.
- **Test command:** `swift test`
- **Build command:** `swift build`

---

## Comment policy (strict)

- No comments unless the WHY is non-obvious (hidden constraint, workaround, subtle invariant).
- No multi-line docstrings. Single `//` line max.
- Code/commit/PR text: write normal English.

---

## Key technical decisions (non-obvious, not in code)

### Audio pipeline

- **Hog mode is owned by `HogModeController`** (`Sources/RPPlayer/Audio/HogModeController.swift`), not mpv. The actor writes `getpid()` to `kAudioDevicePropertyHogMode` via `AudioObjectSetPropertyData` BEFORE mpv opens the device. mpv is configured with the plain `coreaudio` AO and `audio-exclusive` is never set. This bypasses mpv's `coreaudio_exclusive` AO format-negotiation failures observed on USB DACs (Qudelix-5K and similar). `AppContainer.live()`'s settings binder calls `acquire(deviceUID:)` / `release()` based on `(hogModeEnabled, outputDeviceUID)`. `release()` runs on app termination so the device returns to shared use.
- **Cue handling: `loadfile <url> replace start=<seconds>`**, NOT a post-`fileLoaded` `engine.seek(to:)`. mpv reports `time-pos = cue` immediately on seek for HTTP streams while the audio buffer hasn't caught up — UI saw the cue position before audio reached it. Public engine API is `play(url:startSeconds:)`; a default-arg `play(url:)` shim preserves back-compat for tests that don't care about cue.
- **`LivePlaybackCoordinator.handleEngineEvent` defensive hog fallback** still detects mpv-emitted `Failed to initialize audio driver` / `hardware format not supported` errors and disables hog mode + retries the current block. Rarely fires now that hog is acquired outside mpv, but stays as a safety net.

### libmpv vendoring + linkage

- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). Public `client.h` pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`), reported API version 2.1. Refreshing the dylibs requires updating both binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `RPSmoke` and `RPPlayerTests` link libmpv with two `@loader_path`-relative rpaths baked in (3-deep for executables, 6-deep for xctest bundles). No `DYLD_LIBRARY_PATH` is needed for `swift test` or `swift run RPSmoke`. PR 13's `.app` packaging will install dylibs under `Contents/Frameworks/` and use a single `@loader_path/../Frameworks` rpath.
- All vendored dylibs use `@rpath/<name>.dylib` install names. Verify after refresh: `otool -D Vendor/libmpv/lib/*.dylib` — every line after the path must read `@rpath/<name>.dylib`. If a future upstream rebuild ships absolute or `@executable_path/...` install names, rewrite via `install_name_tool -id` before committing.

### libmpv concurrency

- `LibmpvPlayerEngine` runs a single detached event-pump task that calls `mpv_wait_event` with a 0.5s timeout in a loop. Pump exits when `mpv_terminate_destroy` triggers `MPV_EVENT_SHUTDOWN` or when the actor cancels the task. Shutdown ordering: `mpv_wakeup → await pumpTask → mpv_terminate_destroy → emit synthetic .shutdown → finish continuations` — `mpv_terminate_destroy` does not reliably wake an in-flight `mpv_wait_event` on the same handle. mpv's client API is thread-safe except for `mpv_wait_event` (only one thread at a time) — the pump is the only caller.
- The pump task can NOT start from inside `init` because Swift 6.2 strict concurrency forbids capturing `self` (even `[weak self]`) into a `Task.detached` during a non-isolated init. Bootstrap pattern: `init` schedules `Task { await self.startPump() }` (an unstructured Task on the actor's executor); `startPump()` then spawns the detached pump. Handle is wrapped in a private `HandleBox: @unchecked Sendable` to cross the boundary.
- `AppDelegate.applicationWillTerminate` blocks the terminate path on `coordinator.shutdown()` via `DispatchGroup.wait(timeout: 2.0)` with awaiting work spawned via `Task.detached`. The `Task.detached` is load-bearing: `applicationWillTerminate` runs on main, and a non-detached `Task { @MainActor in await shutdown() }` would never start because main is parked in `group.wait`. The 2 s cap matches the libmpv pump shutdown budget.

### Composition root

- `AppContainer` (`Sources/RPPlayer/App/`) is the composition root. `init(...)` is the test seam (pass stub collaborators directly); `static func live() throws` does production wiring (`JSONConfigStore`, `LibmpvPlayerEngine`, `KeychainCookieProvider`, `HogModeController`, etc.). `AppDelegate.init(containerFactory:)` defaults to `{ try .live() }`; tests override with stub-built containers. `Noop*` fallback types live as `private` declarations at the bottom of `AppContainer.swift`.
- `AppContainer.live()` swallows every recoverable construction error (libmpv init failure → `NoopPlayerEngine`, JSON config open failure → `NoopConfigStore`, album-art cache directory failure → `NoopAlbumArtCache`). The `throws` is reserved for future non-recoverable cases. `AppDelegate.applicationDidFinishLaunching` calls `preconditionFailure` if `live()` throws.
- `AppContainer.runOnLaunchTasks()` fans out via `withTaskGroup` so post-launch work items (notification authorization request + `StartupAuthProbe.run`) run concurrently. Sequential execution would block `StartupAuthProbe` behind `UNUserNotificationCenter`'s first-launch permission dialog on a bundled `.app`.

### Coordinator playback

- `LivePlaybackCoordinator` triggers next-block prefetch when `currentSongIndex == orderedSongs.count - 1` AND `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The 10-second window matches DESIGN.md §5.6. One prefetch per block (guarded by `prefetchedBlock == nil && prefetchTask == nil`).
- `LivePlaybackCoordinator` lazy-subscribes to `PlayerEngine.events` from inside `play()` via `await ensureEventSubscription()`, NOT from `init`. Deterministic: by the time `play()` issues the engine command, the actor has already registered an `events` continuation, so events fired by the engine cannot race ahead.
- `LivePlaybackCoordinator.getBlock(... info: true)` is required everywhere. With `info: false` the live API returns `song: null` and omits `image_base`, both required by the `GetBlock` model.
- `LivePlaybackCoordinator.resume()` checks `block.expiration` and re-issues `play(channelId:)` for a fresh block when expired (per DESIGN.md §7).

### Shell (AppKit + SwiftUI)

- The popup is a borderless `NSPanel` (style `[.borderless, .nonactivatingPanel]`, level `.statusBar`), NOT an `NSPopover`. `NSPopover`'s bubble arrow rendered on top of the status item icon and `.transient` dismissal failed for `.accessory`-policy apps on macOS 26. Borderless `NSPanel` gives full positioning control; outside-click dismissal via `NSEvent.addGlobalMonitorForEvents`. Rounded corners on the content view's layer (`cornerRadius = 10`, `masksToBounds = true`) with the panel transparent (`isOpaque = false`, `backgroundColor = .clear`) so the system shadow follows the rounded shape.
- Panel background uses a SwiftUI `Color(nsColor: .windowBackgroundColor)` background applied via `.background(...)` on the wrapped root view. Light/Dark appearance toggles re-render without recomposing the layer.
- Activation policy is `.accessory` set at runtime (not `LSUIElement` in an Info.plist) because SPM executable targets do not ship an Info.plist. PR 13's `.app` bundle may move this into `LSUIElement`.
- `PopoverController` is a non-`final` class only so tests can override `isShown`. The shell otherwise has no protocol abstractions — `AppContainer.init(...)` parameters are the test seam. `PopoverController(rootView:)` takes an `AnyView`; generic propagation buys nothing while complicating the call site.
- Popover installs a global mouse-down monitor (outside-click dismissal) and a local key-down monitor (Esc, keycode 53) on `show(relativeTo:)`. The local monitor is process-wide — if a future text field outside the popover needs Esc, gate on `event.window === panel`.

### View models

- `MiniPlayerViewModel` is `@MainActor final class: ObservableObject`, NOT `@Observable`. Spawns the coordinator-subscription `Task` from `start()` (called by `MiniPlayerView`'s `.task` modifier on first appear), not from `init` — same Swift-6.2 rule that constrains the engine pump bootstrap.
- `MiniPlayerViewModel.selectChannel(_:)` guards rapid double-calls with an `inFlightChannelId` token: if a second `selectChannel` lands before the first awaited `coordinator.changeChannel(to:)` resolves, the late completion short-circuits and the second selection wins. Tested via `testSelectChannelSecondCallSupersedesFirst`.
- `NotificationCoordinator` is `@MainActor final class` (not an actor) because it bridges `nowPlayingUpdates` to AppKit / UserNotifications types that are main-thread anchored. Configuration (notifications-enabled flag, channel title, on-disk file URL) is injected as `@Sendable` async closures.

### API client

- `JSONDecoder.rpDecoder` is a shared `static let` (snake_case → camelCase). Use it for all RP API decodes.
- Query items in `LiveRpApiClient` are sorted alphabetically — `StubURLProtocol` test URLs must match this order.
- `GetBlock.chan` is `String` (live API returns `"0"`, not `Int`). `GetBlock.endEvent` is `String?` (same reason).
- `SongInfo.songId` has a custom `init(from:)` that handles both `Int` and `String` JSON values.

### Auth + cookies

- `WKHTTPCookieStoreObserver` callbacks are not `@MainActor` — always call `getAllCookies(_:)` (completion-handler form, macOS 13 compat) on the delivery thread before hopping to `@MainActor`. Do not capture `WKHTTPCookieStore` across actor boundaries.
- `LoginWindowController.rpCookieString` joins **all** `radioparadise.com` cookies (not just the auth trio) once the three required auth cookies are present and non-anonymous. Earlier filtering to just `C_username` / `C_passwd` / `C_validated` broke `api/rate` because the server expects session cookies (PHPSESSID etc.) too.
- `kSecUseDataProtectionKeychain: true` causes `errSecMissingEntitlement (-34018)` in unsigned `swift test` processes on macOS 26 beta (Darwin 25.3.0). Do not add it until the app is codesigned.
- `swift test --parallel` fails on `KeychainStoreTests.testSaveOverwritesExisting` with `errSecDuplicateItem (-25299)` — multiple test processes race on the same keychain account. Pre-existing since PR 3. Workaround: serial `swift test`. Proper fix is to scope each test to a unique keychain account namespace.

### Persistence

- `ConfigStore.changes` is an actor-isolated `async` property (not `nonisolated`) — registration is synchronous within actor isolation to eliminate a race window. `JSONConfigStore` is multi-subscriber-safe: each call to `.changes` returns a fresh `AsyncStream` with a unique UUID continuation; `update` yields to all continuations.

### Album art

- `LiveAlbumArtCache` keys files by `SHA-256(coverPath) + ".jpg"`, not by `songId` (multiple songs share an album). Cap: 20 files / 10 MB. Eviction runs on every successful write, removes oldest by `contentModificationDate`. In-flight de-dup via a `coverPath → Task<NSImage?, Never>` map. Response bodies are validated with `NSImage(data:)` before persisting so a 200 with non-image bytes (HTML error page, partial body) does not poison the cache.
- `MiniPlayerViewModel` only resets `currentArt` when the cover path actually changes. Defense in depth so spurious `NowPlaying` re-emissions (e.g., bitrate observer ticks within the same song) don't cause art to flicker.

### Logging

- `AppLogger` is a `final class @unchecked Sendable` with `setMinimumLevel(_:)` / `setVerbose(_:)` mutators behind an `NSLock`. `AppContainer.live()` flips the threshold based on `AppSettings.verboseLoggingEnabled` (re-flips on every settings change). Verbose ON: file sink captures every API request, every coordinator decision (play / pause / resume / skip / prefetch / swap / song-boundary cross), every engine state transition (file load, format detection, AO open, hog write, audio-device write), every bootstrap step. Default OFF.
- File sink lives at `~/Library/Application Support/RP Player/Logs/RPPlayer.log` via `AppLogger.fileBacked(category:directory:minimumLevel:)`.

### Errors

- `PlaybackCoordinatorError: LocalizedError` provides clean `errorDescription` strings for all five cases (`notPlaying`, `channelNotFound`, `blockHasNoSongs`, `engineError`, `underlying`). View models surface `error.localizedDescription`.

### Notifications

- `LiveNotificationService.init(center:)` has NO default argument. Reason: the eager evaluation of `= UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") on macOS 26 inside unbundled processes (`swift run RPPlayer`). `AppContainer.live()` constructs `LiveNotificationService(center: UNUserNotificationCenter.current())` only when `Bundle.main.bundleIdentifier != nil`, otherwise uses `NoopNotificationService`. PR 13 ships the `.app` bundle and the real path lights up.

### Deployment target

- `.macOS(.v14)` floor. `NSImage: Sendable` requires macOS 14, and `LiveAlbumArtCache.inFlight: [String: Task<NSImage?, Never>]` produces unrejectable Sendable warnings on `.v13`.

---

## Test counts by PR

- After PR 1: 13
- After PR 2: 18
- After PR 3: 35
- After PR 4: 47
- After PR 5a: 48
- After PR 5b: 67
- After PR 6: 93
- After PR 7: 101
- After PR 8: 111
- After PR 9: 127
- After PR 10: 172
- After PR 11: 184
- After PR 12: 213

---

## Where things live

- **Plans:** `docs/superpowers/plans/` — written just-in-time before each PR's execution. Gitignored (local only).
- **Specs:** `docs/superpowers/specs/` — design docs from the brainstorming phase. Gitignored (local only).
- **Notes / known-issue handoffs:** `docs/notes/` — committed. Most recent: `docs/notes/pr12-outstanding-2026-05-01.md`.
- **Design source of truth:** `docs/DESIGN.md` — the project-level architecture spec.
- **Legacy reference:** `docs/legacy/` — the Windows app's C# code, kept for cross-checking RP API behavior (URLs, cookies, query shapes).
