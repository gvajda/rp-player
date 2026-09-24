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
        let pluginStore = PluginStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-view-tests-plugins-\(UUID().uuidString)"))
        let pluginHost = PluginHost(store: pluginStore, setUnit: { _ in })
        let audioUnits = AudioUnitSettingsModel(
            configStore: StubConfigStore(initial: .default), store: pluginStore, host: pluginHost,
            isBridgeAvailable: false)
        let pluginEditor = PluginEditorController(host: pluginHost)
        let host = NSHostingController(
            rootView: SettingsView(viewModel: viewModel, audioUnits: audioUnits, pluginEditor: pluginEditor))
        host.loadView()
        XCTAssertNotNil(host.view)
        XCTAssertGreaterThan(host.view.intrinsicContentSize.width, 0)
    }
}
