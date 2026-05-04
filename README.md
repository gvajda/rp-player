# Radio Paradise bit-perfect macOS player

Optimized for macOS 14+

[Download the latest RP Player release](https://github.com/gvajda/rp-player/releases/latest)

[![build + tests](https://img.shields.io/github/actions/workflow/status/gvajda/rp-player/ci.yml?label=build%20%2B%20tests)](https://github.com/gvajda/rp-player/actions/workflows/ci.yml)
[![coverage](https://img.shields.io/codecov/c/github/gvajda/rp-player)](https://codecov.io/gh/gvajda/rp-player)
[![latest release](https://img.shields.io/github/v/release/gvajda/rp-player?label=latest%20release)](https://github.com/gvajda/rp-player/releases/latest)
[![license](https://img.shields.io/github/license/gvajda/rp-player?cacheSeconds=3600)](LICENSE)

## Summary

My goal was a tiny menu-bar [Radio Paradise](https://radioparadise.com/) player for macOS that actually plays the streams — bit-perfect to my DAC — and stays out of the way. The app drives the same `api/play` endpoint the official web player uses, so the channel order, song boundaries, and listener cursor match the web/mobile experience. Decoding goes through libmpv; output goes through CoreAudio in hog (exclusive) mode so other apps don't get to resample what reaches the DAC.

> **Disclaimer**\
> This is not an official Radio Paradise product. The Radio Paradise name and logo are owned by Radio Paradise. All displayed metadata and audio streams come from the public Radio Paradise REST API.

_Screenshot placeholder — popover with album art, ambient background, transport, channel picker._

## Getting started

The app ships as a notarisation-free `.app` bundle. Download `RP Player-<version>.zip` from the [Releases](https://github.com/gvajda/rp-player/releases/latest) page, unzip, and drag `RP Player.app` into `/Applications`.

**First launch:** macOS Gatekeeper blocks apps that aren't notarised. Right-click `RP Player.app` in Finder and choose **Open**, then confirm. Or, from a terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/RP Player.app"
open "/Applications/RP Player.app"
```

The app installs a status item in the menu bar (no Dock icon, no main window). Click the icon to open the mini player; right-click for the context menu. On first run all settings are at defaults (FLAC bitrate, hog mode on, system appearance) — no setup required to start listening.

## Features

### Playback

- **Plays every Radio Paradise channel**
  - Channel list fetched live from `api/list_chan`; new/removed channels appear automatically.
  - Includes the Favorites channel (`chan=99`) once you log in.
- **Every bitrate the API offers**
  - 32k / 64k / 128k / 320k AAC, 128k / 320k MP3, **FLAC** (default).
  - Selectable from Settings; takes effect on the next channel switch or block boundary.
- **Bit-perfect output via CoreAudio hog mode**
  - The app acquires the audio device exclusively (`kAudioDevicePropertyHogMode`) and feeds it the decoded sample stream untouched — no system mixer, no resampling.
  - Hog mode is opt-out in Settings if you'd rather share the device with other apps.
  - **Release on Pause** (default on): the device returns to shared use whenever you pause, so other apps and Mac calls work normally without quitting RP Player.
  - **Force Max Volume** (for external DACs): pins the device's CoreAudio volume to 100% and locks `volume-max` so no software attenuation is in the signal path. Confirmation alert before enabling — set your DAC/amp/headphone volume first.
  - **Apply ReplayGain** toggle (default off; force-max overrides it): per-track loudness normalisation when on, untouched audio when off.
  - Output device picker reads from `AudioDeviceCatalog`; refresh button next to the picker rescans on demand for newly paired Bluetooth or hot-plugged devices.
- **Behaviour matches the official player**
  - Bootstrap and advance both go through `api/play` with the personalised per-listener cursor, so the same blocks/songs play in the same order as the web player.
  - Cross-session resume: the backend remembers where you left off per channel. Restarting the app picks up where you stopped.
  - Telemetry endpoints (`update_history`, `update_pause`) keep the cursor accurate across pauses, skips, and song boundaries.

_Screenshot placeholder — Settings window: bitrate, output device, hog mode toggle._

### Mini player popover

- Album art at the top of the panel, edge-to-edge.
- Title / artist / album, current rating (★ N), live elapsed/remaining and a progress bar that updates per second.
- Transport: play–pause + skip-forward (skip respects the per-block song list and falls through to the prefetched next block).
- Channel picker centred under the controls; bitrate label to the right (verbatim from the API: "FLAC", "320k AAC", etc.).
- Hamburger menu with: Settings, Open Song in Browser, Upcoming Program, Floating Window, About, Quit.

### Floating window mode

- Toggle from the menu (right-click icon or in-popover hamburger). Item shows a checkmark when active.
- The popover detaches from the menu-bar anchor: stays visible across other-app interactions, joins all Spaces, and is draggable from any background area.
- Click anywhere to dismiss is disabled; toggle off (or close from the icon click) returns it to anchored mode.
- Setting persists across launches — turn it on once, the panel comes back on the next start.

### Hover tooltip on the menu-bar icon

- Hovering the icon (after a 300 ms delay) shows a two-line tooltip: "RP Player" plus a live `-mm:ss` countdown to the end of the current song.
- The countdown ticks every second while the cursor stays over the icon. No song playing → second line hidden.

_GIF placeholder — cursor hovering the menu-bar icon, countdown ticking down._

### Media keys + Control Center widget

- Hardware **Play/Pause** and **Next Track** keys on Mac and Bluetooth keyboards control the stream.
- macOS **Now Playing** widget (Control Center, lock-screen-style controls) shows current title/artist/album/artwork plus elapsed time, and reflects play/pause state.
- Previous-track and seek are intentionally disabled — Radio Paradise is forward-only.

### Right-click context menu

- Same items as the in-popover hamburger menu (sourced from one shared NSMenu builder).
- "Open Song in Browser" auto-disables when nothing is playing.
- "Upcoming Program…" opens the schedule window described below.
- "Floating Window" toggles the popover into draggable always-on-top mode (see below).

### Upcoming Program window

- Side-by-side columns, one per channel, each showing the next N songs (configurable in Settings).
- Each card has the album art, title, artist, album, and your personal rating if any.
- The currently playing channel's column is tinted with the accent colour and its title carries a glow.
- The currently playing song row gets an accent-colour border + glow if it's still in the loaded slice; if the data is stale the column highlight stays but the row glow doesn't appear.
- **Channel headers are clickable** — switching from this window changes the channel in the popover and on the engine. Songs are not interactable; pause/skip stay in the popover.
- Refresh button in the toolbar; "last updated" relative timestamp; channel filter for hiding channels you never browse (chan 42 + 99 are always excluded).
- Uses `api/play` (not `api/get_block`) so the upcoming list reflects the same personalised cursor as actual playback.

_Screenshot placeholder — Upcoming Program window with current channel highlighted._

### Album art + ambient background

- Album art is fetched from `img.radioparadise.com`, validated as a real image, and cached on disk (LRU, ~10 MB cap).
- The next song's art is **prefetched** as soon as it's known (within-block from the song list, across blocks from the prefetched next block), so the cover swap at song boundaries is instant — no blank tile.
- Optional **ambient background**: samples a representative colour from the bottom edge of the cover and fades the popover background between that colour and the system window colour. Toggle in Settings.

### Song rating

- ★ N picker in the title row. Disabled when signed out. Ratings POST to `api/rate` and update the local `userRating` immediately on success.
- Sign in via Settings → Sign in. The login window is a `WKWebView` pointed at the official login page; the auth cookies stay in the macOS Keychain.

### Notifications

- One macOS notification per song change (banner + tray entry) with cover thumbnail.
- Clicking a notification:
  - For the currently playing song → opens the popover.
  - For a song that finished playing recently → opens a small "past song" panel with the same metadata + rating row, so you can rate a track you only noticed after it ended.
- Toggle in Settings; needs the system notification permission granted on first launch.

### Resilience

- mpv occasionally fails to decode a block (e.g. some short promo `.m4a` files return `MPV_ERROR_NOTHING_TO_PLAY`). Instead of stalling the channel, the app advances past the bad block via `api/play` and tries the next one, up to a small retry budget. The cursor moves forward, the listener doesn't get stuck.
- Audio device unplug surfaces a clear banner ("Audio device unavailable…") and stops cleanly so re-plugging + clicking play recovers without a relaunch.

## Under the hood

### Audio pipeline

- **Decoder:** libmpv 0.36.0, vendored under `Vendor/libmpv/` (universal binaries via `media-kit/libmpv-darwin-build`).
- **Output:** mpv's plain `coreaudio` AO. The app does not use `coreaudio_exclusive` — it opens hog mode itself via `AudioObjectSetPropertyData` on `kAudioDevicePropertyHogMode` _before_ mpv opens the device, then hands the device back on shutdown. This avoids the format-negotiation failures observed on USB DACs (e.g. Qudelix-5K) when mpv tries to own exclusive mode itself.
- **Block-cued seek:** `loadfile <url> replace start=<seconds>` for the initial cue, instead of a post-`fileLoaded` seek, so the UI doesn't briefly show the cue position while the HTTP buffer is still catching up.

### Cookie-based authentication

If you sign in, the app stores the same session cookies your browser stores after a Radio Paradise login (`C_username`, `C_passwd`, `C_validated`, plus the session/PHPSESSID cookies needed by `api/rate`). Storage is the macOS Keychain.

> [!NOTE]\
> The app **does not store or log your password**. Only the cookies the browser sets are kept. Logging out from Settings deletes them.

### Files on disk

`~/Library/Application Support/RP Player/` contains:

- **`config.json`** — user-visible settings (selected channel, bitrate, hog mode, appearance, ambient toggle, upcoming row count, hidden channels, floating-window state, output device UID, etc.). Editing this file by hand is equivalent to changing the setting via the UI.
- **`Logs/RPPlayer.log`** — rotating log file (info-level by default; flip "Verbose logging" in Settings for full coordinator/engine traces).
- **`AlbumArtCache/`** — covers indexed by SHA-256 of the cover path. Capped at 100 files / 10 MB; oldest evicted on every write.

The Keychain account/service used for cookies is `com.gvajda.rpplayer`. Removing the app does not delete the keychain entry — use Settings → Sign out to clear it.

## About the project

Hobby project, deliberately small and macOS-native. Used to learn

- Swift 6 strict concurrency (actors, `@MainActor`, sendable closures, async streams)
- AppKit + SwiftUI interop (status item, borderless `NSPanel` panels hosting SwiftUI views)
- libmpv via the Swift C-interop layer
- CoreAudio HAL (device enumeration, hog-mode acquisition, format probing)
- the Radio Paradise REST API (block fetch, telemetry, info, rating)

This project supersedes the Windows tray app [RP_Notify](https://github.com/gvajda/radio-paradise-song-notification). Scope and architecture differences live in `docs/LEGACY.md`. The full design spec is `docs/DESIGN.md`.

### Build from source

Requires Xcode 16 / Swift 6.2 on macOS 14+.

```sh
swift build
swift test
swift run RPPlayer       # raw process; status item appears in the menu bar
scripts/make-app.sh      # produces a signed RP Player.app bundle
```

## License

MIT — see [`LICENSE`](LICENSE).
