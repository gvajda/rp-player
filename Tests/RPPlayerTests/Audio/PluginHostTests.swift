import AudioToolbox
import AVFAudio
import XCTest
@testable import RPPlayer

@MainActor
final class PluginHostTests: XCTestCase {
    private final class UnitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var units: [AudioUnit?] = []
        func record(_ unit: AudioUnit?) { lock.withLock { units.append(unit) } }
        var calls: [AudioUnit?] { lock.withLock { units } }
    }

    private var root: URL!
    private var store: PluginStore!
    private var recorder: UnitRecorder!
    private var host: PluginHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-host-\(UUID().uuidString)")
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
        recorder = UnitRecorder()
        let recorder = recorder!
        host = PluginHost(store: store, setUnit: { recorder.record($0) })
    }

    override func tearDown() async throws {
        await host.select(nil)
        try? FileManager.default.removeItem(at: root)
    }

    // A plist-only bundle declaring Apple's AUHipass: FindNext finds the system unit, so no registration is needed.
    private func importAppleHipass() async throws -> ImportedPlugin {
        let src = root.appendingPathComponent("src")
        let bundle = try PluginFixtures.makeComponent(in: src, named: "Hipass", entries: [
            PluginFixtures.componentEntry(type: "aufx", subtype: "hpas", manufacturer: "appl",
                                          name: "Apple: AUHipass", factory: "unused"),
        ])
        return try await store.importComponent(from: bundle)
    }

    private func cutoff() -> AudioUnitParameterValue {
        var value: AudioUnitParameterValue = 0
        XCTAssertEqual(AudioUnitGetParameter(host.audioUnit!.audioUnit, kHipassParam_CutoffFrequency,
                                             kAudioUnitScope_Global, 0, &value), noErr)
        return value
    }

    func testSelectLoadsUnitHandsItToBridgeAndRestoresSavedState() async throws {
        let plugin = try await importAppleHipass()
        await host.select(plugin.id)
        XCTAssertEqual(host.current, plugin)
        XCTAssertNil(host.loadError)
        let unit = try XCTUnwrap(host.audioUnit?.audioUnit)
        XCTAssertEqual(recorder.calls.last!, unit)

        XCTAssertEqual(AudioUnitSetParameter(unit, kHipassParam_CutoffFrequency, kAudioUnitScope_Global, 0, 1234, 0), noErr)
        await host.saveCurrentState()
        await host.select(nil)
        await host.select(plugin.id)
        XCTAssertEqual(cutoff(), 1234, accuracy: 0.5)
    }

    func testSelectNilClearsBridgeAndCurrent() async throws {
        let plugin = try await importAppleHipass()
        await host.select(plugin.id)
        await host.select(nil)
        XCTAssertNil(host.current)
        XCTAssertNil(host.audioUnit)
        XCTAssertNil(recorder.calls.last!)
    }

    func testUnknownIdSetsLoadErrorAndPassesThrough() async {
        await host.select("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertNil(host.current)
        XCTAssertNotNil(host.loadError)
        XCTAssertNil(recorder.calls.last!)
    }

    func testUnloadableBundleReportsSigningHint() async throws {
        let src = root.appendingPathComponent("src")
        let bundle = try PluginFixtures.makeComponent(in: src, named: "Ghost", entries: [
            PluginFixtures.componentEntry(subtype: "Zzzz", manufacturer: "Zzzz", name: "Ghost: Nothing", factory: "GhostFactory"),
        ])
        let plugin = try await store.importComponent(from: bundle)
        await host.select(plugin.id)
        XCTAssertNil(host.current)
        XCTAssertTrue(host.loadError?.contains("Open the plugin once in Finder, or check that it is signed.") ?? false,
                      host.loadError ?? "no error")
        XCTAssertNil(recorder.calls.last!)
    }
}
