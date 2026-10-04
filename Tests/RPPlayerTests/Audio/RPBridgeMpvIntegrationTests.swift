import CMpv
import XCTest
@testable import RPPlayer

final class RPBridgeMpvIntegrationTests: XCTestCase {
    func testMpvPlaysThroughBridgeLoadedFromEscapedPath() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RP Bridge's: test, dir; \(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let bridgePath = dir.appendingPathComponent(PluginBridge.fileName).path
        try fm.copyItem(atPath: RPBridgeTestSupport.dylibPath, toPath: bridgePath)
        let wav = dir.appendingPathComponent("tone.wav")
        try RPBridgeTestSupport.writeStereoWav(to: wav, frames: 22050, rate: 44100)
        let part = try XCTUnwrap(PluginBridge.filterPart(path: bridgePath))

        // Held open so af_ladspa's dlclose at end-of-file cannot unload the image before the counter is read.
        let bridge = try RPBridgeTestSupport.open(bridgePath)
        let before = bridge.framesProcessed()

        let mpv = try XCTUnwrap(mpv_create())
        defer { mpv_terminate_destroy(mpv) }
        for (k, v) in [("vid", "no"), ("terminal", "no"), ("audio-display", "no"),
                       ("ao", "null"), ("ao-null-untimed", "yes"), ("idle", "yes")] {
            XCTAssertGreaterThanOrEqual(mpv_set_option_string(mpv, k, v), 0, k)
        }
        XCTAssertGreaterThanOrEqual(mpv_initialize(mpv), 0)
        XCTAssertGreaterThanOrEqual(mpv_set_property_string(mpv, "af", "lavfi=[\(part)]"), 0)

        let cmd = strdup("loadfile")!, file = strdup(wav.path)!
        defer { free(cmd); free(file) }
        var argv: [UnsafePointer<CChar>?] = [UnsafePointer(cmd), UnsafePointer(file), nil]
        XCTAssertGreaterThanOrEqual(argv.withUnsafeMutableBufferPointer { mpv_command(mpv, $0.baseAddress) }, 0)

        var ended = false
        let deadline = Date().addingTimeInterval(10)
        while !ended, Date() < deadline {
            if let event = mpv_wait_event(mpv, 0.5), event.pointee.event_id == MPV_EVENT_END_FILE { ended = true }
        }
        XCTAssertTrue(ended, "mpv never finished the file")
        XCTAssertGreaterThan(bridge.framesProcessed() - before, 0,
                             "bridge never ran — lavfi could not load it from the escaped path")
    }
}
