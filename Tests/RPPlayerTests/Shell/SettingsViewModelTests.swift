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
            openDataFolder: { },
            openLogsFolder: { }
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
            openLoginWindow: { }, openDataFolder: { }, openLogsFolder: { }
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
            openDataFolder: { }, openLogsFolder: { }
        )
        sut.openLoginWindow()
        XCTAssertEqual(calls, 1)
    }

    func testOpenDataFolderAndLogsFolderInvokeInjectedClosures() {
        var dataCalls = 0
        var logsCalls = 0
        sut = SettingsViewModel(
            configStore: configStore, deviceCatalog: deviceCatalog, auth: auth,
            openLoginWindow: { },
            openDataFolder: { dataCalls += 1 },
            openLogsFolder: { logsCalls += 1 }
        )
        sut.openDataFolder()
        sut.openLogsFolder()
        XCTAssertEqual(dataCalls, 1)
        XCTAssertEqual(logsCalls, 1)
    }
}

@MainActor
final class StubConfigStore: ConfigStore {
    var current: AppSettings
    var continuations: [AsyncStream<AppSettings>.Continuation] = []

    init(initial: AppSettings) { self.current = initial }

    var settings: AppSettings { current }

    var changes: AsyncStream<AppSettings> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func update(_ mutate: @Sendable (inout AppSettings) -> Void) async throws {
        var copy = current
        mutate(&copy)
        guard copy != current else { return }
        current = copy
        continuations.forEach { $0.yield(copy) }
    }
}

@MainActor
final class StubAudioDeviceCatalog: AudioDeviceCatalog {
    var current: [AudioDevice]
    var continuations: [AsyncStream<[AudioDevice]>.Continuation] = []

    init(initial: [AudioDevice]) { self.current = initial }

    var devices: [AudioDevice] { current }

    var changes: AsyncStream<[AudioDevice]> {
        AsyncStream { continuation in
            continuation.yield(current)
            continuations.append(continuation)
        }
    }

    func setDevices(_ devices: [AudioDevice]) {
        current = devices
        continuations.forEach { $0.yield(devices) }
    }
}

@MainActor
final class StubKeychainAuth: KeychainAuth {
    var loggedIn: Bool = false
    var storedCookie: String?

    nonisolated var isLoggedIn: Bool {
        MainActor.assumeIsolated { loggedIn }
    }

    nonisolated func currentCookie() async -> String? {
        await MainActor.run { storedCookie }
    }

    func storeCookie(_ cookie: String) async throws {
        storedCookie = cookie
        loggedIn = true
    }

    func clearCookie() async {
        storedCookie = nil
        loggedIn = false
    }
}
