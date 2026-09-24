import AppKit
import SwiftUI
import XCTest
@testable import RPPlayer

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    private func makeAudioUnits() -> (AudioUnitSettingsModel, PluginEditorController) {
        let pluginStore = PluginStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-window-tests-plugins-\(UUID().uuidString)"))
        let pluginHost = PluginHost(store: pluginStore, setUnit: { _ in })
        let audioUnits = AudioUnitSettingsModel(
            configStore: StubConfigStore(initial: .default), store: pluginStore, host: pluginHost,
            isBridgeAvailable: false)
        return (audioUnits, PluginEditorController(host: pluginHost))
    }

    func testInitConfiguresWindowFrameAndStyle() {
        let viewModel = SettingsViewModel(
            configStore: StubConfigStore(initial: AppSettings.default),
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: { }, openApplicationData: { }
        )
        let (audioUnits, pluginEditor) = makeAudioUnits()
        let sut = SettingsWindowController(viewModel: viewModel, audioUnits: audioUnits, pluginEditor: pluginEditor)
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
        let (audioUnits, pluginEditor) = makeAudioUnits()
        let sut = SettingsWindowController(viewModel: viewModel, audioUnits: audioUnits, pluginEditor: pluginEditor)
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
        let (audioUnits, pluginEditor) = makeAudioUnits()
        let controller = SettingsWindowController(viewModel: viewModel, audioUnits: audioUnits, pluginEditor: pluginEditor)
        XCTAssertEqual(controller.window?.title, "RP Player Settings")
    }
}
