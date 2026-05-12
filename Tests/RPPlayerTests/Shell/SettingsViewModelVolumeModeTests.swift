import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelVolumeModeTests: XCTestCase {
    private func makeSUT(_ settings: AppSettings = .default) -> (SettingsViewModel, StubConfigStore) {
        let store = StubConfigStore(initial: settings)
        let sut = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {}
        )
        return (sut, store)
    }

    func testInitialVolumeModeMirrorsSettingsDefault() {
        let (sut, _) = makeSUT()
        XCTAssertEqual(sut.volumeMode, VolumeMode.none)
    }

    func testSetVolumeModeWritesThroughStore() async {
        let (sut, store) = makeSUT()
        await sut.setVolumeMode(.replayGain)
        XCTAssertEqual(store.settings.volumeMode, .replayGain)
    }

    func testSetVolumeModeUpdatesActiveDeviceProfile() async {
        var initial = AppSettings.default
        initial.outputDeviceUID = "uid-x"
        let (sut, store) = makeSUT(initial)
        await sut.setVolumeMode(.forceMax)
        XCTAssertEqual(store.settings.audioProfiles["uid-x"]?.volumeMode, .forceMax)
    }

    func testStreamEmissionUpdatesPublishedVolumeMode() async throws {
        let (sut, store) = makeSUT()
        await sut.start()
        try? await store.update { $0.volumeMode = .forceMax }
        // Yield once to allow the AsyncStream consumer to apply on MainActor.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sut.volumeMode, .forceMax)
        await sut.stop()
    }
}
