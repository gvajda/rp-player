import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresBorderlessPanelWithProvidedRootView() {
        let controller = PopoverController(rootView: AnyView(Text("probe")))
        XCTAssertEqual(controller.panel.frame.size, NSSize(width: 320, height: 540))
        XCTAssertTrue(controller.panel.styleMask.contains(.borderless))
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(controller.panel.level, .statusBar)
        XCTAssertNotNil(controller.panel.contentView)
        XCTAssertTrue(controller.panel.contentView is NSHostingView<AnyView>)
    }

    func testIsShownReflectsPanelVisibility() {
        let controller = PopoverController(rootView: AnyView(Text("probe")))
        XCTAssertFalse(controller.isShown)
    }
}
