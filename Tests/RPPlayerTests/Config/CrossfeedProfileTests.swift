// Tests/RPPlayerTests/Config/CrossfeedProfileTests.swift
import XCTest
@testable import RPPlayer

final class CrossfeedProfileTests: XCTestCase {
    func testRawValueMatchesBs2bProfileStrings() {
        XCTAssertEqual(CrossfeedProfile.cmoy.rawValue, "cmoy")
        XCTAssertEqual(CrossfeedProfile.jmeier.rawValue, "jmeier")
        XCTAssertEqual(CrossfeedProfile.custom.rawValue, "custom")
    }

    func testCaseIterableOrderIsStableForUI() {
        XCTAssertEqual(
            CrossfeedProfile.allCases,
            [.cmoy, .jmeier, .custom]
        )
    }

    func testCodableRoundTrip() throws {
        let original: [CrossfeedProfile] = [.cmoy, .jmeier, .custom]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([CrossfeedProfile].self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
