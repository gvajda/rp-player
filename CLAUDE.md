# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

**GitHub:** <https://github.com/gvajda/rp-player>

---

## Current state

- Last merged: **PR 24** — stale-block detection (api/play action=start with cue=0 + all elapsed<=0 + at least one strictly negative advances via action=play) + long-idle resume refetch (>=59 min). 345 tests passing on `main`.

## PR status

| PR   | Branch         | Status | Contents                                                                    |
| ---- | -------------- | ------ | --------------------------------------------------------------------------- |
| 1    | merged to main | ✅      | Scaffold, AppLogger, RotatingFileSink, AppSettings, ConfigStore             |
| 2    | merged to main | ✅      | RpApiClient, ApiModels, CookieProvider, StubURLProtocol, fixtures           |
| 3    | merged to main | ✅      | KeychainStore, KeychainCookieProvider, LoginWindowController                |
| 4    | merged to main | ✅      | AudioDeviceCatalog                                                          |
| 5a   | merged to main | ✅      | libmpv vendoring + RPSmoke CLI                                              |
| 5b   | merged to main | ✅      | PlayerEngine (libmpv Swift actor)                                           |
| 6    | merged to main | ✅      | PlaybackCoordinator                                                         |
| 7    | merged to main | ✅      | AppKit shell (NSStatusItem + borderless NSPanel hosting placeholder)        |
| 8    | merged to main | ✅      | MiniPlayerView (SwiftUI) + AppDelegate real-graph wiring                    |
| 9    | merged to main | ✅      | NotificationCoordinator + AlbumArtCache + album art in MiniPlayerView       |
| 10   | merged to main | ✅      | SettingsView + rating row + KeychainCookieProvider + login flow             |
| 11   | merged to main | ✅      | AppContainer composition root + App/Edit main menu                          |
| 12   | merged to main | ✅      | Smoke fixes + UI polish (rp.ico, Layout E, live bitrate, cue, hog mode)     |
| 12.5 | merged to main | ✅      | Event-cursor block resume (drops now_playing API; per-channel cursor)       |
| 13   | merged to main | ✅      | api/play migration (replaces get_block; supports favorites chan=99)         |
| 14   | merged to main | ✅      | Telemetry endpoints (update_history, update_pause) for cross-session resume |
| 15   | merged to main | ✅      | GitHub Actions: swift test on push; universal .app bundle on tag push       |
| 16   | merged to main | ✅      | Popover + Settings UI polish (support link, song-in-browser, hamburger menu, ZStack channel row, title3 song title) |
| 17   | merged to main | ✅      | Audio device error handling (errors stream, popover auto-open, VM reset)    |
| 18   | merged to main | ✅      | Ambient background from album art (opt-in; fades on promo/error/disable)    |
| 19   | merged to main | ✅      | Upcoming Program window (get_block read-only fetch, multi-column card view, settings row count + channel filter; ambient card color; cue Int/String fix; black progress bar in light+ambient mode) |
| 20   | merged to main | ✅      | CI: merge release into ci.yml (test + tag-gated release jobs); Codecov coverage via OIDC + sersoft lcov conversion + codecov.yml path fix; README badges (build+tests, coverage, latest release, license) |
| 21   | merged to main | ✅      | Audio settings overhaul: releaseHogOnPauseEnabled, forceMaxVolumeEnabled (replaces dead softwareVolumeEnabled), applyReplayGainEnabled, DeviceVolumeController (CoreAudio scalar pin/read), PlaybackState stream + currentPlaybackState, force-max confirmation alert, ReplayGain hover info popover, Appearance segmented picker, output-device refresh button (AudioDeviceCatalog.reload() on protocol) |
| 22   | merged to main | ✅      | Media-key + Now Playing center support: MPRemoteCommandCenter (play/pause/togglePlayPause/nextTrack), MPNowPlayingInfoCenter (title/artist/album/artwork/duration/elapsed + playbackState); position throttled to 1 Hz; artwork construction in nonisolated helper to avoid MainActor-isolation crash on MediaPlayer's dispatch queue |
| 23   | merged to main | ✅      | Popover shared components: PopoverAlbumArt + SongTitleRow + AmbientGradientBackground extracted; PastSongView gets ambient gradient + matched typography; PastSongPopoverController folded into shared PopoverController via present(rootView:relativeTo:); main popover panel width 320 → 342; rating moved to title row (.title3); year displayed inline with album (right-aligned) |
| 24   | claude/pr24-stale-block-recovery | ✅      | Stale-block detection + long-idle resume refetch: BlockSongs.isStale (cue=0, all elapsed<=0 with at least one strictly negative — distinguishes stale music block from fresh promo); play(channelId:) advances via action=play with last song's event/type/sliceNum (single retry, accepts second stale response without recursing); resume() refetches via play() when paused >=59 min (CDN TCP idle eviction defense); resume() block-expiration check now goes through injected clock() for testability |

---

## Workflow conventions (locked)

- **Plan cadence:** just-in-time — write plan for next PR, get approval, execute, repeat.
- **Execution:** `superpowers:subagent-driven-development` (fresh subagent per task, spec + quality review after each).
- **Branches:** feature branches off `main` (e.g. `claude/pr13-api-play-migration`). Work happens on the branch directly in the main checkout — no separate worktree directory. Push to GitHub via `git push -u origin <branch>` if remote sync is desired.
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
- **Release-on-pause** (`AppSettings.releaseHogOnPauseEnabled`, default true) hooks `HogModeController.acquire` / `release` to coordinator state transitions. AppContainer subscribes to `coordinator.stateUpdates` (new `AsyncStream<PlaybackState>`); on `.playing` it acquires hog (when both settings are on), on `.paused`/`.stopped` it releases. Initial launch skips hog acquire when release-on-pause is on — no point grabbing the device before the user clicks play. The settings binder also reads `coordinator.currentPlaybackState` to decide whether to acquire on a pure settings change while paused.
- **Force-Max Volume** (`AppSettings.forceMaxVolumeEnabled`, default false; replaces dead `softwareVolumeEnabled`) does TWO things: (1) sets mpv `volume=100` + `volume-max=100` (vs default 130) so any future UI volume slider can't exceed unity gain; (2) pins the device's CoreAudio `kAudioDevicePropertyVolumeScalar` to 1.0 via new `DeviceVolumeController` (master element first, per-channel L/R fallback). Toggle is indented under Hog mode and disabled when hog is OFF — outside hog mode the OS slider can override the pin so the toggle is meaningless. On hog OFF→ON transition the binder reads current device volume via `DeviceVolumeController.currentVolume` and writes `forceMaxVolumeEnabled = (volume >= 0.999)` so the toggle reflects ground truth at the moment hog activates. SwiftUI `.alert` with destructive Continue confirms ON-transition (hearing-damage warning).
- **Apply ReplayGain** (`AppSettings.applyReplayGainEnabled`, default false) controls mpv `replaygain` (`track`/`no`). The user's intent persists in settings but the *effective* value pushed to mpv is `applyReplayGainEnabled && !forceMaxVolumeEnabled` — Force-Max forces replaygain out of the signal path. UI toggle reads the effective state and is disabled when force-max is ON; flipping force-max OFF restores the user's stored replaygain choice automatically. Settings binder tracks `lastEffectiveRG` and only pushes to engine on effective-state changes.
- **Cue handling:**`loadfile <url> replace start=<seconds>`, NOT a post-`fileLoaded` `engine.seek(to:)`. mpv reports `time-pos = cue` immediately on seek for HTTP streams while the audio buffer hasn't caught up — UI saw the cue position before audio reached it. Public engine API is `play(url:startSeconds:)`; a default-arg `play(url:)` shim preserves back-compat for tests that don't care about cue. `LivePlaybackCoordinator.play(channelId:)` always seeds `currentSongIndex = 0` and seeks to `block.cue / 1000.0` if non-zero — the server (via `api/play`) returns the block whose first listed song is what should play next, so song[0] is always correct.
- **Block audio file ≠ first listed song.** Each block has one continuous audio file with content before song "0" (typically 4–5 min). The API encodes the true offset on each song's `elapsed` field (absolute ms from file start). `block.cue` is the user's tune-in point in the same reference frame. `BlockSongs.startsAtSeconds` reads `elapsed / 1000` per song (NOT cumulative `duration` sum from 0); `BlockSongs.totalDurationSeconds` returns `last.elapsed + last.duration` (file end). All seeks use this absolute-file-offset frame.
- **No engine-side hog fallback.** `LivePlaybackCoordinator.handleEngineEvent` just logs `.error(message:)` from mpv. The earlier `isHogModeAcquisitionFailure` heuristic + `engine.setHogMode(false)` retry was a vestige of the libmpv-owned hog era and is gone. If `HogModeController.acquire` itself returns false (CoreAudio status non-zero), surfacing that to the UI is a follow-up.
- **Device-unplug (and all engine errors) are handled via `fileEnded(reason: .error(code:))`.** `handlePlaybackError(code:)` cancels prefetch, clears all block/song/position/channel state (`currentBlock`, `orderedSongs`, `startsAt`, `currentSongIndex`, `currentPositionSeconds`, `pausedAt`, `pausePositionMs`, `currentChannelId`), and yields a message to `errors: AsyncStream<String>`. Code -14 (`MPV_ERROR_AO_INIT_FAILED`) → `"Audio device unavailable. Check System Settings → Sound → Output."` Any other code → `"Playback stopped unexpectedly (error \(code))."` The preceding `.error(message:)` log events remain log-only. The `errors` stream is single-subscriber (one continuation, finished in `shutdown()`); the VM is the sole subscriber.
- **`MiniPlayerViewModel.showPopoverIfNeeded`** is a public settable `@MainActor () -> Void` closure (default noop). `AppDelegate` sets it to `statusItemController?.showPopoverIfNeeded()` after both objects are created — this late-binding pattern breaks the `StatusItemController → PopoverController → MiniPlayerView → MiniPlayerViewModel` dependency cycle. The VM's errors subscription task sets `errorMessage`, `isPlaying = false`, `nowPlaying = nil`, then calls this closure on every error.
- **Bitrate label in the popover comes from `block.bitrate` (the API field), not mpv.** mpv's `audio-bitrate` observer reported the decoded stream's running average — confusing because it lagged settings changes (still showed "AAC" after switching to FLAC). The whole observer pipeline is gone: no `mpv_observe_property("audio-bitrate", …)`, no `StreamFormat`, no `PlayerEvent.streamFormatChanged`. The coordinator threads `currentBlock?.bitrate` through `NowPlaying.blockBitrate` and `BlockBitrateLabel.display(_:)` surfaces it verbatim (trim + uppercase only). Confirmed integer→label mapping (exhaustive, from manual API enumeration): 0 → "32k aac", 1 → "64k aac", 2 → "128k aac", 3 → "320k aac", 4 → "flac", 5 → "128k mp3", 6 → "320k mp3". Display is still verbatim (trim + uppercase) — no switch table — so any future server-side renames appear automatically. `MiniPlayerView` renders `viewModel.currentBitrateLabel`.

### libmpv vendoring + linkage

- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). Public `client.h` pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`), reported API version 2.1. Refreshing the dylibs requires updating both binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `RPSmoke` and `RPPlayerTests` link libmpv with two `@loader_path`-relative rpaths baked in (3-deep for executables, 6-deep for xctest bundles). No `DYLD_LIBRARY_PATH` is needed for `swift test` or `swift run RPSmoke`. PR 15's `.app` packaging will install dylibs under `Contents/Frameworks/` and use a single `@loader_path/../Frameworks` rpath.
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
- `LivePlaybackCoordinator` always passes `info: true` to `api.play(...)`. With `info: false` the live API returns `song: null` and omits `image_base`, both required by the `GetBlock` model.
- **Universal block-fetch endpoint is `api/play`.** All channels (including favorites `chan=99`) use it. Same response shape as the legacy `api/get_block`: a multi-song `GetBlock` for music channels, a single-song `GetBlock` for favorites. Browser-derived discovery (HAR captures from the RP web player). The previous `api/get_block` endpoint and its tests are gone.
- **Backend tracks cursors per `(player_id, chan)`.** Bootstrap from any channel switch is `api/play?event=0&action=start&chan=N&bitrate=X&info=true&elapsed=1&source=24` — the server returns the block where the listener last left off (per its records). The client-side `channelCursors: [Int: Int]` map is removed; the coordinator no longer maintains per-channel cursors.
- **Within-session advance/skip uses `api/play?event=<lastEvent>&action=play&audio_type=<M|P>&episode_id=0&slice_num=<n|null>&chan=N&bitrate=X&info=true&elapsed=1&source=24`.** `lastEvent`, `audio_type`, and `slice_num` come from the song that just finished (`orderedSongs.last`). Favorites: `slice_num` is JSON `null` in the response → `String?` decodes as `nil` → URL builder writes literal `slice_num=null`.
- `PlayListSong.type` is `"M"` for music, `"P"` for promo. Used both for `audio_type` query-param construction and for UI gating (e.g., disable rating UI on promo blocks — pending follow-up).
- `PlayListSong.sliceNum` is the song's slice index within the channel's event sequence. String for music ("5"), nil for favorites. Sent verbatim back as `slice_num` URL param on the next `play` call.
- **Cross-session resume is server-driven.** With the telemetry endpoints (`update_history`, `update_pause`) deferred to PR 14, the server's record of where a desktop user is may lag — so on app restart, the bootstrap `event=0&action=start` may return a recently-played slice rather than the next-after-last-played. PR 14 closes this gap.
- `skipForward()` past last song issues an `api/play` advance call (`action=play`, `event=<currentBlock.endEvent>`, plus `audio_type` / `slice_num` from the last song). If a prefetched block is already present it is adopted via `swapToPrefetchedBlockIfAvailable()` (no extra fetch). If a prefetch task is in flight it is cancelled before the synchronous fetch.
- Prefetch issues the same advance call shape with `event=<currentBlock.endEvent>` so the prefetched block is the deterministic next block, not just whatever the live channel happens to be.
- `LivePlaybackCoordinator.resume()` refetches via `play(channelId:)` when either (a) `clock() - pausedAt >= 59 * 60` (long-idle CDN connection eviction defense; observed mpv `Stream ends prematurely` after 8.5h pause), or (b) `block.expiration` has passed per DESIGN.md §7. Both checks now route through the injected `clock()` (was `Date()` directly). The 59m threshold sits just under the typical 1h CDN/server TCP idle eviction window.
- **Stale bootstrap block recovery.** `api/play?action=start` can return a block where `cue=0` and every song's `elapsed` is `<= 0` with at least one strictly negative — the server's per-(player_id, chan) cursor lagged real-time and the encoded offsets are relative to "block end" rather than "file start". Naive playback would seek to file offset 0 (already-aired content) while `BlockSongs.indexOfSong` latches onto the last song. `BlockSongs.isStale(songs:cue:)` detects this; `play(channelId:)` follows up with a single `api/play?action=play&event=<lastSong.event ?? block.endEvent>&audio_type=<lastSong.type>&slice_num=<lastSong.sliceNum>` advance and uses the response. Predicate intentionally requires *at least one strictly negative* elapsed so a fresh promo block (single song, `elapsed=0`) is NOT classified as stale. One retry max — a second stale response is accepted and the user can skip manually. Web player (main.js) has the same negative-elapsed code path with no detection; client-side recovery is correct.
- `LivePlaybackCoordinator` exposes `positionUpdates: AsyncStream<Double>` (block-position seconds, same reference frame as `NowPlaying.songStartSeconds` / `songEndSeconds`). Multi-subscriber: per-call continuation, seeded with the current `currentPositionSeconds`, yields on every `.positionUpdate` engine event, finished on `shutdown`. The mini-player view model subscribes once per `start()` and derives in-song elapsed/duration for the popover progress bar.

### Shell (AppKit + SwiftUI)

- The popup is a borderless `NSPanel` (style `[.borderless, .nonactivatingPanel]`, level `.statusBar`), NOT an `NSPopover`. `NSPopover`'s bubble arrow rendered on top of the status item icon and `.transient` dismissal failed for `.accessory`-policy apps on macOS 26. Borderless `NSPanel` gives full positioning control; outside-click dismissal via `NSEvent.addGlobalMonitorForEvents`. Rounded corners on the content view's layer (`cornerRadius = 10`, `masksToBounds = true`) with the panel transparent (`isOpaque = false`, `backgroundColor = .clear`) so the system shadow follows the rounded shape.
- Panel background uses a SwiftUI `Color(nsColor: .windowBackgroundColor)` background applied via `.background(...)` on the wrapped root view. Light/Dark appearance toggles re-render without recomposing the layer.
- Activation policy is `.accessory` set at runtime (not `LSUIElement` in an Info.plist) because SPM executable targets do not ship an Info.plist. PR 15's `.app` bundle may move this into `LSUIElement`.
- `PopoverController` is a non-`final` class only so tests can override `isShown`. The shell otherwise has no protocol abstractions — `AppContainer.init(...)` parameters are the test seam. `PopoverController(rootView:)` takes an `AnyView`; generic propagation buys nothing while complicating the call site.
- Popover installs a global mouse-down monitor (outside-click dismissal) and a local key-down monitor (Esc, keycode 53) on `show(relativeTo:)`. The local monitor is process-wide — if a future text field outside the popover needs Esc, gate on `event.window === panel`.
- The hamburger `Menu` in `channelRow` (`line.3.horizontal` icon, `.borderlessButton` style, `.menuIndicator(.hidden)`) has four entries in three `Section` groups: `Section("RP Player")` (non-interactive header) contains `Settings…` and `Open Song in Browser` (disabled when `nowPlaying == nil`); an untitled section has `About RP Player` (opens GitHub); an untitled section has `Quit RP Player`. `openCurrentSongInBrowser()` guards `Int(songId) > 0` to skip promo blocks (`songId == "0"`). `openAbout()` opens `https://github.com/gvajda/rp-player`. Both call `NSWorkspace.shared.open(_:)`.
- Transport buttons (play/pause + skip) use `PressOpacityButtonStyle` instead of `.buttonStyle(.plain)`. Plain style flashed the system blue on press; the custom style dims to 0.55 opacity with no background. The hamburger `Menu` uses `.menuStyle(.borderlessButton)` and does not need the custom style.
- `MiniPlayerView` body is `VStack(spacing: 0)` with the album art at full popover width (342×342, `scaledToFill+clipped`) and the inner stack carrying its own 12pt padding. The popover's existing 10pt corner radius + `masksToBounds` clips the top of the art so the popover appears as an extension of the artwork.
- **Shared popover components (PR 23).** Three SwiftUI views in `Sources/RPPlayer/Shell/Components/` are used by both `MiniPlayerView` (main popover) and `PastSongView` (notification-click past-song popover): `PopoverAlbumArt(image: NSImage?, size: CGFloat = 342)`, `SongTitleRow(title:artist:album:currentRating:isSignedIn:onRate:)` (typography: `.title3` title, `.subheadline .primary` artist, `.caption .primary` album), and `AmbientGradientBackground(topColor: Color?)` (2-stop linear gradient: top stop = provided color or `.windowBackgroundColor`; bottom stop = same color at 0.4 opacity). Animation `.animation(.easeInOut(duration: 0.4), value: ambientTopColor)` stays at the call site (consumer's concern), not inside the component. PR 23 also aligned `PopoverController.contentSize` width to 342 to match album-art width.
- `RatingMenu` replaces the previous full-width `RatingRow`. Narrow dropdown sitting in the title row right-aligned; label is `★ <n>` when rated, `☆` when unrated; disabled when signed out.
- Channel row layout uses a `ZStack` so `channelPicker` is geometrically centered. The overlay `HStack` has `Text("RP Player")` leading and a trailing `HStack` with the bitrate label + hamburger menu. Picker uses `.controlSize(.small)` to reduce its visual weight relative to the song title. No `@` separator. Inner VStack order: `titleRow`, `progressRow`, `transport`, `channelRow` (transport above channel picker).
- Song title uses `.title3`; artist uses `.subheadline` + `.primary`; album uses `.caption` + `.primary` (`.tertiary` was unreadable in light mode; `.secondary` faded too much against the ambient gradient — `.primary` reads cleanly in both modes with and without ambient). Both transport buttons keep `PressOpacityButtonStyle`.
- `SettingsView` has a `supportSection` as its first `Form` section: a `Link` to `https://radioparadise.com/donate` with a `heart.fill` icon (`.pink`) and a two-line label ("Support Radio Paradise" + "Opens radioparadise.com in your browser" caption). `Link` renders with macOS's external-arrow affordance.
- `AppSettings.appearance: AppearanceMode` (`.system` / `.light` / `.dark`, default `.system`). `AppContainer.live()` runs a dedicated `@MainActor` settings binder Task that translates each value to `NSApp.appearance` (`nil`, `.aqua`, `.darkAqua` respectively). Persisted JSON without the `appearance` key decodes as `.system` for backwards compatibility.
- `StatusItemController.showPopoverIfNeeded()` guards `!popover.isShown` then calls the same `showHandler(button)` path as the status-item button click. This replaced the identically-bodied `toggleIfHidden()` (removed in PR 17). It is called from: AppDelegate (error-recovery path via `MiniPlayerViewModel.showPopoverIfNeeded` closure) and `NotificationClickRouter` (notification-click path). **Never add a second show-only method** — route all "show if not visible" callers here.
- **Ambient background.** Opt-in (`AppSettings.ambientBackgroundEnabled`, default false; toggle in Settings → Appearance below the picker). When ON, `MiniPlayerView.body` paints a vertical 2-stop `LinearGradient` background: top stop = `viewModel.ambientTopColor` (sampled from the album-art's bottom 5% strip via `AmbientPaletteExtractor` actor — bottom-edge `CGImage.cropping` → 1×1 `CGContext.draw` with `.high` interpolation → RGB doubles → `Color`). Bottom stop = `Color(nsColor: .windowBackgroundColor)`, so the gradient fades into the panel's existing system-colored base and Light/Dark mode still works underneath. Animation: SwiftUI `.animation(.easeInOut(duration: 0.4), value: ambientTopColor)`. Sticky behavior: VM only clears `ambientTopColor` on (a) promo block (`song.songId == "0"`), (b) engine error (errors-stream subscription), or (c) ambient toggle OFF. During mid-track art loading the previous color persists until the new extraction completes. Stale-guard: extraction tasks check `lastLoadedCoverPath == coverAtKickoff` before publishing — if the user skipped to a different cover, the result is dropped. `MiniPlayerViewModel.init` therefore takes both `configStore: any ConfigStore` (subscribes to `ambientBackgroundEnabled`; initial value is read SYNCHRONOUSLY at `start()` via `await configStore.settings.ambientBackgroundEnabled` to avoid the race where the first `loadArt` runs before the settings stream's first emission) and `paletteExtractor: any AmbientPaletteExtracting` (production = `AmbientPaletteExtractor()`; tests use `StubAmbientPaletteExtractor` with an optional `delayNanoseconds` knob for deterministic sticky-test timing).
- **Media keys + Now Playing center.** `NowPlayingCenterController` (`@MainActor final class`) registers handlers on `MPRemoteCommandCenter.shared()` for `playCommand`, `pauseCommand`, `togglePlayPauseCommand`, `nextTrackCommand`. Previous/seek/skip-backward are explicitly disabled (live stream, no rewind). Subscribes to `coordinator.nowPlayingUpdates` / `stateUpdates` / `positionUpdates` and publishes to `MPNowPlayingInfoCenter.default().nowPlayingInfo` (title/artist/album/duration/elapsed/playbackRate/mediaType) plus `playbackState`. Position updates throttled to 1 Hz — mpv emits many per second and Music-app-style widgets interpolate between updates anyway. **Artwork must be built outside MainActor isolation.** `MPMediaItemArtwork(boundsSize:requestHandler:)`'s handler runs on MediaPlayer's `accessQueue` (libdispatch); a closure inheriting `@MainActor` from the enclosing class triggers `_swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail` SIGTRAP. The fix: a `nonisolated private static func makeArtwork(image:size:)` strips the actor isolation. The .app bundle (PR 15) is required for media-key handoff; `swift run` (unbundled) does not register with the system Now Playing service.

### View models

- `MiniPlayerViewModel` is `@MainActor final class: ObservableObject`, NOT `@Observable`. Spawns the coordinator-subscription `Task` from `start()` (called by `MiniPlayerView`'s `.task` modifier on first appear), not from `init` — same Swift-6.2 rule that constrains the engine pump bootstrap.
- `MiniPlayerViewModel.openCurrentSongInBrowser()` and `openAbout()` call `NSWorkspace.shared.open(_:)` directly (no injected closure). `openCurrentSongInBrowser` constructs `https://radioparadise.com/music/song/<id>` from `nowPlaying.song.songId` after `Int(songId) > 0` guard (promo blocks have `songId == "0"`).
- `MiniPlayerViewModel.selectChannel(_:)` guards rapid double-calls with an `inFlightChannelId` token: if a second `selectChannel` lands before the first awaited `coordinator.changeChannel(to:)` resolves, the late completion short-circuits and the second selection wins. Tested via `testSelectChannelSecondCallSupersedesFirst`.
- `NotificationCoordinator` is `@MainActor final class` (not an actor) because it bridges `nowPlayingUpdates` to AppKit / UserNotifications types that are main-thread anchored. Configuration (notifications-enabled flag, channel title, on-disk file URL) is injected as `@Sendable` async closures.

### API client

- `JSONDecoder.rpDecoder` is a shared `static let` (snake_case → camelCase). Use it for all RP API decodes.
- Query items in `LiveRpApiClient` are sorted alphabetically — `StubURLProtocol` test URLs must match this order.
- `GetBlock.chan` is `String` (live API returns `"0"`, not `Int`). `GetBlock.endEvent` is `String?` (same reason). `PlayListSong.event` is `String?` for the same reason.
- `RpApiClient.play(...)` is the universal block-fetch endpoint. Bootstrap shape: `event=0&action=start&chan=N&bitrate=X&info=true&elapsed=1&source=24`. Advance shape: `event=<lastEvent>&action=play&audio_type=<M|P>&episode_id=0&slice_num=<n|null>&chan=N&bitrate=X&info=true&elapsed=1&source=24`. Query items are sorted alphabetically; `slice_num=null` is written literally when the previous song's `sliceNum` is `nil` (favorites). The legacy `getBlock(channel:bitrate:info:event:)` method is gone.
- `SongInfo.songId` has a custom `init(from:)` that handles both `Int` and `String` JSON values.
- **Promo block edge case (**`type: "P"`**).** RP serves DJ-talk segments between music blocks. The promo block has `type: "P"`, `block_id: "0"`, single song with `song_id: "0"`, `artist: "Commercial-free"`, `title: "Listener-supported"`, short duration (~5s), `event == end_event`, and **no `album` field on the song dict** (also no `year`, `user_rating`, `rating`). `PlayListSong.album` is therefore `String?`. Symptom of regression: `keyNotFound(CodingKeys(stringValue: "album", ...))` decode error on the block-fetch response. Fixture: `Tests/RPPlayerTests/Fixtures/Api/get_block_promo.json` (filename predates the api/play migration). Other RP block types observed: `"M"` = music. If a future log shows a similar `keyNotFound` for a different field, check whether the request was for an unusual block type and add the missing field to the optional set.

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

- `LiveNotificationService.init(center:)` has NO default argument. Reason: the eager evaluation of `= UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") on macOS 26 inside unbundled processes (`swift run RPPlayer`). `AppContainer.live()` constructs `LiveNotificationService(center: UNUserNotificationCenter.current())` only when `Bundle.main.bundleIdentifier != nil`, otherwise uses `NoopNotificationService`. PR 15 ships the `.app` bundle and the real path lights up.
- **Notification authorization requires a stable code-signing identity.** Ad-hoc signing (`codesign --sign -`) registers the bundle with `usernoted` under a non-stable identity; `requestAuthorization` returns `UNErrorDomain Code=1 "Notifications are not allowed for this application"` with no user prompt. Fix: sign with any real identity (Apple Development, Developer ID Application, or self-signed cert named `RP Player Dev`). `scripts/make-app.sh` auto-detects whichever is available and falls back to ad-hoc with a warning. Hardened runtime (`--options runtime`) is required at the same time; library validation must be disabled via `scripts/entitlements.plist` so the ad-hoc-signed vendored libmpv dylibs still load. After changing identity, reset cached state with `tccutil reset All com.gvajda.rpplayer; killall NotificationCenter usernoted` then relaunch — the first launch enables the toggle in System Settings → Notifications, but the in-app prompt only fires on subsequent launches.
- **Notification request id format:** `"<UUID>|<songId>"`. `LiveNotificationService.extractSongId(from:)` parses the suffix; the UUID prefix prevents `usernoted` from collapsing duplicate notifications when the same song replays.
- `SongRegistry` (in-memory, 100-song bounded ring buffer keyed by songId) caches every notified `PlayListSong` so notification clicks can recover full metadata without an API round-trip when the app is still running. `NotificationCoordinator.handle` records before notifying.
- `NotificationClickRouter` is the `UNUserNotificationCenterDelegate`. On click it: (a) extracts the songId from the request identifier; (b) if it matches `coordinator.nowPlaying`, opens the main popover; (c) else looks up the song in `SongRegistry`; (d) if missing (post-restart, distant past), fetches via `api/info` and converts to `PlayListSong` via `PlayListSong.init(from: SongInfo)`; (e) on API failure, falls back to opening the main popover. Held strongly on `AppDelegate` because `UN.delegate` is `weak`.
- Past-song popover (notification-click) uses `PopoverController.present(rootView:relativeTo:)` — the same controller class as the main popover. PR 23 removed `PastSongPopoverController` and folded it into the shared base. The shared `PopoverController` is constructed with an `EmptyView` placeholder for the past-song instance and gets its hosted view replaced on every notification click. `PastSongView` renders via the shared `PopoverAlbumArt` + `SongTitleRow` + `AmbientGradientBackground` components — visual changes to one popover propagate to the other automatically. Mutual exclusion is bidirectional: `pastSongPresenter` calls `statusItemController.closeIfShown()` before showing the past popover, and `mainPresenter` calls `pastSongPopoverController.close()` before toggling the main popover. The `PastSongViewModel` is held by `AppDelegate.pastSongViewModel` (not by the controller); both `mainPresenter` and `pastSongPresenter` closures call `viewModel.stop()` on the previous VM before transitioning. **Tradeoff:** outside-click / Esc dismissal of the past-song popover does NOT eagerly stop the VM (one orphaned `for await store.changes` loop lingers until the next interaction terminates it). Bounded leak of ≤1 VM at any time. Cleaner alternative is an `onClose:` callback on `PopoverController.present(...)` — tracked as a follow-up.

### Deployment target

- `.macOS(.v14)` floor. `NSImage: Sendable` requires macOS 14, and `LiveAlbumArtCache.inFlight: [String: Task<NSImage?, Never>]` produces unrejectable Sendable warnings on `.v13`.

### CI / coverage

- **Single workflow** `.github/workflows/ci.yml` with two jobs: `test` (runs on push/PR/tag) and `release` (gated `if: startsWith(github.ref, 'refs/tags/v')`, `needs: test`). Eliminates duplicate test runs on tag pushes; release blocks on green tests.
- **Coverage upload is tokenless via OIDC.** `codecov/codecov-action@v4` with `use_oidc: true` + job-level `permissions: id-token: write`. Codecov GitHub App is installed scoped to `gvajda/rp-player` only — no OAuth `repo` scope, no `CODECOV_TOKEN` secret.
- **Coverage conversion via `sersoft-gmbh/swift-coverage-action@v4`.** SPM's `swift test --enable-code-coverage --show-codecov-path` produces raw llvm-cov-export JSON which Codecov's processor reports as "No swift data found" → empty report. The sersoft action runs `xcrun llvm-cov export -format=lcov` against the test bundle and writes `.swiftcov/*.lcov`. Do NOT pass `target-name-filter` — it filters by **test bundle** name (`RPPlayerPackageTests`), not source target, so `^RPPlayer$` skipped everything.
- **`codecov.yml` path-fix:** `fixes: ["/Users/runner/work/rp-player/rp-player/::"]` strips the CI runner absolute-path prefix so lcov entries align with repo-relative paths. Without this Codecov reports 0% (paths don't match repo files).
- **Repo is public.** Default branch = `main`. shields.io badges (`img.shields.io/github/...`) require public repos — they fail with "repo not found" on private repos. Build-status badge defaults to default branch; if default branch ever changes again, add `?branch=main` query param.
- **GitHub camo proxy caches badge SVGs.** If a badge URL resolved to an error (e.g. "repo not found" while private) and was rendered once, the camo cache holds the bad SVG. Bust by changing the URL string slightly (e.g. add `?cacheSeconds=3600`).

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
- After promo block fix (PlayListSong.album optional; promo block decode test + fixture): 209
- After popover visual polish (positionUpdates stream + RatingMenu + edge-to-edge art + Quit menu + press-opacity buttons; deletes RatingRow): 217
- After popover polish round 2 (Appearance setting + outline play button + ★/☆ rating label + centered picker w/ bitrate@ + inline RP Player; drops verbose-logging caption + footer): 222
- After notification click → past-song popover (SongRegistry + identifier suffix + NotificationClickRouter + PastSongView + PastSongPopoverController + PlayListSong(from: SongInfo); review fixes: bidirectional mutual exclusion + restored cancellation comment + registry-record test): 246
- After PR 13 api/play migration (drops getBlock + channelCursors; per-install rp3\_ player_id; drops GetBlock.filename; supports favorites chan=99): 251
- After PR 14 telemetry (update_history + update_pause; 5 trigger sites; clock injection; promo/favorites guards): 265
- After PR 16 UI polish (SettingsView support link, MiniPlayerViewModel URL-open methods, channelRow ZStack + hamburger menu, title3 song title, secondary album color, small picker): 265
- After PR 17 audio device error handling (errors stream on coordinator, handlePlaybackError, VM showPopoverIfNeeded injection, StatusItemController.showPopoverIfNeeded; 7 new tests): 272
- After PR 18 ambient background from album art (`AmbientPaletteExtractor` actor, `AppSettings.ambientBackgroundEnabled`, `MiniPlayerViewModel` configStore + paletteExtractor wiring, gradient `.background` + 0.4s ease-in-out animation in `MiniPlayerView`, re-extract on toggle ON mid-playback; 15 new tests): 287
- After PR 19 upcoming program window (`getBlock` restored, `UpcomingProgramViewModel` + `UpcomingColumn` + `UpcomingSongRow` models, `UpcomingProgramView` card/column/skeleton, `UpcomingWindowController`, `AppSettings.upcomingRowCount` + `upcomingHiddenChannelIds`, Settings "Upcoming Program" section, hamburger menu item, `AlbumArtCache.defaultMaxFiles` bumped to 100; ambient card color, promo filter, cue Int/String fix, black progress bar in light+ambient; 22 new tests): 309
- After PR 21 audio settings overhaul (`releaseHogOnPauseEnabled` + `forceMaxVolumeEnabled` replacing dead `softwareVolumeEnabled` + `applyReplayGainEnabled`; `DeviceVolumeController`; `PlaybackState` enum + `stateUpdates` stream + `currentPlaybackState`; engine `setForceMaxVolume`/`setApplyReplayGain`; UI: indented "Release on Pause" + "Force Max Volume", segmented Appearance picker, output-device refresh button, ReplayGain hover info icon, force-max confirmation alert; 2 new state-stream tests): 324
- After PR 22 media-key + Now Playing center support (`NowPlayingCenterController`, `MPRemoteCommandCenter` handlers, `MPNowPlayingInfoCenter` info dict, position throttled to 1 Hz, artwork built in `nonisolated static func` to avoid MainActor-isolation crash on MediaPlayer's dispatch queue): 324
- After PR 23 popover shared components (`PopoverAlbumArt` + `SongTitleRow` + `AmbientGradientBackground` extracted to `Sources/RPPlayer/Shell/Components/`; `PastSongViewModel` gains `configStore` + `paletteExtractor` + `ambientTopColor` published prop + `stop()` cancellation method; `PastSongView` renders ambient gradient with `.easeInOut(0.4s)` animation; `PastSongPopoverController` removed in favor of `PopoverController.present(rootView:relativeTo:)` — `AppDelegate` holds the past-song VM ref and stops it on transitions; main popover panel width corrected 320 → 342 to match album-art width): 334
- After PR 24 stale-block + long-idle resume recovery (`BlockSongs.isStale(songs:cue:)` requiring `cue==0 && all elapsed<=0 && at least one strictly negative` to distinguish stale music block from fresh promo; `play(channelId:)` post-bootstrap stale check + 1 advance retry via `action=play` with last song's event/type/sliceNum; `resume()` refetches via `play()` when `pausedAt` >= 59 min; `Date()` → injected `clock()` migration in `resume()`): 345

---

## Where things live

- **Plans:** `docs/superpowers/plans/` — written just-in-time before each PR's execution. Gitignored (local only).
- **Specs:** `docs/superpowers/specs/` — design docs from the brainstorming phase. Gitignored (local only).
- **Notes / known-issue handoffs:** `docs/notes/` — committed. Most recent: `docs/notes/pr12-outstanding-2026-05-01.md`.
- **Design source of truth:** `docs/DESIGN.md` — the project-level architecture spec.
- **Legacy reference:** `docs/legacy/` — the Windows app's C# code, kept for cross-checking RP API behavior (URLs, cookies, query shapes).
