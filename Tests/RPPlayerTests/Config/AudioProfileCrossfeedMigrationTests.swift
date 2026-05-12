// Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift
import XCTest
@testable import RPPlayer

final class AudioProfileCrossfeedMigrationTests: XCTestCase {
    func testDefaultsWhenKeysAbsent() throws {
        let json = """
        {
            "hogModeEnabled": true,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "none",
            "bitrate": 4
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
    }

    func testRoundTrip() throws {
        let original = AudioProfile(
            hogModeEnabled: true,
            releaseHogOnPauseEnabled: false,
            volumeMode: .replayGain,
            bitrate: 3,
            eqEnabled: true,
            eqPresetName: "my-preset",
            crossfeedEnabled: true,
            crossfeedStrength: 0.35,
            crossfeedRange: 0.65
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testExistingEqOnlyProfileUnchangedAfterUpgrade() throws {
        // Simulates a profile saved by PR 35 (no crossfeed keys yet).
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "forceMax",
            "bitrate": 4,
            "eqEnabled": true,
            "eqPresetName": "harman"
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertTrue(profile.eqEnabled)
        XCTAssertEqual(profile.eqPresetName, "harman")
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
        XCTAssertEqual(profile.volumeMode, .forceMax)
    }

    func testLegacyBoolMigrationStillWorks() throws {
        // PR 34 migration path: legacy forceMaxVolumeEnabled bool with no volumeMode.
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": false,
            "forceMaxVolumeEnabled": true,
            "applyReplayGainEnabled": true,
            "bitrate": 3
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(profile.volumeMode, .forceMax)
        XCTAssertFalse(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedStrength, 0.2, accuracy: 1e-9)
        XCTAssertEqual(profile.crossfeedRange, 0.5, accuracy: 1e-9)
    }
}
