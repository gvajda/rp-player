import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelDisconnectedRowTests: XCTestCase {
    private var configStore: StubConfigStore!
    private var deviceCatalog: StubAudioDeviceCatalog!
    private var auth: StubKeychainAuth!
    private var sut: SettingsViewModel!

    override func setUp() async throws {
        configStore = StubConfigStore(initial: AppSettings.default)
        deviceCatalog = StubAudioDeviceCatalog(initial: [])
        auth = StubKeychainAuth()
    }

    override func tearDown() async throws {
        await sut?.stop()
    }

    private func makeVM(settings: AppSettings = .default) -> SettingsViewModel {
        configStore = StubConfigStore(initial: settings)
        let vm = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: {},
            openApplicationData: {}
        )
        sut = vm
        return vm
    }

    // 1. No UID selected → nil
    func testDisconnectedDeviceNilWhenNoUIDSelected() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = nil
        let vm = makeVM(settings: settings)
        await vm.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.disconnectedDevice)
    }

    // 2. Selected UID present in live catalog → nil
    func testDisconnectedDeviceNilWhenSelectedDevicePresent() async throws {
        let device = AudioDevice(uid: "dev-A", name: "My DAC", transportType: .usb)
        deviceCatalog.setDevices([device])

        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        let vm = makeVM(settings: settings)
        await vm.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.disconnectedDevice)
    }

    // 3. UID set but device removed from catalog → synth row with cached name
    func testDisconnectedDeviceSynthesizedWithCachedName() async throws {
        let device = AudioDevice(uid: "dev-A", name: "My DAC", transportType: .usb)
        deviceCatalog.setDevices([device])

        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        let vm = makeVM(settings: settings)
        await vm.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Device disappears from catalog
        deviceCatalog.setDevices([])
        try await Task.sleep(nanoseconds: 100_000_000)

        let row = vm.disconnectedDevice
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.uid, "dev-A")
        XCTAssertEqual(row?.name, "My DAC (disconnected)")
        XCTAssertEqual(row?.transportType, .unknown)
    }

    // 4. UID set but never seen → falls back to "Unknown device (disconnected)"
    func testDisconnectedDeviceFallsBackToUnknownWhenCacheMiss() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "uid-never-seen"
        let vm = makeVM(settings: settings)
        await vm.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        let row = vm.disconnectedDevice
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.uid, "uid-never-seen")
        XCTAssertEqual(row?.name, "Unknown device (disconnected)")
    }
}
