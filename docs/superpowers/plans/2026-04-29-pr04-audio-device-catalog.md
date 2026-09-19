# PR 4: AudioDeviceCatalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `AudioDeviceCatalog` that enumerates CoreAudio output devices (name, UID, transport type), surfaces a snapshot, and emits hot-plug updates via `AsyncStream<[AudioDevice]>` so `SettingsView` can drive the output-device picker (see DESIGN.md §4 + §6.2).

**Architecture:** Pure value types (`AudioDevice`, `TransportType`) carry the device data. `AudioDeviceLister` is a low-level seam that returns the current device list synchronously; `CoreAudioDeviceLister` is the production implementation backed by `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices, …)`. `CoreAudioDeviceCatalog` is a Swift actor implementing `AudioDeviceCatalog`: it caches the latest snapshot, fans out updates via continuations (matching the `JSONConfigStore.changes` pattern), and registers an `AudioObjectAddPropertyListenerBlock` against `kAudioHardwarePropertyDevices` so hot-plug events trigger a reload. A `HotplugListener` reference type owns the CoreAudio listener registration and removes it in `deinit`.

**Tech Stack:** Swift 6.2, CoreAudio (`AudioToolbox`/`CoreAudio` system framework), XCTest.

---

## File map

**New source files:**
- `Sources/RPPlayer/Player/AudioDevice.swift` — `AudioDevice` struct + `TransportType` enum + `TransportType.init(rawCoreAudioValue:)`
- `Sources/RPPlayer/Player/AudioDeviceCatalog.swift` — `AudioDeviceCatalog` protocol, `AudioDeviceLister` protocol, `CoreAudioDeviceLister` struct, `CoreAudioDeviceCatalog` actor, `HotplugListener` private class

**New test files:**
- `Tests/RPPlayerTests/Player/TransportTypeTests.swift` — pure mapping table tests
- `Tests/RPPlayerTests/Player/StubAudioDeviceLister.swift` — programmable lister test double
- `Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift` — actor logic via stub lister + smoke test against real CoreAudio

**Modified:**
- (none)

`Package.swift` already declares `platforms: [.macOS(.v13)]`. CoreAudio is a system framework auto-linked when `import CoreAudio` is present; no linker setting expected. If the linker complains, Task 5 documents the fallback.

---

## Task 1: AudioDevice value types + TransportType mapping

**Files:**
- Create: `Tests/RPPlayerTests/Player/TransportTypeTests.swift`
- Create: `Sources/RPPlayer/Player/AudioDevice.swift`

`TransportType` raw values are CoreAudio four-char-codes (UInt32). The constants are defined in `<CoreAudio/AudioHardwareBase.h>`:

| Constant | Hex | Four-char |
|---|---|---|
| `kAudioDeviceTransportTypeBuiltIn` | 0x626C746E | `'bltn'` |
| `kAudioDeviceTransportTypeUSB` | 0x75736220 | `'usb '` |
| `kAudioDeviceTransportTypeThunderbolt` | 0x7468756E | `'thun'` |
| `kAudioDeviceTransportTypeHDMI` | 0x68646D69 | `'hdmi'` |
| `kAudioDeviceTransportTypeBluetooth` | 0x626C7565 | `'blue'` |
| `kAudioDeviceTransportTypeBluetoothLE` | 0x626C6561 | `'blea'` |
| `kAudioDeviceTransportTypeAirPlay` | 0x61697270 | `'airp'` |
| `kAudioDeviceTransportTypeUnknown` | 0 | — |

The DESIGN spec calls out USB / Thunderbolt / HDMI / Built-in / Bluetooth / AirPlay. Anything else (DisplayPort, FireWire, Aggregate, Virtual, …) maps to `.unknown` for v1 — the picker UI only differentiates the listed cases.

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Player/TransportTypeTests.swift`:

```swift
import XCTest
import CoreAudio
@testable import RPPlayer

final class TransportTypeTests: XCTestCase {
    func testMapsKnownTransportTypes() {
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeThunderbolt), .thunderbolt)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeHDMI), .hdmi)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeAirPlay), .airplay)
    }

    func testUnknownMapsToUnknown() {
        XCTAssertEqual(TransportType(rawCoreAudioValue: 0), .unknown)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeUnknown), .unknown)
    }

    func testUnmappedTransportTypeFallsBackToUnknown() {
        // 'aggr' (kAudioDeviceTransportTypeAggregate) is a real CoreAudio value
        // we explicitly do not surface in v1.
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeAggregate), .unknown)
    }

    func testIsBitPerfectRecommended() {
        XCTAssertTrue(TransportType.usb.isBitPerfectRecommended)
        XCTAssertTrue(TransportType.thunderbolt.isBitPerfectRecommended)
        XCTAssertTrue(TransportType.hdmi.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.builtIn.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.bluetooth.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.airplay.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.unknown.isBitPerfectRecommended)
    }

    func testAudioDeviceIsEquatableAndSendable() {
        let a = AudioDevice(uid: "uid-1", name: "Device 1", transportType: .usb)
        let b = AudioDevice(uid: "uid-1", name: "Device 1", transportType: .usb)
        let c = AudioDevice(uid: "uid-2", name: "Device 2", transportType: .builtIn)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TransportTypeTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'TransportType'` or `cannot find type 'AudioDevice'`.

- [ ] **Step 3: Implement AudioDevice.swift**

Create `Sources/RPPlayer/Player/AudioDevice.swift`:

```swift
import CoreAudio
import Foundation

public struct AudioDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let transportType: TransportType

    public init(uid: String, name: String, transportType: TransportType) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
    }

    public var id: String { uid }
}

public enum TransportType: String, Equatable, Sendable, CaseIterable {
    case builtIn
    case usb
    case thunderbolt
    case hdmi
    case bluetooth
    case airplay
    case unknown

    /// Returns whether this transport can plausibly deliver bit-perfect audio.
    /// Bluetooth always re-encodes; AirPlay ditto; Built-in is technically
    /// bit-perfect but never the right choice for an external DAC scenario.
    public var isBitPerfectRecommended: Bool {
        switch self {
        case .usb, .thunderbolt, .hdmi: return true
        case .builtIn, .bluetooth, .airplay, .unknown: return false
        }
    }

    /// Maps a raw CoreAudio `kAudioDevicePropertyTransportType` four-char-code value
    /// to a stable case. BluetoothLE collapses into `.bluetooth` — the picker UI does
    /// not need to distinguish them. Anything not listed maps to `.unknown`.
    public init(rawCoreAudioValue value: UInt32) {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn:                 self = .builtIn
        case kAudioDeviceTransportTypeUSB:                     self = .usb
        case kAudioDeviceTransportTypeThunderbolt:             self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI:                    self = .hdmi
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:             self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay:                 self = .airplay
        default:                                               self = .unknown
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter TransportTypeTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/AudioDevice.swift \
        Tests/RPPlayerTests/Player/TransportTypeTests.swift
git commit -m "feat(pr04): add AudioDevice value type and TransportType mapping"
```

---

## Task 2: AudioDeviceCatalog protocol + AudioDeviceLister seam + StubAudioDeviceLister

This task introduces the protocols and the test double, but no production CoreAudio code yet. We need the test double in place first so Task 3's actor tests can be driven without poking real hardware.

**Files:**
- Create: `Tests/RPPlayerTests/Player/StubAudioDeviceLister.swift`
- Create: `Sources/RPPlayer/Player/AudioDeviceCatalog.swift` (protocols + lister protocol; actor and CoreAudio impl come in Tasks 3–4)

- [ ] **Step 1: Create the StubAudioDeviceLister test double**

Create `Tests/RPPlayerTests/Player/StubAudioDeviceLister.swift`:

```swift
import Foundation
@testable import RPPlayer

/// Programmable AudioDeviceLister for tests. Mutate `_devices` to simulate
/// hot-plug events; tests then drive the catalog by calling `reload()` on it.
final class StubAudioDeviceLister: AudioDeviceLister, @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [AudioDevice]

    init(devices: [AudioDevice]) {
        self._devices = devices
    }

    func currentDevices() -> [AudioDevice] {
        lock.lock(); defer { lock.unlock() }
        return _devices
    }

    func setDevices(_ devices: [AudioDevice]) {
        lock.lock(); defer { lock.unlock() }
        _devices = devices
    }
}
```

- [ ] **Step 2: Create the AudioDeviceCatalog protocol file (protocols only — actor in Task 3)**

Create `Sources/RPPlayer/Player/AudioDeviceCatalog.swift`:

```swift
import Foundation

/// High-level interface consumed by `SettingsView`. Provides the current snapshot
/// and an `AsyncStream` of every subsequent change. Mirrors the
/// `JSONConfigStore.changes` pattern: the stream yields the current snapshot
/// immediately on subscription, then yields whenever the device set changes.
public protocol AudioDeviceCatalog: Sendable {
    var devices: [AudioDevice] { get async }
    var changes: AsyncStream<[AudioDevice]> { get async }
}

/// Low-level seam: returns the current set of CoreAudio output devices on demand.
/// Production code uses `CoreAudioDeviceLister` (added in Task 3); tests use
/// `StubAudioDeviceLister` to drive the actor without real hardware.
public protocol AudioDeviceLister: Sendable {
    func currentDevices() -> [AudioDevice]
}
```

- [ ] **Step 3: Verify the project still builds**

```
swift build 2>&1 | tail -10
```

Expected: `Build complete!`. (No tests yet for these protocols — Task 3 exercises them.)

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Player/AudioDeviceCatalog.swift \
        Tests/RPPlayerTests/Player/StubAudioDeviceLister.swift
git commit -m "feat(pr04): add AudioDeviceCatalog and AudioDeviceLister protocols + stub"
```

---

## Task 3: CoreAudioDeviceCatalog actor (snapshot + changes stream, manual reload)

This task implements the actor's stream/snapshot fan-out and an internal `reload()` entry point. The CoreAudio listener wiring comes in Task 4 — keeping these split lets the stream behaviour be unit-tested without involving real hardware.

**Files:**
- Create: `Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift`
- Modify: `Sources/RPPlayer/Player/AudioDeviceCatalog.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class CoreAudioDeviceCatalogTests: XCTestCase {
    private let deviceA = AudioDevice(uid: "uid-A", name: "DAC A", transportType: .usb)
    private let deviceB = AudioDevice(uid: "uid-B", name: "DAC B", transportType: .thunderbolt)
    private let deviceBuiltin = AudioDevice(uid: "uid-builtin", name: "MacBook Speakers", transportType: .builtIn)

    func testInitialSnapshotMatchesLister() async {
        let lister = StubAudioDeviceLister(devices: [deviceA, deviceBuiltin])
        let sut = CoreAudioDeviceCatalog(lister: lister)
        let snapshot = await sut.devices
        XCTAssertEqual(snapshot, [deviceA, deviceBuiltin])
    }

    func testChangesYieldsCurrentSnapshotImmediately() async {
        let lister = StubAudioDeviceLister(devices: [deviceA])
        let sut = CoreAudioDeviceCatalog(lister: lister)
        let stream = await sut.changes
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [deviceA])
    }

    func testReloadEmitsChangedSnapshot() async {
        let lister = StubAudioDeviceLister(devices: [deviceA])
        let sut = CoreAudioDeviceCatalog(lister: lister)
        let stream = await sut.changes
        let collector = Task { () -> [[AudioDevice]] in
            var snapshots: [[AudioDevice]] = []
            for await s in stream {
                snapshots.append(s)
                if snapshots.count == 2 { return snapshots }
            }
            return snapshots
        }
        // Simulate a hot-plug event.
        lister.setDevices([deviceA, deviceB])
        await sut.reload()
        let result = await collector.value
        XCTAssertEqual(result, [[deviceA], [deviceA, deviceB]])
    }

    func testReloadWithUnchangedListIsNoOp() async {
        let lister = StubAudioDeviceLister(devices: [deviceA])
        let sut = CoreAudioDeviceCatalog(lister: lister)
        let stream = await sut.changes
        let collector = Task { () -> [[AudioDevice]] in
            var snapshots: [[AudioDevice]] = []
            for await s in stream {
                snapshots.append(s)
                if snapshots.count == 2 { return snapshots }
            }
            return snapshots
        }
        await sut.reload() // no-op (devices unchanged)
        lister.setDevices([deviceA, deviceB])
        await sut.reload() // real change
        let result = await collector.value
        // First emission is the initial snapshot; second is the real change.
        XCTAssertEqual(result, [[deviceA], [deviceA, deviceB]])
    }

    func testMultipleSubscribersAllReceiveUpdates() async {
        let lister = StubAudioDeviceLister(devices: [deviceA])
        let sut = CoreAudioDeviceCatalog(lister: lister)
        let stream1 = await sut.changes
        let stream2 = await sut.changes
        async let first1: [AudioDevice]? = {
            var it = stream1.makeAsyncIterator()
            _ = await it.next() // initial snapshot
            return await it.next() // post-reload
        }()
        async let first2: [AudioDevice]? = {
            var it = stream2.makeAsyncIterator()
            _ = await it.next() // initial snapshot
            return await it.next() // post-reload
        }()
        lister.setDevices([deviceA, deviceB])
        await sut.reload()
        let r1 = await first1
        let r2 = await first2
        XCTAssertEqual(r1, [deviceA, deviceB])
        XCTAssertEqual(r2, [deviceA, deviceB])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter CoreAudioDeviceCatalogTests 2>&1 | head -20
```

Expected: compile error containing `cannot find type 'CoreAudioDeviceCatalog'`.

- [ ] **Step 3: Add the actor to AudioDeviceCatalog.swift**

Append to `Sources/RPPlayer/Player/AudioDeviceCatalog.swift` (keep the protocols already added in Task 2, then append the actor below — full updated file shown below for clarity):

```swift
import CoreAudio
import Foundation

public protocol AudioDeviceCatalog: Sendable {
    var devices: [AudioDevice] { get async }
    var changes: AsyncStream<[AudioDevice]> { get async }
}

public protocol AudioDeviceLister: Sendable {
    func currentDevices() -> [AudioDevice]
}

public actor CoreAudioDeviceCatalog: AudioDeviceCatalog {
    private let lister: any AudioDeviceLister
    private var current: [AudioDevice]
    private var continuations: [UUID: AsyncStream<[AudioDevice]>.Continuation] = [:]

    public init(lister: any AudioDeviceLister) {
        self.lister = lister
        self.current = lister.currentDevices()
    }

    public var devices: [AudioDevice] { current }

    /// Subscribes a new continuation atomically: by the time the stream is returned,
    /// the subscriber is registered and has been yielded the current snapshot.
    public var changes: AsyncStream<[AudioDevice]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    /// Re-enumerates devices via the lister and yields the new snapshot to every
    /// subscriber if the list changed. Called from the CoreAudio hot-plug listener
    /// (Task 4) and directly from tests.
    public func reload() {
        let new = lister.currentDevices()
        guard new != current else { return }
        current = new
        for c in continuations.values {
            c.yield(new)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter CoreAudioDeviceCatalogTests 2>&1 | tail -10
```

Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/AudioDeviceCatalog.swift \
        Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift
git commit -m "feat(pr04): CoreAudioDeviceCatalog actor with snapshot + changes stream"
```

---

## Task 4: CoreAudioDeviceLister + hot-plug observation

Production wiring: enumerate output devices via CoreAudio, and register an `AudioObjectAddPropertyListenerBlock` against `kAudioHardwarePropertyDevices` so device add/remove events trigger `reload()` on the actor. The CoreAudio listener requires a dispatch queue and a block that we hold onto for later removal — encapsulated in a `HotplugListener` reference type.

**Why a separate `HotplugListener` class:** `AudioObjectAddPropertyListenerBlock` returns no token. Removal needs the same `block` reference passed back to `AudioObjectRemovePropertyListenerBlock`. Holding the block in a class lets `deinit` clean up unconditionally, so `CoreAudioDeviceCatalog.deinit` (or losing the strong reference) tears down the registration.

**Filtering logic:** of the device IDs returned by `kAudioHardwarePropertyDevices`, only keep those that have ≥1 output channel (queried via `kAudioDevicePropertyStreamConfiguration` with `mScope = kAudioDevicePropertyScopeOutput`). The list also includes input-only devices (USB mics, the MacBook microphone), which the picker must not show.

**Files:**
- Create: `Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift` (append a smoke test — see Step 1 below)
- Modify: `Sources/RPPlayer/Player/AudioDeviceCatalog.swift` (add `CoreAudioDeviceLister`, `HotplugListener`, `startWatching()`/`stopWatching()` on the actor)

- [ ] **Step 1: Add the smoke test**

Append to `Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift`:

```swift
extension CoreAudioDeviceCatalogTests {
    /// Smoke test: enumerate the host's real CoreAudio devices. CI runners and
    /// dev Macs always expose at least one output device (built-in speakers
    /// or the headphone jack), so this assertion is safe.
    func testCoreAudioDeviceListerReturnsHostDevices() {
        let lister = CoreAudioDeviceLister()
        let devices = lister.currentDevices()
        XCTAssertFalse(devices.isEmpty, "expected at least one CoreAudio output device on the host")
        // Every device must have a non-empty UID and name. Transport type may be .unknown.
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty, "device UID should not be empty")
            XCTAssertFalse(device.name.isEmpty, "device name should not be empty for \(device.uid)")
        }
    }

    /// Smoke test: instantiating with the real lister and starting/stopping the
    /// hot-plug listener does not crash and does not leak the listener.
    func testStartAndStopWatchingDoesNotCrash() async {
        let sut = CoreAudioDeviceCatalog(lister: CoreAudioDeviceLister())
        await sut.startWatching()
        await sut.stopWatching()
    }
}
```

- [ ] **Step 2: Run test to verify the smoke tests fail**

```
swift test --filter CoreAudioDeviceCatalogTests 2>&1 | head -20
```

Expected: compile error containing `cannot find 'CoreAudioDeviceLister'` and/or `value of type 'CoreAudioDeviceCatalog' has no member 'startWatching'`.

- [ ] **Step 3: Add CoreAudioDeviceLister, HotplugListener, and watching API**

Edit `Sources/RPPlayer/Player/AudioDeviceCatalog.swift`. The full file after this edit:

```swift
import CoreAudio
import Foundation

public protocol AudioDeviceCatalog: Sendable {
    var devices: [AudioDevice] { get async }
    var changes: AsyncStream<[AudioDevice]> { get async }
}

public protocol AudioDeviceLister: Sendable {
    func currentDevices() -> [AudioDevice]
}

public struct CoreAudioDeviceLister: AudioDeviceLister {
    public init() {}

    public func currentDevices() -> [AudioDevice] {
        let ids = Self.allDeviceIDs()
        return ids.compactMap(Self.audioDevice(from:))
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func audioDevice(from id: AudioDeviceID) -> AudioDevice? {
        guard hasOutputChannels(id) else { return nil }
        guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? uid
        let transportRaw = uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
        return AudioDevice(uid: uid, name: name, transportType: TransportType(rawCoreAudioValue: transportRaw))
    }

    private static func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        for buf in bufferList where buf.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value else { return nil }
        return cf as String
    }

    private static func uint32Property(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }
}

public actor CoreAudioDeviceCatalog: AudioDeviceCatalog {
    private let lister: any AudioDeviceLister
    private var current: [AudioDevice]
    private var continuations: [UUID: AsyncStream<[AudioDevice]>.Continuation] = [:]
    private var hotplugListener: HotplugListener?

    public init(lister: any AudioDeviceLister) {
        self.lister = lister
        self.current = lister.currentDevices()
    }

    public var devices: [AudioDevice] { current }

    public var changes: AsyncStream<[AudioDevice]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.continuations[id] = continuation
            continuation.yield(self.current)
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.unregister(id: id) }
            }
        }
    }

    public func reload() {
        let new = lister.currentDevices()
        guard new != current else { return }
        current = new
        for c in continuations.values {
            c.yield(new)
        }
    }

    /// Starts observing `kAudioHardwarePropertyDevices`. Idempotent.
    /// Production code calls this once after constructing the catalog.
    public func startWatching() {
        guard hotplugListener == nil else { return }
        hotplugListener = HotplugListener { [weak self] in
            Task { await self?.reload() }
        }
    }

    /// Stops observing hot-plug events. Idempotent.
    public func stopWatching() {
        hotplugListener = nil
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// Owns one `AudioObjectAddPropertyListenerBlock` registration against
/// `kAudioHardwarePropertyDevices`. Releases the registration in `deinit` so
/// callers do not need to clean up explicitly. Marked `@unchecked Sendable`
/// because the captured closure and the stored block are only mutated during
/// init/deinit, both of which are exclusive.
private final class HotplugListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gvajda.RPPlayer.audio-hotplug")
    private let block: AudioObjectPropertyListenerBlock
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @Sendable () -> Void) {
        // Ignore both block parameters: the only signal we need is "something changed".
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        self.block = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter CoreAudioDeviceCatalogTests 2>&1 | tail -15
```

Expected: `Executed 7 tests, with 0 failures` (5 from Task 3 + 2 smoke tests added here).

- [ ] **Step 5: Commit**

```bash
git add Sources/RPPlayer/Player/AudioDeviceCatalog.swift \
        Tests/RPPlayerTests/Player/CoreAudioDeviceCatalogTests.swift
git commit -m "feat(pr04): CoreAudioDeviceLister enumeration + hot-plug observation"
```

---

## Task 5: Full build + test verification

Sanity-check the whole module compiles cleanly and the full test suite still passes (PR 1–3 plus PR 4).

**Files:**
- Verify only.

- [ ] **Step 1: Full build**

```
swift build 2>&1 | tail -10
```

Expected: `Build complete!` with 0 errors.

If the linker reports `Undefined symbols ... _AudioObjectGetPropertyData` or `framework not found CoreAudio`, add the explicit linker setting to `Package.swift`:

```swift
.executableTarget(
    name: "RPPlayer",
    path: "Sources/RPPlayer",
    linkerSettings: [
        .linkedFramework("CoreAudio"),
    ]
)
```

(macOS `swift build` should auto-link system frameworks via `import CoreAudio`. The fallback above is documented for completeness only — if Step 1 succeeded, skip the Package.swift change and continue.)

- [ ] **Step 2: Full test suite**

```
swift test 2>&1 | tail -15
```

Expected: `Executed 47 tests, with 0 failures` (35 from PR 1–3 + 5 TransportType + 5 actor logic + 2 CoreAudio smoke).

- [ ] **Step 3: Commit (only if Package.swift was modified in Step 1)**

```bash
git add Package.swift
git commit -m "build(pr04): explicitly link CoreAudio framework"
```

- [ ] **Step 4: Update CLAUDE.md test count**

Edit `CLAUDE.md`. Find the "Test counts by PR" section and replace:

```markdown
- After PR 4: TBD
```

with:

```markdown
- After PR 4: 47 tests
```

(Adjust the number to whatever `swift test` actually reported in Step 2.)

```bash
git add CLAUDE.md
git commit -m "docs(pr04): record post-PR4 test count"
```

---

## Self-review

**Spec coverage check (DESIGN.md §4 + §6.2):**

| Requirement | Covered by |
|---|---|
| Lists CoreAudio output devices (name, UID, transport type) | `CoreAudioDeviceLister.currentDevices()` (Task 4) returns `[AudioDevice]` with `name`, `uid`, `transportType` |
| Output devices only (filter out input-only devices) | `hasOutputChannels(_:)` via `kAudioDevicePropertyStreamConfiguration` / `kAudioDevicePropertyScopeOutput` (Task 4) |
| Transport types: USB / Thunderbolt / HDMI / Built-in / Bluetooth / AirPlay | `TransportType` enum cases (Task 1), mapped from raw CoreAudio four-char codes |
| Watches `kAudioHardwarePropertyDevices` for hot-plug changes | `HotplugListener` registers `AudioObjectAddPropertyListenerBlock` on this selector (Task 4) |
| Emits updates via `AsyncStream<[AudioDevice]>` | `CoreAudioDeviceCatalog.changes` (Task 3) |
| Identifies devices by `kAudioDevicePropertyDeviceUID` (stable string) | `stringProperty(id, selector: kAudioDevicePropertyDeviceUID)` populates `AudioDevice.uid` (Task 4) |
| Bus-type label / "(not recommended for bit-perfect)" UI signal | `TransportType.isBitPerfectRecommended` (Task 1) — consumed by `SettingsView` in PR 10 |
| Bluetooth / AirPlay / Built-in listed but de-emphasized — not blocked | The catalog returns all output devices; consumer (`SettingsView`, PR 10) renders the de-emphasis. No filtering at the catalog layer. |

**Placeholder scan:** searched the plan for "TBD", "TODO", "implement later", "fill in details", "add appropriate", "similar to". The "After PR 4: TBD" line in Step 4 of Task 5 is the spec text in CLAUDE.md being replaced — not a planning placeholder. No other placeholders.

**Type consistency:**
- `AudioDevice` defined Task 1, used Tasks 2–4 ✓
- `TransportType` defined Task 1, used Task 4 (`TransportType(rawCoreAudioValue:)`) ✓
- `AudioDeviceCatalog` protocol defined Task 2, implemented Tasks 3–4 ✓
- `AudioDeviceLister` protocol defined Task 2, implemented in `StubAudioDeviceLister` (Task 2) and `CoreAudioDeviceLister` (Task 4) ✓
- `CoreAudioDeviceCatalog.reload()` defined Task 3, called by `HotplugListener` callback in Task 4 ✓
- `CoreAudioDeviceCatalog.startWatching()`/`stopWatching()` defined Task 4, exercised by smoke test in Task 4 ✓
- `StubAudioDeviceLister` defined Task 2, used in Task 3 tests ✓
- `HotplugListener` is private to `AudioDeviceCatalog.swift`, only consumed by `CoreAudioDeviceCatalog` in the same file ✓

**Test count math:** PR 3 final = 35 tests. PR 4 adds:
- TransportType: 5 tests
- CoreAudioDeviceCatalog stream logic (stub lister): 5 tests
- CoreAudio smoke: 2 tests

Total expected after PR 4: 47 tests. Reflected in Task 5 Step 2 expected output and Step 4 CLAUDE.md update.
