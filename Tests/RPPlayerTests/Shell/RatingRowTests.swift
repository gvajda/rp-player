import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class RatingRowTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        var rated: [Int] = []
        let host = NSHostingController(
            rootView: RatingRow(currentRating: 7, isSignedIn: true) { rated.append($0) }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
