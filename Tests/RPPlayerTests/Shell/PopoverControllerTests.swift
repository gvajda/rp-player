import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class PopoverControllerTests: XCTestCase {
    func testInitConfiguresBorderlessPanelWithProvidedRootView() {
        let controller = PopoverController(rootView: AnyView(Text("probe")), configStore: StubConfigStore(initial: .default))
        XCTAssertEqual(controller.panel.frame.size, NSSize(width: 342, height: 540))
        XCTAssertTrue(controller.panel.styleMask.contains(.borderless))
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(controller.panel.level, .statusBar)
        XCTAssertNotNil(controller.panel.contentView)
        // Content view is a container NSView holding an NSVisualEffectView (frosted, hidden by default) and the SwiftUI host on top.
        let subviews = controller.panel.contentView?.subviews ?? []
        XCTAssertTrue(subviews.contains { $0 is NSVisualEffectView })
        XCTAssertTrue(subviews.contains { $0 is NSHostingView<AnyView> })
    }

    func testIsShownReflectsPanelVisibility() {
        let controller = PopoverController(rootView: AnyView(Text("probe")), configStore: StubConfigStore(initial: .default))
        XCTAssertFalse(controller.isShown)
    }
}
