import XCTest
@testable import RPPlayer

final class MockPlaybackCoordinatorNextReadyTests: XCTestCase {
    func testNextReadyInitialIsFalse() async {
        let mock = MockPlaybackCoordinator()
        let value = await mock.nextReady
        XCTAssertFalse(value)
    }

    func testFireNextReadyUpdatesValue() async {
        let mock = MockPlaybackCoordinator()
        await mock.fireNextReady(true)
        let value = await mock.nextReady
        XCTAssertTrue(value)
    }
}
