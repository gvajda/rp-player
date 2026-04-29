# RP Player (macOS) — Design

**Status:** brainstorm-approved, ready for implementation planning **Date:** 2026-04-29 **Author:** Gergely Vajda + Claude (brainstorming session) **Predecessor:** [RP_Notify (Windows)](https://github.com/gvajda/radio-paradise-song-notification)

---

## 1. Goal & non-goals

**Goal.** Replace the official Radio Paradise desktop player on macOS with a menu-bar app that:

- plays Radio Paradise streams in **bit-perfect** mode (CoreAudio hog mode, integer-mode passthrough);
- shows rich desktop notifications on song changes (album art, title, artist, album, channel);
- lets the user **skip forward** within Radio Paradise's 4-song block API;
- lets logged-in users submit ratings (1–10) from the popover UI;
- ships as a single bundled `.app`, no external player dependencies.

**Non-goals.**

- No tracker mode — the app is the player. The Windows app's polling of external sessions (`api/nowplaying*`, `api/sync_v2`) is not ported.
- No third-party player integrations (foobar2000, MusicBee, MPD).
- No iOS / iPad / tvOS targets.
- No video, podcasts, or local library — strictly live channels via RP's block API.
- No skip-backward. RP's block API exposes only the current 4-song block, and the official RP players do not allow skip-back. This is intentional, by design.

## 2. Core decisions (locked during brainstorming)

| Decision                 | Choice                                                                                      | Rationale                                                                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Repo strategy            | New repository `rp-player`                                                                  | Mac app is a rewrite, not a port. Fresh CI, clean Swift project.                                                                 |
| "Exclusive mode" meaning | Bit-perfect — CoreAudio hog mode + integer mode                                             | Bypasses OS mixer; passes native sample rate / bit depth to DAC.                                                                 |
| Audio engine             | **libmpv** (LGPLv2.1, dynamically linked)                                                   | Supports HTTP streams + `audio-exclusive=yes` → CoreAudio integer mode. Proven by IINA. SFBAudioEngine rejected: file URLs only. |
| App scope                | In-app player only — no tracker mode                                                        | We control playback. Metadata comes from `api/get_block`.                                                                        |
| App shape                | Menu bar app with rich SwiftUI popover (mini-player)                                        | Matches "non-intrusive but detailed" goal of original app. No Dock icon.                                                         |
| Notification UX          | Info-only (no action buttons)                                                               | Click notification or status-bar icon to open popover for rating.                                                                |
| Notification subtitle    | "Album · Channel"                                                                           | Channel name visible at-a-glance, replaces the less-useful ratings count.                                                        |
| Rating UI                | 1–10 clickable buttons in popover                                                           | Granularity Mac notifications cannot easily host.                                                                                |
| Authentication           | Embedded `WKWebView` opening `radioparadise.com/account/sign-in`, scrape cookie post-login  | No password ever touches our process.                                                                                            |
| Cookie storage           | macOS Keychain                                                                              | Single entry, no plaintext on disk.                                                                                              |
| Distribution             | Unsigned `.app` from GitHub Releases (notarization deferred to v1.0; Homebrew Cask later)   | Hobby project. App Store is impossible — sandbox forbids hog mode.                                                               |
| App name                 | **RP Player**                                                                               | Descriptive; "RP" unambiguous to Radio Paradise listeners.                                                                       |
| Bundle ID                | `com.gvajda.RPPlayer`                                                                       | Reverse-DNS from GitHub username.                                                                                                |
| macOS minimum target     | macOS 13 Ventura                                                                            | Stable `MenuBarExtra` and modern SwiftUI APIs.                                                                                   |
| UI framework             | SwiftUI (popover + windows), AppKit (`NSStatusItem`, `WKWebView` host), C bridge for libmpv | Standard 2026 menu bar app pattern.                                                                                              |
| Settings storage         | JSON at `~/Library/Application Support/RP Player/config.json`, atomic write                 | Explicit, debuggable. Replaces the Windows INI.                                                                                  |
| Default stream bitrate   | `bitrate=4` (FLAC, highest)                                                                 | Matches bit-perfect goal.                                                                                                        |
| Album art cache          | LRU on disk, 20 files / ~10 MB                                                              | Mirrors Windows behavior.                                                                                                        |
| Logging                  | Apple `Logger` (os_log) + rotating file sink, max 10 files × 1 MB                           | Mirrors Windows; Mac-native primary.                                                                                             |
| Volume control           | mpv software volume **off** by default; user can opt in                                     | Bit-perfect = hardware volume only.                                                                                              |
| Audio output device      | User-selected from CoreAudio device list; persisted by `kAudioDevicePropertyDeviceUID`      | Bit-perfect requires explicit device choice; built-in / Bluetooth / AirPlay shown but de-emphasized.                             |
| libmpv build             | Slim CI build from mpv source, bundled in `Vendor/libmpv/` — no Homebrew dependency         | Self-contained `.app`; no risk of upstream Homebrew breakage.                                                                    |

## 3. High-level architecture

```
                ┌─────────────────────────────────────────────────────┐
                │  AppKit shell                                       │
                │  • NSStatusItem (menu bar icon)                     │
                │  • NSPopover hosting SwiftUI MiniPlayerView         │
                │  • WKWebView in NSWindow for login                  │
                └────────────────────────┬────────────────────────────┘
                                         │
   ┌──────────────────┬──────────────────┼──────────────────┬───────────────┐
   ▼                  ▼                  ▼                  ▼               ▼
┌────────┐      ┌────────────┐     ┌────────────┐    ┌─────────────┐  ┌──────────┐
│Player  │◀─────│PlaybackCoor│────▶│ RpApiClient│    │NotificationC│  │AlbumArt  │
│Engine  │      │dinator     │     │            │    │enter        │  │Cache     │
│(libmpv │      │            │     │            │    │             │  │          │
│ wrap)  │      └────────────┘     └────────────┘    └─────────────┘  └──────────┘
└────────┘             │
                       ▼
                ┌────────────┐    ┌────────────┐    ┌─────────────┐
                │ConfigStore │    │KeychainAuth│    │   Logger    │
                │(JSON file) │    │            │    │ (os_log +   │
                │            │    │            │    │  rotating)  │
                └────────────┘    └────────────┘    └─────────────┘
```

Each unit lives behind a Swift `protocol`. Wiring is explicit constructor injection assembled in `AppContainer`. No DI framework — the project is small enough that an 80-line composition root reads better than indirection.

## 4. Module breakdown

| Module                      | Responsibility                                                                                                                                                                                                                                                                               |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PlayerEngine`              | Wraps `libmpv` (C API) in a Swift `actor`. Commands: `play(url:)`, `pause`, `resume`, `stop`, `seek(to:)`, `setHogMode(_:)`, `setOutputDevice(uid:)`. Publishes state via `AsyncStream<PlayerEvent>` (positionUpdate, fileEnded, error, hogModeChanged, outputDeviceChanged).                |
| `AudioDeviceCatalog`        | Lists CoreAudio output devices (name, UID, transport type). Watches `kAudioHardwarePropertyDevices` for hot-plug changes and emits updates via `AsyncStream<[AudioDevice]>`. Used by `SettingsView` for the device picker.                                                                   |
| `PlaybackCoordinator`       | Owns the active session: current channel, current block, song-within-block index. Drives `PlayerEngine`. Implements `skipForward` and `changeChannel`. Emits `NowPlaying` updates via an `AsyncStream`. Prefetches the next block before the current one ends to enable gapless transitions. |
| `RpApiClient`               | Async Swift client for `api/list_chan`, `api/get_block`, `api/info`, `api/rating`, `api/auth-state`. Reads cookie from `KeychainAuth`. Decodes via `Codable`.                                                                                                                                |
| `KeychainAuth`              | Stores RP cookie blob in Keychain. Provides cookie for HTTP requests. Knows whether user is logged in.                                                                                                                                                                                       |
| `LoginWindow`               | `WKWebView` opening `radioparadise.com/account/sign-in`. After successful login, reads `WKWebsiteDataStore` cookies and hands them to `KeychainAuth`.                                                                                                                                        |
| `NotificationCenterWrapper` | Posts `UNNotification` on song-start. No actions. Title = "Artist — Title", subtitle = "Album · Channel". Attaches album art from `AlbumArtCache`.                                                                                                                                           |
| `AlbumArtCache`             | LRU on disk in `Application Support/RP Player/AlbumArtCache`, max 20 files / 10 MB. Async `image(for songId:)`.                                                                                                                                                                              |
| `ConfigStore`               | JSON file at `Application Support/RP Player/config.json`. Observable settings: selected channel, hog mode on/off, software volume on/off, notifications on/off, log level, output device UID. Atomic write.                                                                                  |
| `MiniPlayerView` (SwiftUI)  | Album art, song title/artist/album, channel name, play/pause, **skip-forward only**, 1–10 rating row, channel switcher, settings link.                                                                                                                                                       |
| `SettingsView` (SwiftUI)    | Audio (output device picker with bus-type labels, hog mode, software volume, bitrate), notifications toggle, account (login/logout), data folder, logs button.                                                                                                                               |
| `Logger`                    | Wrapper over Apple `Logger` (os_log) plus rotating file sink. 10 files × 1 MB.                                                                                                                                                                                                               |
| `AppContainer`              | Composition root. Builds singletons, wires dependencies, owns the long-lived `PlaybackCoordinator`.                                                                                                                                                                                          |

## 5. Data flow — typical session

1. User clicks the status bar icon. The popover opens. `MiniPlayerView` reads from `PlaybackCoordinator.nowPlayingPublisher`.
2. User clicks Play. `PlaybackCoordinator` calls `RpApiClient.getBlock(channel: 0, bitrate: 4)`. The response yields `{url, songs: [s1..s4], cue, expiration, image_base}`.
3. Coordinator tells `PlayerEngine` to `play(url: block.url)`. The engine selects the user-configured output device (by UID), sets hog mode, opens the URL via libmpv, and starts playback. If no device is configured or the saved UID is no longer present, playback is blocked and the popover prompts the user to pick one in Settings.
4. Coordinator tracks the song boundary using `block.songs[i].duration` plus libmpv's reported position. On boundary, advance `currentSongIndex`, fetch `api/info` for richer detail, emit a fresh `NowPlaying`.
5. `NotificationCenterWrapper` posts a `UNNotification` with album art (fetched via `AlbumArtCache`).
6. When `currentSongIndex == 3` and time-to-end < 10 s, coordinator prefetches the next block. On end-of-file from `PlayerEngine`, swap URL → seamless transition.
7. **Skip forward**: coordinator computes the next song's start offset within the block and calls `PlayerEngine.seek(to:)`. If user skips past the last song, immediately fetch the next block and play from song 1.
8. **Channel switch**: coordinator stops the engine, fetches a fresh block for the new channel, plays. The old block is discarded.
9. **Rate**: user clicks 7/10 in the popover → `RpApiClient.rate(songId: current.id, value: 7)`. UI updates the rating immediately on success.

## 6. Bit-perfect playback

### 6.1 libmpv configuration

The intent is "no resampling, no format conversion, no extra processing — decode the FLAC and hand it to the device." Concrete settings:

- `audio-exclusive=yes` — engages CoreAudio hog mode.
- `audio-device=coreaudio_exclusive/<UID>` — locks playback to the user-selected device (see 6.2).
- `audio-format` and `audio-samplerate` are **left unset / auto** so libmpv negotiates the device's physical format to match the source. Forcing either one would defeat bit-perfect.
- `audio-channels=auto` — same reason, no channel remapping.
- `audio-pitch-correction=no` — no time-stretching.
- Software volume off (`volume-max=100`, internal volume control disabled) unless user explicitly opts in via Settings.

We deliberately do **not** set `audio-resample-mode`. That option only takes effect when libswresample resamples — a quality knob for the resampler. In a bit-perfect chain resampling never runs, so setting it is meaningless and including it in the config implies otherwise.

`bitrate=4` from `get_block` returns the FLAC stream URL. Decoded by libmpv, passed at native sample rate / bit depth to CoreAudio integer mode on the hogged device.

### 6.2 Audio device selection

Bit-perfect output requires the user to pick the right output device — typically an external USB DAC, S/PDIF interface, or HDMI receiver. Hog mode on built-in speakers, AirPlay endpoints, or Bluetooth headphones is **either pointless or actively broken**:

- **Bluetooth** — audio is re-encoded into the BT codec (SBC / AAC / aptX / LDAC) before transmission, so "bit-perfect" is impossible regardless of CoreAudio mode. Hog mode tends to fail or behave erratically.
- **AirPlay** — same issue (lossy or lossless re-encode at the AirPlay layer), and hog mode is unsupported by the AirPlay output endpoint.
- **Built-in speakers / built-in headphone jack** — works but defeats the purpose; users running RP Player almost certainly have an external DAC.

UI:

- Settings → Audio → "Output device" dropdown lists CoreAudio output devices via mpv's `audio-device-list` property (or directly via `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices, …)`).
- For each device, show the name and the bus type label (USB / Thunderbolt / HDMI / Built-in / Bluetooth / AirPlay). Bus type comes from the `kAudioDevicePropertyTransportType` selector.
- Devices with transport type `Bluetooth`, `AirPlay`, or `Built-in` are listed but visually de-emphasized and tagged "(not recommended for bit-perfect)". They are not blocked — power users may want to test.
- Selection persists in `ConfigStore` as the device's `kAudioDevicePropertyDeviceUID` (a stable string), not the index — the index changes when devices are plugged/unplugged.
- On launch, if the saved UID is not found, the dropdown shows "Select an output device" and playback is disabled until one is chosen.

### 6.3 Stop / release behavior

On `stop`, libmpv releases the audio device. Other apps can immediately use it (the "Tidal-like" behavior).

## 7. Error handling

- **Network failures on**`get_block`: retry 3× with exponential backoff. After exhaustion, surface a banner in the popover and stop playback.
- **libmpv errors / hog-mode acquisition fail**: fall back to shared mode, surface a one-time toast: "Bit-perfect unavailable on this device — playing in shared mode." Continue playing.
- **Auth expired** (cookie invalid → API returns anonymous): clear keychain entry, show popover banner: "Logged out — sign in again to rate."
- **Disk full / cache write fail**: log, skip caching, continue.
- **Block expiration during pause**: on resume, if `block.expiration` has passed, fetch a fresh block and start from song 1 of the new block (the user effectively gets a new 4-song window — unavoidable, RP API limitation).
- All errors logged via `Logger`. No fatal crashes from RP API or audio path.

## 8. Testing strategy

- `RpApiClient` — unit-tested with `URLProtocol` stub returning canned JSON fixtures from `RpApiFixtures/*.json`. Capture real RP API responses once and freeze them.
- `PlaybackCoordinator` — unit-tested with mock `PlayerEngine` and mock `RpApiClient`. Cover skip logic, block prefetch, channel-switch, expiration recovery.
- `PlayerEngine` — manual integration test: play a known channel, verify song advances and skip works on a real DAC.
- No UI snapshot tests in v1; SwiftUI views are kept thin enough that bugs surface visually.

## 9. Repo layout (new repo `rp-player`)

```
rp-player/
├── Package.swift                  SwiftPM exec target + libmpv binary dep
├── Sources/
│   └── RPPlayer/
│       ├── App/                   AppDelegate, AppContainer, StatusItem
│       ├── Player/                PlayerEngine, libmpv bridging
│       ├── Playback/              PlaybackCoordinator, NowPlaying model
│       ├── Api/                   RpApiClient, response models
│       ├── Auth/                  KeychainAuth, LoginWindow
│       ├── Notifications/         NotificationCenterWrapper
│       ├── Cache/                 AlbumArtCache
│       ├── Config/                ConfigStore
│       ├── Logging/               Logger
│       └── UI/                    MiniPlayerView, SettingsView, RatingRow
├── Tests/
│   └── RPPlayerTests/
│       ├── Fixtures/              *.json from real RP API
│       ├── ApiTests/
│       └── PlaybackTests/
├── Resources/
│   ├── AppIcon.iconset/
│   └── StatusBarIcon.png
├── Vendor/
│   └── libmpv/                    bundled libmpv.dylib (LGPL, dynamic)
├── docs/
│   ├── DESIGN.md                  copy of this spec
│   └── LEGACY.md                  pointer to Windows repo + scope diff
├── .github/workflows/build.yml    macos-14 runner, xcodebuild + zip .app
├── README.md
├── LICENSE                        MIT
└── .gitignore
```

## 10. Risks & open items

- **libmpv binary distribution.** Build a slim `libmpv.dylib` in CI from mpv source for both `arm64` and `x86_64`, then ship it in `Vendor/libmpv/`. We do **not** depend on Homebrew at install time — the `.app` must be self-contained. The CI step is documented in the implementation plan; rough shape: a separate workflow that compiles libmpv with the minimum set of decoders we need (FLAC, AAC, MP3) and the CoreAudio output drivers, then commits the resulting `.dylib` (or publishes it as a workflow artifact pulled by the main build). Open question to resolve during implementation: whether to commit the binary into `Vendor/libmpv/` (simpler but bloats git history) or fetch it from a pinned release tag (more complex but cleaner repo).
- **Hog mode reliability.** Hog mode has historically had quirks with Bluetooth and AirPlay devices on macOS. Mitigation: device-selection UI surfaces this (see 6.2), the shared-mode fallback (see 7) catches the rest, and manual testing covers a real USB DAC plus a Bluetooth headphone to verify both paths.
- **Block expiration on long pause.** Documented in error handling. The user simply gets a new 4-song window after a long pause. We will not attempt to bridge it.
- **First-launch login UX.** On first launch, show a one-time, dismissible banner in the popover prompting the user to sign in (rating requires it). No modal interruption.

---

## 11. Bootstrapping the new repo

Steps to start the Swift project. The intent is for an AI coding agent (or human) to be able to start work in the new repo with full context.

### 11.1 Files to carry over from this Windows repo

Copy these into the new `rp-player` repo at bootstrap time:

| Source (this repo)                                          | Destination (new repo)              | Why                                                                                                                            |
| ----------------------------------------------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `docs/superpowers/specs/2026-04-29-rp-player-mac-design.md` | `docs/DESIGN.md`                    | Canonical design — the new project's source of truth.                                                                          |
| `README.md`                                                 | `docs/LEGACY_README.md`             | Original feature descriptions, screenshots references. Useful when implementing notifications, popover content, settings list. |
| `RP_Notify/RpApi/RpApiResponseModel.cs`                     | `docs/legacy/RpApiResponseModel.cs` | Reference for `Codable` model shapes — names + types map nearly 1:1 to Swift.                                                  |
| `RP_Notify/RpApi/IRpApiClient.cs` and `RpApiClient.cs`      | `docs/legacy/RpApiClient.cs`        | Exact endpoint paths and parameter conventions, useful even though we drop tracker endpoints.                                  |
| `RP_Notify/Resources/config.ini`                            | `docs/legacy/config.ini`            | Default-settings reference. The Mac config.json mirrors most of these keys.                                                    |
| `.screenshots/*.gif`                                        | (skip)                              | Out of date for Mac UI; new screenshots will be taken from the Mac app.                                                        |

A new `docs/LEGACY.md` is written from scratch in the new repo. It should:

- link to this Windows repo (`https://github.com/gvajda/radio-paradise-song-notification`);
- summarize the scope diff (no tracker mode, no foobar2000/MusicBee, in-app player added, skip-forward added, bit-perfect added);
- declare the design doc (`docs/DESIGN.md`) as the source of truth for the new project.

### 11.2 Initial repo setup commands

Run these on the host that will hold the new repo. The `gh` CLI assumes the user is logged in.

```bash
# 1. Create the new repo locally
mkdir -p ~/git/rp-player
cd ~/git/rp-player
git init -b main

# 2. Scaffold the Swift project
swift package init --type executable --name RPPlayer
mkdir -p Sources/RPPlayer/{App,Player,Playback,Api,Auth,Notifications,Cache,Config,Logging,UI}
mkdir -p Tests/RPPlayerTests/{Fixtures,ApiTests,PlaybackTests}
mkdir -p Resources Vendor/libmpv docs/legacy .github/workflows

# 3. Carry over the legacy reference material from the Windows repo
cp ~/git/radio-paradise-song-notification/docs/superpowers/specs/2026-04-29-rp-player-mac-design.md docs/DESIGN.md
cp ~/git/radio-paradise-song-notification/README.md docs/LEGACY_README.md
cp ~/git/radio-paradise-song-notification/RP_Notify/RpApi/RpApiResponseModel.cs docs/legacy/
cp ~/git/radio-paradise-song-notification/RP_Notify/RpApi/IRpApiClient.cs docs/legacy/
cp ~/git/radio-paradise-song-notification/RP_Notify/RpApi/RpApiClient.cs docs/legacy/
cp ~/git/radio-paradise-song-notification/RP_Notify/Resources/config.ini docs/legacy/

# 4. Author docs/LEGACY.md (see template in this section)

# 5. Standard files
cat > .gitignore <<'EOF'
.build/
.swiftpm/
*.xcodeproj/
DerivedData/
.DS_Store
.superpowers/
Vendor/libmpv/*.dylib
EOF

# Write the MIT LICENSE file using the standard template
# (replace YEAR and HOLDER, e.g. "2026 Gergely Vajda")
# Template: https://opensource.org/license/mit

# 6. First commit
git add -A
git commit -m "chore: scaffold RP Player (Swift menu-bar app for Radio Paradise)

Bootstrapped from design doc: docs/DESIGN.md
Predecessor: github.com/gvajda/radio-paradise-song-notification"

# 7. Create remote and push
gh repo create gvajda/rp-player --public --source=. --remote=origin --description "Bit-perfect Radio Paradise player for macOS — menu bar app with notifications and song rating"
git push -u origin main
```

### 11.3 Starting prompt for an AI coding agent

Use this prompt verbatim when opening the first session in the new repo. It points the agent at the design and the legacy references without overwhelming it with full source files.

```
This is a fresh Swift menu-bar macOS app called RP Player. It is a rewrite-and-rescope of an older C# Windows app that lived at github.com/gvajda/radio-paradise-song-notification.

Read the following before doing anything else, in this order:

1. docs/DESIGN.md — the source of truth for this project. Locked decisions are in section 2; the architecture is in sections 3-5.
2. docs/LEGACY.md — short pointer to the predecessor and the scope diff.
3. docs/legacy/RpApiResponseModel.cs — only as a Codable shape reference for the new Swift response models.
4. docs/legacy/RpApiClient.cs — only for endpoint paths, parameter names, and the Set-Cookie handling on api/auth.
5. docs/LEGACY_README.md — to understand the feature intent (notifications visuals, rating semantics, settings layout).

Do not port the Windows code line-by-line. The Mac app is structurally different: in-app player using libmpv + bit-perfect (CoreAudio hog mode), no tracker mode, no foobar2000/MusicBee integrations, skip-forward only.

Project conventions:
- Swift 5.9, macOS 13 minimum, SwiftUI for views, AppKit for NSStatusItem and the WKWebView login window.
- libmpv is dynamically linked from Vendor/libmpv/libmpv.dylib. A C bridging header lives in Sources/RPPlayer/Player/.
- Constructor injection only. No DI framework. AppContainer in Sources/RPPlayer/App/ wires everything.
- Each module is a folder under Sources/RPPlayer/. Each public type lives behind a protocol.
- Tests use URLProtocol fixtures for the API client and mock protocols for the playback coordinator.
- Logs go through Logging/Logger. Settings persist as JSON under Application Support/RP Player.

Before writing any code, propose an implementation plan that breaks the work into small, independently-testable PR-sized chunks. Get approval on the plan before implementing.
```

### 11.4 First implementation milestones (rough order, to be expanded by the implementation plan)

1. CI workflow that builds a slim `libmpv.dylib` from mpv source for `arm64` + `x86_64` and emits the binary as an artifact (or commits it into `Vendor/libmpv/`). Decision on commit-vs-artifact taken here.
2. SwiftPM scaffold + libmpv dylib vendoring + a "smoke test" CLI target that opens libmpv against the system default output device, plays a hard-coded RP block URL, prints position events, exits cleanly. Validates the audio path before any UI.
3. `RpApiClient` (no auth) — `list_chan`, `get_block`, `info`, against fixtures.
4. `AudioDeviceCatalog` — list CoreAudio output devices with name, UID, transport type. Hot-plug observation.
5. `PlayerEngine` (Swift actor wrapping libmpv) with hog-mode toggle, output-device selection, and event stream.
6. `PlaybackCoordinator` orchestrating client + engine, with skip-forward and gapless block prefetch.
7. AppKit shell — `NSStatusItem` + empty `NSPopover` hosting a SwiftUI placeholder.
8. `MiniPlayerView` reading from coordinator, play/pause/skip/channel switcher.
9. `NotificationCenterWrapper` + `AlbumArtCache`.
10. `KeychainAuth` + `LoginWindow` (`WKWebView`) + rating submission.
11. `SettingsView` (output device picker, hog mode, software volume, bitrate, account, notifications, logs) + persistence via `ConfigStore`.
12. App-distribution CI workflow on `macos-14` — builds + zips the `.app`, attaches to GitHub Releases on tag push.

Each milestone is a separate PR. Tests written alongside the module they cover.
