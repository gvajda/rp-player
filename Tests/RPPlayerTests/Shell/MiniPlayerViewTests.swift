import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class MiniPlayerViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let coordinator = MockPlaybackCoordinator()
        let api = MockRpApiClient()
        let viewModel = MiniPlayerViewModel(coordinator: coordinator, api: api, initialChannelId: 0)
        let host = NSHostingController(rootView: MiniPlayerView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
