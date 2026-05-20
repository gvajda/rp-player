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
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            crossfeedEnabled: true,
            crossfeedProfile: .jmeier,
            crossfeedFcut: 650,
            crossfeedFeedDb: 9.5
        )
        let vm = makeVM(settings)
        await vm.start()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.crossfeedEnabled)
        XCTAssertEqual(vm.crossfeedProfile, .jmeier)
        XCTAssertEqual(vm.crossfeedFcut, 650)
        XCTAssertEqual(vm.crossfeedFeedDb, 9.5, accuracy: 1e-9)
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

    func testSetCrossfeedProfileWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedProfile(.jmeier)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedProfile, .jmeier)
    }

    func testSetCrossfeedFcutClampsAndWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedFcut(50)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFcut, 300)

        await vm.setCrossfeedFcut(99_999)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFcut, 2000)

        await vm.setCrossfeedFcut(850)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFcut, 850)
    }

    func testSetCrossfeedFeedDbClampsAndWritesProfile() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = .safeDefault
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedFeedDb(-3.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFeedDb ?? -1, 1.0, accuracy: 1e-9)

        await vm.setCrossfeedFeedDb(99.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFeedDb ?? -1, 15.0, accuracy: 1e-9)

        await vm.setCrossfeedFeedDb(7.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.current.audioProfiles["dev-A"]?.crossfeedFeedDb ?? -1, 7.2, accuracy: 1e-9)
    }

    func testSettersAreNoOpWithoutSelectedDevice() async throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = nil
        let vm = makeVM(settings)
        await vm.start()

        await vm.setCrossfeedEnabled(true)
        await vm.setCrossfeedProfile(.cmoy)
        await vm.setCrossfeedFcut(850)
        await vm.setCrossfeedFeedDb(7.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(configStore.current.audioProfiles.isEmpty)
    }
}
