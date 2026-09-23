import XCTest
@testable import RPPlayer

final class AudioProfilePluginTests: XCTestCase {
    func testLegacyJsonDecodesWithPluginDisabled() throws {
        let json = #"{"hogModeEnabled":true,"releaseHogOnPauseEnabled":false,"volumeMode":"none","bitrate":4}"#
        let profile = try JSONDecoder().decode(AudioProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.pluginEnabled)
        XCTAssertNil(profile.pluginId)
    }

    func testPluginFieldsRoundTrip() throws {
        var profile = AudioProfile.safeDefault
        profile.pluginEnabled = true
        profile.pluginId = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testDeviceSettingsWriteBackKeepsFilterAndPluginFields() {
        var existing = AudioProfile.safeDefault
        existing.eqEnabled = true
        existing.eqPresetName = "HD600"
        existing.crossfeedEnabled = true
        existing.crossfeedProfile = .jmeier
        existing.pluginEnabled = true
        existing.pluginId = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        var settings = AppSettings.default
        settings.hogModeEnabled = true
        settings.releaseHogOnPauseEnabled = true
        settings.volumeMode = .replayGain
        settings.bitrate = 4

        let result = AppContainer.profileWritingDeviceSettings(settings, onto: existing)

        var expected = existing
        expected.hogModeEnabled = true
        expected.releaseHogOnPauseEnabled = true
        expected.volumeMode = .replayGain
        expected.bitrate = 4
        XCTAssertEqual(result, expected)
    }
}
