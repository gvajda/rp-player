import AppKit
import XCTest
@testable import RPPlayer

@MainActor
final class AppDelegateTests: XCTestCase {
    private var delegate: AppDelegate!

    override func setUp() async throws {
        delegate = AppDelegate(bootstrap: {
            let coordinator = MockPlaybackCoordinator()
            let api = MockRpApiClient()
            let viewModel = MiniPlayerViewModel(
                coordinator: coordinator,
                api: api,
                initialChannelId: 0,
                albumArtCache: StubArtCache()
            )
            return AppDelegate.Bootstrap(
                viewModel: viewModel,
                coordinatorShutdown: { await coordinator.shutdown() }
            )
        })
    }

    override func tearDown() async throws {
        if let item = delegate?.statusItemController?.statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        delegate = nil
    }

    func testApplicationDidFinishLaunchingCreatesStatusItemControllerAndViewModel() {
        XCTAssertNil(delegate.statusItemController)
        XCTAssertNil(delegate.viewModel)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNotNil(delegate.statusItemController)
        XCTAssertNotNil(delegate.viewModel)
    }
}
