import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testInitConfiguresWindowFrameAndStyle() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { }, openApplicationData: { }
        )
        let sut = SettingsWindowController(viewModel: viewModel)
        let window = sut.window!
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 480, height: 560))
        XCTAssertEqual(window.title, "Settings")
    }

    func testIsVisibleReflectsWindowVisibility() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { }, openApplicationData: { }
        )
        let sut = SettingsWindowController(viewModel: viewModel)
        XCTAssertFalse(sut.isVisible)
    }
}
