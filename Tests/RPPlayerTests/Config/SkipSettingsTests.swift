import XCTest
@testable import RPPlayer

final class SkipSettingsTests: XCTestCase {
    func testDefaults() {
        let s = AppSettings.default
        XCTAssertFalse(s.skipLowRatedEnabled)
        XCTAssertEqual(s.skipRatingThreshold, 5)
    }

    func testDecodeMissingKeysUsesDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(s.skipLowRatedEnabled)
        XCTAssertEqual(s.skipRatingThreshold, 5)
    }

    func testRoundTrip() throws {
        var s = AppSettings.default
        s.skipLowRatedEnabled = true
        s.skipRatingThreshold = 7
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.skipLowRatedEnabled)
        XCTAssertEqual(decoded.skipRatingThreshold, 7)
    }
}
