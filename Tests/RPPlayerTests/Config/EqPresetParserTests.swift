import XCTest
@testable import RPPlayer

final class EqPresetParserTests: XCTestCase {
    func testParsesPreampAndThreeBands() throws {
        let text = """
        CH: 0
        TYPE: PEQ
        Preamp: -1.2 dB
        Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.820
        Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.600
        Filter 3: ON HS Fc 8000 Hz Gain -0.5 dB Q 0.700
        """
        let result = EqPresetParser.parse(text: text, filename: "demo")
        let preset = try result.get()
        XCTAssertEqual(preset.name, "demo")
        XCTAssertEqual(preset.preampDb, -1.2, accuracy: 0.0001)
        XCTAssertEqual(preset.bands.count, 3)
        XCTAssertEqual(preset.bands[0].type, .lowShelf)
        XCTAssertEqual(preset.bands[1].type, .peak)
        XCTAssertEqual(preset.bands[2].type, .highShelf)
        XCTAssertEqual(preset.bands[1].fcHz, 300)
        XCTAssertEqual(preset.bands[1].gainDb, -1.6, accuracy: 0.0001)
        XCTAssertEqual(preset.bands[1].q, 0.6, accuracy: 0.0001)
    }

    func testDefaultsPreampToZeroWhenAbsent() throws {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0"
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.preampDb, 0)
    }

    func testIgnoresHeaderAndXfeedLines() throws {
        let text = """
        CH: 0
        TYPE: PEQ
        Xfeed: 1 1
        Preamp: 0 dB
        Filter 1: ON PK Fc 1000 Hz Gain 0 dB Q 1.0
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 1)
    }

    func testOffFiltersSilentlySkippedNoWarning() throws {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
        Filter 2: OFF PK Fc 200 Hz Gain 2 dB Q 1.0
        Filter 3: ON PK Fc 300 Hz Gain 3 dB Q 1.0
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 2)
        XCTAssertEqual(preset.bands.map(\.fcHz), [100, 300])
    }

    func testRejectsUnsupportedFilterType() {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0
        Filter 2: ON LP Fc 8000 Hz Gain 0 dB Q 1.0
        """
        let result = EqPresetParser.parse(text: text, filename: "n")
        switch result {
        case .success:
            XCTFail("should reject unsupported type LP")
        case .failure(let err):
            guard case .warningsNotPermitted(let warnings) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertTrue(warnings.contains { $0.contains("LP") })
        }
    }

    func testRejectsMoreThanTenBands() {
        let lines = (1...11).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 0 dB Q 1.0" }
        let result = EqPresetParser.parse(text: lines.joined(separator: "\n"), filename: "n")
        switch result {
        case .success: XCTFail("should reject >10 bands")
        case .failure(let err):
            guard case .warningsNotPermitted(let warnings) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertTrue(warnings.contains { $0.lowercased().contains("cap") || $0.contains("10") })
        }
    }

    func testRejectsMalformedFilterLine() {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0
        Filter 2: ON PK Fc whoops Gain 0 dB Q 1.0
        """
        let result = EqPresetParser.parse(text: text, filename: "n")
        if case .success = result {
            XCTFail("should reject malformed line")
        }
    }

    func testRejectsEmptyFile() {
        let result = EqPresetParser.parse(text: "   \n\n  \n", filename: "n")
        if case .success = result {
            XCTFail("should reject empty file")
        }
    }

    func testNameDerivedFromFilename() throws {
        let preset = try EqPresetParser.parse(
            text: "Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1.0",
            filename: "my-preset"
        ).get()
        XCTAssertEqual(preset.name, "my-preset")
    }
}
