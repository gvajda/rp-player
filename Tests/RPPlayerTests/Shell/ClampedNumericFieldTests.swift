// Tests/RPPlayerTests/Shell/ClampedNumericFieldTests.swift
import XCTest
@testable import RPPlayer

final class ClampedNumericFieldTests: XCTestCase {
    func testParseValidDotFormat() throws {
        let r = try XCTUnwrap(ClampedNumericFieldLogic.parse("0.40", locale: Locale(identifier: "en_US")))
        XCTAssertEqual(r, 0.40, accuracy: 1e-9)
    }

    func testParseValidCommaFormatLocale() throws {
        let r = try XCTUnwrap(ClampedNumericFieldLogic.parse("0,40", locale: Locale(identifier: "de_DE")))
        XCTAssertEqual(r, 0.40, accuracy: 1e-9)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(ClampedNumericFieldLogic.parse("abc", locale: Locale(identifier: "en_US")))
        XCTAssertNil(ClampedNumericFieldLogic.parse("", locale: Locale(identifier: "en_US")))
    }

    func testValidityCheckRespectsClosedRange() {
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(0.0, in: 0.0...1.0))
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(0.5, in: 0.0...1.0))
        XCTAssertTrue(ClampedNumericFieldLogic.isValid(1.0, in: 0.0...1.0))
        XCTAssertFalse(ClampedNumericFieldLogic.isValid(-0.01, in: 0.0...1.0))
        XCTAssertFalse(ClampedNumericFieldLogic.isValid(1.01, in: 0.0...1.0))
    }

    func testFormatTwoDecimalPlaces() {
        XCTAssertEqual(ClampedNumericFieldLogic.format(0.4), "0.40")
        XCTAssertEqual(ClampedNumericFieldLogic.format(0.0), "0.00")
        XCTAssertEqual(ClampedNumericFieldLogic.format(1.0), "1.00")
    }

    func testFormatWithExplicitDecimals() {
        XCTAssertEqual(ClampedNumericFieldLogic.format(700.0, decimals: 0), "700")
        XCTAssertEqual(ClampedNumericFieldLogic.format(2000.4, decimals: 0), "2000")
        XCTAssertEqual(ClampedNumericFieldLogic.format(6.0, decimals: 1), "6.0")
        XCTAssertEqual(ClampedNumericFieldLogic.format(9.5, decimals: 3), "9.500")
        XCTAssertEqual(ClampedNumericFieldLogic.format(1.234, decimals: -1), "1")
    }
}
