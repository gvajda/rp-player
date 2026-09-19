import XCTest
@testable import RPPlayer

final class SkipPolicyTests: XCTestCase {
    func testDisabledNeverSkips() {
        let policy = SkipPolicy(enabled: false, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(1))
        XCTAssertFalse(policy.shouldSkip(10))
    }

    func testUnratedNeverSkips() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(0))
    }

    func testBelowThresholdSkips() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertTrue(policy.shouldSkip(1))
        XCTAssertTrue(policy.shouldSkip(4))
    }

    func testAtOrAboveThresholdKept() {
        let policy = SkipPolicy(enabled: true, threshold: 5)
        XCTAssertFalse(policy.shouldSkip(5))
        XCTAssertFalse(policy.shouldSkip(6))
        XCTAssertFalse(policy.shouldSkip(10))
    }
}
