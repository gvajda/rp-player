import XCTest
@testable import RPPlayer

final class SemVerTests: XCTestCase {
    func testParseStripsLeadingV() {
        XCTAssertEqual(SemVer.parse("v0.5.2"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseAcceptsBareSemver() {
        XCTAssertEqual(SemVer.parse("0.5.2"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseStripsPrereleaseSuffix() {
        XCTAssertEqual(SemVer.parse("v0.5.2-beta.1"), SemVer(major: 0, minor: 5, patch: 2))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SemVer.parse("garbage"))
        XCTAssertNil(SemVer.parse("v"))
        XCTAssertNil(SemVer.parse(""))
        XCTAssertNil(SemVer.parse("v1.2"))
        XCTAssertNil(SemVer.parse("v1.2.x"))
    }

    func testCompareNumericNotLex() {
        XCTAssertLessThan(
            SemVer(major: 0, minor: 5, patch: 2),
            SemVer(major: 0, minor: 5, patch: 10)
        )
    }

    func testCompareMajorBeatsMinor() {
        XCTAssertGreaterThan(
            SemVer(major: 1, minor: 0, patch: 0),
            SemVer(major: 0, minor: 99, patch: 99)
        )
    }

    func testEqualityIgnoresPrereleaseSuffix() {
        XCTAssertEqual(SemVer.parse("v0.5.2"), SemVer.parse("v0.5.2-rc.1"))
    }
}
