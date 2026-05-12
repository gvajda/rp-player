import XCTest
@testable import RPPlayer

final class AudioProfileMigrationTests: XCTestCase {
    func testLegacyForceMaxBoolMigratesToForceMaxEnum() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":true,"applyReplayGainEnabled":false,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testLegacyReplayGainBoolMigratesToReplayGain() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":false,"applyReplayGainEnabled":true,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testLegacyBothFalseMigratesToNone() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":false,"applyReplayGainEnabled":false,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, VolumeMode.none)
    }

    func testLegacyBothTrueMigratesToForceMax() throws {
        // Force Max takes precedence — matches current effective-RG rule.
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "forceMaxVolumeEnabled":true,"applyReplayGainEnabled":true,
         "bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .forceMax)
    }

    func testNewKeyDecodesDirectly() throws {
        let json = """
        {"hogModeEnabled":true,"releaseHogOnPauseEnabled":true,
         "volumeMode":"replayGain","bitrate":4}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(decoded.volumeMode, .replayGain)
    }

    func testRoundTripUsesVolumeModeKeyNotLegacyBools() throws {
        let profile = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: true,
            volumeMode: .forceMax,
            bitrate: 4
        )
        let data = try JSONEncoder().encode(profile)
        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.contains("\"volumeMode\""))
        XCTAssertFalse(string.contains("forceMaxVolumeEnabled"))
        XCTAssertFalse(string.contains("applyReplayGainEnabled"))
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testSafeDefaultUsesNoneMode() {
        XCTAssertEqual(AudioProfile.safeDefault.volumeMode, VolumeMode.none)
    }

    func testEqFieldsDefaultWhenAbsent() throws {
        let json = """
        { "hogModeEnabled": false, "releaseHogOnPauseEnabled": false, "volumeMode": "none", "bitrate": 3 }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertFalse(profile.eqEnabled)
        XCTAssertNil(profile.eqPresetName)
    }

    func testEqFieldsRoundTrip() throws {
        let profile = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: true,
            volumeMode: .replayGain,
            bitrate: 4,
            eqEnabled: true,
            eqPresetName: "my-headphones"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertTrue(decoded.eqEnabled)
        XCTAssertEqual(decoded.eqPresetName, "my-headphones")
    }
}
