import XCTest
@testable import RPPlayer

final class AppSettingsUpdateFieldsTests: XCTestCase {
    func testDefaultsForNewUpdateFields() {
        let s = AppSettings.default
        XCTAssertTrue(s.updateCheckEnabled)
        XCTAssertNil(s.lastUpdateCheckAt)
        XCTAssertNil(s.dismissedUpdateVersion)
        XCTAssertNil(s.cachedLatestRelease)
    }

    func testCodableRoundTripPreservesUpdateFields() throws {
        var s = AppSettings.default
        s.updateCheckEnabled = false
        s.lastUpdateCheckAt = Date(timeIntervalSince1970: 1_715_000_000)
        s.dismissedUpdateVersion = "v0.5.0"
        s.cachedLatestRelease = ReleaseInfo(
            tagName: "v0.5.0",
            version: SemVer(major: 0, minor: 5, patch: 0),
            publishedAt: Date(timeIntervalSince1970: 1_715_000_000),
            body: "notes",
            htmlUrl: URL(string: "https://example.com")!,
            dmgAssetUrl: URL(string: "https://example.com/x.dmg")
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func testDecodeFromOldJsonMissingUpdateFieldsUsesDefaults() throws {
        let json = """
        {
          "selectedChannelId": 0,
          "hogModeEnabled": true,
          "releaseHogOnPauseEnabled": true,
          "forceMaxVolumeEnabled": false,
          "applyReplayGainEnabled": false,
          "notificationsEnabled": true,
          "appearance": "system",
          "menuBarIconStyle": "template",
          "ambientBackgroundEnabled": true,
          "popoverStyle": "ambient",
          "frostedUpcomingEnabled": false,
          "bitrate": 4,
          "logLevel": "info",
          "verboseLoggingEnabled": false,
          "upcomingRowCount": 5,
          "upcomingHiddenChannelIds": [],
          "popoverFloating": false,
          "audioProfiles": {}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.updateCheckEnabled)
        XCTAssertNil(decoded.lastUpdateCheckAt)
        XCTAssertNil(decoded.dismissedUpdateVersion)
        XCTAssertNil(decoded.cachedLatestRelease)
    }
}
