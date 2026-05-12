import XCTest
@testable import RPPlayer

final class AppSettingsVolumeModeMigrationTests: XCTestCase {
    func testLegacyBoolsMigrateForceMaxWins() throws {
        let json = """
        {"forceMaxVolumeEnabled":true,"applyReplayGainEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testLegacyReplayGainOnly() throws {
        let json = """
        {"forceMaxVolumeEnabled":false,"applyReplayGainEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testLegacyBothOff() throws {
        let json = """
        {"forceMaxVolumeEnabled":false,"applyReplayGainEnabled":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }

    func testNewKeyTakesPrecedenceWhenBothPresent() throws {
        let json = """
        {"forceMaxVolumeEnabled":true,"applyReplayGainEnabled":false,
         "volumeMode":"replayGain"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testEncodedJSONOmitsLegacyKeys() throws {
        var settings = AppSettings.default
        settings.volumeMode = .forceMax
        let data = try JSONEncoder().encode(settings)
        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("\"volumeMode\":\"forceMax\""))
        XCTAssertFalse(string.contains("forceMaxVolumeEnabled"))
        XCTAssertFalse(string.contains("applyReplayGainEnabled"))
    }

    func testMissingFieldDefaultsToNone() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }
}
