# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

---

## Current state

- Last merged: **PR 12** (smoke fixes + UI polish) + post-merge follow-ups (pull-based bitrate, libmpv hog vestige cleanup, bitrate-display fix, stream-format pipeline removal, now_playing-based song match + elapsed-based offsets, settings bitrate picker corrected, **event-cursor block resume**). 208 tests passing on branch `claude/event-cursor-resume`.
- Next: **PR 13** — distribution CI workflow + `.app` bundling.

### PR 12 follow-ups (landed post-merge)

All open smoke bugs from `docs/notes/pr12-outstanding-2026-05-01.md` resolved. Awaiting fresh user smoke before starting PR 13.

1. **Bitrate runtime propagation.** Root cause not pinpointed by static analysis (binder Task may not have fired at all, or raced with channel change). Structural fix: `LivePlaybackCoordinator` now takes `bitrateProvider: @Sendable () async -> Int` instead of stored `bitrate: Int` + `setBitrate`. Every `play` / `skipForward` / prefetch reads bitrate via `await bitrateProvider()`. `AppContainer.live()` wires the provider to `store.settings.bitrate`, so the freshest persisted value is read on the next call regardless of binder timing. `setBitrate` is removed from the protocol and binder.
2. **Song / metadata offset.** Two stacked root causes:
   - **Block audio file does not start at song "0".** RP serves a single audio file per block whose first listed song begins partway through (4–5 minutes in is typical). Each `song.elapsed` field is the song's absolute ms offset from the **file** start (not from song "0"). Old `BlockSongs.startsAtSeconds` accumulated durations from 0, which is wrong whenever the song dict is partial or pre-song content exists. Fix: `startsAtSeconds` now reads `song.elapsed / 1000` directly; `totalDurationSeconds` returns `last.elapsed + last.duration` (absolute file end, not sum-of-durations). `block.cue` is in the same reference frame (current playback position in ms from file start).
   - **Initial song selection** was later superseded by the event-cursor model (see item 3 below), which makes song-start resolution server-side and deterministic.
3. **Event-cursor block resume.** Replaced the `api/now_playing`-based song-match approach with a per-channel cursor that tracks the last finished event id. `LivePlaybackCoordinator` keeps `channelCursors: [Int: Int]`; `play(channelId:)` passes the cursor as the `event` query param to `RpApiClient.getBlock(...event:)` so the server returns the block starting after the last known song. All four cursor-write points (in-block auto-advance, in-block skipForward, skipForward-past-last-song, prefetch swap) keep the map current. `api/now_playing`, `NowPlayingEntry`, and `resolveStart` are fully removed. Covered by `testPlayWithCursorCallsGetBlockWithEventParam`, `testInBlockAutoAdvanceUpdatesCursorToFinishedSongEvent`, `testSkipForwardPastLastSongUsesEndEventAsCursorAndFetchParam`, `testSwapToPrefetchedBlockUpdatesCursorToOldEndEvent`, `testSkipForwardPastLastSongAdoptsPrefetchedBlockWhenAvailable`, `testSkipForwardPastLastSongCancelsInFlightPrefetchAndFetches`, `testChannelSwitchPreservesCursors`.

---

## PR status

| PR   | Branch                     | Status | Contents                                                                |
| ---- | -------------------------- | ------ | ----------------------------------------------------------------------- |
| 1    | merged to main             | ✅     | Scaffold, AppLogger, RotatingFileSink, AppSettings, ConfigStore         |
| 2    | merged to main             | ✅     | RpApiClient, ApiModels, CookieProvider, StubURLProtocol, fixtures       |
| 3    | merged to main             | ✅     | KeychainStore, KeychainCookieProvider, LoginWindowController            |
| 4    | merged to main             | ✅     | AudioDeviceCatalog                                                      |
| 5a   | merged to main             | ✅     | libmpv vendoring + RPSmoke CLI                                          |
| 5b   | merged to main             | ✅     | PlayerEngine (libmpv Swift actor)                                       |
| 6    | merged to main             | ✅     | PlaybackCoordinator                                                     |
| 7    | merged to main             | ✅     | AppKit shell (NSStatusItem + borderless NSPanel hosting placeholder)    |
| 8    | merged to main             | ✅     | MiniPlayerView (SwiftUI) + AppDelegate real-graph wiring                |
| 9    | merged to main             | ✅     | NotificationCoordinator + AlbumArtCache + album art in MiniPlayerView   |
| 10   | merged to main             | ✅     | SettingsView + rating row + KeychainCookieProvider + login flow         |
| 11   | merged to main             | ✅     | AppContainer composition root + App/Edit main menu                      |
| 12   | merged to main             | ✅     | Smoke fixes + UI polish (rp.ico, Layout E, live bitrate, cue, hog mode) |
| 12.5 | claude/event-cursor-resume | ⬜     | Event-cursor block resume (drops now_playing API; per-channel cursor)   |
| 13   | pending                    | ⬜     | Distribution CI workflow                                                |

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

- **Hog mode is owned by**`HogModeController` (`Sources/RPPlayer/Audio/HogModeController.swift`), not mpv. The actor writes `getpid()` to `kAudioDevicePropertyHogMode` via `AudioObjectSetPropertyData` BEFORE mpv opens the device. mpv is configured with the plain `coreaudio` AO and `audio-exclusive` is never set. This bypasses mpv's `coreaudio_exclusive` AO format-negotiation failures observed on USB DACs (Qudelix-5K and similar). `AppContainer.live()`'s settings binder calls `acquire(deviceUID:)` / `release()` based on `(hogModeEnabled, outputDeviceUID)`. `release()` runs on app termination so the device returns to shared use. The engine has no `setHogMode` method and no `hogModeChanged` event — the libmpv-owned hog era is fully gone.
- **Cue handling:**`loadfile <url> replace start=<seconds>`, NOT a post-`fileLoaded` `engine.seek(to:)`. mpv reports `time-pos = cue` immediately on seek for HTTP streams while the audio buffer hasn't caught up — UI saw the cue position before audio reached it. Public engine API is `play(url:startSeconds:)`; a default-arg `play(url:)` shim preserves back-compat for tests that don't care about cue. `LivePlaybackCoordinator.play(channelId:)` always seeds `currentSongIndex = 0` and seeks to `block.cue / 1000.0` if non-zero — the server returns the block whose first listed song matches the per-channel cursor, so song[0] is always what should play next.
- **Block audio file ≠ first listed song.** Each block has one continuous audio file with content before song "0" (typically 4–5 min). The API encodes the true offset on each song's `elapsed` field (absolute ms from file start). `block.cue` is the user's tune-in point in the same reference frame. `BlockSongs.startsAtSeconds` reads `elapsed / 1000` per song (NOT cumulative `duration` sum from 0); `BlockSongs.totalDurationSeconds` returns `last.elapsed + last.duration` (file end). All seeks use this absolute-file-offset frame.
- **No engine-side hog fallback.** `LivePlaybackCoordinator.handleEngineEvent` just logs `.error(message:)` from mpv. The earlier `isHogModeAcquisitionFailure` heuristic + `engine.setHogMode(false)` retry was a vestige of the libmpv-owned hog era and is gone. If `HogModeController.acquire` itself returns false (CoreAudio status non-zero), surfacing that to the UI is a follow-up.
- **Bitrate label in the popover comes from **`block.bitrate`** (the API field), not mpv.** mpv's `audio-bitrate` observer reported the decoded stream's running average — confusing because it lagged settings changes (still showed "AAC" after switching to FLAC). The whole observer pipeline is gone: no `mpv_observe_property("audio-bitrate", …)`, no `StreamFormat`, no `PlayerEvent.streamFormatChanged`. The coordinator threads `currentBlock?.bitrate` through `NowPlaying.blockBitrate` and `BlockBitrateLabel.display(_:)` surfaces it verbatim (trim + uppercase only). Confirmed integer→label mapping (exhaustive, from manual API enumeration): 0 → "32k aac", 1 → "64k aac", 2 → "128k aac", 3 → "320k aac", 4 → "flac", 5 → "128k mp3", 6 → "320k mp3". Display is still verbatim (trim + uppercase) — no switch table — so any future server-side renames appear automatically. `MiniPlayerView` renders `viewModel.currentBitrateLabel`.

### libmpv vendoring + linkage

- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). Public `client.h` pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`), reported API version 2.1. Refreshing the dylibs requires updating both binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `RPSmoke` and `RPPlayerTests` link libmpv with two `@loader_path`-relative rpaths baked in (3-deep for executables, 6-deep for xctest bundles). No `DYLD_LIBRARY_PATH` is needed for `swift test` or `swift run RPSmoke`. PR 13's `.app` packaging will install dylibs under `Contents/Frameworks/` and use a single `@loader_path/../Frameworks` rpath.
- All vendored dylibs use `@rpath/<name>.dylib` install names. Verify after refresh: `otool -D Vendor/libmpv/lib/*.dylib` — every line after the path must read `@rpath/<name>.dylib`. If a future upstream rebuild ships absolute or `@executable_path/...` install names, rewrite via `install_name_tool -id` before committing.

### libmpv concurrency

- `MpvPlayerEngine` runs a single detached event-pump task that calls `mpv_wait_event` with a 0.5s timeout in a loop. Pump exits when `mpv_terminate_destroy` triggers `MPV_EVENT_SHUTDOWN` or when the actor cancels the task. Shutdown ordering: `mpv_wakeup → await pumpTask → mpv_terminate_destroy → emit synthetic .shutdown → finish continuations` — `mpv_terminate_destroy` does not reliably wake an in-flight `mpv_wait_event` on the same handle. mpv's client API is thread-safe except for `mpv_wait_event` (only one thread at a time) — the pump is the only caller.
- The pump task can NOT start from inside `init` because Swift 6.2 strict concurrency forbids capturing `self` (even `[weak self]`) into a `Task.detached` during a non-isolated init. Bootstrap pattern: `init` schedules `Task { await self.startPump() }` (an unstructured Task on the actor's executor); `startPump()` then spawns the detached pump. Handle is wrapped in a private `HandleBox: @unchecked Sendable` to cross the boundary.
- `AppDelegate.applicationWillTerminate` blocks the terminate path on `coordinator.shutdown()` via `DispatchGroup.wait(timeout: 2.0)` with awaiting work spawned via `Task.detached`. The `Task.detached` is load-bearing: `applicationWillTerminate` runs on main, and a non-detached `Task { @MainActor in await shutdown() }` would never start because main is parked in `group.wait`. The 2 s cap matches the libmpv pump shutdown budget.

### Composition root

- `AppContainer` (`Sources/RPPlayer/App/`) is the composition root. `init(...)` is the test seam (pass stub collaborators directly); `static func live() throws` does production wiring (`JSONConfigStore`, `MpvPlayerEngine`, `KeychainCookieProvider`, `HogModeController`, etc.). `AppDelegate.init(containerFactory:)` defaults to `{ try .live() }`; tests override with stub-built containers. `Noop*` fallback types live as `private` declarations at the bottom of `AppContainer.swift`.
- `AppContainer.live()` swallows every recoverable construction error (libmpv init failure → `NoopPlayerEngine`, JSON config open failure → `NoopConfigStore`, album-art cache directory failure → `NoopAlbumArtCache`). The `throws` is reserved for future non-recoverable cases. `AppDelegate.applicationDidFinishLaunching` calls `preconditionFailure` if `live()` throws.
- `AppContainer.runOnLaunchTasks()` fans out via `withTaskGroup` so post-launch work items (notification authorization request + `StartupAuthProbe.run`) run concurrently. Sequential execution would block `StartupAuthProbe` behind `UNUserNotificationCenter`'s first-launch permission dialog on a bundled `.app`.

### Coordinator playback

- `LivePlaybackCoordinator` triggers next-block prefetch when `currentSongIndex == orderedSongs.count - 1` AND `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The 10-second window matches DESIGN.md §5.6. One prefetch per block (guarded by `prefetchedBlock == nil && prefetchTask == nil`).
- **Bitrate is pull, not push.** `LivePlaybackCoordinator` takes `bitrateProvider: @Sendable () async -> Int` at init and calls `await bitrateProvider()` at the top of `play(channelId:)`, on the next-block branch of `skipForward()`, and inside the prefetch Task. There is no `setBitrate` and no settings-binder hop for bitrate. `AppContainer.live()` wires the provider to `store.settings.bitrate`. This eliminates a class of races where a Settings change had to traverse `store.changes → AppContainer binder Task → coordinator.setBitrate` before the user's next channel change, which previously left the coordinator using the old bitrate when the binder hadn't completed in time.
- `LivePlaybackCoordinator` lazy-subscribes to `PlayerEngine.events` from inside `play()` via `await ensureEventSubscription()`, NOT from `init`. Deterministic: by the time `play()` issues the engine command, the actor has already registered an `events` continuation, so events fired by the engine cannot race ahead.
- `LivePlaybackCoordinator.getBlock(... info: true)` is required everywhere. With `info: false` the live API returns `song: null` and omits `image_base`, both required by the `GetBlock` model.
- `LivePlaybackCoordinator` keeps a per-channel `channelCursors: [Int: Int]` map that tracks the most recently finished or skipped-from event id per channel. `play(channelId:)` reads `channelCursors[channelId]` and passes it as `event:` to `RpApiClient.getBlock(...event:)`; the server returns the block whose first listed song is `cursor + 1` (i.e. "songs after cursor"). Empty cursor → no event param → server returns the live block.
- The cursor mutates at four boundary-cross points: in-block auto-advance (engine `positionUpdate` crosses a song boundary), in-block `skipForward()`, `skipForward()` past last song, and prefetched-block auto-swap (`swapToPrefetchedBlockIfAvailable`). Each writes the event id of the song just finished or skipped from. Channel switch-away is *not* a cursor-write point — the cursor already reflects the right value via the four points above.
- `skipForward()` past last song uses `currentBlock.endEvent` as both the cursor value and the `event` query param for the next-block fetch. If a prefetched block is already present it is adopted via `swapToPrefetchedBlockIfAvailable()` (no extra fetch). If a prefetch task is in flight it is cancelled before the synchronous fetch.
- Prefetch uses `event=<currentBlock.endEvent>` (parsed from `String?`) so the prefetched block is the deterministic next block, not just whatever the live channel happens to be.
- The earlier `now_playing`-based song-match path (`api.nowPlaying(channel:)` + `resolveStart(...)` + `NowPlayingEntry`) is gone. The cursor model makes it redundant: server tells us where the listener is by what we hand back.
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
- `GetBlock.chan` is `String` (live API returns `"0"`, not `Int`). `GetBlock.endEvent` is `String?` (same reason). `PlayListSong.event` is `String?` for the same reason.
- `RpApiClient.getBlock(channel:bitrate:info:event:)` takes an optional `event: Int?`; non-nil appends `event=<id>` to the query (sorted alphabetically with the other items: `bitrate`, `chan`, `event`, `info`). The cursor model in the coordinator drives this argument.
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
- After PR 12 follow-ups (pull-based bitrate, cue-seeded song index): 214
- After libmpv hog vestige cleanup (engine.setHogMode + hogModeChanged event + coordinator hog fallback removed; `LibmpvPlayerEngine` renamed to `MpvPlayerEngine`): 206
- After bitrate-display fix (NowPlaying.blockBitrate + `BlockBitrateLabel` raw-string display; popover shows `block.bitrate` from API instead of mpv's runtime audio-bitrate observer): 210
- After stream-format pipeline removal (deleted `StreamFormat`, `PlayerEvent.streamFormatChanged`, mpv `audio-bitrate` property observer + handler, coordinator `currentStreamFormat`, view-model `currentStreamFormat`; pipeline became dead once display switched to `block.bitrate`): 199
- After now_playing-based song match + elapsed-based offsets (added `RpApiClient.nowPlaying`, `NowPlayingEntry`, `resolveStart` in coordinator; `BlockSongs.startsAtSeconds` reads `elapsed` instead of summing durations; replaced cue-seeded tests with nowPlaying-match + cue-fallback tests; settings bitrate picker shows the 7-option API mapping): 201
- After event-cursor block resume (channelCursors map, drop now_playing API path, deterministic next-block fetch via event=endEvent, prefetch-adoption + cancellation in skipForward past-last): 208

---

## Where things live

- **Plans:** `docs/superpowers/plans/` — written just-in-time before each PR's execution. Gitignored (local only).
- **Specs:** `docs/superpowers/specs/` — design docs from the brainstorming phase. Gitignored (local only).
- **Notes / known-issue handoffs:** `docs/notes/` — committed. Most recent: `docs/notes/pr12-outstanding-2026-05-01.md`.
- **Design source of truth:** `docs/DESIGN.md` — the project-level architecture spec.
- **Legacy reference:** `docs/legacy/` — the Windows app's C# code, kept for cross-checking RP API behavior (URLs, cookies, query shapes).
