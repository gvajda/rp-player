# PR 12 outstanding items (carry into next session)

PR 12 shipped: stale-track-info bug fix, rp.ico menu icon, live stream-format
event, Layout E rebuild, Settings window title, verbose logging toggle, cue
handling via `loadfile` start option, bitrate bridging, direct CoreAudio hog
mode (HogModeController), and dead-code cleanup. Test count: 184 → 213 (+29
across new and existing tests).

Confirmed working in user smoke (May 1, 2026):
- Hog mode now engages correctly on the user's USB DAC (Qudelix-5K) via
  the new HogModeController. Other system audio silences during playback.
- Bitrate display is correct (no more spurious "AAC" label when stream is FLAC).
- Album art no longer "vibrates" on FLAC bitrate fluctuations.

Still broken — pick up next session:

## 1. Bitrate setting changes don't propagate at runtime

**Symptom:** User changes Settings → Audio → Bitrate (e.g., AAC 64k → FLAC).
Setting persists to disk. Even after a channel change (which forces a fresh
`getBlock` API call), the new block uses the OLD bitrate. Restarting the app
picks up the new value. So it's a runtime propagation bug, not a persistence bug.

**Static analysis (commit `a2d1896` codebase) ruled out the obvious causes:**

- H1 (multi-subscriber race on `store.changes`): not the cause.
  `JSONConfigStore.changes` (`Sources/RPPlayer/Config/ConfigStore.swift:37-46`)
  is multi-subscriber-safe — each call returns a fresh AsyncStream with a
  unique UUID continuation, all yielded to on `update`.
- H2 (`bitrate` field immutable): not the cause. `LivePlaybackCoordinator.bitrate`
  is `private var` (line 21), `setBitrate` writes it directly.
- H3 (cached at call site): not the cause. `play(channelId:)` reads `self.bitrate`
  fresh on every call.
- H4 (channel change doesn't re-fetch): not the cause. `changeChannel(to:)`
  cancels prefetch + calls `play(channelId:)` which reads `self.bitrate`.
- H5 (API ignores bitrate): not the cause. `LiveRpApiClient.getBlock` includes
  `bitrate` in the URL query.

**Most likely root cause (H6):** the `AppContainer.live()` settings binder Task
either doesn't fire at runtime, or its execution order has a subtle interaction
that prevents `coordinator.setBitrate` from being called. Static analysis can't
distinguish — needs runtime instrumentation.

**Recommended next-session debug step:**

1. Add `logger.debug("AppContainer settings binder: bitrate=\(settings.bitrate)
   hog=\(settings.hogModeEnabled) device=\(settings.outputDeviceUID ?? "nil")")`
   at the top of the `for await settings in stream` body in
   `Sources/RPPlayer/App/AppContainer.swift` (currently around line 118).
2. Add `logger.debug("coordinator.setBitrate(\(newBitrate))")` at the head
   of `LivePlaybackCoordinator.setBitrate(_:)` in
   `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`.
3. With verbose logging ON, change the bitrate in Settings, then change channels.
   Look in `~/Library/Application Support/RP Player/Logs/RPPlayer.log` for
   either log line.
   - **Neither line:** the binder Task is dead — investigate why `store` was
     nil or the Task didn't schedule. Possible Swift 6 strict-concurrency
     issue silently dropping the closure.
   - **Binder fires but setBitrate doesn't:** look for early returns in
     the binder body (e.g., `try? await engine.setOutputDevice(...)` somehow
     short-circuits — though semantically it can't).
   - **Both fire but next `getBlock` still uses old bitrate:** investigate
     whether the user clicked "Change channel" but coordinator's prefetch
     pipeline already had a request in flight at the old bitrate that it
     committed to before the setBitrate landed.

## 2. Song / metadata offset still desyncs

**Symptom:** User reports "the played song and metadata offset is still an
issue" after the cue-via-loadfile-start fix (commit `0a9bf13`). The exact
nature post-fix isn't yet captured — need fresh repro.

**Hypotheses for next-session debugging:**

1. The `start=<seconds>` argument to `loadfile` works for some codecs/streams
   but not others. RP serves M4A AAC, FLAC, MP3 depending on bitrate; mpv's
   handling of `start=` may vary. Check whether the offset re-appears for a
   specific bitrate.
2. The hog-mode-acquisition-failure fallback in `LivePlaybackCoordinator`
   re-issues `engine.play(url:startSeconds:)` — passes the cue, so should be
   correct, but verify in the log that it does.
3. mpv's `time-pos` after `loadfile <url> replace start=<s>` — does it report
   `s` from frame 0 (correct) or `0` and count up from there (in which case
   our `BlockSongs.indexOfSong(at:in:)` lookup is wrong by `s` seconds)?
   The user's report suggests the latter: "displayed song stays offset" —
   if mpv reports `time-pos = 0` after a successful `start=386` load, then
   indexOfSong returns song 0 (correct for audio at 0+0 = 0s into block),
   but **wait** — actually we want the displayed song to match the audio. If
   audio is at block-offset 386s (Hound Dog) and time-pos is 0 (mpv's local
   frame counter), we'd display song at 0 (Weak) — that's the inverse of
   what user reports. Unclear without fresh logs.

**Recommended next-session debug step:** with verbose logging ON, play a
block, watch for `engine streamFormat:` lines AND `song boundary crossed:`
lines. Cross-reference with the actual song the user hears and the block.json
(at `/Users/gergely/git/rp-player-pr12/.temp/block.json`) to figure out
whether audio and metadata are in sync, off by exactly the cue value, or
off by something else.

## 3. (Possibly) `setHogMode` event/state vestige

`LibmpvPlayerEngine.setHogMode(_:)` is now informational only (emits
`.hogModeChanged`, no state). Some downstream consumers may still expect the
event for UI updates. Verify `LivePlaybackCoordinator.handleEngineEvent`'s
`.hogModeChanged, .outputDeviceChanged, .shutdown:` catch-all still handles it
gracefully. Also verify the `onHogModeFallback` closure in `AppContainer.live()`
— it writes `ConfigStore.hogModeEnabled = false`. If hog acquisition via
HogModeController itself fails (CoreAudio status non-zero), the binder
silently swallows it. Surfacing acquisition failures to the UI is a follow-up.
