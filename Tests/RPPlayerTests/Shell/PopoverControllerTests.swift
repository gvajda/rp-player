import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresPopoverContentSizeAndBehavior() {
        let controller = PopoverController()
        XCTAssertEqual(controller.popover.contentSize, NSSize(width: 320, height: 420))
        XCTAssertEqual(controller.popover.behavior, .transient)
        XCTAssertTrue(controller.popover.contentViewController is NSHostingController<AppShellPlaceholderView>)
    }

    func testIsShownReflectsPopoverState() {
        let controller = PopoverController()
        XCTAssertFalse(controller.isShown)
    }
}
