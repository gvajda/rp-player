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
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 480, height: 560))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 480, height: 400))
        XCTAssertEqual(window.contentMaxSize, NSSize(width: 480, height: 2000))
        XCTAssertEqual(window.title, "RP Player Settings")
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

    @MainActor
    func testWindowTitleIsRPPlayerSettings() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: .default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { },
            openApplicationData: { }
        )
        let controller = SettingsWindowController(viewModel: viewModel)
        XCTAssertEqual(controller.window?.title, "RP Player Settings")
    }
}
