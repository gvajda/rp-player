import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var configStore: StubConfigStore!
    private var deviceCatalog: StubAudioDeviceCatalog!
    private var auth: StubKeychainAuth!
    private var sut: SettingsViewModel!

    override func setUp() async throws {
        configStore = StubConfigStore(initial: AppSettings.default)
        deviceCatalog = StubAudioDeviceCatalog(initial: [])
        auth = StubKeychainAuth()
        sut = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
    }

    override func tearDown() async throws {
        await sut.stop()
    }

    func testInitialStateMirrorsAppSettingsDefault() {
        XCTAssertEqual(sut.selectedChannelId, AppSettings.default.selectedChannelId)
        XCTAssertEqual(sut.bitrate, AppSettings.default.bitrate)
        XCTAssertEqual(sut.hogModeEnabled, AppSettings.default.hogModeEnabled)
        XCTAssertEqual(sut.softwareVolumeEnabled, AppSettings.default.softwareVolumeEnabled)
        XCTAssertEqual(sut.notificationsEnabled, AppSettings.default.notificationsEnabled)
        XCTAssertEqual(sut.outputDeviceUID, AppSettings.default.outputDeviceUID)
        XCTAssertTrue(sut.devices.isEmpty)
        XCTAssertFalse(sut.isSignedIn)
    }

    func testStartAdoptsConfigStoreSnapshotAndDeviceCatalog() async throws {
        var seed = AppSettings.default
        seed.bitrate = 2
        seed.hogModeEnabled = false
        configStore = StubConfigStore(initial: seed)
        let device = AudioDevice(uid: "uid-1", name: "Probe DAC", transportType: .usb)
        deviceCatalog = StubAudioDeviceCatalog(initial: [device])
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { }, openApplicationData: { }
        )

        await sut.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.bitrate, 2)
        XCTAssertFalse(sut.hogModeEnabled)
        XCTAssertEqual(sut.devices.map(\.uid), ["uid-1"])
    }

    func testStartReflectsAuthState() async throws {
        auth.loggedIn = true
        await sut.start()
        XCTAssertTrue(sut.isSignedIn)
    }

    func testStartExposesUsernameWhenSignedIn() async throws {
        auth.loggedIn = true
        auth.username = "alice"
        await sut.start()
        XCTAssertEqual(sut.currentUsername, "alice")
    }

    func testSignOutClearsUsername() async throws {
        auth.loggedIn = true
        auth.username = "alice"
        await sut.start()
        XCTAssertEqual(sut.currentUsername, "alice")

        await sut.signOut()

        XCTAssertNil(sut.currentUsername)
    }

    func testSetBitratePersistsToConfigStore() async throws {
        await sut.start()
        await sut.setBitrate(2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stored = await configStore.settings
        XCTAssertEqual(stored.bitrate, 2)
        XCTAssertEqual(sut.bitrate, 2)
    }

    func testToggleHogModeFlipsBoth() async throws {
        await sut.start()
        await sut.setHogModeEnabled(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(sut.hogModeEnabled)
        let stored = await configStore.settings
        XCTAssertFalse(stored.hogModeEnabled)
    }

    func testSetVerboseLoggingEnabledPersistsToConfigStore() async throws {
        await sut.start()
        XCTAssertFalse(sut.verboseLoggingEnabled)
        await sut.setVerboseLoggingEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        let stored = await configStore.settings
        XCTAssertTrue(stored.verboseLoggingEnabled)
        XCTAssertTrue(sut.verboseLoggingEnabled)
    }

    func testSetOutputDeviceUIDPersistsAndRoundTrips() async throws {
        await sut.start()
        await sut.setOutputDeviceUID("uid-2")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sut.outputDeviceUID, "uid-2")
        let stored = await configStore.settings
        XCTAssertEqual(stored.outputDeviceUID, "uid-2")
    }

    func testSignOutCallsKeychainClearAndUpdatesIsSignedIn() async throws {
        auth.loggedIn = true
        await sut.start()
        XCTAssertTrue(sut.isSignedIn)

        await sut.signOut()

        XCTAssertFalse(sut.isSignedIn)
        XCTAssertFalse(auth.loggedIn)
    }

    func testOpenLoginWindowInvokesInjectedClosure() {
        var calls = 0
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { calls += 1 },
            openApplicationData: { }
        )
        sut.openLoginWindow()
        XCTAssertEqual(calls, 1)
    }

    func testOpenApplicationDataInvokesInjectedClosure() {
        var calls = 0
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { },
            openApplicationData: { calls += 1 }
        )
        sut.openApplicationData()
        XCTAssertEqual(calls, 1)
    }

    func testAppearanceDefaultsToSystem() {
        XCTAssertEqual(sut.appearance, .system)
    }

    func testSetAppearancePersists() async throws {
        await sut.start()
        await sut.setAppearance(.dark)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(configStore.settings.appearance, .dark)
        XCTAssertEqual(sut.appearance, .dark)
    }

    func testAmbientBackgroundEnabledDefaultsToFalse() async {
        let store = StubConfigStore(initial: .default)
        let catalog = StubAudioDeviceCatalog(initial: [])
        let auth = StubKeychainAuth()
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: catalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        XCTAssertFalse(sut.ambientBackgroundEnabled)
    }

    func testSetAmbientBackgroundEnabledPersistsAndUpdatesViewModel() async throws {
        let store = StubConfigStore(initial: .default)
        let catalog = StubAudioDeviceCatalog(initial: [])
        let auth = StubKeychainAuth()
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: catalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await sut.start()
        await sut.setAmbientBackgroundEnabled(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(sut.ambientBackgroundEnabled)
        XCTAssertTrue(store.current.ambientBackgroundEnabled)
        await sut.stop()
    }

    func testUpcomingRowCountDefaultsToFive() async throws {
        await sut.start()
        XCTAssertEqual(sut.upcomingRowCount, 5)
    }

    func testSetUpcomingRowCountPersists() async throws {
        let store = StubConfigStore(initial: .default)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await vm.start()
        await vm.setUpcomingRowCount(7)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.settings.upcomingRowCount, 7)
        await vm.stop()
    }

    func testSetChannelHiddenAddsToList() async throws {
        let store = StubConfigStore(initial: .default)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await vm.start()
        await vm.setChannelHidden(3, true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.settings.upcomingHiddenChannelIds.contains(3))
        await vm.stop()
    }

    func testSetChannelHiddenRemovesFromList() async throws {
        var settings = AppSettings.default
        settings.upcomingHiddenChannelIds = [3, 5]
        let store = StubConfigStore(initial: settings)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await vm.start()
        await vm.setChannelHidden(3, false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(store.settings.upcomingHiddenChannelIds.contains(3))
        XCTAssertTrue(store.settings.upcomingHiddenChannelIds.contains(5))
        await vm.stop()
    }

    func testSetChannelHiddenIsIdempotent() async throws {
        let store = StubConfigStore(initial: .default)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { }
        )
        await vm.start()
        await vm.setChannelHidden(3, true)
        await vm.setChannelHidden(3, true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.settings.upcomingHiddenChannelIds.filter { $0 == 3 }.count, 1)
        await vm.stop()
    }

    func testStartLoadsChannelsFiltering42And99() async throws {
        let channels: [Channel] = [
            Channel(chan: "0", title: "RP", streamName: nil, bannerUrl: nil, slug: nil, image: nil),
            Channel(chan: "1", title: "Mellow", streamName: nil, bannerUrl: nil, slug: nil, image: nil),
            Channel(chan: "42", title: "KINK", streamName: nil, bannerUrl: nil, slug: nil, image: nil),
            Channel(chan: "99", title: "Favorites", streamName: nil, bannerUrl: nil, slug: nil, image: nil),
        ]
        let vm = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: deviceCatalog,
            auth: auth,
            openLoginWindow: { },
            openApplicationData: { },
            listChannels: { channels }
        )
        await vm.start()
        let deadline = Date().addingTimeInterval(2)
        while vm.upcomingChannels.isEmpty && Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(vm.upcomingChannels.count, 2)
        XCTAssertFalse(vm.upcomingChannels.contains { $0.chan == "42" })
        XCTAssertFalse(vm.upcomingChannels.contains { $0.chan == "99" })
        await vm.stop()
    }
}
