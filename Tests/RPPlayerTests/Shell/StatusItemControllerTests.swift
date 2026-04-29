import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var popoverController: PopoverController!
    private var showCount = 0
    private var closeCount = 0

    override func setUp() async throws {
        popoverController = PopoverController()
        showCount = 0
        closeCount = 0
    }

    private func makeController() -> StatusItemController {
        StatusItemController(
            popover: popoverController,
            show: { [unowned self] _ in self.showCount += 1 },
            close: { [unowned self] in self.closeCount += 1 }
        )
    }

    func testButtonImageAndTooltipAreConfigured() {
        let controller = makeController()
        let button = controller.statusItem.button
        XCTAssertNotNil(button)
        XCTAssertEqual(button?.toolTip, "RP Player")
        XCTAssertNotNil(button?.image)
        XCTAssertTrue(button?.image?.isTemplate ?? false)
    }

    func testToggleShowsWhenPopoverIsHidden() {
        let controller = makeController()
        controller.toggle()
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(closeCount, 0)
    }

    func testToggleClosesWhenPopoverIsShown() {
        final class AlwaysShownPopover: PopoverController {
            override var isShown: Bool { true }
        }
        let stub = AlwaysShownPopover()
        let controller = StatusItemController(
            popover: stub,
            show: { [unowned self] _ in self.showCount += 1 },
            close: { [unowned self] in self.closeCount += 1 }
        )
        controller.toggle()
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(closeCount, 1)
    }
}
