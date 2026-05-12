import XCTest
@testable import RPPlayer

final class EqModelsTests: XCTestCase {
    func testEqPresetRoundTrip() throws {
        let preset = EqPreset(
            name: "test",
            preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(EqPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testEqBandTypeRawValues() {
        XCTAssertEqual(EqBandType.peak.rawValue, "peak")
        XCTAssertEqual(EqBandType.lowShelf.rawValue, "lowShelf")
        XCTAssertEqual(EqBandType.highShelf.rawValue, "highShelf")
    }

    func testEqPresetEqualityIgnoresNothing() {
        let a = EqPreset(name: "a", preampDb: 0, bands: [])
        let b = EqPreset(name: "b", preampDb: 0, bands: [])
        XCTAssertNotEqual(a, b)
    }
}
