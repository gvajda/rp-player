import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresBorderlessPanelWithHostedSwiftUIContent() {
        let controller = PopoverController()
        XCTAssertEqual(controller.panel.frame.size, NSSize(width: 320, height: 420))
        XCTAssertTrue(controller.panel.styleMask.contains(.borderless))
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(controller.panel.level, .statusBar)
        XCTAssertTrue(controller.panel.contentView is NSHostingView<AppShellPlaceholderView>)
    }

    func testIsShownReflectsPanelVisibility() {
        let controller = PopoverController()
        XCTAssertFalse(controller.isShown)
    }
}
