import XCTest
@testable import RPPlayer

final class EqChainBuilderTests: XCTestCase {
    func testEmptyBandsAndZeroPreampReturnsNil() {
        let preset = EqPreset(name: nil, preampDb: 0, bands: [])
        XCTAssertNil(EqChainBuilder.build(preset))
    }

    func testPreampOnly() {
        let preset = EqPreset(name: nil, preampDb: -2.5, bands: [])
        XCTAssertEqual(EqChainBuilder.build(preset), "lavfi=[volume=-2.5dB]")
    }

    func testPeakBand() {
        let preset = EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 2.0, q: 1.4)]
        )
        XCTAssertEqual(
            EqChainBuilder.build(preset),
            "lavfi=[volume=0dB,equalizer=f=1000:t=q:w=1.4:g=2]"
        )
    }

    func testMixedBands() {
        let preset = EqPreset(
            name: nil, preampDb: -1.2,
            bands: [
                EqBand(enabled: true, type: .lowShelf, fcHz: 83, gainDb: 1.2, q: 0.82),
                EqBand(enabled: true, type: .peak, fcHz: 300, gainDb: -1.6, q: 0.6),
                EqBand(enabled: true, type: .highShelf, fcHz: 8000, gainDb: -0.8, q: 0.7),
            ]
        )
        XCTAssertEqual(
            EqChainBuilder.build(preset),
            "lavfi=[volume=-1.2dB,lowshelf=f=83:t=q:w=0.82:g=1.2,equalizer=f=300:t=q:w=0.6:g=-1.6,highshelf=f=8000:t=q:w=0.7:g=-0.8]"
        )
    }

    func testDisabledBandsSkipped() {
        let preset = EqPreset(
            name: nil, preampDb: 0,
            bands: [
                EqBand(enabled: false, type: .peak, fcHz: 1000, gainDb: 2, q: 1),
                EqBand(enabled: true, type: .peak, fcHz: 2000, gainDb: 3, q: 1),
            ]
        )
        XCTAssertEqual(
            EqChainBuilder.build(preset),
            "lavfi=[volume=0dB,equalizer=f=2000:t=q:w=1:g=3]"
        )
    }
}
