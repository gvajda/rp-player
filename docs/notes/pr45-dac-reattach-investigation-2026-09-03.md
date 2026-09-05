# DAC reattach → silent play (investigated 2026-09-03)

## Symptom
After the Qudelix-5K was unplugged and replugged, Play flipped to Pause, progress bar stayed at 0, no audio, no error. Relaunch fixed it.

## Log timeline (RPPlayer.log, 3 Sep)
- 12:52:52 device disappeared, hog on → app stopped mpv, held selection.
- 14:29:12 Play pressed while device still absent → mpv `[ao/coreaudio] could not check whether device is alive`, end-file -14.
- 14:30:40 device reappeared, hog re-acquired.
- 14:30:52 Play → fileStarted/fileLoaded, no mpv errors, time-pos stuck at 0, `loadfile append-play` blocked ~7s (mpv core thread stalled in CoreAudio).
- 14:32:39 relaunch → fine.

## What is known
- Reattach → Play worked in ~15 earlier occurrences (all five log files). This is the only "failed AO init on absent device, then reattach" sequence and the only silent play.
- mpv 0.36 `ao_coreaudio.c` `init()` is stateless on failure (checked against tag v0.36.0). Leftover state is in-process CoreAudio HAL / AudioUnit.
- Evidence gaps closed by PR 45: mpv log was error-only; hog acquire/release + sample-rate flips were unlogged.

## Open hypotheses (ranked)
1. Sample-rate flip immediately before AU open (release restores original rate, acquire re-sets 44.1 kHz, ~1 s before mpv `AudioUnitInitialize`) leaves the HAL mid-reconfigure on a freshly enumerated device → AU starts but never renders.
2. Stale HAL object for the old AudioDeviceID (touched by mpv's `DeviceIsAlive` query at 14:29) poisons the new device's IO in this process.

## If it recurs
Collect the `mpv[ao/coreaudio]` and `hog acquired/released` lines around the Play. If the AU "selected audio output device" ID differs from the hog `id=`, hypothesis 2. If `rateBefore != 44100`, hypothesis 1 — candidate fix: skip the rate restore on release-on-pause releases, or settle before `engine.play`.
Recovery candidate: if `time-pos` stays 0 for ~3 s after `fileLoaded`, issue mpv `ao-reload`.

## Resolved (2026-09-05, PR 46)

Recurred 5 Sep with PR 45 logging on. App log: `hog acquired id=17683 rateBefore=48000.0 rateNow=48000.0` 80 ms after `reappeared`; Play 4 min later → AUHAL init fine, 7 s stall, `mpv[ao/coreaudio] can't start audio unit ([35][0][0][0]/35)`, `time-pos` 0 on every skip.

Unified log (`/usr/bin/log show`, process `RP Player`, sender `CoreAudio`):
- 21:07:45.344 coreaudiod `HALS_PlugInDevice::HandlePlugIn_RequestConfigChange` (driver bring-up, returned 46.198, restarting IO 46.230).
- 21:07:45.345–46.276 our process: `HALC_ProxyIOContext::PauseIO/ResumeIO` on IO context 446040 across 5 threads; a `ResumeIO` at 45.609 lands at count 0 (`-> 0 0 0 <- 0 0 0`, clamped); pause at 46.0299 never resumed; final `ResumeIO: <- 0 1 1`. Counter still 1 at 21:13.
- 21:11:45.403 `HALB_IOThread::_Start: IO is still disabled after waiting`; 21:11:50.675 `HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState returned error 35`.
- Baseline: acquire on an already-44.1 kHz device (4 Sep 20:56) produces no HAL lines at all.

Hypothesis 1 was directionally right (rate flip on a fresh device) but the mechanism is the HAL client pause-counter race, not resampling. Hypothesis 2 ruled out (AUHAL and hog ids match: 17683). mpv is stateless as expected. Fix in PR 46: no device writes during bring-up + relaunch message when the warn appears.
