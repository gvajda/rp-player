import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class RatingMenuTests: XCTestCase {
    func testRendersWithRatingValue() {
        var rated: [Int] = []
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: 7, isSignedIn: true) { rated.append($0) }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }

    func testRendersWithoutRating() {
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: nil, isSignedIn: true) { _ in }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWhenSignedOut() {
        let host = NSHostingController(
            rootView: RatingMenu(currentRating: nil, isSignedIn: false) { _ in }
        )
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}
