import XCTest
@testable import RPPlayer

@MainActor
final class HogModeControllerTests: XCTestCase {
    func testInitialStateIsNotHogging() async {
        let controller = HogModeController()
        let isHogging = await controller.isHogging
        XCTAssertFalse(isHogging)
    }

    func testAcquireWithUnknownUIDReturnsFalse() async {
        let controller = HogModeController()
        let acquired = await controller.acquire(deviceUID: "definitely-not-a-real-uid-\(UUID().uuidString)")
        XCTAssertFalse(acquired)
        let isHogging = await controller.isHogging
        XCTAssertFalse(isHogging)
    }

    func testReleaseWithoutAcquireDoesNotCrash() async {
        let controller = HogModeController()
        await controller.release()
        let isHogging = await controller.isHogging
        XCTAssertFalse(isHogging)
    }

    func testSetSampleRateOnUnknownDeviceReturnsFalse() async {
        let controller = HogModeController()
        let ok = await controller.setSampleRate(44100, deviceUID: "definitely-not-a-real-uid-\(UUID().uuidString)")
        XCTAssertFalse(ok)
    }

    func testAcquireWithUnknownUIDLeavesOriginalSampleRateNil() async {
        let controller = HogModeController()
        _ = await controller.acquire(deviceUID: "definitely-not-a-real-uid-\(UUID().uuidString)")
        let stored = await controller.originalSampleRate
        XCTAssertNil(stored)
    }

    func testReleaseWithoutAcquireDoesNotMutateOriginalSampleRate() async {
        let controller = HogModeController()
        await controller.release()
        let stored = await controller.originalSampleRate
        XCTAssertNil(stored)
    }
}
