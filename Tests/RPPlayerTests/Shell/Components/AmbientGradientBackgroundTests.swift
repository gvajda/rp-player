import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class AmbientGradientBackgroundTests: XCTestCase {
    func testRendersWithNilColor() {
        let view = AmbientGradientBackground(topColor: nil)
        let host = NSHostingController(rootView: view.frame(width: 100, height: 100))
        host.loadView()
        XCTAssertNotNil(host.view)
    }

    func testRendersWithColor() {
        let view = AmbientGradientBackground(topColor: Color.red)
        let host = NSHostingController(rootView: view.frame(width: 100, height: 100))
        host.loadView()
        XCTAssertNotNil(host.view)
    }
}
