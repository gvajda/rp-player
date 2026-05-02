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
}
