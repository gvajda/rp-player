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

extension CoreAudioDeviceCatalogTests {
    /// Smoke test: enumerate the host's real CoreAudio devices. CI runners and
    /// dev Macs always expose at least one output device (built-in speakers
    /// or the headphone jack), so this assertion is safe.
    func testCoreAudioDeviceListerReturnsHostDevices() {
        let lister = CoreAudioDeviceLister()
        let devices = lister.currentDevices()
        XCTAssertFalse(devices.isEmpty, "expected at least one CoreAudio output device on the host")
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
