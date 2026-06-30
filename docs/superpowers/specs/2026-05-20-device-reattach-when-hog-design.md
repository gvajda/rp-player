# Preserve selected output device on disconnect when hog mode is on

Date: 2026-05-20
Status: Design — ready for plan

## Problem

Today, when the active CoreAudio output device disappears mid-playback (user unplugs a USB DAC, Bluetooth drop, etc.), libmpv emits error `-14` (`AO_INIT_FAILED`) and the app's `onDeviceUnavailable` handler at [AppContainer.swift:219-234](../../../Sources/RPPlayer/App/AppContainer.swift#L219-L234) clears three pieces of state for hearing-safety:

- `outputDeviceUID` → nil
- `hogModeEnabled` → false
- `volumeMode` → `.none`

The picker then falls back to "Select an output device" and the user must re-pick the device, re-enable hog mode, and re-enable Force Max Volume when they plug the DAC back in. For users who run with hog mode on (the entire reason this app exists), this loses their setup on every cable wiggle.

## Goal

When the active output device disconnects **and hog mode was enabled at the moment of disconnect**, preserve the device selection + hog + Force Max settings. When the same device reappears, automatically re-acquire hog mode and re-pin Force Max volume. Playback stays stopped — the user clicks play to resume.

Non-goal: any change to behavior when hog mode was off. The existing hearing-safety reset still runs in that case (built-in speakers must never blast at 100%).

## Decisions (recorded from brainstorming)

| Question | Decision |
|---|---|
| Reconnect behavior | Auto re-acquire hog + Force Max, stay paused. User clicks play. |
| Force Max preserved? | Yes, alongside hog. Symmetrical. |
| Startup-clear parity | No. `AppContainer.swift:106-129` startup-clear stays as-is. Only the runtime path changes. |
| Picker label while held | "DeviceName (disconnected)" suffix using last-known name. |
| Disconnect banner | Friendly: "DeviceName disconnected — waiting for it to come back." Auto-clears on reattach. |

## Architecture

Approach: branch inside the existing `onDeviceUnavailable` closure in `AppContainer`. No new top-level component. The closure already has the wiring it needs (`store`, `hogController`, `volumeController`, and access to the catalog instance).

### State

No new persisted fields. The decision to preserve uses the already-persisted `hogModeEnabled`.

New in-memory state lives on `AppContainer`:

- `heldUID: String?` — the UID we are waiting to see reappear. `nil` when not in a held-disconnect state.
- `reattachTask: Task<Void, Never>?` — one-shot watcher subscribed to `CoreAudioDeviceCatalog.changes`. Cancelled when `heldUID` clears (reattach succeeded, or user selected a different device).

These are mutated only from `@MainActor` (AppContainer wiring) for simplicity; the actual CoreAudio work delegates to the existing `HogModeController` / `DeviceVolumeController` actors, which already serialize their own state.

### Disconnect flow

`onDeviceUnavailable` (called by `PlaybackCoordinator` on mpv error `-14`):

1. Read settings snapshot from `store`.
2. **If `hogModeEnabled == false`** (existing path, unchanged): clear `outputDeviceUID` + `hogModeEnabled` + `volumeMode`, release hog, emit the existing "device unavailable — turned off for safety" banner.
3. **If `hogModeEnabled == true`** (new preserve path):
    - Do NOT mutate `store`.
    - `heldUID = settings.outputDeviceUID`.
    - `await hogController.release()` — clears the actor's `hoggedDeviceID` bookkeeping. The CoreAudio call against the dead AudioDeviceID will fail with an OSStatus error; we ignore it. (Verify in plan-writing whether the existing `releaseHog()` correctly clears actor state when the CoreAudio call errors. If not, add a `noteDeviceGone()` method that resets state without making the CoreAudio call.)
    - If `settings.volumeMode == .forceMax`: clear `volumeController` bookkeeping similarly.
    - Cancel any prior `reattachTask`; spawn a new one (see below).
    - Emit the friendly banner via the errors stream: `"<deviceName> disconnected — waiting for it to come back."`

Banner emission moves out of `PlaybackCoordinator` for the `-14` case. The coordinator's existing message string at [PlaybackCoordinator.swift:681-683](../../../Sources/RPPlayer/Playback/PlaybackCoordinator.swift#L681-L683) is no longer the source of truth; the handler decides which message to push. (Keep the non-`-14` "Playback stopped unexpectedly (error N)" path in the coordinator — that's not device-policy.)

### Reattach task

Subscribes to `catalog.changes`. For each yielded snapshot:

1. If `heldUID` is nil: return (task should exit; defensive).
2. If snapshot contains a device whose `uid == heldUID`:
    - `await hogController.acquire(deviceUID: heldUID)`.
    - If current `settings.volumeMode == .forceMax`: `await volumeController.setVolumeMax(deviceUID: heldUID)`.
    - Push a "banner clear" sentinel to the errors stream (or use whatever the existing mechanism is for clearing — confirm in plan).
    - Clear `heldUID`, set `reattachTask = nil`, return.

The catalog's `changes` stream yields a snapshot immediately on subscribe, so if the device is somehow already present by the time we subscribe (race between the mpv `-14` event and a quick replug), the reattach fires on the first yield. Idempotent.

### User overrides while held

If the user picks a different device via the picker while `heldUID` is set, the existing `SettingsViewModel.setOutputDeviceUID` path runs. AppContainer must observe settings changes (via its existing `store.changes` subscription) and, when `outputDeviceUID` changes to anything other than `heldUID`:

- Cancel `reattachTask`.
- Clear `heldUID`.
- Clear the friendly banner.

If the user toggles hog mode off via the device-settings UI while held: same cleanup, plus run the standard "turn off hog / force-max" flow against the held UID (which is no-op for hog since the actor already cleared, but ensures `volumeController` releases anything it might still think it owns).

### Player state

`PlaybackCoordinator` continues to `emitState(.stopped)` on `-14`. After reattach succeeds, state stays `.stopped`. User clicks play → existing `prePlayHook` re-runs (already acquires hog before mpv opens), playback resumes.

## UI surface

### Picker

`SettingsViewModel` gains:

- `deviceNameCache: [String: String]` — uid→name map. Updated from every snapshot yielded by `catalog.changes` subscription (which the VM already consumes for the `devices` array).
- Computed `disconnectedDevice: AudioDevice?` — returns non-nil when `outputDeviceUID` is set, not empty, AND not found in the current `devices` array. Synthesizes:
  ```swift
  AudioDevice(
      uid: heldUID,
      name: "\(cachedName) (disconnected)",
      transportType: .unknown
  )
  ```
- If `deviceNameCache` has no entry for the held UID (shouldn't happen given startup-clear is preserved, but defensive), use `"Unknown device (disconnected)"`.

`SettingsView`'s picker `ForEach` injects the synth row when present:

```swift
ForEach([viewModel.disconnectedDevice].compactMap { $0 } + viewModel.devices, id: \.uid) { ... }
```

(Or equivalent — exact layout decided in plan. The synth row should appear above the live devices to highlight the held state.)

The picker's `selection` binding still maps to the UID, so SwiftUI shows the synth row as selected without any extra binding work.

### Banner

Single string pushed to the existing errors stream:

- On preserve-disconnect: `"<deviceName> disconnected — waiting for it to come back."`
- On reattach success: clear the banner.

If the errors stream today is fire-and-forget (no way to clear from outside), the plan needs a small extension — e.g., a separate "transient status" stream, or a sentinel string the UI treats as "clear". Decide in plan, not here.

## Edge cases

| Case | Behavior |
|---|---|
| User unplugs device while hog OFF | Existing reset path (unchanged). |
| User unplugs device while playing + hog ON | Preserve path. Banner + synth row. |
| User unplugs device while paused + hog ON (release-on-pause off) | mpv `-14` may not fire (nothing playing). Hot-plug listener fires → catalog yields a snapshot missing the UID. New: AppContainer's catalog subscription detects "current `outputDeviceUID` disappeared AND `hogModeEnabled == true`" and triggers the same preserve flow. Without this, the disconnect goes unnoticed until next play attempt. |
| Device returns within milliseconds (rapid wiggle) | Reattach task fires on first snapshot, re-acquires. No user-visible flicker beyond the brief banner. |
| Two rapid disconnects of different devices (user swaps cables fast) | `heldUID` only tracks one; the second disconnect overwrites the first (with the new device's UID being whatever the user has selected — which doesn't change mid-swap). Documented: only one device can be held at a time. |
| User quits app while held | Startup-clear runs next launch (decision: no parity). Held state discarded. |
| User picks different device while held | Reattach task cancelled, banner cleared, normal selection takes over. |
| User toggles hog off while held | Reattach task cancelled, `heldUID` cleared, banner cleared. `outputDeviceUID` stays selected; the synth row keeps showing "(disconnected)" because that's driven by `outputDeviceUID` + absence-from-catalog, not by `heldUID`. If the device returns later it just appears as a normal row; user can manually re-enable hog. |
| Force Max was on, device returns | Re-acquire hog + re-pin volume to max. |
| Device returns with a different sample rate set externally | `hogController.acquire` already enforces 44.1kHz (existing behavior). No extra work. |

## Files touched

| File | Change |
|---|---|
| `Sources/RPPlayer/App/AppContainer.swift` | Branch in `onDeviceUnavailable`. New `heldUID` + `reattachTask` state. New subscription to `catalog.changes` for paused-disconnect detection. New subscription to `store.changes` for user-override detection. |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Stop emitting the hardcoded `-14` error string; let the handler decide. Keep `emitState(.stopped)` + non-`-14` error path. |
| `Sources/RPPlayer/Audio/HogModeController.swift` | Verify `release()` clears actor state when CoreAudio call fails. Add `noteDeviceGone()` if needed. |
| `Sources/RPPlayer/Audio/DeviceVolumeController.swift` | Same verification + possibly same new method. |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | `deviceNameCache` + `disconnectedDevice` computed. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | Inject `disconnectedDevice` synth row into picker `ForEach`. |
| Tests (new + extended) | See below. |

## Testing

### New / extended tests

`Tests/RPPlayerTests/DeviceReattachTests.swift` (new):
- hog off + disconnect → existing clear path (regression).
- hog on + disconnect → settings preserved, `heldUID` set, friendly banner emitted.
- hog on + disconnect → device reappears → `hogController.acquire` called with held UID, banner cleared.
- hog on + Force Max + disconnect → reappears → `acquire` + `setVolumeMax` both called.
- hog on + disconnect → user picks different device via VM → reattach task cancelled, no stray re-acquire, banner cleared.
- hog on + disconnect → user toggles hog off → cleanup, banner cleared, no re-acquire.
- Two rapid disconnects of the same device → only one reattach task active (no leak).
- hog on + paused + device disappears via hot-plug (no mpv `-14`) → preserve flow triggers from catalog subscription.

`Tests/RPPlayerTests/SettingsViewModelTests.swift` (extend):
- `deviceNameCache` populated from catalog stream.
- `disconnectedDevice` synth row appears when `outputDeviceUID` set + UID missing from current devices.
- Synth row label uses cached name + "(disconnected)" suffix.
- Picker selection round-trips with synth row present.

`Tests/RPPlayerTests/HogModeControllerTests.swift` (extend, if needed):
- `release()` clears `hoggedDeviceID` even when CoreAudio call returns non-noErr (may require introducing a thin protocol seam around `AudioObjectSetPropertyData`; gate on the verification step above).

### Out of scope

- Real-hardware integration tests (no CI setup for unplug events).
- mpv-level behavior — `onDeviceUnavailable` is the seam; we trust mpv signals it.

## Open questions to resolve in plan-writing

1. Does the errors stream support a "clear banner" signal, or does the UI just time-banners out? If the latter, we may need a tiny status-stream addition for the friendly message.
2. `HogModeController.release()` — does it clear `hoggedDeviceID` when the CoreAudio call fails on a dead device? If yes, no new method needed. If no, add `noteDeviceGone()`.
3. Where does the paused-disconnect catalog subscription live — AppContainer (consistent with the rest of this PR) or pushed into a small helper for testability? Leaning AppContainer to keep the surface area small; helper if the test ergonomics get ugly.

## Documentation updates required at PR time

- `CHANGELOG.md` — entry under `Added` (or `Changed`): "Preserve output device + hog mode + Force Max when device disconnects while hog is on; auto-re-acquire on reconnect."
- `docs/pr-history.md` — new row in status table.
- `docs/test-counts.md` — new test count line.
- `docs/architecture.md` — entry only if the design lands meaningfully different from this doc; the AppContainer-internal state machine is probably not architecturally significant enough to warrant one.
- `CLAUDE.md` — refresh *Current state* block.
- `README.md` — likely no change (this is reliability, not a user-facing toggle).
