import XCTest
@testable import RPPlayer

final class VolumeModeTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(VolumeMode.none.rawValue, "none")
        XCTAssertEqual(VolumeMode.replayGain.rawValue, "replayGain")
        XCTAssertEqual(VolumeMode.forceMax.rawValue, "forceMax")
    }

    func testCodableRoundTrip() throws {
        for mode in [VolumeMode.none, .replayGain, .forceMax] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(VolumeMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
