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

    func testMissingAmbientBackgroundEnabledKeyDecodesAsTrue() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.ambientBackgroundEnabled)
    }

    func testMissingUpcomingRowCountDecodesAsFive() throws {
        let json = #"{"selectedChannelId":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.upcomingRowCount, 5)
    }

    func testMissingUpcomingHiddenChannelIdsDecodesAsEmpty() throws {
        let json = #"{"selectedChannelId":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.upcomingHiddenChannelIds, [])
    }

    func testUpcomingRowCountRoundTrips() throws {
        var settings = AppSettings.default
        settings.upcomingRowCount = 8
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.upcomingRowCount, 8)
    }

    func testUpcomingHiddenChannelIdsRoundTrips() throws {
        var settings = AppSettings.default
        settings.upcomingHiddenChannelIds = [1, 3]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.upcomingHiddenChannelIds, [1, 3])
    }

    func testRoundTripPreservesPopoverStyle() throws {
        for style in PopoverStyle.allCases {
            var settings = AppSettings.default
            settings.popoverStyle = style
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.popoverStyle, style, "round-trip failed for \(style)")
        }
    }

    func testMissingPopoverStyleKeyDecodesAsAmbient() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.popoverStyle, .ambient)
    }

    func testRoundTripPreservesFrostedUpcomingEnabled() throws {
        var settings = AppSettings.default
        settings.frostedUpcomingEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.frostedUpcomingEnabled)
    }

    func testMissingFrostedUpcomingEnabledKeyDecodesAsFalse() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.frostedUpcomingEnabled)
    }

    func testAudioProfileSafeDefaultValues() {
        let d = AudioProfile.safeDefault
        XCTAssertFalse(d.hogModeEnabled)
        XCTAssertFalse(d.releaseHogOnPauseEnabled)
        XCTAssertFalse(d.forceMaxVolumeEnabled)
        XCTAssertFalse(d.applyReplayGainEnabled)
        XCTAssertEqual(d.bitrate, 3)
    }

    func testAudioProfileRoundTrip() throws {
        let profile = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: false,
            forceMaxVolumeEnabled: true,
            applyReplayGainEnabled: false,
            bitrate: 4
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testMissingAudioProfilesKeyDecodesAsEmpty() throws {
        let json = """
        {"selectedChannelId":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.audioProfiles.isEmpty)
    }

    func testAudioProfilesRoundTripInAppSettings() throws {
        var settings = AppSettings.default
        settings.outputDeviceUID = "uid-dac"
        settings.audioProfiles["uid-dac"] = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: true,
            forceMaxVolumeEnabled: false,
            applyReplayGainEnabled: true,
            bitrate: 4
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.audioProfiles["uid-dac"], settings.audioProfiles["uid-dac"])
    }

    func testNoCrossDeviceBleedInAudioProfiles() throws {
        var settings = AppSettings.default
        settings.audioProfiles["uid-a"] = AudioProfile(
            hogModeEnabled: true, releaseHogOnPauseEnabled: true,
            forceMaxVolumeEnabled: true, applyReplayGainEnabled: true, bitrate: 4
        )
        settings.audioProfiles["uid-b"] = AudioProfile.safeDefault
        settings.audioProfiles["uid-a"]?.bitrate = 2
        XCTAssertEqual(settings.audioProfiles["uid-b"]?.bitrate, 3, "device B must not be affected")
    }
}
