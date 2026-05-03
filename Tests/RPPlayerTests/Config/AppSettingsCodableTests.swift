import XCTest
@testable import RPPlayer

final class AppSettingsCodableTests: XCTestCase {
    func testRoundTripPreservesAppearance() throws {
        var settings = AppSettings.default
        settings.appearance = .dark
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.appearance, .dark)
    }

    func testMissingAppearanceKeyDecodesAsSystem() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.appearance, .system)
    }

    func testAllAppearanceCasesRoundTrip() throws {
        for mode in AppearanceMode.allCases {
            var settings = AppSettings.default
            settings.appearance = mode
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.appearance, mode, "round-trip failed for \(mode)")
        }
    }

    func testMissingPlayerIdKeyDecodesAsNil() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertNil(decoded.playerId)
    }

    func testPlayerIdRoundTrips() throws {
        var settings = AppSettings.default
        settings.playerId = "rp3_abcd1234-5678-90ab-cdef-1234567890ab"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.playerId, "rp3_abcd1234-5678-90ab-cdef-1234567890ab")
    }

    func testRoundTripPreservesAmbientBackgroundEnabled() throws {
        var settings = AppSettings.default
        settings.ambientBackgroundEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.ambientBackgroundEnabled)
    }

    func testMissingAmbientBackgroundEnabledKeyDecodesAsFalse() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.ambientBackgroundEnabled)
    }
}
