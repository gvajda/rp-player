import XCTest
@testable import RPPlayer

final class StreamFormatTests: XCTestCase {
    func testDisplayStringForFLAC() {
        let f = StreamFormat(codec: "flac", sampleRateHz: 44100, kbps: 850)
        XCTAssertEqual(f.displayString, "FLAC 44.1 kHz")
    }
    func testDisplayStringForMP3() {
        let f = StreamFormat(codec: "mp3", sampleRateHz: 44100, kbps: 320)
        XCTAssertEqual(f.displayString, "MP3 320 kbps")
    }
    func testDisplayStringForUnknownCodec() {
        let f = StreamFormat(codec: "aac", sampleRateHz: 48000, kbps: 256)
        XCTAssertEqual(f.displayString, "AAC 48000 Hz")
    }
    func testDisplayStringHandlesMissingKbpsForMP3() {
        let f = StreamFormat(codec: "mp3", sampleRateHz: 44100, kbps: nil)
        XCTAssertEqual(f.displayString, "MP3 44.1 kHz")
    }
    func testDisplayStringHandlesNonRoundKHz() {
        let f = StreamFormat(codec: "flac", sampleRateHz: 96000, kbps: nil)
        XCTAssertEqual(f.displayString, "FLAC 96 kHz")
    }
}
