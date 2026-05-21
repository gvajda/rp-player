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

    func testOffFiltersKeptInOrderWithDisabledFlag() throws {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
        Filter 2: OFF PK Fc 200 Hz Gain 2 dB Q 1.0
        Filter 3: ON PK Fc 300 Hz Gain 3 dB Q 1.0
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 3)
        XCTAssertEqual(preset.bands.map(\.fcHz), [100, 200, 300])
        XCTAssertEqual(preset.bands.map(\.enabled), [true, false, true])
    }

    func testOffFilterPreservedAsDisabledBand() throws {
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1.0
        Filter 2: OFF LS Fc 200 Hz Gain 2 dB Q 0.7
        Filter 3: ON HS Fc 300 Hz Gain 3 dB Q 0.5
        """
        let preset = try EqPresetParser.parse(text: text, filename: "n").get()
        XCTAssertEqual(preset.bands.count, 3)
        XCTAssertEqual(preset.bands[0].enabled, true)
        XCTAssertEqual(preset.bands[1].enabled, false)
        XCTAssertEqual(preset.bands[1].type, .lowShelf)
        XCTAssertEqual(preset.bands[1].fcHz, 200)
        XCTAssertEqual(preset.bands[1].gainDb, 2)
        XCTAssertEqual(preset.bands[1].q, 0.7, accuracy: 0.0001)
        XCTAssertEqual(preset.bands[2].enabled, true)
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

    func testParsesCRLFLineEndings() throws {
        let text = "Preamp: -1.2 dB\r\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\r\n"
        let preset = try EqPresetParser.parse(text: text, filename: "crlf").get()
        XCTAssertEqual(preset.preampDb, -1.2, accuracy: 0.0001)
        XCTAssertEqual(preset.bands.count, 1)
    }

    func testParsesLinesWithTrailingSpaces() throws {
        let text = "Preamp: -1.2 dB \r\nFilter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.820 \r\n"
        let preset = try EqPresetParser.parse(text: text, filename: "trail").get()
        XCTAssertEqual(preset.bands.count, 1)
        XCTAssertEqual(preset.bands[0].type, .lowShelf)
        XCTAssertEqual(preset.bands[0].fcHz, 83)
    }

    func testParsesCRLFFullPresetExample() throws {
        let text = """
        CH: 0 \r
        TYPE: PEQ \r
        Preamp: -1.2 dB \r
        Xfeed: 1 1\r
        Filter 1: ON LS Fc 83 Hz Gain 1.2 dB Q 0.820 \r
        Filter 2: ON PK Fc 300 Hz Gain -1.6 dB Q 0.600 \r
        Filter 3: ON PK Fc 950 Hz Gain -1.9 dB Q 1.800 \r
        Filter 4: ON PK Fc 1900 Hz Gain 0.9 dB Q 0.800 \r
        Filter 5: ON PK Fc 3400 Hz Gain -2.1 dB Q 2.100 \r
        Filter 6: ON PK Fc 8000 Hz Gain -2.0 dB Q 1.420 \r
        Filter 7: ON PK Fc 7400 Hz Gain -2.0 dB Q 5.000 \r
        Filter 8: ON PK Fc 9100 Hz Gain -3.0 dB Q 6.000 \r
        Filter 9: ON HS Fc 11500 Hz Gain -1.2 dB Q 0.710 \r
        Filter 10: ON PK Fc 12000 Hz Gain -3.0 dB Q 4.000 \r
        """
        let preset = try EqPresetParser.parse(text: text, filename: "real").get()
        XCTAssertEqual(preset.preampDb, -1.2, accuracy: 0.0001)
        XCTAssertEqual(preset.bands.count, 10)
        XCTAssertEqual(preset.bands.first?.type, .lowShelf)
        XCTAssertEqual(preset.bands.last?.type, .peak)
    }
}
