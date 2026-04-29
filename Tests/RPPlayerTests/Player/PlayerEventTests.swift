import XCTest
@testable import RPPlayer

final class PlayerEventTests: XCTestCase {
    func testEqualityForPositionUpdate() {
        XCTAssertEqual(
            PlayerEvent.positionUpdate(seconds: 12.5),
            PlayerEvent.positionUpdate(seconds: 12.5)
        )
        XCTAssertNotEqual(
            PlayerEvent.positionUpdate(seconds: 12.5),
            PlayerEvent.positionUpdate(seconds: 12.6)
        )
    }

    func testEqualityForFileEnded() {
        XCTAssertEqual(PlayerEvent.fileEnded(reason: .eof), PlayerEvent.fileEnded(reason: .eof))
        XCTAssertNotEqual(PlayerEvent.fileEnded(reason: .eof), PlayerEvent.fileEnded(reason: .stopped))
    }

    func testEqualityForOutputDeviceChanged() {
        XCTAssertEqual(
            PlayerEvent.outputDeviceChanged(uid: "uid-1"),
            PlayerEvent.outputDeviceChanged(uid: "uid-1")
        )
        XCTAssertEqual(
            PlayerEvent.outputDeviceChanged(uid: nil),
            PlayerEvent.outputDeviceChanged(uid: nil)
        )
        XCTAssertNotEqual(
            PlayerEvent.outputDeviceChanged(uid: "uid-1"),
            PlayerEvent.outputDeviceChanged(uid: nil)
        )
    }

    func testPlayerEndReasonUnknownPreservesRawValue() {
        XCTAssertEqual(PlayerEndReason.unknown(rawValue: 99), .unknown(rawValue: 99))
        XCTAssertNotEqual(PlayerEndReason.unknown(rawValue: 99), .unknown(rawValue: 100))
    }

    func testPlayerEngineErrorEquality() {
        XCTAssertEqual(
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail"),
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail")
        )
        XCTAssertNotEqual(
            PlayerEngineError.commandFailed(name: "loadfile", code: -3, message: "fail"),
            PlayerEngineError.commandFailed(name: "loadfile", code: -4, message: "fail")
        )
    }
}
