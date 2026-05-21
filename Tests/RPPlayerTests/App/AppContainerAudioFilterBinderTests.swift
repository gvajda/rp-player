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

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain == nil }
                return false
            }
        }, timeout: 1.0)

        try await configStore.update { $0.audioProfiles["dev-A"]?.eqEnabled = true }
        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain != nil }
                return false
            }
        }, timeout: 1.0)

        try await configStore.update { $0.audioProfiles["dev-A"]?.eqEnabled = false }
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

    func testCrossfeedNamedProfileEmitsBs2bChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: nil,
            crossfeedEnabled: true,
            crossfeedProfile: .cmoy,
            crossfeedFcut: 700,
            crossfeedFeedDb: 6.0
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
                if case .setAudioFilterChain(let chain) = call {
                    return chain == "lavfi=[bs2b=profile=cmoy]"
                }
                return false
            }
        }, timeout: 1.0)
    }

    func testCrossfeedCustomProfileEmitsFcutAndFeed() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: nil,
            crossfeedEnabled: true,
            crossfeedProfile: .custom,
            crossfeedFcut: 850,
            crossfeedFeedDb: 7.5
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
                if case .setAudioFilterChain(let chain) = call {
                    return chain == "lavfi=[bs2b=fcut=850:feed=75]"
                }
                return false
            }
        }, timeout: 1.0)
    }

    func testEqAndCrossfeedEmitCombinedChainInOrder() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(
            name: "combo-preset",
            text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n",
            overwrite: false
        )
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "combo-preset",
            crossfeedEnabled: true,
            crossfeedProfile: .jmeier,
            crossfeedFcut: 650,
            crossfeedFeedDb: 9.5
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
            // Expected order: preamp (volume) → EQ band → bs2b.
            let expected = "lavfi=[volume=volume=0dB,equalizer=f=1000:t=q:w=1:g=2,bs2b=profile=jmeier]"
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain == expected }
                return false
            }
        }, timeout: 1.0)
    }

    func testBothOffClearsChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: nil,
            crossfeedEnabled: false
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

    func testCrossfeedProfileChangeRewritesChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: nil,
            crossfeedEnabled: true,
            crossfeedProfile: .cmoy,
            crossfeedFcut: 700,
            crossfeedFeedDb: 6.0
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
                if case .setAudioFilterChain(let chain) = call {
                    return chain == "lavfi=[bs2b=profile=cmoy]"
                }
                return false
            }
        }, timeout: 1.0)

        try await configStore.update {
            $0.audioProfiles["dev-A"]?.crossfeedProfile = .jmeier
        }

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call {
                    return chain == "lavfi=[bs2b=profile=jmeier]"
                }
                return false
            }
        }, timeout: 1.0)
    }
}
