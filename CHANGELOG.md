# Changelog

All notable changes to RP Player are listed here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Section labels: `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`. Only include the sections that apply.

## [Unreleased]

### Added

- Preserve output device selection + hog mode + Force Max Volume when the active device disconnects while hog mode is on; auto-re-acquire hog (and re-pin Force Max volume) when the same device reappears. Playback stays stopped — user clicks play to resume. Settings picker shows the held device as "DeviceName (disconnected)" while it's absent.
- Hover-info tooltips on the **Bitrate** picker and **Hog mode** toggle in Settings (icon styled identically to the Volume/EQ/Crossfeed tooltips). Bitrate explains that the change applies on the next song. Hog mode explains exclusive device ownership, the automatic 44.1 kHz sample-rate lock, and the side-effect that other apps lose audio output until RP Player pauses or quits.
- **EQ preset editor** — per-preset edit panel in Settings → Equalizer lets you create, edit, rename, and save presets without leaving the app. Grid layout with one row per band (Type / Frequency / Gain / Q + trash icon) plus an Add band button (capped at 10 bands). Filter-type dropdown covers Bypass / Peak / Low Shelf / High Shelf. Save updates the current preset; Save As writes a copy under a new name; Rename updates every `AudioProfile.eqPresetName` reference atomically.
- **Live audio preview while editing.** Edits route through an in-memory `EqEditingOverride` channel so the lavfi chain reflects your in-flight draft in real time; the on-disk preset file stays untouched until you click Save or Save As. Preview survives across re-entry to the editor and is cleared on dismiss.
- Confirmation alert when saving an EQ preset shared by multiple output devices.

### Changed

- Crossfeed now uses the FFmpeg `bs2b` filter (Bauer stereo-to-binaural) with proper ITD (inter-aural time difference) modeling. Profiles: **Chu Moy** (700 Hz, 6.0 dB), **Jan Meier** (650 Hz, 9.5 dB), or **Custom** (fcut 300–2000 Hz, feed 1.0–15.0 dB). Replaces the previous `crossfeed` filter which lacked group-delay modeling and sounded notably worse than hardware-DAC implementations.
- Vendored libmpv rebuilt from `gvajda/libmpv-darwin-build` fork with `--enable-libbs2b`. Adds `Vendor/libmpv/lib/libbs2b.dylib` (~50 KB, MIT) alongside existing dylibs. API version (`MPV_MAKE_VERSION(2, 1)` = 131073) unchanged.
- Crossfeed Custom-mode fcut/feed input row is now right-aligned in the device settings section. The row's right edge sits at the Custom button's right edge in the row above (full-width `HStack` with leading `Spacer(minLength: 0)` and an `opacity(0)` toggle anchor reserving the trailing column). `ClampedNumericField` widened from 56×18 to 72×22 with explicit 12 pt font so wider values like `1650` or `12.00` render inside the bezel instead of overflowing below it. The fcut field now renders without decimals (`decimals: 0`) since Hz is an integer-valued setting.
- Crossfeed tooltip rewritten — drops the bs2b/Qudelix-5K hardware reference, lists only the three remaining profiles, and notes that Custom seeds at 700 Hz / 4.5 dB (the bs2b library's named-default values).
- EQ parser and writer now round-trip `OFF` filter rows verbatim. Previously the parser silently skipped them on load and the writer renumbered remaining bands; OFF rows are now preserved as `EqBand.enabled = false` so they survive an edit-save cycle. Writer emits `Filter N: ON|OFF …` with sequential N over all bands (enabled + disabled).
- EQ preset filenames are now capped at **30 characters** (was 255). The UI label length is the binding constraint; import filenames longer than the cap are truncated on first save with no warning.

### Removed

- `AudioProfile.crossfeedStrength` and `AudioProfile.crossfeedRange` (legacy `crossfeed` filter parameters). Old profiles migrate to Chu Moy defaults (`crossfeedProfile = .cmoy`, fcut 700 Hz, feed 6.0 dB) on first decode.
- **Default** crossfeed profile button (rendered fine but cluttered the row at four buttons). Custom now seeds with 700 Hz / 4.5 dB when entered from any other profile, so the prior Default-button starting point is one click away (Custom). The `CrossfeedProfile.bs2bDefault` enum case is gone; profiles previously stored as `"default"` on disk migrate to `.custom` with fcut 700 Hz / feed 4.5 dB seeded.
- Read-only EQ preset details view (eye icon next to the preset picker). Replaced by the editable panel — preset details are now always editable when the panel is open.

### Fixed

- Cold-start audio filter chain failure (`AVFilterGraph: No such filter: 'volume' / 'bs2b'` errors at song start when EQ or crossfeed was enabled). The vendored `libmpv.dylib` and `libfftools-ffi.dylib` from the fork build shipped with poisoned `LC_RPATH` entries pointing at a stale nix-store path for the audio-default FFmpeg variant (no bs2b, only equalizer filter). When the host binary's own `@rpath` failed to resolve, dyld fell through to the baked-in nix-store rpath and silently loaded the wrong `libavfilter.dylib`. Fix: rewrote every `@rpath/lib<sibling>.dylib` reference across all 16 `Vendor/libmpv/lib/*.dylib` to `@loader_path/lib<sibling>.dylib` and re-signed each dylib ad-hoc. Sibling-dylib resolution now bypasses rpath search entirely.
- Crossfeed Custom-mode numeric input rendering glitch where wider values (4-digit fcut like `1650`, 5-character feed like `12.00`) caused the rawText to render below the field's rounded-rect bezel instead of inside it. Root cause: the 56×18 frame from the prior `roundedBorder`-bezel fix was tuned for the original feed-only field (max 5 chars at small font); fcut Hz values pushed content past the inner padding and triggered a SwiftUI TextField vertical-baseline shift identical in symptom to the `roundedBorder` autosize bug fixed in `f526544`. Widened frame + pinned font removes the squeeze.

## [v0.7.2] - 2026-05-17

### Changed

- Hog mode now enforces 44.1 kHz on the output device. When exclusive ownership is confirmed, `HogModeController` reads the device's current nominal sample rate, stores it, and sets it to 44100 Hz (with a 50 ms CoreAudio settle). On release, the original rate is restored. Devices configured at 48 kHz or another rate in Audio MIDI Setup are automatically corrected for the duration of playback and left as-found on release. No new setting needed — rate enforcement is automatic whenever hog mode is on.

## [v0.7.1] - 2026-05-16

### Added

- Loading indicator in the play/pause button while a song downloads. The play/pause glyph is replaced with a small circular spinner inside the same outer circle, so the popover signals progress instead of looking frozen during the 0.5–3 s HTTP fetch. Covers initial play, channel change, long-idle cache-miss recovery, and skip-forward when the next song hasn't finished downloading yet.

### Changed

- `PlaybackCoordinator` gains a `.loading` state. Emitted at the top of `play(channelId:)` and reset to `.stopped` on throw. `MiniPlayerViewModel` adds an `isLoading` published flag; the errors stream clears it alongside `isPlaying`. `NowPlayingCenterController` and the AppContainer hog binder both treat `.loading` as a no-op.

### Fixed

- Spinner staying up for ~10 s after audio started after a channel change. `play(channelId:)` used to emit `.playing` only after awaiting the queue[1] download + `engine.queueNext`, so on slow networks the spinner outlasted the actual playback start by the full duration of the second song's HTTP fetch. State emission now fires immediately after `engine.play` returns; queue[1] download still runs inline-after but no longer gates the UI transition out of `.loading`.
- Skip-forward halting playback when queue[1] hadn't yet been queueNext'd into mpv's playlist. `skipForward` previously checked the in-memory queue and called `engine.advanceToQueued()`, but the inline queue[1] download + `engine.queueNext` runs AFTER `emitState(.playing)` — so a fast skip during the post-play download window hit an empty mpv playlist and stopped. New actor field `queueNextEventId: Int?` tracks what is actually queued in mpv (vs only in memory). When skipForward detects a mismatch, it emits `.loading`, awaits the download + `engine.queueNext`, then advances. Race-guards added to every queueNext site re-check `queue[1].eventId` after the actor-reentrant localFile await.

## [v0.7.0] - 2026-05-13

### Added

- Per-device crossfeed for headphone listening. Bauer-style (BS2B) via ffmpeg `crossfeed` filter, with two numeric stepper inputs (Strength + Range, each 0.00–1.00 in 0.05 increments) and a single hover-tooltip in Settings. Default OFF; tooltip explains use case, the parameter→Hz/dB mapping, and lists BS2B preset equivalents (BS2B Default / Chu Moy / Jan Meier). Composes with EQ orthogonally — chain order is locked as Preamp → EQ → Crossfeed inside the single `mpv af` filter chain. Diagnostic flag `RPSmoke --probe-filters` extended with a `crossfeed` assertion.
- Parametric EQ MVP. Per-device toggle plus preset library at `~/Library/Application Support/RP Player/EqPresets/`. Imports AutoEQ / Equalizer APO / REW `.txt` format (PK / LS / HS bands, up to 10, with Preamp). Strict parser — files with unsupported filter types, malformed lines, or more than 10 bands are rejected before save. Export writes the stored .txt verbatim. Delete prompts when other devices reference the preset and nil-outs their reference on confirm. Filter chain applied via libmpv `af` property using FFmpeg `lavfi=[volume,equalizer,lowshelf,highshelf,...]` graph. Diagnostic flag `RPSmoke --probe-filters` confirms the three filters are available in the vendored libmpv.

### Changed

- `AudioProfile` gains three flat per-device crossfeed fields: `crossfeedEnabled: Bool` (default false), `crossfeedStrength: Double` (default 0.15, ~Chu Moy 4.5 dB feed), `crossfeedRange: Double` (default 0.67, ~700 Hz cut — classical BS2B). Pre-PR-36 profiles migrate via `decodeIfPresent` defaults; the volume/hog binder's per-iteration write-back gains three `existing.crossfeed*` passthroughs so non-crossfeed settings changes don't silently wipe crossfeed state.
- `EqChainBuilder.build(_:) -> String?` split into `buildParts(_:) -> [String]` (no `lavfi=[...]` wrapper). The single production caller now wraps inline alongside the new `CrossfeedFilterBuilder.buildPart(strength:range:)` fragment.
- `AppContainer.runEqBinder` / `applyEqState` renamed to `runAudioFilterBinder` / `applyAudioFilterState`. The binder diffs a 5-tuple `AudioFilterKey` (eqEnabled / eqPresetName / crossfeedEnabled / crossfeedStrength / crossfeedRange) and emits a single `mpv af` write per change.
- `AudioProfile` gains `eqEnabled: Bool` (default false) and `eqPresetName: String?` (default nil). Pre-PR-35 profiles migrate via `decodeIfPresent` defaults; the existing per-device binder write-back path preserves both fields across other settings changes.
- `PlayerEngine` gains `setAudioFilterChain(_ chain: String?) async throws`. `MpvPlayerEngine` writes the `af` property (empty string clears the chain).
- Settings → Output device settings: replaces the "Force Max Volume" + "Apply ReplayGain" toggles with a 3-state Volume button row (`None` / `ReplayGain` / `Force Max`) matching the existing Appearance / Menu bar icon / Popover style row patterns (Button + `StableButtonStyle`). A single ⓘ hover tooltip sits to the left of the buttons (after the "Volume" label) covering both modes. Force Max button is disabled when Hog Mode is off (SwiftUI honors `.disabled` on `Button`, unlike `Picker(.segmented)`'s per-tag disable). Destructive-confirmation alert fires from the Force Max button's action handler on transition into Force Max. Bit-perfect lingo moves from the Hog row label to the Force Max section of the tooltip ("Bit-perfect when EQ is off").
- `AppSettings` + `AudioProfile`: replaces `forceMaxVolumeEnabled` + `applyReplayGainEnabled` bool pair with a single `volumeMode: VolumeMode` enum (`none` / `replayGain` / `forceMax`). Legacy JSON migrates automatically on first decode (Force Max wins on conflict). Encoded JSON omits the legacy keys.
- AppContainer audio-settings binder reads `volumeMode` directly. The dual-bool `effectiveRG = applyRG && !forceMax` collapses to `volumeMode == .replayGain` since the enum encodes mutual exclusion at the type level. The hog OFF→ON ground-truth check is demote-only: when device volume is below max but `volumeMode == .forceMax`, downgrades to `.none`. No longer silently promotes `.none → .forceMax` when the device happens to be at max — that bidirectional sync was a property of the old bool-toggle UI and is gone in the picker model.
- Safety-wipe sites (saved device missing at startup, device disappears at runtime) now clear `volumeMode` entirely to `.none`. The legacy code only cleared `forceMaxVolumeEnabled` and left `applyReplayGainEnabled` latently set — that's now fixed as a side effect of the model migration.

## [v0.6.2] - 2026-05-12

### Fixed

- Duplicate macOS notifications on every song change. The coordinator emits `NowPlaying` twice per song-start by design (synchronously from `play`/`skip`/`resume`/error-recovery so the UI doesn't wait for mpv, then again from `syncQueueHeadFromMpv` on `MPV_EVENT_START_FILE`). The UI is idempotent — art is keyed by cover path — but notifications were not: the request id format `<UUID>|<songId>` uses a fresh UUID per emission by design (so a replayed song generates a fresh notification instead of being collapsed by `usernoted`), which also meant the second emission for the same song produced a second visible banner. `NotificationCoordinator` now dedupes by `(channelId, eventId)`, preserving the replay-makes-fresh-notification semantics while killing the duplicate.
- Long-idle resume preserves the currently paused song. Resume after a multi-hour pause now `engine.resume()`s the cached, paused queue head (mpv's playlist still holds the queueNext'd queue[1]), then truncates the in-memory queue to `[queue[0], queue[1]]` and kicks a background `api/gapless` refetch. The merged response appends as the new tail (filter `eventId > queue.last!.eventId`), so playback catches up to the backend's current cursor at the queue[1]→queue[2] boundary instead of abruptly cancelling the user's song. Cache-miss for queue[0] (LRU eviction during pause) falls through to the legacy `clearPlaylist + refetch + restart` path. The double-resume race (user clicks play twice when audio doesn't start instantly because the old code blocked on the synchronous refetch) is gone — `engine.resume()` now returns essentially instantly.

### Removed

- PR 30's long-idle stall watchdog (`armLongIdleStallWatchdog`, `cancelStallWatchdog`, `waitForFirstPositionUpdate`, `logStallWatchdogTimeout`, `surfaceStallError` in `LivePlaybackCoordinator`; `stallWatchdog` field; `stallWatchdogTimeoutSeconds` constant; `sleep:` init param + `private let sleep` field; 7 `cancelStallWatchdog()` call sites across play / pause / stop / skipForward / changeChannel / shutdown / handlePlaybackError; `Tests/RPPlayerTests/Playback/LivePlaybackCoordinatorStallWatchdogTests.swift` file with inline `ControllableSleep` helper + 6 tests; `markQueueHeadPending` dead helper). The defense protected against mpv getting stuck on an HTTP `ffurl_read` after a long pause; with PR 32's local cache the resumed song is a `file://` URL, so the failure mode is unreachable. Historical rationale stays documented in the CLAUDE.md PR 30 entry for revival reference.

## [v0.6.1] - 2026-05-11

### Added

- **Sample-accurate gapless playback via pre-downloaded song files.** Each song from `api/gapless` is downloaded fully to disk under `~/Library/Application Support/RP Player/SongFileCache/` before being handed to mpv as a `file://` URL. Required because mpv's `prefetch-playlist=yes` only opens the next playlist entry's URL (TCP + HTTP headers) — it does NOT pull body bytes ahead of time (confirmed by the mpv maintainer in mpv#6437). Without pre-download every song boundary had ~100–500 ms of audible silence while mpv pulled the first bytes of the next file over HTTP. With pre-download the next file is fully on disk before its boundary arrives, so mpv only opens a local file at the boundary and the transition is sample-accurate.
- **Sequential, capped prefetch.** At most one outstanding download at a time; only the next 2 songs (queue[1] + queue[2]) are pre-fetched. Saves bandwidth and disk — previously the entire 20-song `api/gapless` response was being walked in background.
- **LRU cache cap of 10 files.** Oldest files evicted on every successful write. Switching to a previously-played channel reuses cached files (no re-download).
- **`SongFileCache.cancelInFlightDownloads()`** — releases network bandwidth immediately on channel-change / stop / bitrate change / shutdown. URLSession.data honors Task cancellation, so the underlying network stream actually stops streaming bytes (previously the in-flight downloads continued in the background after the coordinator cancelled, stealing bandwidth from the new channel's first song).
- **Album art prefetched 2 songs ahead** (was: 1 song ahead). Matches the song-file prefetch depth so the popover never shows a blank tile on skip.

### Changed

- **mpv baseline tweaks.** `gapless-audio=yes` (was: `weak` default — keeps the audio output device open across all song boundaries instead of close+reopen on any format mismatch). `demuxer-max-bytes` bumped 8 MiB → 32 MiB so a whole FLAC fits in the demuxer cache for snappier skip-forward.
- `LivePlaybackCoordinator` resolves every `engine.play` / `engine.queueNext` URL through `SongFileCache`. Falls back to the remote `gaplessUrl` on cache miss (network failure, disk error, `NoopSongFileCache`) so playback never breaks because of a download error.

### Fixed

- **Queue head matched against both remote URL and local file path.** With pre-downloaded files, mpv reports the local file path (`/Users/.../SongFileCache/<hash>.flac`) as its current path. The boundary-advance lookup used to only check `gaplessUrl` (remote URL), so every boundary advance fell back to queue[0]: the UI stayed stuck on the first song, telemetry kept reporting the first event id, and after two skips mpv exhausted its playlist (visible freeze). The coordinator now matches against both the remote URL and `cache.expectedLocalPath(for: song).path`.
- **In-flight downloads now actually cancel on channel-change.** Previously, cancelling the coordinator's `downloaderTask` cancelled the outer Task but the cache's inner `Task<URL?, Never>` kept running and `URLSession.data(from:)` kept draining bytes. Net effect: the new channel's first song shared bandwidth with the previous channel's now-irrelevant downloads, so first-song-start could take 3× longer than necessary. `cancelInFlightDownloads()` fixes this — bandwidth releases immediately.
- **Cache files no longer wiped on channel-change / stop / bitrate change.** Previously every cleanup path called `cache.clear()` — meaning a quick channel A → B → A round-trip re-downloaded every song. Now LRU eviction is the only deletion mechanism; channel changes only cancel in-flight downloads.

## [v0.6.0] - 2026-05-11

### Changed

- Migrated to Radio Paradise's new `api/gapless` endpoint. Each song now has its own self-contained file URL with its own duration and event id, so the coordinator carries a flat queue of song objects instead of stitching multi-song "blocks". Album art, song info and the URL travel as one unit — what's playing is identical to what's displayed by construction.
- Songs always start from the beginning. The server's tune-in offset (`cue`) is ignored on purpose — better to hear the full song; skip forward if you don't want it.
- Skip-forward jumps straight to the prefetched next song (no fetch round-trip when the queue is deep). Skip telemetry fires immediately so the backend cursor stays in sync.
- The Upcoming Program window now issues one API call per channel instead of stitching consecutive blocks.

### Fixed

- Channel-change after a long pause used to silently hang: mpv's `pause` property is global and persisted across the channel switch, so the new song loaded but never started playing. The engine now resets `pause=false` on every `engine.play(url:)`.
- After an unplayable song was dropped, the popover briefly displayed the wrong song (one ahead of audio). The coordinator now derives the currently-playing song from mpv's `path` property and dedupes redundant `MPV_EVENT_START_FILE` events, so the UI can never get out of sync with the audio.
- A song with `cue >= duration` (server cursor past song end) used to fail with mpv error `-16` and trigger the unplayable-song recovery path. With cue ignored, the song always plays from the start.

## [v0.5.3] - 2026-05-09

### Fixed

- Long-idle resume could leave the player stuck after a 4h+ pause: the new HTTP connection to the audio CDN sometimes stalls mid-stream after demuxer headers, leaving mpv silent until the user pause/plays manually. PR 30 adds a 10-second watchdog after the long-idle refetch — if no audio frames arrive in time the player retries once, and if a second timeout hits surfaces "Playback stalled. Try Pause/Play to recover."

## [v0.5.2] - 2026-05-08

### Changed

- Update panel renders the full release notes (was: truncated to 5 lines). Body is now scrollable and renders Markdown headings (`##`, `###`), bullet lists (`-`, `*`), and inline formatting (`**bold**`, `*italic*`, `` `code` ``). Panel grows to 460×540 to fit the longer body comfortably.

### Fixed

- Update panel line breaks were collapsed because `AttributedString(markdown:)` defaults to inline-only parsing. Replaced with a per-line renderer that splits on `\n`, treats blank lines as spacing, recognises heading + bullet prefixes, and applies inline Markdown to each line.

## [v0.5.1] - 2026-05-08

### Added

- `CHANGELOG.md` (this file). Release notes are now authored here and consumed by the GitHub Actions release job (replaces the auto-generated commit-list notes).

### Changed

- All panel-open paths now dismiss the popover "Update Available" button. Previously only the popover-button click dismissed; menu and Settings paths left the button visible until the next state propagation.
- Settings → Updates section moved between *Upcoming Program* and *Account*.

### Fixed

- Race in Settings → *Open Update…* that opened the panel with the stale cached release info while the version line raced ahead with the new one. The panel now reads the freshest `ReleaseInfo` directly from `UpdateChecker.currentState` after `checkNow` returns instead of going through the `MiniPlayerViewModel` published prop.

## [v0.5.1-rc.1] - 2026-05-08

Pre-release. Same content as v0.5.1; tagged for testing the prerelease filter in `UpdateChecker` (UpdateChecker excludes `prerelease == true` releases from the available-update notification).

## [v0.5.0] - 2026-05-08

### Added

- Update Checker. Automatic GitHub release polling on startup + every 24 hours; notify-only (the user clicks through to the `.dmg` download in the browser — no auto-install, no Sparkle).
- Settings → Updates section: toggle (default ON), *Check Now* / *Open Update…* button, *Last checked* + current-version status lines.
- Mini-player popover: "Update Available" button replaces "RP Player" text when an update is available; dismisses on click and stays dismissed until a higher release ships.
- Hamburger menu: sticky *Update Available…* item between *About* and *Quit*, visible until the running version matches the latest release.
- Update panel: title, relative published-at date, ~5-line markdown release-body preview, *Later* / *View Full Notes* / *Download DMG* buttons. Esc and outside-click dismiss.
- `AppSettings.updateCheckEnabled` (default `true`), `lastUpdateCheckAt`, `dismissedUpdateVersion`, `cachedLatestRelease` persisted across launches.
