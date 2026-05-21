// Tests/RPPlayerTests/Config/CrossfeedFilterBuilderTests.swift
import XCTest
@testable import RPPlayer

final class CrossfeedFilterBuilderTests: XCTestCase {
    func testNamedProfileEmitsProfileOnly() {
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .bs2bDefault, fcut: 700, feedDb: 4.5),
            "bs2b=profile=default"
        )
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .cmoy, fcut: 700, feedDb: 6.0),
            "bs2b=profile=cmoy"
        )
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .jmeier, fcut: 650, feedDb: 9.5),
            "bs2b=profile=jmeier"
        )
    }

    func testCustomProfileEmitsFcutAndFeed() {
        // feed=Int(feedDb*10) since FFmpeg bs2b feed is in 10*dB units (60 = 6.0 dB).
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 750, feedDb: 6.0),
            "bs2b=fcut=750:feed=60"
        )
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 1200, feedDb: 11.2),
            "bs2b=fcut=1200:feed=112"
        )
    }

    func testCustomProfileClampsOutOfRangeValues() {
        // fcut clamped to 300...2000 (bs2b accepts 0..2000 but UI lower bound is 300 — defense in depth).
        let low = CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 100, feedDb: 0.2)
        XCTAssertEqual(low, "bs2b=fcut=300:feed=10")
        let high = CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 9999, feedDb: 99.0)
        XCTAssertEqual(high, "bs2b=fcut=2000:feed=150")
    }

    func testCustomProfileFeedDbRoundsToNearestTenth() {
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 700, feedDb: 4.55),
            "bs2b=fcut=700:feed=46"
        )
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .custom, fcut: 700, feedDb: 4.54),
            "bs2b=fcut=700:feed=45"
        )
    }

    func testNamedProfileIgnoresFcutAndFeedDb() {
        // Named profiles always emit profile=<name>; bs2b lib uses its own table.
        XCTAssertEqual(
            CrossfeedFilterBuilder.buildPart(profile: .cmoy, fcut: 999, feedDb: 99.9),
            "bs2b=profile=cmoy"
        )
    }
}
