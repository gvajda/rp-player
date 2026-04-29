import XCTest
import CoreAudio
@testable import RPPlayer

final class TransportTypeTests: XCTestCase {
    func testMapsKnownTransportTypes() {
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeThunderbolt), .thunderbolt)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeHDMI), .hdmi)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeAirPlay), .airplay)
    }

    func testUnknownMapsToUnknown() {
        XCTAssertEqual(TransportType(rawCoreAudioValue: 0), .unknown)
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeUnknown), .unknown)
    }

    func testUnmappedTransportTypeFallsBackToUnknown() {
        // 'aggr' (kAudioDeviceTransportTypeAggregate) is a real CoreAudio value
        // we explicitly do not surface in v1.
        XCTAssertEqual(TransportType(rawCoreAudioValue: kAudioDeviceTransportTypeAggregate), .unknown)
    }

    func testIsBitPerfectRecommended() {
        XCTAssertTrue(TransportType.usb.isBitPerfectRecommended)
        XCTAssertTrue(TransportType.thunderbolt.isBitPerfectRecommended)
        XCTAssertTrue(TransportType.hdmi.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.builtIn.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.bluetooth.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.airplay.isBitPerfectRecommended)
        XCTAssertFalse(TransportType.unknown.isBitPerfectRecommended)
    }

    func testAudioDeviceIsEquatableAndSendable() {
        let a = AudioDevice(uid: "uid-1", name: "Device 1", transportType: .usb)
        let b = AudioDevice(uid: "uid-1", name: "Device 1", transportType: .usb)
        let c = AudioDevice(uid: "uid-2", name: "Device 2", transportType: .builtIn)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
