import XCTest
@testable import RPPlayer

final class EqPresetWriterTests: XCTestCase {
    func testWriteEmitsAllSupportedTypes() {
        let preset = EqPreset(
            name: "n",
            preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        let text = EqPresetWriter.write(preset)
        XCTAssertTrue(text.contains("Preamp: -1.2 dB"))
        XCTAssertTrue(text.contains("Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.82"))
        XCTAssertTrue(text.contains("Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.6"))
        XCTAssertTrue(text.contains("Filter 3: ON HS Fc 8000 Hz Gain -0.8 dB Q 0.7"))
    }

    func testRoundTripFromParsedForm() throws {
        let original = """
        Preamp: -1.2 dB
        Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.82
        Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.6
        """
        let parsed = try EqPresetParser.parse(text: original, filename: "n").get()
        let written = EqPresetWriter.write(parsed)
        let reparsed = try EqPresetParser.parse(text: written, filename: "n").get()
        XCTAssertEqual(reparsed, parsed)
    }

    func testDisabledBandEmittedAsOff() {
        let preset = EqPreset(
            name: nil,
            preampDb: 0,
            bands: [
                EqBand(enabled: false, type: .peak, fcHz: 100, gainDb: 0, q: 1),
                EqBand(enabled: true,  type: .peak, fcHz: 200, gainDb: 0, q: 1),
                EqBand(enabled: true,  type: .peak, fcHz: 300, gainDb: 0, q: 1),
            ]
        )
        let text = EqPresetWriter.write(preset)
        XCTAssertTrue(text.contains("Filter 1: OFF PK Fc 100 Hz Gain 0 dB Q 1"), "got:\n\(text)")
        XCTAssertTrue(text.contains("Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1"),  "got:\n\(text)")
        XCTAssertTrue(text.contains("Filter 3: ON PK Fc 300 Hz Gain 0 dB Q 1"),  "got:\n\(text)")
    }

    func testRoundTripPreservesDisabledBand() throws {
        let preset = EqPreset(
            name: nil,
            preampDb: -1,
            bands: [
                EqBand(enabled: true,  type: .peak,     fcHz: 100, gainDb: 1,   q: 1),
                EqBand(enabled: false, type: .lowShelf, fcHz: 200, gainDb: 2,   q: 0.7),
                EqBand(enabled: true,  type: .highShelf, fcHz: 300, gainDb: 0.5, q: 0.5),
            ]
        )
        let written = EqPresetWriter.write(preset)
        let reparsed = try EqPresetParser.parse(text: written, filename: "n").get()
        XCTAssertEqual(reparsed.bands, preset.bands)
        XCTAssertEqual(reparsed.preampDb, preset.preampDb, accuracy: 0.0001)
    }
}
