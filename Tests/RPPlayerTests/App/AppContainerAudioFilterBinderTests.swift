import XCTest
@testable import RPPlayer

@MainActor
final class AppContainerAudioFilterBinderTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eq-binder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    func testTogglingEqEnabledWithPresetAppliesAndClearsChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(
            name: "test-preset",
            text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n",
            overwrite: false
        )
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: "test-preset"
        )
        var initialSettings = AppSettings.default
        initialSettings.outputDeviceUID = "dev-A"
        initialSettings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: initialSettings)
        let engine = MockPlayerEngine()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                initialProfile: initialProfile
            )
        }
        defer { binderTask.cancel() }

        // Initial state has eqEnabled=false → expect a setAudioFilterChain(nil) within a short window.
        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain == nil }
                return false
            }
        }, timeout: 1.0)

        // Toggle EQ on.
        try await configStore.update {
            $0.audioProfiles["dev-A"]?.eqEnabled = true
        }
        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain != nil }
                return false
            }
        }, timeout: 1.0)

        // Toggle EQ off.
        try await configStore.update {
            $0.audioProfiles["dev-A"]?.eqEnabled = false
        }
        // After turning EQ off there must be at least 2 nil-chain records (initial + post-toggle).
        try await waitUntil({
            let calls = await engine.recordedCalls()
            let nils = calls.filter { call in
                if case .setAudioFilterChain(let chain) = call { return chain == nil }
                return false
            }
            return nils.count >= 2
        }, timeout: 1.0)
    }

    func testMissingPresetFileClearsChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        // Profile says eqEnabled=true + eqPresetName="ghost" but file does not exist on disk.
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "ghost"
        )
        var initialSettings = AppSettings.default
        initialSettings.outputDeviceUID = "dev-A"
        initialSettings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: initialSettings)
        let engine = MockPlayerEngine()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                initialProfile: initialProfile
            )
        }
        defer { binderTask.cancel() }

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain == nil }
                return false
            }
        }, timeout: 1.0)
    }
}
