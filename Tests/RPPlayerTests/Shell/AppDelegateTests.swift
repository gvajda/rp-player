import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationDidFinishLaunchingCreatesStatusItemController() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.statusItemController)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
    }
}
