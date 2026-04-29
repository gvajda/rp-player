import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class AppShellPlaceholderViewTests: XCTestCase {
    func testHostingControllerExposesPlaceholderViewWithoutCrash() {
        let host = NSHostingController(rootView: AppShellPlaceholderView())
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }

    func testPlaceholderHeadlineIsRpPlayer() {
        XCTAssertEqual(AppShellPlaceholderView.headline, "RP Player")
    }
}
