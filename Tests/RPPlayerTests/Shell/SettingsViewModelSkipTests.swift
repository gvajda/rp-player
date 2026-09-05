import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelSkipTests: XCTestCase {
    private func makeVM(_ settings: AppSettings) -> (SettingsViewModel, StubConfigStore) {
        let store = StubConfigStore(initial: settings)
        let vm = SettingsViewModel(
            configStore: store,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {}, openApplicationData: {}
        )
        return (vm, store)
    }

    func testInitialReflectsSnapshot() async throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 7
        let (vm, _) = makeVM(s)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.skipLowRatedEnabled)
        XCTAssertEqual(vm.skipRatingThreshold, 7)
        await vm.stop()
    }

    func testSetTogglePersists() async throws {
        let (vm, store) = makeVM(.default)
        await vm.start()
        await vm.setSkipLowRatedEnabled(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(store.current.skipLowRatedEnabled)
        XCTAssertTrue(vm.skipLowRatedEnabled)
        await vm.stop()
    }

    func testSetThresholdPersists() async throws {
        let (vm, store) = makeVM(.default)
        await vm.start()
        await vm.setSkipRatingThreshold(3)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.current.skipRatingThreshold, 3)
        XCTAssertEqual(vm.skipRatingThreshold, 3)
        await vm.stop()
    }
}
