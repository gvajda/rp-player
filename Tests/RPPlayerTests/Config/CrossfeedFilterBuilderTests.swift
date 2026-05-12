// Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift
import XCTest
@testable import RPPlayer

final class CrossfeedFilterBuilderTests: XCTestCase {
    func testDefaultsFormat() {
        let part = CrossfeedFilterBuilder.buildPart(strength: 0.2, range: 0.5)
        XCTAssertEqual(part, "crossfeed=strength=0.2:range=0.5")
    }

    func testNonDefaultValuesUseTrimmedFractions() {
        let part = CrossfeedFilterBuilder.buildPart(strength: 0.45, range: 0.875)
        XCTAssertEqual(part, "crossfeed=strength=0.45:range=0.875")
    }

    func testOutOfRangeValuesAreClamped() {
        // Defense-in-depth: UI's Stepper already clamps, but builder must too.
        let low = CrossfeedFilterBuilder.buildPart(strength: -0.5, range: -2.0)
        XCTAssertEqual(low, "crossfeed=strength=0:range=0")

        let high = CrossfeedFilterBuilder.buildPart(strength: 1.5, range: 99.0)
        XCTAssertEqual(high, "crossfeed=strength=1:range=1")
    }
}
