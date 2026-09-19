# PR 12 — Smoke fixes + UI polish design

**Date:** 2026-05-01
**Branch target:** new sibling worktree `claude/pr12-polish` against `main` (post-PR-11 HEAD `113ad34`).
**Status:** spec, awaiting user review before plan generation.

The original PR 12 ("Distribution CI workflow") shifts to PR 13. This PR fixes two bugs + lands six UI/UX polish items the user asked for after PR 11.

---

## Goals

**Bugs**

1. **Stale track info / pause handling.** Title / artist / album / album art sometimes shows the wrong song. Block timing (not the `nowPlaying` API) is what we use, so the bug must live in `BlockSongs.indexOfSong` lookup, the cue-offset bookkeeping during prefetch swap, block-expiration recovery on resume, or the album-art cache key flow. Diagnose first, fix at root cause.
2. **Hog mode acquisition fails on user's USB DAC** even though other macOS players do bit-perfect on the same device. Investigation is bounded: try the three hypotheses recorded in PR 10's plan doc (mpv format-negotiation timing, audio-device set ordering, IINA recipe diff). If three concrete attempts don't land it, document the captured mpv error log and defer.

**UI / UX**

3. **`rp.ico` as menu-bar icon.** User dropped the file in the worktree root. Move it into the repo as a SPM resource and load it via `NSImage(contentsOfFile:)`, set as `statusItem.button.image`. Not template — keep colors.
4. **Tighter popover margins.** Current padding is roughly `16pt`. Drop to `12pt` outer, with `12pt` between major sections, `4pt` within tightly-coupled groups.
5. **Album art 318×318.** Currently smaller. Match the rating bar's measured 318 pt width.
6. **Live stream bitrate.** Display under the channel picker. Sourced from mpv (`audio-bitrate` + `audio-params/codec` + `audio-params/samplerate`), not the user's `bitrate` setting. Updates after each `fileLoaded`.
7. **Layout E.** Vertical stack: album art → title/artist/album → channel-picker + bitrate + gear (single row) → rating bar → play/pause + forward → "RP Player" centered wordmark footer.
8. **App name in Settings window title.** Currently the title bar may be empty / generic. Set to `"RP Player Settings"`.

---

## Files added / moved / modified

| Path                                                            | Status   | Purpose                                                                                  |
| --------------------------------------------------------------- | -------- | ---------------------------------------------------------------------------------------- |
| `Resources/rp.ico` *(or `Sources/RPPlayer/Resources/rp.ico`)*   | new      | Menu-bar icon asset, declared in `Package.swift` `resources:`                            |
| `rp.ico` (repo root)                                            | deleted  | Move into resources folder                                                               |
| `Package.swift`                                                 | modified | Add `resources: [.process("Resources")]` to `RPPlayer` target                            |
| `Sources/RPPlayer/Player/PlayerEngine.swift`                    | modified | Add `case streamFormatChanged(StreamFormat)` to `PlayerEvent`; add `StreamFormat` struct |
| `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`              | modified | Read `audio-bitrate` / `audio-params/codec` / `audio-params/samplerate` after fileLoaded; emit `streamFormatChanged` |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`           | modified | Forward `streamFormatChanged` into `nowPlayingUpdates`'s payload (or new stream)         |
| `Sources/RPPlayer/Playback/NowPlaying.swift`                    | modified | Optional `currentStreamFormat: StreamFormat?` field                                      |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`              | modified | New `@Published var currentStreamFormat: StreamFormat?`                                  |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift`                   | modified | Layout E rewrite: 318 pt album art, tighter spacing, gear next to channel picker, footer wordmark, bitrate label |
| `Sources/RPPlayer/Shell/StatusItemController.swift`             | modified | Load `rp.ico` from bundle and set as `statusItem.button.image`                           |
| `Sources/RPPlayer/Shell/SettingsWindowController.swift`         | modified | Set window title to `"RP Player Settings"`                                               |
| `Sources/RPPlayer/Playback/BlockSongs.swift` (or coordinator)   | modified (likely) | Bug 1 fix — TBD by investigation                                                |
| `Sources/RPPlayer/Player/LibmpvPlayerEngine.swift`              | modified (maybe)  | Bug 2 fix — TBD by hypothesis ordering                                          |
| `Tests/RPPlayerTests/...`                                       | additions / modifications | Each bug fix gets a regression test; layout changes verified via existing snapshot tests where possible |
| `CLAUDE.md`                                                     | modified | Mark PR 12 merged, post-PR-12 test count, update PR 13 entry to "Distribution CI workflow" |

The `Package.swift` resource declaration is required because SPM doesn't auto-pick up non-Swift assets even with implicit globbing. We'll use `.process("Resources")` so SPM compiles the asset into the bundle correctly.

---

## Bug 1 — stale track info: investigation plan

**Hypotheses ranked by likelihood (informed by code reading, not yet verified):**

1. **Cue offset not reset on prefetch swap.** `LivePlaybackCoordinator.play(channelId:)` sets `pendingCueSeekSeconds = block.cue > 0 ? Double(block.cue) / 1000.0 : nil` so the first block plays from its real start. `swapToPrefetchedBlockIfAvailable` may not reset `pendingCueSeekSeconds` (or `currentSongIndex` / `startsAt`) — meaning the second block uses stale lookup tables.
2. **Block expiration during long pause.** Per DESIGN.md §7 the coordinator should refetch a fresh block on resume if `block.expiration` has passed. Verify the resume path checks expiration; if not, implement.
3. **Album art cache stale key.** `LiveAlbumArtCache` keys files by SHA-256 of `coverPath`. If two consecutive songs share the same cover path (frequent — same album), the cached image is reused — that's correct. But if `MiniPlayerViewModel` doesn't clear the displayed image when `nowPlaying.cover` is nil between songs, the previous song's art lingers.
4. **`indexOfSong(at:in:)` boundary off by one.** Worth a sanity check — does it return `n` for `position == startsAt[n]` exactly, or `n-1`?

**Diagnosis approach:** before writing any fix, dispatch a research subagent to map the actual coordinator + cache flow end-to-end. Output: a short report identifying which of the four hypotheses is the cause, with file:line evidence. Then write a regression test that reproduces the symptom and apply the minimal fix.

If the cause turns out to be something not in the hypotheses (5th option), the research report becomes the input to a follow-up planning round.

---

## Bug 2 — hog mode on USB DAC: bounded investigation

User reports: their DAC accepts exclusive-mode bit-perfect from other macOS players (e.g., Audirvāna, Roon, IINA), but RP Player's mpv `coreaudio_exclusive` AO emits `Failed to initialize audio driver 'coreaudio_exclusive'` / `hardware format not supported` and falls back.

**Bounded budget:** three concrete attempts. Each attempt = one engine-level change + one smoke run by the user with `RPPlayer.log` capture. If attempt 3 still fails, freeze the captured logs into `docs/notes/hog-mode-investigation-2026-05-01.md` and defer.

**Attempts in order:**

1. **Set `audio-device` BEFORE `mpv_initialize` rather than after.** Today, `LibmpvPlayerEngine.init` calls `mpv_initialize` first, then a follow-up `setOutputDevice(uid:)` from the ConfigStore binder writes `audio-device`. mpv may negotiate the device's mixer-mode format on init when `audio-device` is `auto`, then fail to flip the AO to exclusive cleanly. Fix: read the persisted device UID from `JSONConfigStore` synchronously inside the engine init (or inject a `bootstrapDeviceUID:` parameter) and pass it via `mpv_set_option_string("audio-device", "coreaudio_exclusive/<UID>")` BEFORE `mpv_initialize`.
2. **Explicitly pre-set `audio-format` / `audio-samplerate` to match the FLAC stream.** mpv at the AO-open moment may not know the source's native rate yet; passing `--audio-samplerate=44100 --audio-format=s16` (the typical RP FLAC native format) up front lets `coreaudio_exclusive` ask the DAC for that exact rate. If the DAC supports 44.1 kHz exclusive, this should land.
3. **Diff against IINA's `mpv.conf`.** IINA ships a known-good config for hog mode on macOS. Pull their relevant `audio-*` properties and apply ours.

**Out of scope for this PR:** a full refactor of the audio pipeline. If three attempts don't crack it, the deferral is honest.

---

## UI plumbing — live bitrate

**Engine** (`LibmpvPlayerEngine`):

- After receiving `MPV_EVENT_FILE_LOADED` (which is what fires `PlayerEvent.fileLoaded` today), read three properties and emit a new event:
  - `audio-bitrate` — Double (bits per second). Convert to kbps via `/1000`.
  - `audio-params/codec` — String, e.g. `"flac"`, `"mp3"`, `"aac"`.
  - `audio-params/samplerate` — Int, e.g. `44100`.
- Build a `StreamFormat(codec: String, sampleRateHz: Int, kbps: Double?)` and emit `PlayerEvent.streamFormatChanged(StreamFormat)`.
- The lookup must guard against `mpv_get_property` returning negative status (codec sometimes resolves slightly after `fileLoaded`); retry once after a short delay if any property is unavailable.

**Coordinator** (`LivePlaybackCoordinator`):

- New private `currentStreamFormat: StreamFormat?` property.
- On `streamFormatChanged`, store and re-emit through `nowPlayingUpdates` so the UI sees it without a parallel stream.

**`NowPlaying`** model: add `let streamFormat: StreamFormat?`. Default `nil` for back-compat.

**View model** (`MiniPlayerViewModel`):

- New `@Published private(set) var currentStreamFormat: StreamFormat?` mirroring `nowPlaying.streamFormat`.

**View** (`MiniPlayerView`): display string under channel picker:

```
Main Mix · FLAC 44.1 kHz
Main Mix · MP3 320 kbps
```

Or, since the channel picker shows the channel name already, the bitrate row reads:

```
FLAC 44.1 kHz
```

with the codec / format primary, the kbps secondary when known. Color: `secondaryLabelColor` for the codec line, smaller font (11 pt, monospaced digits).

**Format helper:** `StreamFormat.displayString` — `"FLAC 44.1 kHz"` for FLAC, `"MP3 \(kbps) kbps"` for MP3, `"\(codec.uppercased()) \(rate) Hz"` fallback.

---

## Layout E — concrete spec

The popover is hosted by `PopoverController` which is a borderless `NSPanel` with rounded corners. Inside, a `MiniPlayerView` SwiftUI view. Total content width = 318 pt (album art / rating bar width) + 12 pt left padding + 12 pt right padding = 342 pt. Vertical: laid out `VStack(spacing: 12)`.

```
ZStack (popover background = .windowBackgroundColor)
  VStack(spacing: 12)
    Image(albumArt) — 318×318, .resizable().scaledToFit()
    VStack(spacing: 2) — title (.headline), artist (.subheadline), album (.caption)
    HStack(spacing: 8)
      Picker(channel) — .menu style — flexible
      Text(streamFormat.displayString) — .caption2, .secondary
      Button(gear icon) — 22×22, plain style
    RatingRow — 318 pt
    HStack(spacing: 18)
      Button(play/pause) — 48×48, accent
      Button(forward) — 38×38
    Text("RP Player") — .caption2, .tertiary, frame(maxWidth: .infinity, alignment: .center), padding(.top, 6)
```

Padding: `.padding(12)` on the outer VStack (not the ZStack — the popover background should bleed to corners).

The play/pause + forward HStack is centered. The play/pause button uses `.tint(.accentColor)` and the SF Symbol `play.circle.fill` / `pause.circle.fill`; forward uses `forward.end.fill` in a smaller circle.

---

## Test plan

**Unit / integration:**
- New `StreamFormat.displayString` helper has unit tests covering FLAC / MP3 / unknown-codec branches.
- `LibmpvPlayerEngine` test verifies that after `play(url:)` resolves, querying the new `currentStreamFormatForTesting()` accessor returns a non-nil value (using the existing `https://stream.radioparadise.com/mp3-320` smoke URL — don't hit FLAC because flaky in CI).
- Coordinator test: when the engine emits `streamFormatChanged`, the next `nowPlayingUpdates` element carries the new format.
- `MiniPlayerViewModel` test: `currentStreamFormat` updates when coordinator emits.
- Bug 1 regression test: TBD by investigation. Expected shape — given a coordinator with two sequential blocks queued, simulate the EOF + prefetch swap, fire one `positionUpdate` for the new block at offset 0, assert `nowPlaying.song` matches the new block's first song.

**Manual smoke (user):**
- Hog mode toggle on the USB DAC for each of the three attempts.
- Pause for >5 minutes, resume, verify track info refreshes correctly.
- Confirm rp.ico shows in the menu bar.
- Confirm popover layout matches Variant E mockup.
- Confirm Settings window title reads "RP Player Settings".

---

## Risks / open questions

- **`audio-bitrate` may not be stable for FLAC streams.** mpv reports the instantaneous bitrate which jiggles for VBR. May want to display only kHz + codec for FLAC and skip the kbps number; or hide the kbps if the codec is FLAC.
- **`rp.ico` resolution mismatch.** The file is 48×48 / 32×32 8bpp Windows ICO. macOS menu bar icon is typically 16×16 at 1x, 32×32 at 2x. Image I/O will pick the closest layer; the result may look pixelated. If so, ask the user for a 16/32/64 PNG set or a `.icns`.
- **SPM resource bundle path.** The runtime bundle path differs between `swift run` and a bundled `.app`. Need `Bundle.module` (auto-generated for resource-bearing targets) for both. Verify both paths in smoke.
- **Bug 1 may turn out to be a 5th hypothesis.** If the research subagent's report doesn't pin the cause to one of the four candidates, the fix slips to a follow-up.
- **Hog mode bounded budget.** Three attempts is a budget; if the third gets close but doesn't quite work, surface progress to the user before deferring.
