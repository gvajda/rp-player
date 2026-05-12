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
        XCTAssertEqual(sut.volumeMode, AppSettings.default.volumeMode)
        XCTAssertEqual(sut.releaseHogOnPauseEnabled, AppSettings.default.releaseHogOnPauseEnabled)
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

    func testAmbientBackgroundEnabledDefaultsToTrue() async {
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
        XCTAssertTrue(sut.ambientBackgroundEnabled)
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
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.upcomingChannels.count, 2)
        XCTAssertFalse(vm.upcomingChannels.contains { $0.chan == "42" })
        XCTAssertFalse(vm.upcomingChannels.contains { $0.chan == "99" })
        await vm.stop()
    }

    func testPopoverStyleDefaultsToAmbient() async throws {
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
        XCTAssertEqual(sut.popoverStyle, .ambient)
    }

    func testSetPopoverStylePersistsAndSyncsAmbientFlag() async throws {
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
        await sut.setPopoverStyle(.ambient)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sut.popoverStyle, .ambient)
        XCTAssertEqual(store.current.popoverStyle, .ambient)
        XCTAssertTrue(store.current.ambientBackgroundEnabled, "selecting .ambient must keep ambientBackgroundEnabled in sync")

        await sut.setPopoverStyle(.frosty)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sut.popoverStyle, .frosty)
        XCTAssertFalse(store.current.ambientBackgroundEnabled, "non-.ambient styles must clear ambientBackgroundEnabled")

        await sut.stop()
    }

    func testFrostedUpcomingEnabledDefaultsToFalse() async throws {
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
        XCTAssertFalse(sut.frostedUpcomingEnabled)
    }

    func testSetFrostedUpcomingEnabledPersistsAndUpdatesViewModel() async throws {
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
        await sut.setFrostedUpcomingEnabled(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(sut.frostedUpcomingEnabled)
        XCTAssertTrue(store.current.frostedUpcomingEnabled)
        await sut.stop()
    }

    func testSetBitrateWritesToAudioProfile() async throws {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-dac"
        let store = StubConfigStore(initial: initial)
        let sut = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {}
        )
        await sut.start()
        await sut.setBitrate(4)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.audioProfiles["uid-dac"]?.bitrate, 4)
        await sut.stop()
    }

    func testSetHogModeEnabledWritesToAudioProfile() async throws {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-dac"
        let store = StubConfigStore(initial: initial)
        let sut = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {}
        )
        await sut.start()
        await sut.setHogModeEnabled(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.audioProfiles["uid-dac"]?.hogModeEnabled, false)
        await sut.stop()
    }

    func testNoProfileWriteWhenNoDevice() async throws {
        let store = StubConfigStore(initial: .default)
        let sut = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {}
        )
        await sut.start()
        await sut.setBitrate(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.current.audioProfiles.isEmpty)
        await sut.stop()
    }

    func testSetUpdateCheckEnabledPersists() async throws {
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: NoopUpdateChecker()
        )
        await sut.setUpdateCheckEnabled(false)
        let snapshot = await configStore.settings
        XCTAssertFalse(snapshot.updateCheckEnabled)
        await sut.setUpdateCheckEnabled(true)
        let snapshot2 = await configStore.settings
        XCTAssertTrue(snapshot2.updateCheckEnabled)
    }

    func testCheckNowInvokesUpdateChecker() async throws {
        let spy = SpyUpdateChecker()
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: spy
        )
        await sut.checkNow()
        let count = await spy.checkNowCallCount
        XCTAssertEqual(count, 1)
    }

    func testCurrentVersionLineUpToDate() async {
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: NoopUpdateChecker(),
            currentVersionString: "v0.4.1"
        )
        sut.applyUpdateState(.upToDate(checkedAt: Date(timeIntervalSince1970: 1_715_100_000)))
        XCTAssertEqual(sut.currentVersionLine, "v0.4.1 (up to date)")
    }

    func testCurrentVersionLineAvailable() async {
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: NoopUpdateChecker(),
            currentVersionString: "v0.4.1"
        )
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        sut.applyUpdateState(.available(info, dismissedFromButton: false))
        XCTAssertEqual(sut.currentVersionLine, "v0.5.0 available")
    }

    func testUpdateAvailableFlagSetByApplyUpdateState() async {
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: NoopUpdateChecker(),
            currentVersionString: "v0.4.1"
        )
        XCTAssertFalse(sut.updateAvailable)
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        sut.applyUpdateState(.available(info, dismissedFromButton: false))
        XCTAssertTrue(sut.updateAvailable)
        sut.applyUpdateState(.upToDate(checkedAt: Date()))
        XCTAssertFalse(sut.updateAvailable)
    }

    func testOpenUpdateRunsCheckNowThenOpensPanel() async {
        let info = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(),
            body: "",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: nil
        )
        let spy = SpyUpdateChecker(initialState: .available(info, dismissedFromButton: false))
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: spy
        )
        var openedTag: String?
        sut.openUpdatePanel = { received in openedTag = received.tagName }
        await sut.openUpdate()
        let checkCount = await spy.checkNowCallCount
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(openedTag, "v0.5.0")
        let dismissCount = await spy.dismissCallCount
        XCTAssertEqual(dismissCount, 1)
    }

    func testOpenUpdateDoesNotOpenPanelWhenStateNotAvailable() async {
        let spy = SpyUpdateChecker(initialState: .upToDate(checkedAt: Date()))
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            updateChecker: spy
        )
        var openCount = 0
        sut.openUpdatePanel = { _ in openCount += 1 }
        await sut.openUpdate()
        XCTAssertEqual(openCount, 0)
    }

    // MARK: - EQ surface (PR 35 Task 7)

    private func makeEqTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("svm-eq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeEqFixture(_ text: String, named: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent("\(named).txt", isDirectory: false)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSetEqEnabledWritesToActiveDeviceProfile() async throws {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-dac"
        let store = StubConfigStore(initial: initial)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: dir)
        )
        await vm.start()
        await vm.setEqEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.audioProfiles["uid-dac"]?.eqEnabled, true)
        XCTAssertTrue(vm.eqEnabled)
        await vm.stop()
    }

    func testSetEqPresetNameWritesToActiveDeviceProfile() async throws {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-dac"
        let store = StubConfigStore(initial: initial)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: dir)
        )
        await vm.start()
        await vm.setEqPresetName("foo")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.audioProfiles["uid-dac"]?.eqPresetName, "foo")
        XCTAssertEqual(vm.eqPresetName, "foo")
        await vm.stop()
    }

    func testImportPresetFileValidTxtSavesAndRefreshes() async throws {
        let store = StubConfigStore(initial: .default)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importDir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: dir)
        )
        await vm.start()
        let fixture = writeEqFixture(
            "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n",
            named: "MyPreset",
            in: importDir
        )

        let outcome = try await vm.importPresetFile(url: fixture, overwrite: false)
        XCTAssertEqual(outcome, .imported(name: "MyPreset"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(vm.availablePresets.contains("MyPreset"))
        await vm.stop()
    }

    func testImportPresetFileWithUnsupportedFilterTypeThrowsParseFailed() async throws {
        let store = StubConfigStore(initial: .default)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importDir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: dir)
        )
        await vm.start()
        let fixture = writeEqFixture(
            "Filter 1: ON LP Fc 8000 Hz Gain 0 dB Q 1.0\n",
            named: "Bad",
            in: importDir
        )

        do {
            _ = try await vm.importPresetFile(url: fixture, overwrite: false)
            XCTFail("expected EqImportError.parseFailed")
        } catch let error as SettingsViewModel.EqImportError {
            switch error {
            case .parseFailed: break
            default: XCTFail("expected .parseFailed, got \(error)")
            }
        }
        await vm.stop()
    }

    func testImportPresetFileNameCollisionWithOverwriteFalseReturnsCollision() async throws {
        let store = StubConfigStore(initial: .default)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let importDir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }
        let presetStore = LiveEqPresetStore(directory: dir)
        try await presetStore.save(name: "Dup", text: "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: presetStore
        )
        await vm.start()
        let fixture = writeEqFixture(
            "Filter 1: ON PK Fc 2000 Hz Gain 0 dB Q 1.0\n",
            named: "Dup",
            in: importDir
        )

        let outcome = try await vm.importPresetFile(url: fixture, overwrite: false)
        XCTAssertEqual(outcome, .nameCollision(name: "Dup"))
        await vm.stop()
    }

    func testPrepareDeletePresetReturnsAllReferencingDeviceUids() async throws {
        var initial = AppSettings.default
        var p1 = AudioProfile.safeDefault
        p1.eqPresetName = "Shared"
        var p2 = AudioProfile.safeDefault
        p2.eqPresetName = "Shared"
        var p3 = AudioProfile.safeDefault
        p3.eqPresetName = "Other"
        initial.audioProfiles = ["uid-a": p1, "uid-b": p2, "uid-c": p3]
        let store = StubConfigStore(initial: initial)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: LiveEqPresetStore(directory: dir)
        )

        let uids = await vm.prepareDeletePreset(name: "Shared")
        XCTAssertEqual(Set(uids), Set(["uid-a", "uid-b"]))
    }

    func testDeletePresetConfirmedClearsReferencesAndRemovesFile() async throws {
        var initial = AppSettings.default
        var p1 = AudioProfile.safeDefault
        p1.eqPresetName = "Target"
        var p2 = AudioProfile.safeDefault
        p2.eqPresetName = "Target"
        var p3 = AudioProfile.safeDefault
        p3.eqPresetName = "Keep"
        initial.audioProfiles = ["uid-a": p1, "uid-b": p2, "uid-c": p3]
        let store = StubConfigStore(initial: initial)
        let dir = makeEqTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presetStore = LiveEqPresetStore(directory: dir)
        try await presetStore.save(name: "Target", text: "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        try await presetStore.save(name: "Keep", text: "Filter 1: ON PK Fc 2000 Hz Gain 0 dB Q 1.0\n", overwrite: false)
        let vm = SettingsViewModel(
            configStore: store, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: {}, openApplicationData: {},
            eqPresetStore: presetStore
        )
        await vm.start()

        try await vm.deletePresetConfirmed(name: "Target")

        XCTAssertNil(store.current.audioProfiles["uid-a"]?.eqPresetName)
        XCTAssertNil(store.current.audioProfiles["uid-b"]?.eqPresetName)
        XCTAssertEqual(store.current.audioProfiles["uid-c"]?.eqPresetName, "Keep")
        let exists = await presetStore.exists(name: "Target")
        XCTAssertFalse(exists)
        let stillKeep = await presetStore.exists(name: "Keep")
        XCTAssertTrue(stillKeep)
        await vm.stop()
    }
}

private actor SpyUpdateChecker: UpdateChecking {
    private(set) var checkNowCallCount = 0
    private(set) var dismissCallCount = 0
    private var state: UpdateState

    init(initialState: UpdateState = .unknown) {
        self.state = initialState
    }

    func start() async {}
    func checkNow() async { checkNowCallCount += 1 }
    func dismissCurrentForButton() async { dismissCallCount += 1 }
    var stateUpdates: AsyncStream<UpdateState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }
    var currentState: UpdateState { state }
}
