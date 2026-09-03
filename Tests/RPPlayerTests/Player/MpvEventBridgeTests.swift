import XCTest
import CMpv
@testable import RPPlayer

final class MpvEventBridgeTests: XCTestCase {
    func testEndFileReasonsMapCorrectly() {
        var endEof = mpv_event_end_file()
        endEof.reason = MPV_END_FILE_REASON_EOF
        XCTAssertEqual(MpvEventBridge.endReason(from: endEof), .eof)

        var endStop = mpv_event_end_file()
        endStop.reason = MPV_END_FILE_REASON_STOP
        XCTAssertEqual(MpvEventBridge.endReason(from: endStop), .stopped)

        var endQuit = mpv_event_end_file()
        endQuit.reason = MPV_END_FILE_REASON_QUIT
        XCTAssertEqual(MpvEventBridge.endReason(from: endQuit), .quit)

        var endRedirect = mpv_event_end_file()
        endRedirect.reason = MPV_END_FILE_REASON_REDIRECT
        XCTAssertEqual(MpvEventBridge.endReason(from: endRedirect), .redirect)
    }

    func testEndFileErrorPreservesCode() {
        var endError = mpv_event_end_file()
        endError.reason = MPV_END_FILE_REASON_ERROR
        endError.error = -7
        XCTAssertEqual(MpvEventBridge.endReason(from: endError), .error(code: -7))
    }

    func testEndFileUnknownReasonFallsBack() {
        var endUnknown = mpv_event_end_file()
        endUnknown.reason = mpv_end_file_reason(rawValue: 999)
        XCTAssertEqual(MpvEventBridge.endReason(from: endUnknown), .unknown(rawValue: 999))
    }

    func testTimePosPropertyChangeBecomesPositionUpdate() {
        var pos: Int64 = 42
        let event = withUnsafeMutablePointer(to: &pos) { posPtr -> PlayerEvent? in
            "time-pos".withCString { namePtr in
                var prop = mpv_event_property()
                prop.name = namePtr
                prop.format = MPV_FORMAT_INT64
                prop.data = UnsafeMutableRawPointer(posPtr)
                return MpvEventBridge.propertyChange(from: prop)
            }
        }
        XCTAssertEqual(event, .positionUpdate(seconds: 42.0))
    }

    func testNonTimePosPropertyChangeReturnsNil() {
        var dummy: Double = 0
        let event = withUnsafeMutablePointer(to: &dummy) { ptr -> PlayerEvent? in
            "volume".withCString { namePtr in
                var prop = mpv_event_property()
                prop.name = namePtr
                prop.format = MPV_FORMAT_DOUBLE
                prop.data = UnsafeMutableRawPointer(ptr)
                return MpvEventBridge.propertyChange(from: prop)
            }
        }
        XCTAssertNil(event)
    }

    func testStartFileEventTranslatesToFileStarted() {
        var event = mpv_event()
        event.event_id = MPV_EVENT_START_FILE
        event.data = nil
        XCTAssertEqual(MpvEventBridge.playerEvent(from: event), .fileStarted)
    }

    func testTimePosWithWrongFormatReturnsNil() {
        var prop = mpv_event_property()
        "time-pos".withCString { namePtr in
            prop.name = namePtr
            prop.format = MPV_FORMAT_NONE
            prop.data = nil
            XCTAssertNil(MpvEventBridge.propertyChange(from: prop))
        }
    }

    private func withLogMessage<T>(
        level: String, prefix: String, text: String,
        _ body: (mpv_event_log_message) -> T
    ) -> T {
        level.withCString { levelPtr in
            prefix.withCString { prefixPtr in
                text.withCString { textPtr in
                    var msg = mpv_event_log_message()
                    msg.level = levelPtr
                    msg.prefix = prefixPtr
                    msg.text = textPtr
                    return body(msg)
                }
            }
        }
    }

    func testLogLineParsesFieldsAndTrimsNewline() {
        let line = withLogMessage(level: "warn", prefix: "ao/coreaudio", text: "can't start audio unit\n") {
            MpvEventBridge.logLine(from: $0)
        }
        XCTAssertEqual(line, MpvLogLine(level: "warn", prefix: "ao/coreaudio", text: "can't start audio unit"))
    }

    func testDiagnosticTextForwardsWarnAndAoVerboseOnly() {
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "warn", prefix: "demux", text: "x")),
            "mpv[demux] x"
        )
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "v", prefix: "ao/coreaudio", text: "selected audio output device: Q (78)")),
            "mpv[ao/coreaudio] selected audio output device: Q (78)"
        )
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "info", prefix: "ao", text: "y")),
            "mpv[ao] y"
        )
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "v", prefix: "demux", text: "x")))
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "info", prefix: "cplayer", text: "x")))
        XCTAssertNil(MpvEventBridge.diagnosticText(for: MpvLogLine(level: "error", prefix: "ao/coreaudio", text: "x")))
        XCTAssertEqual(
            MpvEventBridge.diagnosticText(for: MpvLogLine(level: "fatal", prefix: "ao", text: "z")),
            "mpv[ao] z"
        )
    }
}
