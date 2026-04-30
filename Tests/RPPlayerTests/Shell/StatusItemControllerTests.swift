import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var popoverController: PopoverController!
    private var createdControllers: [StatusItemController] = []
    private var showCount = 0
    private var closeCount = 0

    override func setUp() async throws {
        popoverController = PopoverController()
        createdControllers = []
        showCount = 0
        closeCount = 0
    }

    override func tearDown() async throws {
        for controller in createdControllers {
            NSStatusBar.system.removeStatusItem(controller.statusItem)
        }
        createdControllers = []
    }

    private func makeController() -> StatusItemController {
        let controller = StatusItemController(
            popover: popoverController,
            show: { [unowned self] _ in self.showCount += 1 },
            close: { [unowned self] in self.closeCount += 1 }
        )
        createdControllers.append(controller)
        return controller
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
        createdControllers.append(controller)
        controller.toggle()
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(closeCount, 1)
    }
}
