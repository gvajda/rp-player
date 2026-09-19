import XCTest
@testable import RPPlayer

@MainActor
final class DeviceReattachTests: XCTestCase {
    private func makeTempStore() throws -> JSONConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceReattachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try JSONConfigStore(url: dir.appendingPathComponent("config.json"))
    }

    private func makeLogger() -> AppLogger {
        AppLogger(category: "DeviceReattachTests")
    }

    // MARK: handleDeviceLost

    func testHandleDeviceLostHogOffClearsSettings() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "some-uid"
            $0.hogModeEnabled = false
            $0.volumeMode = .none
        }
        let hogController = HogModeController()

        let result = await AppContainer.handleDeviceLost(
            store: store,
            hogController: hogController,
            knownDeviceNames: [:],
            logger: makeLogger()
        )

        XCTAssertEqual(
            result.message,
            "Audio device unavailable. Hog mode + Force Max Volume turned off so the next device you pick can't surprise you. Check System Settings → Sound → Output."
        )
        XCTAssertNil(result.preservedUID)

        let s = await store.settings
        XCTAssertNil(s.outputDeviceUID)
        XCTAssertFalse(s.hogModeEnabled)
        XCTAssertEqual(s.volumeMode, .none)
    }

    func testHandleDeviceLostHogOnPreservesSettings() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "test-uid"
            $0.hogModeEnabled = true
            $0.volumeMode = .forceMax
        }
        let hogController = HogModeController()

        let result = await AppContainer.handleDeviceLost(
            store: store,
            hogController: hogController,
            knownDeviceNames: ["test-uid": "Test DAC"],
            logger: makeLogger()
        )

        XCTAssertEqual(result.message, "Test DAC disconnected \u{2014} waiting for it to come back.")
        XCTAssertEqual(result.preservedUID, "test-uid")

        let s = await store.settings
        XCTAssertEqual(s.outputDeviceUID, "test-uid")
        XCTAssertTrue(s.hogModeEnabled)
        XCTAssertEqual(s.volumeMode, .forceMax)
    }

    func testHandleDeviceLostNilUIDReturnsNils() async throws {
        let store = try makeTempStore()
        // outputDeviceUID defaults to nil
        let hogController = HogModeController()

        let result = await AppContainer.handleDeviceLost(
            store: store,
            hogController: hogController,
            knownDeviceNames: [:],
            logger: makeLogger()
        )

        XCTAssertNil(result.message)
        XCTAssertNil(result.preservedUID)
    }

    // MARK: spawnReattachWatcher

    func testSpawnReattachWatcherFiresCallbackOnReappear() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "watch-uid"
            $0.hogModeEnabled = true
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogController = HogModeController()
        let volumeController = DeviceVolumeController()

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "watch-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: volumeController,
            store: store,
            logger: makeLogger(),
            settle: .zero,
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        // Device not yet present — callback must NOT have been called.
        // Sleep long enough for the watcher task to subscribe to catalog.changes.
        try await Task.sleep(nanoseconds: 150_000_000) // 150ms
        XCTAssertFalse(reattachCalled)

        // Now make the device appear and drive the catalog
        lister.setDevices([AudioDevice(uid: "watch-uid", name: "Watch DAC", transportType: .usb)])
        await catalog.reload()

        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        XCTAssertTrue(reattachCalled)
    }

    func testSpawnReattachWatcherDoesNotFireAfterCancellation() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "cancel-uid"
            $0.hogModeEnabled = true
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogController = HogModeController()
        let volumeController = DeviceVolumeController()

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "cancel-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: volumeController,
            store: store,
            logger: makeLogger(),
            onReattached: { reattachCalled = true }
        )

        task.cancel()

        // Make device appear after cancellation
        lister.setDevices([AudioDevice(uid: "cancel-uid", name: "Cancel DAC", transportType: .usb)])
        await catalog.reload()

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertFalse(reattachCalled)
    }

    func testSpawnReattachWatcherSkipsHogWhenReleaseOnPauseIsOn() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "rop-uid"
            $0.hogModeEnabled = true
            $0.releaseHogOnPauseEnabled = true
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogLogger = RecordingLogger()
        let hogController = HogModeController(logger: hogLogger)

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "rop-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: DeviceVolumeController(),
            store: store,
            logger: makeLogger(),
            settle: .zero,
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 150_000_000)
        lister.setDevices([AudioDevice(uid: "rop-uid", name: "ROP DAC", transportType: .usb)])
        await catalog.reload()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(reattachCalled)
        let acquires = hogLogger.entries().filter { $0.contains("hog acquire") }
        XCTAssertTrue(acquires.isEmpty, "watcher must not touch the device when release-on-pause is on: \(acquires)")
    }

    func testSpawnReattachWatcherAcquiresAfterSettleWhenHogIsHeldWhileIdle() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "hold-uid"
            $0.hogModeEnabled = true
            $0.releaseHogOnPauseEnabled = false
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogLogger = RecordingLogger()
        let hogController = HogModeController(logger: hogLogger)

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "hold-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: DeviceVolumeController(),
            store: store,
            logger: makeLogger(),
            settle: .milliseconds(100),
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 150_000_000)
        lister.setDevices([AudioDevice(uid: "hold-uid", name: "Hold DAC", transportType: .usb)])
        await catalog.reload()

        // Before the settle window elapses nothing may have touched the device.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(hogLogger.entries().filter { $0.contains("hog acquire") }.isEmpty)
        XCTAssertFalse(reattachCalled)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(reattachCalled)
        let acquires = hogLogger.entries().filter { $0.contains("hog acquire") && $0.contains("hold-uid") }
        XCTAssertEqual(acquires.count, 1, "expected one acquire attempt after settle: \(hogLogger.entries())")
    }

    func testSpawnReattachWatcherDelaysCallbackDuringSettleWhenReleaseOnPauseIsOn() async throws {
        let store = try makeTempStore()
        try await store.update {
            $0.outputDeviceUID = "rop-settle-uid"
            $0.hogModeEnabled = true
            $0.releaseHogOnPauseEnabled = true
            $0.volumeMode = .none
        }
        let lister = StubAudioDeviceLister(devices: [])
        let catalog = CoreAudioDeviceCatalog(lister: lister)
        let hogLogger = RecordingLogger()
        let hogController = HogModeController(logger: hogLogger)

        var reattachCalled = false
        let task = AppContainer.spawnReattachWatcher(
            heldUID: "rop-settle-uid",
            catalog: catalog,
            hogController: hogController,
            volumeController: DeviceVolumeController(),
            store: store,
            logger: makeLogger(),
            settle: .milliseconds(100),
            onReattached: { reattachCalled = true }
        )
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 150_000_000)
        lister.setDevices([AudioDevice(uid: "rop-settle-uid", name: "ROP Settle DAC", transportType: .usb)])
        await catalog.reload()

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(reattachCalled)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(reattachCalled)
        let acquires = hogLogger.entries().filter { $0.contains("hog acquire") }
        XCTAssertTrue(acquires.isEmpty, "watcher must not touch the device when release-on-pause is on: \(acquires)")
    }
}
