import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() async throws {
        delegate = AppDelegate()
    }

    override func tearDown() async throws {
        if let item = delegate?.statusItemController?.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate = nil
    }

    func testApplicationDidFinishLaunchingCreatesStatusItemController() {
        XCTAssertNil(delegate.statusItemController)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
    }
}
