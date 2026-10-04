import XCTest
@testable import RPPlayer

@MainActor
final class AudioUnitSettingsModelTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!
    private var config: StubConfigStore!
    private var model: AudioUnitSettingsModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("au-model-\(UUID().uuidString)")
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        config = StubConfigStore(initial: settings)
        let host = PluginHost(store: store, setUnit: { _ in })
        model = AudioUnitSettingsModel(configStore: config, store: store, host: host, isBridgeAvailable: true)
        await model.start()
    }

    override func tearDown() async throws {
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String = "Console7Channel", entries: [[String: Any]] = [PluginFixtures.componentEntry()]) throws -> URL {
        try PluginFixtures.makeComponent(in: root.appendingPathComponent("src-\(UUID().uuidString)"), named: name, entries: entries)
    }

    func testImportSelectsAndEnablesOnCurrentDevice() async throws {
        try await model.importComponent(from: try source())
        let profile = try XCTUnwrap(config.settings.audioProfiles["dev-A"])
        XCTAssertTrue(profile.pluginEnabled)
        XCTAssertEqual(profile.pluginId, model.plugins.first?.id)
        XCTAssertEqual(model.plugins.count, 1)
        try await waitUntil({ [model] in await MainActor.run { model!.pluginEnabled && model!.pluginId != nil } }, timeout: 1.0)
    }

    func testSettersWriteCurrentDeviceProfile() async throws {
        await model.setPluginId("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        await model.setEnabled(true)
        let profile = try XCTUnwrap(config.settings.audioProfiles["dev-A"])
        XCTAssertEqual(profile.pluginId, "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertTrue(profile.pluginEnabled)
    }

    func testNoDeviceWritesNothing() async throws {
        try await config.update { $0.outputDeviceUID = nil }
        try await waitUntil({ [model] in await MainActor.run { !model!.hasOutputDevice } }, timeout: 1.0)
        await model.setEnabled(true)
        XCTAssertTrue(config.settings.audioProfiles.isEmpty)
    }

    func testDeleteClearsEveryReferenceThenRemovesPlugin() async throws {
        try await model.importComponent(from: try source())
        let id = try XCTUnwrap(model.plugins.first?.id)
        try await config.update {
            var other = AudioProfile.safeDefault
            other.pluginEnabled = true
            other.pluginId = id
            $0.audioProfiles["dev-B"] = other
        }
        try await model.deletePlugin(id: id)
        XCTAssertNil(config.settings.audioProfiles["dev-A"]?.pluginId)
        XCTAssertNil(config.settings.audioProfiles["dev-B"]?.pluginId)
        XCTAssertEqual(model.plugins, [])
        let remaining = await store.list()
        XCTAssertEqual(remaining, [])
    }

    func testImportErrorsHavePlainMessages() {
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.notAnEffect),
                       "This plugin is an instrument or generator. Only effect plugins can be used.")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.duplicate(name: "Console7")),
                       "\u{201C}Console7\u{201D} is already imported. Delete it first to import another copy.")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.wrongArchitecture),
                       "This plugin doesn't support this Mac's processor (it may be Intel-only).")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.notAComponent),
                       "This isn't an Audio Unit plugin (.component).")
    }
}
