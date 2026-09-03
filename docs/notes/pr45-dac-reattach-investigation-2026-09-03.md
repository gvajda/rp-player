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
