# Hog Mode Sample Rate Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When hog mode is acquired, automatically set the device's nominal sample rate to 44.1 kHz (matching RP streams); restore the original rate when hog is released.

**Architecture:** All changes are confined to `HogModeController.swift`. A new actor-isolated property stores the device's pre-hog sample rate. The `acquire` method reads it before writing hog, then sets 44100 Hz after confirming exclusive ownership. `releaseHog` restores it after writing pid -1. The public `setSampleRate(rate:deviceUID:)` method's behaviour is unchanged but internally delegates to a new private helper that separates the settle sleep from the CoreAudio write.

**Tech Stack:** Swift 6.2, CoreAudio (`AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`, `kAudioDevicePropertyNominalSampleRate`).

---

## File Map

| Action | Path |
|--------|------|
| Modify | `Sources/RPPlayer/Audio/HogModeController.swift` |
| Modify | `Tests/RPPlayerTests/Audio/HogModeControllerTests.swift` |

---

### Task 1: Add failing tests for the new `originalSampleRate` state contract

Real CoreAudio hardware is unavailable in CI, so tests assert state-machine correctness via an `internal private(set)` accessor added in Task 2. These tests must be written first (TDD) and will fail to compile until Task 2 exposes the property.

**Files:**
- Modify: `Tests/RPPlayerTests/Audio/HogModeControllerTests.swift`

- [ ] **Step 1: Append two new test methods to `HogModeControllerTests`**

Open `Tests/RPPlayerTests/Audio/HogModeControllerTests.swift` and add after the existing four tests:

```swift
func testAcquireWithUnknownUIDLeavesOriginalSampleRateNil() async {
    let controller = HogModeController()
    _ = await controller.acquire(deviceUID: "definitely-not-a-real-uid-\(UUID().uuidString)")
    let stored = await controller.originalSampleRate
    XCTAssertNil(stored)
}

func testReleaseWithoutAcquireDoesNotMutateOriginalSampleRate() async {
    let controller = HogModeController()
    await controller.release()
    let stored = await controller.originalSampleRate
    XCTAssertNil(stored)
}
```

- [ ] **Step 2: Verify the tests fail to compile (property not yet exposed)**

```
swift build 2>&1 | grep "originalSampleRate"
```

Expected output contains: `error: 'originalSampleRate' is inaccessible due to 'private' protection level` (or similar — property doesn't exist yet). Proceed once confirmed.

---

### Task 2: Rewrite `HogModeController.swift` with rate enforcement

**Files:**
- Modify: `Sources/RPPlayer/Audio/HogModeController.swift`

- [ ] **Step 1: Replace the entire file contents**

```swift
import CoreAudio
import Foundation

public actor HogModeController {
    private var hoggedDeviceID: AudioDeviceID?
    internal private(set) var originalSampleRate: Double?

    public init() {}

    public var isHogging: Bool { hoggedDeviceID != nil }

    public func acquire(deviceUID: String) -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        if let current = hoggedDeviceID, current == target { return true }
        if hoggedDeviceID != nil {
            releaseHog()
        }
        let savedRate = readSampleRate(deviceID: target)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = getpid()
        let setStatus = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        guard setStatus == noErr else { return false }
        var size = UInt32(MemoryLayout<pid_t>.size)
        var actual: pid_t = -1
        let getStatus = AudioObjectGetPropertyData(
            target, &address, 0, nil, &size, &actual
        )
        guard getStatus == noErr, actual == getpid() else { return false }
        hoggedDeviceID = target
        originalSampleRate = savedRate
        // RP streams are always 44.1 kHz; enforce matching hardware rate to
        // prevent CoreAudio resampling when the device is configured otherwise.
        if !setSampleRateInternal(44100.0, deviceID: target, settle: true) {
            fputs("[HogModeController] setSampleRate(44100) failed — playback may resample\n", stderr)
        }
        return true
    }

    public func release() {
        releaseHog()
    }

    public func setSampleRate(_ rate: Double, deviceUID: String) -> Bool {
        guard let target = deviceID(forUID: deviceUID) else { return false }
        return setSampleRateInternal(rate, deviceID: target, settle: true)
    }

    private func releaseHog() {
        guard let target = hoggedDeviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        _ = AudioObjectSetPropertyData(
            target, &address, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid
        )
        hoggedDeviceID = nil
        if let rate = originalSampleRate {
            // No settle sleep on restore — we are releasing, not about to open IO.
            _ = setSampleRateInternal(rate, deviceID: target, settle: false)
            originalSampleRate = nil
        }
    }

    private func readSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private func setSampleRateInternal(_ rate: Double, deviceID: AudioDeviceID, settle: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Double>.size), &value
        )
        guard status == noErr else { return false }
        if settle {
            // CoreAudio quirk: hardware needs a brief settle window before subsequent IO opens.
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioDeviceUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                ptr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }
}
```

- [ ] **Step 2: Run the full test suite**

```
swift test
```

Expected: all 6 `HogModeControllerTests` pass (4 existing + 2 new). Full suite passes (489 total, or ≥489 if any other tests were added since PR 36).

- [ ] **Step 3: Commit**

```bash
git add Sources/RPPlayer/Audio/HogModeController.swift \
        Tests/RPPlayerTests/Audio/HogModeControllerTests.swift
git commit -m "feat(hog-mode): enforce 44.1 kHz sample rate on acquire, restore on release

HogModeController now reads the device's nominal sample rate before
acquiring hog, stores it, sets 44100 Hz (settle 50ms) after confirming
exclusive ownership, and restores the original rate on release.
No AppContainer / AppSettings / UI changes needed — automatic with hog.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Audio pipeline section under Key technical decisions**

Find the paragraph that begins `**Hog mode is owned by**` and append this sentence at the end of that paragraph:

> Additionally, `acquire(deviceUID:)` reads and stores the device's pre-hog nominal sample rate, then sets it to 44100 Hz after confirming exclusive ownership (`setSampleRateInternal` with a 50 ms settle); `releaseHog` restores the original rate (no settle — no IO will open on the release path) and clears the stored value. This ensures RP's 44.1 kHz streams play through the hardware without CoreAudio resampling even when the device was previously configured at 48 kHz or another rate.

- [ ] **Step 2: Update test count entry for this PR in the *Test counts by PR* section**

Add a new entry at the end of the test count list:

```
- After hog-mode sample rate enforcement — `HogModeController` gains `internal private(set) var originalSampleRate: Double?`; `acquire` reads + stores pre-hog rate and sets 44100 Hz after hog confirmed; `releaseHog` restores original rate (no settle) and clears storage; `setSampleRate(rate:deviceUID:)` delegates to new private `setSampleRateInternal(_:deviceID:settle:)`. New tests: `testAcquireWithUnknownUIDLeavesOriginalSampleRateNil`, `testReleaseWithoutAcquireDoesNotMutateOriginalSampleRate`. 489 → 491.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for hog-mode sample rate enforcement

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
