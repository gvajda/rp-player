// Tests/RPPlayerTests/Config/AudioProfileCrossfeedMigrationTests.swift
import XCTest
@testable import RPPlayer

final class AudioProfileCrossfeedMigrationTests: XCTestCase {
    func testDefaultsWhenAllCrossfeedKeysAbsent() throws {
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
        XCTAssertEqual(profile.crossfeedProfile, .cmoy)
        XCTAssertEqual(profile.crossfeedFcut, 700)
        XCTAssertEqual(profile.crossfeedFeedDb, 6.0, accuracy: 1e-9)
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
            crossfeedProfile: .custom,
            crossfeedFcut: 850,
            crossfeedFeedDb: 7.2
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyStrengthRangeProfilesMigrateToCmoyDefaults() throws {
        // Simulates a profile saved by PR 36 (crossfeedStrength + crossfeedRange present, no new keys).
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "forceMax",
            "bitrate": 4,
            "eqEnabled": true,
            "eqPresetName": "harman",
            "crossfeedEnabled": true,
            "crossfeedStrength": 0.45,
            "crossfeedRange": 0.69
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertTrue(profile.crossfeedEnabled)
        XCTAssertEqual(profile.crossfeedProfile, .cmoy)
        XCTAssertEqual(profile.crossfeedFcut, 700)
        XCTAssertEqual(profile.crossfeedFeedDb, 6.0, accuracy: 1e-9)
        XCTAssertEqual(profile.volumeMode, .forceMax)
        XCTAssertTrue(profile.eqEnabled)
        XCTAssertEqual(profile.eqPresetName, "harman")
    }

    func testLegacyEqOnlyProfileUnchangedAfterUpgrade() throws {
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
        XCTAssertEqual(profile.crossfeedProfile, .cmoy)
    }

    func testLegacyBs2bDefaultProfileMigratesToCustomWithSeedValues() throws {
        let json = """
        {
            "hogModeEnabled": false,
            "releaseHogOnPauseEnabled": true,
            "volumeMode": "none",
            "bitrate": 4,
            "crossfeedEnabled": true,
            "crossfeedProfile": "default",
            "crossfeedFcut": 700,
            "crossfeedFeedDb": 4.5
        }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AudioProfile.self, from: json)
        XCTAssertEqual(profile.crossfeedProfile, .custom)
        XCTAssertEqual(profile.crossfeedFcut, 700)
        XCTAssertEqual(profile.crossfeedFeedDb, 4.5, accuracy: 1e-9)
    }

    func testEncodedJsonOmitsLegacyStrengthRangeKeys() throws {
        let profile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            crossfeedEnabled: true,
            crossfeedProfile: .jmeier,
            crossfeedFcut: 650,
            crossfeedFeedDb: 9.5
        )
        let data = try JSONEncoder().encode(profile)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(object["crossfeedStrength"])
        XCTAssertNil(object["crossfeedRange"])
        XCTAssertEqual(object["crossfeedProfile"] as? String, "jmeier")
        XCTAssertEqual(object["crossfeedFcut"] as? Int, 650)
        XCTAssertEqual(object["crossfeedFeedDb"] as? Double, 9.5)
    }
}
