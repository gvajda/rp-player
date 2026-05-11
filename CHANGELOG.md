# Changelog

All notable changes to RP Player are listed here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Section labels: `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`. Only include the sections that apply.

## [Unreleased]

### Fixed

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
