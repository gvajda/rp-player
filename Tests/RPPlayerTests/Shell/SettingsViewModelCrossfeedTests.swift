import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelCrossfeedTests: XCTestCase {
    private var configStore: StubConfigStore!
    private var deviceCatalog: StubAudioDeviceCatalog!
    private var auth: StubKeychainAuth!
    private var sut: SettingsViewModel!
    private var presetDir: URL!

    override func setUp() async throws {
        configStore = StubConfigStore(initial: AppSettings.default)
        deviceCatalog = StubAudioDeviceCatalog(initial: [])
        auth = StubKeychainAuth()
        presetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-vm-crossfeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await sut?.stop()
        try? FileManager.default.removeItem(at: presetDir)
    }

    private func makeVM(_ settings: AppSettings) -> SettingsViewModel {
        configStore = StubConfigStore(initial: settings)
        let vm = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: presetDir)
        )
        sut = vm
        return vm
    }

    func testInitialPropsReflectActiveProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = AudioProfile(
            hogModeEnabled: false,
            releaseHogOnPauseEnabled: false,
            volumeMode: .none,
            bitrate: 3,
            eqEnabled: false,
            eqPresetName: nil,
            crossfeedEnabled: true,
            crossfeedStrength: 0.35,
            crossfeedRange: 0.65
        )
        let vm = makeVM(settings)
        await vm.start()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.crossfeedEnabled)
        XCTAssertEqual(vm.crossfeedStrength, 0.35, accuracy: 1e-9)
        XCTAssertEqual(vm.crossfeedRange, 0.65, accuracy: 1e-9)
    }

    func testSetCrossfeedEnabledWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedEnabled, true)
    }

    func testSetCrossfeedStrengthWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedStrength(0.45)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedStrength ?? 0, 0.45, accuracy: 1e-9)
    }

    func testSetCrossfeedRangeWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedRange(0.75)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedRange ?? 0, 0.75, accuracy: 1e-9)
    }

    func testSettersClampOutOfRangeInput() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedStrength(1.7)
        await vm.setCrossfeedRange(-0.3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedStrength ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedRange ?? -1, 0.0, accuracy: 1e-9)
    }

    func testSettersAreNoOpWithoutSelectedDevice() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = nil
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedEnabled(true)
        await vm.setCrossfeedStrength(0.4)
        await vm.setCrossfeedRange(0.6)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(configStore.current.audioProfiles.isEmpty)
    }
}
