import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewTests: XCTestCase {
    func testHostingControllerRendersWithoutCrash() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { },
            openApplicationData: { }
        )
        let host = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
