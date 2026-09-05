# Device Reattach When Hog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the active output device disconnects while hog mode was enabled, preserve the device selection + hog + Force Max settings, show a friendly "waiting" banner, and auto-re-acquire hog (and re-pin Force Max volume) when the same device reappears. Playback stays stopped — user clicks play to resume.

**Architecture:** Branch logic inside `AppContainer` at the two existing disconnect sites (the `onDeviceUnavailable` closure passed to `PlaybackCoordinator`, and the device-catalog watcher). When `hogModeEnabled == true` at disconnect, take a preserve path that captures `heldUID`, releases the now-dead hog bookkeeping, emits a friendly banner via the existing errors stream, and spawns a one-shot reattach watcher subscribed to `CoreAudioDeviceCatalog.changes`. The watcher re-acquires hog + (optionally) re-pins Force Max when the held UID reappears, then clears the banner via a new `clearErrorMessage()` method on `MiniPlayerViewModel`. UI surface: `SettingsViewModel` caches a uid→name map updated from the catalog stream and exposes a synthesized `disconnectedDevice` row when the saved UID is absent from the live device list; `SettingsView` injects the synth row into the picker.

**Tech Stack:** Swift 6.2 / SwiftUI / AppKit, CoreAudio (`HogModeController` actor, `DeviceVolumeController` actor, `CoreAudioDeviceCatalog` actor with `HotplugListener`), `JSONConfigStore` actor with `AsyncStream<AppSettings>` snapshots, libmpv via `MpvPlayerEngine`, XCTest.

**Spec:** [docs/superpowers/specs/2026-05-20-device-reattach-when-hog-design.md](../specs/2026-05-20-device-reattach-when-hog-design.md)

**Branch:** `claude/device-reattach-on-hog`

---

## Pre-flight notes (read before starting)

- `HogModeController.release()` (verified at [Audio/HogModeController.swift:55-73](../../../Sources/RPPlayer/Audio/HogModeController.swift#L55-L73)) **already** clears `hoggedDeviceID = nil` unconditionally on line 67, before the sample-rate restore call. So when the actor's CoreAudio set/get against the dead device fails, the actor's bookkeeping still resets. **No new `noteDeviceGone()` method needed.** Open Q #2 from the spec → resolved.
- `DeviceVolumeController` (at [Audio/DeviceVolumeController.swift](../../../Sources/RPPlayer/Audio/DeviceVolumeController.swift)) is **stateless** — no internal bookkeeping, just direct CoreAudio calls. No "clear" step needed for it. Reattach simply calls `setVolumeMax(deviceUID:)` again. Spec adjusted accordingly.
- Two disconnect sites exist in `AppContainer`:
  1. `onDeviceUnavailable` closure at [App/AppContainer.swift:219-234](../../../Sources/RPPlayer/App/AppContainer.swift#L219-L234) — fires on mpv error -14 during playback.
  2. The device-catalog watcher Task at [App/AppContainer.swift:433-447](../../../Sources/RPPlayer/App/AppContainer.swift#L433-L447) — fires on hot-plug events (covers paused-disconnect).

  Both currently do the same reset. Both need the same preserve branch. This plan introduces a single private helper to keep them in lock-step.
- The errors stream is `AsyncStream<String>` (consumed by `MiniPlayerViewModel.errorsSubscriptionTask` at [Shell/MiniPlayerViewModel.swift:158-169](../../../Sources/RPPlayer/Shell/MiniPlayerViewModel.swift#L158)). It cannot carry a "clear" signal. We add a `clearErrorMessage()` method on `MiniPlayerViewModel` (it's `@MainActor`) and have the reattach task call it directly via the AppContainer's reference.
- We do NOT touch the startup-clear logic at [App/AppContainer.swift:106-129](../../../Sources/RPPlayer/App/AppContainer.swift#L106-L129) (decision recorded in spec: no startup parity).
- Tests use the existing `StubAudioDeviceLister` from `Tests/RPPlayerTests/Helpers/` (search for it during Task 0 if exact path differs).

## File Structure

| Path | Status | Responsibility |
|------|--------|---|
| `Sources/RPPlayer/App/AppContainer.swift` | Modify | Add `heldUID` + `reattachTask` state on the type. New private static helper `handleDeviceLost` invoked from both disconnect sites. New private static helper `spawnReattachTask`. New `clearErrorMessage()` call site on reattach success. |
| `Sources/RPPlayer/Playback/PlaybackCoordinator.swift` | Modify | Stop yielding the hardcoded -14 error string. Coordinator still emits `.stopped` state; the handler decides which (if any) message to push. Non-`-14` error path unchanged. |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | Modify | New `func clearErrorMessage()` `@MainActor` method that sets `errorMessage = nil`. |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | Modify | New `deviceNameCache: [String: String]` updated from device stream. New computed `disconnectedDevice: AudioDevice?` synthesizing a "(disconnected)" row when `outputDeviceUID` set + absent from `devices`. |
| `Sources/RPPlayer/Shell/SettingsView.swift` | Modify | Inject `disconnectedDevice` synth row into the picker's `ForEach`. |
| `Tests/RPPlayerTests/DeviceReattachTests.swift` | Create | Integration tests for both disconnect paths, reattach, user-override-while-held, Force Max preservation, idempotency. |
| `Tests/RPPlayerTests/SettingsViewModelDisconnectedRowTests.swift` | Create | VM-level tests for `deviceNameCache` + `disconnectedDevice`. |
| `CHANGELOG.md` | Modify | New entry under `## [Unreleased]` → `Added`. |
| `docs/pr-history.md` | Modify | New row in status table. |
| `docs/test-counts.md` | Modify | New count line. |
| `CLAUDE.md` | Modify | Refresh *Current state* block. |

---

## Task 1: Verify baseline + create branch

**Files:**
- N/A

- [ ] **Step 1: Confirm clean working tree**

Run: `git status --short`
Expected: only the four pre-existing modified/untracked files from the project state (`CLAUDE.md`, `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md`). No code in `Sources/` or `Tests/` modified.

- [ ] **Step 2: Confirm tests pass on main**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass. Note the test count (should be ~462 per CLAUDE.md). Record the exact number — we will append a new line to `docs/test-counts.md` at the end.

- [ ] **Step 3: Create branch**

Run: `git checkout -b claude/device-reattach-on-hog`
Expected: switched to new branch.

- [ ] **Step 4: Locate `StubAudioDeviceLister` for later test wiring**

Run: `grep -rn "class StubAudioDeviceLister\|struct StubAudioDeviceLister" Tests/`
Expected: at least one match. Record its path — we will reuse it in Task 8.

---

## Task 2: Add `clearErrorMessage()` to `MiniPlayerViewModel`

**Files:**
- Modify: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`

Rationale: the errors stream is one-way and carries non-optional strings, so the reattach task needs a direct way to dismiss the friendly "waiting" banner. `MiniPlayerViewModel` is `@MainActor` and `AppContainer` already holds a reference, so this is a one-line method.

- [ ] **Step 1: Read the existing class declaration to find the right place for the method**

Run: `grep -n "^extension MiniPlayerViewModel\|^final class MiniPlayerViewModel\|errorMessage = nil" Sources/RPPlayer/Shell/MiniPlayerViewModel.swift`
Expected: locate the class header and the existing `errorMessage = nil` reset call sites. Note the indentation style.

- [ ] **Step 2: Add the public method**

Add right after the existing `errorMessage` `@Published` declaration's last grouped peer (or near other small public actions like `func showPopoverIfNeeded`). Use the same indentation as existing methods.

```swift
    /// Dismiss any error/info banner currently shown to the user. Called from
    /// AppContainer when a held device reattaches and the "waiting" banner
    /// should clear without user intervention.
    func clearErrorMessage() {
        errorMessage = nil
    }
```

(That comment lead is non-obvious WHY this is called and from where — keep it.)

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/MiniPlayerViewModel.swift
git commit -m "feat(shell): add MiniPlayerViewModel.clearErrorMessage for external dismiss"
```

---

## Task 3: Stop emitting the hardcoded -14 message from `PlaybackCoordinator`

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift:681-692`

The coordinator currently yields a fixed "Audio device unavailable… turned off for safety" string AND invokes `onDeviceUnavailable`. We want the handler to decide the message (different copy for preserve vs. reset). Move the message responsibility into the handler.

- [ ] **Step 1: Read the exact current block**

Run: `sed -n '680,695p' Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
Expected: prints lines including the existing `let message = code == -14 ? ...` ternary, `errorsContinuation?.yield(message)`, and the `if code == -14, let handler ... await handler()` block.

- [ ] **Step 2: Update the block**

Replace lines roughly 681-692 (verify exact range first) so that for code -14 we **only** call the handler. The handler will push its own message via the errors stream (we will expose a small seam for it in Task 4).

New shape:

```swift
        let nonDeviceMessage = "Playback stopped unexpectedly (error \(code))."
        emitState(.stopped)
        if code == -14, let handler = onDeviceUnavailable {
            // Hearing-safety + reattach-preserve policy lives in the handler.
            // The handler decides which (if any) message to push to the errors
            // stream — different copy depending on whether hog mode was on.
            await handler()
        } else {
            errorsContinuation?.yield(nonDeviceMessage)
        }
```

Note: do NOT yield anything from this method for the -14 case. The handler does it.

- [ ] **Step 3: Verify no other code in the coordinator relied on the old message**

Run: `grep -n "Audio device unavailable\|turned off so the next device" Sources/RPPlayer/Playback/`
Expected: no matches (the string moves entirely to the AppContainer handler in Task 4).

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 5: Run tests likely to touch this path**

Run: `swift test --filter PlaybackCoordinator 2>&1 | tail -30`
Expected: PASS. If any test was asserting on the old hardcoded string, fix it in this commit by either deleting the assertion (the message is no longer the coordinator's concern) or moving it. Search:

Run: `grep -rn "Audio device unavailable\|turned off so" Tests/`
Expected: if any matches, update those tests to assert on the handler's behavior instead (the handler will be tested in Task 8).

- [ ] **Step 6: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/
git commit -m "refactor(playback): move -14 user message responsibility to handler"
```

---

## Task 4: Add a coordinator seam for handler-pushed messages

**Files:**
- Modify: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`

The handler in `AppContainer` needs a way to push a message to the errors stream that `MiniPlayerViewModel` is subscribed to. Expose a small public method on the coordinator that fronts `errorsContinuation`.

- [ ] **Step 1: Find the protocol declaration**

Run: `grep -n "^public protocol PlaybackCoordinator\|protocol PlaybackCoordinator" Sources/RPPlayer/Playback/PlaybackCoordinator.swift`
Expected: find the protocol header (around the top of the file).

- [ ] **Step 2: Add a method to the protocol**

```swift
    /// Push a one-off message to the errors stream. Used by AppContainer's
    /// device-reattach policy to surface friendly status text without bypassing
    /// the existing UI banner plumbing.
    func emitUserMessage(_ message: String) async
```

- [ ] **Step 3: Implement on `LivePlaybackCoordinator`**

Add near the other public methods (e.g. near `play()` or near the existing `emitState`):

```swift
    public func emitUserMessage(_ message: String) async {
        errorsContinuation?.yield(message)
    }
```

- [ ] **Step 4: Implement on any conforming mock/stub**

Run: `grep -rn "PlaybackCoordinator" Sources/ Tests/ | grep -v "\.swiftpm\|^Binary" | grep -E "class|struct|extension" | head -30`
Expected: find any test mocks or no-op stubs that conform to the protocol. For each, add an `emitUserMessage(_:)` implementation. Likely just one or two test mocks — implement as a no-op or record the message for assertion.

Example for a typical mock:

```swift
    var emittedUserMessages: [String] = []
    func emitUserMessage(_ message: String) async {
        emittedUserMessages.append(message)
    }
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds. If a mock is missing the method, the compiler will say so — add it.

- [ ] **Step 6: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/Playback/PlaybackCoordinator.swift Tests/
git commit -m "feat(playback): add emitUserMessage seam for handler-pushed banners"
```

---

## Task 5: Add `heldUID` + `reattachTask` state and the preserve-vs-reset helper to `AppContainer`

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

This task introduces the shared helper but does NOT yet wire it into the two disconnect sites — that's Task 6. We commit the helper alone so it's easy to review in isolation.

- [ ] **Step 1: Add storage for the held state and the reattach task on the `AppContainer` class**

Add these `@MainActor` stored properties near the existing fields (e.g. just below `let initialMenuBarIconStyle`):

```swift
    // Device-reattach state. Set when the active output device disappears
    // while hog mode was on; cleared when the device returns or the user
    // selects a different device. See docs/superpowers/specs/2026-05-20-device-reattach-when-hog-design.md.
    private(set) var heldDeviceUID: String?
    private var reattachTask: Task<Void, Never>?
```

(These live on the type because the two disconnect sites are spawned Tasks inside `live()`; they need a shared place to coordinate. `AppContainer` is `@MainActor`-isolated so plain `var` is fine.)

- [ ] **Step 2: Add a private static helper that runs the disconnect policy**

The helper takes everything it needs as parameters so it's safe to call from spawned Tasks. It returns `String?` — the message to push to the errors stream — so the call site can decide whether to also send `.stopped` etc.

Add at the bottom of the file, inside the existing `extension AppContainer { ... }`:

```swift
    /// Disconnect policy for the active output device. Returns the message the
    /// caller should push via `coordinator.emitUserMessage`, OR nil if no
    /// message is appropriate (shouldn't happen in current call sites but kept
    /// as the signal type so future call sites can opt out).
    ///
    /// Preserve path (hog on): keeps outputDeviceUID + hogModeEnabled + volumeMode
    /// intact, releases the now-dead hog bookkeeping, returns a friendly
    /// "waiting" banner. Caller is responsible for spawning the reattach
    /// watcher via `spawnReattachWatcher(...)`.
    ///
    /// Reset path (hog off): wipes outputDeviceUID + hogModeEnabled + volumeMode
    /// for hearing-safety so a fallback to built-in speakers can't blast at
    /// 100%, returns the existing user-facing message.
    @discardableResult
    static func handleDeviceLost(
        store: JSONConfigStore,
        hogController: HogModeController,
        knownDeviceNames: [String: String],
        logger: any Logging
    ) async -> (message: String?, preservedUID: String?) {
        let s = await store.settings
        guard let uid = s.outputDeviceUID, !uid.isEmpty else {
            // Nothing to do; the saved UID was already nil.
            return (nil, nil)
        }
        if s.hogModeEnabled {
            let name = knownDeviceNames[uid] ?? uid
            logger.info("device '\(uid)' disappeared while hog mode on; preserving selection + waiting for reattach")
            // Drop hog actor's stale bookkeeping. The CoreAudio call against
            // the dead AudioDeviceID will silently no-op; release() clears
            // hoggedDeviceID unconditionally so the next acquire() is clean.
            await hogController.release()
            return ("\(name) disconnected — waiting for it to come back.", uid)
        } else {
            logger.info("output device '\(uid)' disappeared at runtime; clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
            try? await store.update {
                $0.hogModeEnabled = false
                $0.volumeMode = .none
                $0.outputDeviceUID = nil
            }
            await hogController.release()
            return (
                "Audio device unavailable. Hog mode + Force Max Volume turned off so the next device you pick can't surprise you. Check System Settings → Sound → Output.",
                nil
            )
        }
    }
```

- [ ] **Step 3: Add a private static helper that spawns the reattach watcher**

Add immediately after `handleDeviceLost`:

```swift
    /// Spawn a one-shot reattach watcher. The task subscribes to the catalog's
    /// changes stream and, on the first snapshot containing `heldUID`, calls
    /// hog acquire + (if Force Max is set) volume re-pin, then invokes
    /// `onReattached` on the MainActor so the caller can clear state + dismiss
    /// the banner.
    static func spawnReattachWatcher(
        heldUID: String,
        catalog: CoreAudioDeviceCatalog,
        hogController: HogModeController,
        volumeController: DeviceVolumeController,
        store: JSONConfigStore,
        logger: any Logging,
        onReattached: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { [catalog, hogController, volumeController, store, logger] in
            let stream = await catalog.changes
            for await devices in stream {
                if Task.isCancelled { return }
                guard devices.contains(where: { $0.uid == heldUID }) else { continue }
                logger.info("held device '\(heldUID)' reappeared; re-acquiring hog")
                _ = await hogController.acquire(deviceUID: heldUID)
                let s = await store.settings
                if s.volumeMode == .forceMax {
                    _ = await volumeController.setVolumeMax(deviceUID: heldUID)
                }
                await MainActor.run { onReattached() }
                return
            }
        }
    }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds. The new helpers and state are not yet referenced — that's Task 6.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(app): add device-lost helper + reattach-watcher spawner (unused yet)"
```

---

## Task 6: Wire the helpers into the two disconnect sites

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift:219-234` (onDeviceUnavailable closure)
- Modify: `Sources/RPPlayer/App/AppContainer.swift:433-447` (catalog watcher)

Both sites currently inline the same reset logic. Both now delegate to `handleDeviceLost` and conditionally spawn the reattach watcher.

`AppContainer.live()` is a class method that returns the container; the container reference doesn't exist yet inside `live()`. So we maintain the held state via a `@MainActor` actor-isolated holder declared inside `live()` — a small `class StateHolder` or just rely on `MainActor.run { ... }` closures capturing locals. **Simpler:** declare the state on the returned `AppContainer` and pass `(container: AppContainer)` into a late-binding step. **Even simpler:** since the catalog watcher and the onDeviceUnavailable closure are both spawned inside `live()` BEFORE the container is constructed, use a captured-by-reference `Box<String?>` for `heldUID` and `Box<Task<Void, Never>?>` for the task — these are owned by the closures and outlive `live()`.

Decision: use a single MainActor-isolated helper class `DeviceReattachState` declared as a private nested type inside `AppContainer` (or just a small private class in the same file). Both closures hold a reference and mutate state through it. Cleaner than `Box`, easier to test.

- [ ] **Step 1: Add the state holder type**

Add immediately above `extension AppContainer { ... static func live()`:

```swift
@MainActor
final class DeviceReattachState {
    var heldUID: String?
    var reattachTask: Task<Void, Never>?

    func cancelReattach() {
        reattachTask?.cancel()
        reattachTask = nil
        heldUID = nil
    }
}
```

(Internal access — tests in the same module need to peek at it.)

- [ ] **Step 2: Construct one instance early in `live()`**

Just before the existing `let coordinator = LivePlaybackCoordinator(...)` block (around line 204):

```swift
        let reattachState = DeviceReattachState()
```

- [ ] **Step 3: Add a `lastKnownDeviceNames` cache populated by the existing catalog watcher**

We need a uid→name cache that `handleDeviceLost` can consult for the friendly banner. The simplest place: store it on `DeviceReattachState`. Extend the holder:

```swift
@MainActor
final class DeviceReattachState {
    var heldUID: String?
    var reattachTask: Task<Void, Never>?
    var lastKnownDeviceNames: [String: String] = [:]

    func cancelReattach() {
        reattachTask?.cancel()
        reattachTask = nil
        heldUID = nil
    }
}
```

Then update the existing catalog watcher (currently at lines 433-447) so it populates the cache on every snapshot BEFORE the disappearance check. See Step 5.

- [ ] **Step 4: Replace the body of `onDeviceUnavailable` (lines 219-234)**

Current:

```swift
            onDeviceUnavailable: { [store, hogController, logger] in
                // ... existing comment ...
                guard let store else { return }
                logger.info("device unavailable: clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
                try? await store.update {
                    $0.hogModeEnabled = false
                    $0.volumeMode = .none
                    $0.outputDeviceUID = nil
                }
                await hogController.release()
            },
```

Replace with:

```swift
            onDeviceUnavailable: { [store, hogController, volumeController, logger, reattachState, deviceCatalog, coordinator] in
                // Disconnect policy lives in handleDeviceLost: preserve when
                // hog was on, hearing-safety reset when it was off. See
                // docs/superpowers/specs/2026-05-20-device-reattach-when-hog-design.md.
                guard let store else { return }
                let names = await MainActor.run { reattachState.lastKnownDeviceNames }
                let result = await AppContainer.handleDeviceLost(
                    store: store,
                    hogController: hogController,
                    knownDeviceNames: names,
                    logger: logger
                )
                if let msg = result.message {
                    await coordinator.emitUserMessage(msg)
                }
                if let heldUID = result.preservedUID {
                    await MainActor.run {
                        reattachState.heldUID = heldUID
                        reattachState.reattachTask?.cancel()
                        reattachState.reattachTask = AppContainer.spawnReattachWatcher(
                            heldUID: heldUID,
                            catalog: deviceCatalog,
                            hogController: hogController,
                            volumeController: volumeController,
                            store: store,
                            logger: logger,
                            onReattached: { [weak reattachState] in
                                reattachState?.heldUID = nil
                                reattachState?.reattachTask = nil
                                // The banner-clear hookup happens in Task 7 once
                                // viewModel exists — for now this just clears state.
                            }
                        )
                    }
                }
            },
```

Note: `coordinator` is captured but it's the local being constructed — Swift forward-references work because the closure body runs later. If the compiler complains (it shouldn't since `coordinator` is `let coordinator =` in the same scope), restructure by capturing `[weak coordinator]` later (Task 7 final wiring) or by extracting after coordinator construction. The simplest fix if needed: declare `let coordinator: LivePlaybackCoordinator` with deferred init via `lazy var` pattern is overkill. If forward-capture fails, do this instead: pass a `emitMessage: @Sendable (String) async -> Void` closure into a wrapper and bind it post-construction. **Recommended: try the straight capture first; restructure only if the build fails.**

Note: `deviceCatalog` is declared later in `live()` (line 426). Move its declaration up to just before the `coordinator` construction. If that creates other order issues, instead defer the reattach-task spawn until after both exist — keep the policy call in `onDeviceUnavailable` but wrap the spawn in a `Task { ... }` that reads from the already-constructed `reattachState`. The cleanest restructure:

```
1. let hogController = HogModeController()
2. let volumeController = DeviceVolumeController()
3. let reattachState = DeviceReattachState()
4. let deviceCatalog = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())   // moved up
5. let coordinator = LivePlaybackCoordinator(..., onDeviceUnavailable: { ... })  // now can capture all of the above
```

Do this restructure as part of this step. The existing `Task { await deviceCatalog.startWatching() }` and the catalog-watcher task can stay where they are.

- [ ] **Step 5: Replace the body of the catalog watcher (lines 433-447)**

Current:

```swift
            Task { [logger] in
                let stream = await deviceCatalog.changes
                for await devices in stream {
                    let s = await store.settings
                    guard let uid = s.outputDeviceUID, !uid.isEmpty else { continue }
                    if devices.contains(where: { $0.uid == uid }) { continue }
                    logger.info("output device '\(uid)' disappeared at runtime; clearing hogModeEnabled + volumeMode + outputDeviceUID for safety")
                    try? await store.update {
                        $0.hogModeEnabled = false
                        $0.volumeMode = .none
                        $0.outputDeviceUID = nil
                    }
                }
            }
```

Replace with:

```swift
            Task { [logger, hogController, volumeController, reattachState, coordinator] in
                let stream = await deviceCatalog.changes
                for await devices in stream {
                    // Maintain the uid→name cache used by handleDeviceLost
                    // for the friendly banner text.
                    let nameMap = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0.name) })
                    await MainActor.run {
                        for (uid, name) in nameMap {
                            reattachState.lastKnownDeviceNames[uid] = name
                        }
                    }
                    let s = await store.settings
                    guard let uid = s.outputDeviceUID, !uid.isEmpty else { continue }
                    if devices.contains(where: { $0.uid == uid }) {
                        // Device is present. If we were holding it, the
                        // reattach watcher will fire and clear state — no
                        // action here.
                        continue
                    }
                    // Device gone. Run the shared disconnect policy.
                    let names = await MainActor.run { reattachState.lastKnownDeviceNames }
                    let result = await AppContainer.handleDeviceLost(
                        store: store,
                        hogController: hogController,
                        knownDeviceNames: names,
                        logger: logger
                    )
                    if let msg = result.message {
                        await coordinator.emitUserMessage(msg)
                    }
                    if let heldUID = result.preservedUID {
                        await MainActor.run {
                            reattachState.heldUID = heldUID
                            reattachState.reattachTask?.cancel()
                            reattachState.reattachTask = AppContainer.spawnReattachWatcher(
                                heldUID: heldUID,
                                catalog: deviceCatalog,
                                hogController: hogController,
                                volumeController: volumeController,
                                store: store,
                                logger: logger,
                                onReattached: { [weak reattachState] in
                                    reattachState?.heldUID = nil
                                    reattachState?.reattachTask = nil
                                }
                            )
                        }
                    }
                }
            }
```

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -30`
Expected: build succeeds. If the forward-capture of `coordinator` in `onDeviceUnavailable` fails (Step 4), apply the restructure noted there.

- [ ] **Step 7: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: PASS. New behavior isn't tested yet (Task 8); existing tests should be unaffected because the reset path through `handleDeviceLost` is byte-equivalent to what was inline.

- [ ] **Step 8: Manual smoke (if hardware available, otherwise skip)**

Run the app, plug in a USB audio device, enable hog mode, start playback. Unplug the device. Observe that the friendly banner appears. Plug back in. Observe that hog re-acquires (the logs at `Library/Application Support/RP Player/Logs/` should show `held device '...' reappeared; re-acquiring hog`). Click play — playback resumes.

If no USB device is available, skip and rely on the integration tests in Task 8.

- [ ] **Step 9: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(app): wire device-lost policy + reattach watcher into both disconnect sites"
```

---

## Task 7: Hook up banner-clear and user-override-while-held

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

Two remaining wiring tasks:

(a) When the reattach watcher fires, it should also dismiss the friendly banner via `viewModel.clearErrorMessage()`. The view model exists only after the catalog/coordinator wiring, so we extend the onReattached closure post-construction.

(b) When the user picks a different device via the picker while `heldUID` is set, we must cancel the reattach task and clear `heldUID` so a stale reattach doesn't fire later. The settings change is observable on the existing `store.changes` subscription — extend it.

- [ ] **Step 1: Locate where `viewModel` (MiniPlayerViewModel) is constructed**

Run: `grep -n "let viewModel = MiniPlayerViewModel" Sources/RPPlayer/App/AppContainer.swift`
Expected: matches around line 519.

- [ ] **Step 2: After `viewModel` is constructed but before the final `return AppContainer(...)`, add a late-binding step**

We update the `reattachState`'s spawn behavior so future re-spawns include the banner-clear. But the simpler approach: replace the `onReattached` closure used at the two spawn sites in Task 6. Since the spawn is inline (inside the two Tasks), we need a single source of truth for the `onReattached` body.

Refactor: extract the `onReattached` body to a method on `DeviceReattachState`:

```swift
@MainActor
final class DeviceReattachState {
    var heldUID: String?
    var reattachTask: Task<Void, Never>?
    var lastKnownDeviceNames: [String: String] = [:]

    /// Called by the reattach watcher's onReattached callback. Default impl
    /// just clears state; AppContainer.live() replaces it with a closure that
    /// also dismisses the friendly banner once the MiniPlayerViewModel exists.
    var onReattached: @MainActor () -> Void = { }

    func cancelReattach() {
        reattachTask?.cancel()
        reattachTask = nil
        heldUID = nil
    }
}
```

Then change the two spawn sites in Task 6 to pass:

```swift
                                onReattached: { [weak reattachState] in
                                    reattachState?.heldUID = nil
                                    reattachState?.reattachTask = nil
                                    reattachState?.onReattached()
                                }
```

(Update both call sites with the same `onReattached: { ... }` block.)

- [ ] **Step 3: After `viewModel` is constructed, assign the real onReattached**

```swift
        reattachState.onReattached = { [weak viewModel] in
            viewModel?.clearErrorMessage()
        }
```

Place this immediately after `let viewModel = MiniPlayerViewModel(...)` and before `let upcomingViewModel = ...`.

- [ ] **Step 4: Add user-override detection**

In the existing `store.changes` subscription Task (the big one starting around line 255 that handles device switches), add at the top of the for-await body — right after `for await settings in stream {` and before any other branch:

```swift
                    // User-override detection: if the held UID is no longer the
                    // selected device, the user picked something else via the
                    // picker (or toggled hog off). Cancel the reattach watcher.
                    let currentHeld = await MainActor.run { reattachState.heldUID }
                    if let held = currentHeld,
                       (settings.outputDeviceUID != held || !settings.hogModeEnabled) {
                        await MainActor.run {
                            reattachState.cancelReattach()
                        }
                        // Also dismiss the friendly banner since the held state
                        // is no longer interesting.
                        await MainActor.run { viewModel.clearErrorMessage() }
                    }
```

Note: this requires `viewModel` to be in scope. Move the `store.changes` subscription Task to AFTER the `let viewModel = MiniPlayerViewModel(...)` construction, OR capture `viewModel` later via a late-bound `weak` reference. Simpler: move the Task. If moving causes ordering issues with the engine state initialization (it shouldn't — the stream's first yield carries the current snapshot which the engine already processed), do so.

If moving the entire Task is too invasive, alternate: declare `let viewModelRef = WeakBox<MiniPlayerViewModel>()` early, assign `viewModelRef.value = viewModel` after construction, and capture `viewModelRef` in the closure. **Prefer moving the Task** for clarity unless ordering breaks.

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 6: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(app): clear reattach banner + cancel watcher on user override"
```

---

## Task 8: Integration tests for `handleDeviceLost` + `spawnReattachWatcher`

**Files:**
- Create: `Tests/RPPlayerTests/DeviceReattachTests.swift`

These tests exercise the two static helpers directly — they're pure async functions that take the actors as parameters, so they're testable in isolation. We use `StubAudioDeviceLister` (located in Task 1 Step 4) to drive the catalog.

- [ ] **Step 1: Write the failing test for the hog-off reset path**

Create the file with:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class DeviceReattachTests: XCTestCase {

    func testHandleDeviceLostHogOffClearsSettings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("device-reattach-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try JSONConfigStore(url: tmp)
        try await store.update {
            $0.outputDeviceUID = "test-uid"
            $0.hogModeEnabled = false
            $0.volumeMode = .none
        }
        let hog = HogModeController()
        let logger = AppLogger.noop()

        let result = await AppContainer.handleDeviceLost(
            store: store,
            hogController: hog,
            knownDeviceNames: ["test-uid": "Test DAC"],
            logger: logger
        )

        XCTAssertNil(result.preservedUID)
        XCTAssertNotNil(result.message)
        XCTAssertTrue(result.message!.contains("Hog mode + Force Max Volume turned off"))
        let s = await store.settings
        XCTAssertNil(s.outputDeviceUID)
        XCTAssertFalse(s.hogModeEnabled)
        XCTAssertEqual(s.volumeMode, .none)
    }
}
```

- [ ] **Step 2: Run to verify it fails or passes**

Run: `swift test --filter DeviceReattachTests 2>&1 | tail -20`
Expected: should PASS (we're testing existing behavior that the new helper preserves). If it fails because `AppLogger.noop()` doesn't exist, replace with whatever the project uses for test loggers — likely a stub or `FileBackedLogger.testInstance` or similar. Run `grep -rn "noop\|NoopLogger\|TestLogger" Tests/RPPlayerTests/ | head -5` to find the right idiom.

- [ ] **Step 3: Add the preserve-when-hog test**

```swift
    func testHandleDeviceLostHogOnPreservesSettings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("device-reattach-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try JSONConfigStore(url: tmp)
        try await store.update {
            $0.outputDeviceUID = "test-uid"
            $0.hogModeEnabled = true
            $0.volumeMode = .forceMax
        }
        let hog = HogModeController()

        let result = await AppContainer.handleDeviceLost(
            store: store,
            hogController: hog,
            knownDeviceNames: ["test-uid": "Test DAC"],
            logger: AppLogger.noop()
        )

        XCTAssertEqual(result.preservedUID, "test-uid")
        XCTAssertEqual(result.message, "Test DAC disconnected — waiting for it to come back.")
        let s = await store.settings
        XCTAssertEqual(s.outputDeviceUID, "test-uid")
        XCTAssertTrue(s.hogModeEnabled)
        XCTAssertEqual(s.volumeMode, .forceMax)
    }
```

- [ ] **Step 4: Add the reattach-watcher test**

```swift
    func testSpawnReattachWatcherReacquiresOnReappear() async throws {
        let lister = StubAudioDeviceLister(initialDevices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hog = HogModeController()
        let vol = DeviceVolumeController()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("device-reattach-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try JSONConfigStore(url: tmp)
        try await store.update {
            $0.outputDeviceUID = "test-uid"
            $0.hogModeEnabled = true
            $0.volumeMode = .none
        }

        var reattached = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "test-uid",
            catalog: catalog,
            hogController: hog,
            volumeController: vol,
            store: store,
            logger: AppLogger.noop(),
            onReattached: { reattached = true }
        )

        // Initially absent — watcher should not fire.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(reattached)

        // Simulate reappearance.
        await lister.set([AudioDevice(uid: "test-uid", name: "Test DAC", transportType: .usb)])
        await catalog.reload()

        // Wait for the watcher's onReattached MainActor.run to schedule.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(reattached)
        task.cancel()
    }
```

Note: this test does NOT verify the actual CoreAudio hog acquisition (we have no real device in CI). It verifies the watcher topology — that the reattach callback runs when the held UID appears in a snapshot. The hog/volume controllers will silently fail their CoreAudio calls against `"test-uid"` (no such device exists in the OS), which is fine for this assertion.

If `StubAudioDeviceLister.set(_:)` doesn't exist with that exact signature, adapt to the actual API surfaced in Task 1 Step 4. Likely there's a `setDevices(_:)` or initialiser that takes mutable state.

- [ ] **Step 5: Add the user-override-cancels-watcher test**

```swift
    func testSpawnReattachWatcherDoesNotFireAfterCancellation() async throws {
        let lister = StubAudioDeviceLister(initialDevices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hog = HogModeController()
        let vol = DeviceVolumeController()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("device-reattach-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try JSONConfigStore(url: tmp)

        var reattached = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "test-uid",
            catalog: catalog,
            hogController: hog,
            volumeController: vol,
            store: store,
            logger: AppLogger.noop(),
            onReattached: { reattached = true }
        )
        task.cancel()

        await lister.set([AudioDevice(uid: "test-uid", name: "Test DAC", transportType: .usb)])
        await catalog.reload()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(reattached)
    }
```

- [ ] **Step 6: Run all tests**

Run: `swift test --filter DeviceReattachTests 2>&1 | tail -20`
Expected: 4 tests PASS.

Then run the full suite to confirm nothing else broke:

Run: `swift test 2>&1 | tail -10`
Expected: All tests PASS, total count = previous + 4.

- [ ] **Step 7: Commit**

```bash
git add Tests/RPPlayerTests/DeviceReattachTests.swift
git commit -m "test(app): integration tests for device-lost policy + reattach watcher"
```

---

## Task 9: `SettingsViewModel.deviceNameCache` + `disconnectedDevice` computed

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsViewModel.swift`

The picker needs to show a "(disconnected)" row when the saved UID is missing from the live device list. The cache and computed live on the existing view model.

- [ ] **Step 1: Add the cache property next to `devices`**

```swift
    @Published private(set) var deviceNameCache: [String: String] = [:]
```

- [ ] **Step 2: Populate the cache in the existing device stream subscription**

In `start()` (around line 152), inside the `for await devices in deviceStream` loop, update the cache alongside `self.devices`:

```swift
                await MainActor.run {
                    self.devices = devices
                    for d in devices {
                        self.deviceNameCache[d.uid] = d.name
                    }
                    self.currentDeviceName = devices.first(where: { $0.uid == self.outputDeviceUID })?.name
                        ?? self.deviceNameCache[self.outputDeviceUID ?? ""]
                }
```

(Last line falls back to the cache so `currentDeviceName` survives a disconnect — useful for the existing device-settings section title.)

- [ ] **Step 3: Add the computed `disconnectedDevice` property**

Add near the `devices` declaration:

```swift
    /// Synthesizes a picker row representing the saved output device when it
    /// is not currently in the live device list (e.g. user unplugged the DAC).
    /// Returns nil when no device is selected or the selected device is
    /// present. Used by SettingsView to keep the picker showing the held
    /// selection during a disconnect-while-hog-on scenario.
    var disconnectedDevice: AudioDevice? {
        guard let uid = outputDeviceUID, !uid.isEmpty else { return nil }
        if devices.contains(where: { $0.uid == uid }) { return nil }
        let cached = deviceNameCache[uid] ?? "Unknown device"
        return AudioDevice(
            uid: uid,
            name: "\(cached) (disconnected)",
            transportType: .unknown
        )
    }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds. If `TransportType.unknown` doesn't exist, use whichever variant means "no specific transport" (check the enum: `grep -n "case " Sources/RPPlayer/Player/AudioDevice.swift`).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsViewModel.swift
git commit -m "feat(settings-vm): deviceNameCache + disconnectedDevice synth row"
```

---

## Task 10: VM tests for `disconnectedDevice` synth row

**Files:**
- Create: `Tests/RPPlayerTests/SettingsViewModelDisconnectedRowTests.swift`

- [ ] **Step 1: Write the failing tests**

Create file with:

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelDisconnectedRowTests: XCTestCase {

    func testDisconnectedRowNilWhenNoUIDSelected() async throws {
        let vm = makeVM(initialDevices: [AudioDevice(uid: "a", name: "A", transportType: .usb)])
        XCTAssertNil(vm.disconnectedDevice)
    }

    func testDisconnectedRowNilWhenSelectedDevicePresent() async throws {
        let vm = makeVM(initialDevices: [AudioDevice(uid: "a", name: "A", transportType: .usb)])
        await vm.setOutputDeviceUID("a")
        // Allow the settings stream to propagate.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(vm.disconnectedDevice)
    }

    func testDisconnectedRowSynthesizedWhenSelectedDeviceAbsent() async throws {
        let vm = makeVM(initialDevices: [AudioDevice(uid: "a", name: "DragonFly Cobalt", transportType: .usb)])
        await vm.setOutputDeviceUID("a")
        try await Task.sleep(nanoseconds: 50_000_000)
        // Now remove the device from the catalog.
        await (vm.testHelpers_lister as? StubAudioDeviceLister)?.set([])
        // ...trigger the catalog to push the new (empty) snapshot.
        // Implementation: depends on how StubAudioDeviceLister + the test catalog wire together.
        // ...
        try await Task.sleep(nanoseconds: 100_000_000)
        let row = vm.disconnectedDevice
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.uid, "a")
        XCTAssertEqual(row?.name, "DragonFly Cobalt (disconnected)")
    }

    func testDisconnectedRowFallsBackToUnknownDeviceLabel() async throws {
        // If the cache has no entry for the held UID (e.g. UID was loaded
        // from disk and the device has never been present in this session),
        // we fall back to "Unknown device (disconnected)".
        let vm = makeVM(initialDevices: [])
        await vm.setOutputDeviceUID("never-seen-uid")
        try await Task.sleep(nanoseconds: 100_000_000)
        let row = vm.disconnectedDevice
        XCTAssertEqual(row?.name, "Unknown device (disconnected)")
    }

    // MARK: - Helpers

    private func makeVM(initialDevices: [AudioDevice]) -> SettingsViewModel {
        // ... build using the same pattern existing SettingsViewModelTests use.
        // Look in Tests/RPPlayerTests/SettingsViewModelTests.swift for the
        // canonical factory. Replicate it here.
        fatalError("Replace with the actual factory pattern from SettingsViewModelTests.swift")
    }
}
```

- [ ] **Step 2: Locate the existing `SettingsViewModelTests` factory and replicate**

Run: `grep -rn "func makeViewModel\|private func make.*SettingsViewModel\|SettingsViewModel(" Tests/RPPlayerTests/ | head -10`
Expected: find the factory. Copy its construction into the `makeVM` helper above. It likely takes a `StubAudioDeviceLister` or builds an in-memory `ConfigStore`.

For the third test (synth row appears when device removed), you may need to expose a way to update the stub's device list AND get the catalog to notify the VM. If the test setup doesn't make this easy, simplify the test by:
1. Constructing the VM with empty devices.
2. Manually populating the VM's `deviceNameCache` if the public surface allows (or via `@testable import` write).
3. Setting `outputDeviceUID = "a"`.
4. Asserting that `disconnectedDevice` synthesizes correctly.

Use whichever approach has the smallest test-surface footprint.

- [ ] **Step 3: Run the new tests**

Run: `swift test --filter SettingsViewModelDisconnectedRowTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/RPPlayerTests/SettingsViewModelDisconnectedRowTests.swift
git commit -m "test(settings-vm): disconnectedDevice synth row coverage"
```

---

## Task 11: SettingsView picker — inject synth row

**Files:**
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift:144-163` (audioSection)

- [ ] **Step 1: Update the picker `ForEach` to include the synth row**

Current (lines 147-152):

```swift
                Picker("Output device", selection: deviceBinding) {
                    Text("Select an output device").tag(String?.none)
                    ForEach(viewModel.devices, id: \.uid) { device in
                        Text(deviceLabel(device)).tag(Optional(device.uid))
                    }
                }
```

Replace with:

```swift
                Picker("Output device", selection: deviceBinding) {
                    Text("Select an output device").tag(String?.none)
                    if let disconnected = viewModel.disconnectedDevice {
                        // Held selection — device is absent. Show it as
                        // selectable so the picker doesn't render blank.
                        Text(deviceLabel(disconnected)).tag(Optional(disconnected.uid))
                    }
                    ForEach(viewModel.devices, id: \.uid) { device in
                        Text(deviceLabel(device)).tag(Optional(device.uid))
                    }
                }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: build succeeds.

- [ ] **Step 3: Manual smoke (skip if no hardware)**

Run the app, plug + select a USB DAC, enable hog. Unplug. Open the popover Settings → confirm picker shows "DragonFly Cobalt (disconnected)" selected.

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Shell/SettingsView.swift
git commit -m "feat(settings-ui): picker shows '(disconnected)' row for held device"
```

---

## Task 12: Documentation updates

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add CHANGELOG entry**

Open `CHANGELOG.md`. Under `## [Unreleased]` → `### Added`, add:

```
- Preserve output device selection + hog mode + Force Max Volume when the active device disconnects while hog mode is on; auto-re-acquire hog (and re-pin Force Max volume) when the same device reappears. Playback stays stopped — user clicks play to resume. Settings picker shows the held device as "DeviceName (disconnected)" while it's absent.
```

If no `### Added` subsection exists under `## [Unreleased]`, create it.

- [ ] **Step 2: Add `docs/pr-history.md` row**

Append a new row to the status table following the existing format. PR number: next available (after PR 36). Description should be a single dense line summarizing the change in the same style as existing rows (see PR 35 / PR 36 entries for tone).

Example:

```
| 37   | claude/device-reattach-on-hog | ⏳ | Device reattach when hog: `AppContainer.handleDeviceLost` (preserve when `hogModeEnabled` / hearing-safety reset when off) shared by `onDeviceUnavailable` closure AND the catalog-changes watcher; `AppContainer.spawnReattachWatcher` one-shot Task subscribed to `CoreAudioDeviceCatalog.changes` re-acquires hog + (if Force Max) `volumeController.setVolumeMax` when held UID reappears, then calls `onReattached` via MainActor.run. New `DeviceReattachState` @MainActor holder (`heldUID` / `reattachTask` / `lastKnownDeviceNames` / `onReattached`) glues the disconnect sites + reattach callback together. `PlaybackCoordinator.emitUserMessage(_:)` seam lets the handler push friendly "DeviceName disconnected — waiting for it to come back." banner; coordinator no longer hardcodes the -14 message. `MiniPlayerViewModel.clearErrorMessage()` dismisses the banner on reattach. User-override detection in the existing `store.changes` Task cancels the watcher when the user picks a different device or toggles hog off while held. `SettingsViewModel` adds `deviceNameCache` + computed `disconnectedDevice` synth row; `SettingsView` picker injects it. Startup-clear path at AppContainer.swift:106-129 unchanged (no parity decision). Tests: 4 new `DeviceReattachTests` + N new `SettingsViewModelDisconnectedRowTests`. |
```

(Update the test count substitution `N` to match the actual number after Task 10.)

- [ ] **Step 3: Append to `docs/test-counts.md`**

Append a new line in the existing format. Example:

```
- 2026-05-20  466 tests (462 + 4 reattach helpers; SettingsViewModelDisconnectedRowTests count varies — see Task 10)
```

(Replace numbers with the actual final count from `swift test`.)

- [ ] **Step 4: Update `CLAUDE.md` *Current state* block**

Replace the `Last merged` line + `Next up` line to reflect this PR. Example:

```
- Last merged: **PR 37** — Device reattach when hog. On disconnect while `hogModeEnabled`, preserve `outputDeviceUID` + hog + Force Max; auto-re-acquire on reattach via a one-shot catalog watcher; friendly "(DeviceName) disconnected — waiting for it to come back." banner replaces the hearing-safety reset message in this branch. Picker shows "(disconnected)" row for the held UID. Startup-clear path unchanged. 466 tests.
- **Next up:** TBD — pick from the deferred list (`docs/pr-history.md` § Deferred) or brainstorm the next subsystem.
```

(Numbers/dates to match the actual merge.)

- [ ] **Step 5: Commit docs**

```bash
git add CHANGELOG.md docs/pr-history.md docs/test-counts.md CLAUDE.md
git commit -m "docs: device-reattach-when-hog PR entries + CLAUDE.md state"
```

---

## Task 13: Final verification + merge prep

**Files:**
- N/A

- [ ] **Step 1: Run the full suite one more time**

Run: `swift test 2>&1 | tail -10`
Expected: All tests PASS. Count matches what's recorded in `docs/test-counts.md`.

- [ ] **Step 2: Build release config to catch warning-vs-error mismatches**

Run: `swift build -c release 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Review the full diff against main**

Run: `git diff main --stat`
Expected: changes touch only the files listed in the File Structure table. No drive-by edits to unrelated files.

- [ ] **Step 4: Confirm with user that the PR is ready to merge**

Per project workflow (`CLAUDE.md` → "Merge strategy: fast-forward only (`git merge --ff-only`) to main after all reviews pass"), do not merge unprompted. Report status and wait for the go-ahead.

---

## Self-Review Notes

(Inline check after writing this plan; ran without dispatching a subagent.)

- **Spec coverage:** all five decisions (auto re-acquire + stay paused, Force Max preserved, no startup parity, "(disconnected)" picker label, friendly banner with auto-clear) map to tasks 5/6/7/9/11. The two open questions from the spec are resolved in the Pre-flight notes (Q2 → release() already clears state; Q3 → AppContainer is fine, no helper component needed) and the third (Q1 → banner clear via `MiniPlayerViewModel.clearErrorMessage()`) is Task 2 + Task 7.
- **Placeholder scan:** one fatalError remains in Task 10 Step 1 as a deliberate "look at existing factory and replicate" prompt — the canonical pattern depends on what the existing `SettingsViewModelTests` use, which I haven't fully read. Step 2 of that task instructs the engineer to fill it in. This is acceptable per the "look at existing patterns" guidance, not a TBD; everywhere else, code is complete.
- **Type consistency:** `handleDeviceLost` returns `(message: String?, preservedUID: String?)` — used the same labels at both call sites. `spawnReattachWatcher` signature consistent at both call sites. `DeviceReattachState.onReattached` introduced as `@MainActor () -> Void` and called via `MainActor.run` from inside the spawned Task.
- **One small risk:** the forward-capture of `coordinator` and `deviceCatalog` in `onDeviceUnavailable` may need the restructure described in Task 6 Step 4. The plan flags this explicitly and gives the fix. No silent assumption.
