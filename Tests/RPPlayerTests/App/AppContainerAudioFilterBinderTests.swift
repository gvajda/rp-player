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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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
        let override = EqEditingOverride()

        let binderTask = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
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

    func testOverridePresetTakesPrecedenceOverDiskFile() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(
            name: "disk-preset",
            text: "Filter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.0\n",
            overwrite: false
        )
        let override = EqEditingOverride()
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "disk-preset"
        )
        var initialSettings = AppSettings.default
        initialSettings.outputDeviceUID = "dev-A"
        initialSettings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: initialSettings)
        let engine = MockPlayerEngine()

        let task = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
                initialProfile: initialProfile
            )
        }
        defer { task.cancel() }

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call {
                    return chain?.contains("equalizer") == true && chain?.contains("g=6") == true
                }
                return false
            }
        }, timeout: 1.0)

        let editingPreset = EqPreset(
            name: nil,
            preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: -12, q: 1)]
        )
        await override.set(editingPreset)
        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call {
                    return chain?.contains("g=-12") ?? false
                }
                return false
            }
        }, timeout: 1.0)
    }

    func testClearingOverrideRevertsToDiskPreset() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(
            name: "p",
            text: "Filter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n",
            overwrite: false
        )
        let override = EqEditingOverride()
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "p"
        )
        var initialSettings = AppSettings.default
        initialSettings.outputDeviceUID = "dev-A"
        initialSettings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: initialSettings)
        let engine = MockPlayerEngine()

        await override.set(EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: -6, q: 1)]
        ))

        let task = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
                initialProfile: initialProfile
            )
        }
        defer { task.cancel() }

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain?.contains("g=-6") ?? false }
                return false
            }
        }, timeout: 1.0)

        await override.set(nil)
        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain?.contains("g=3") ?? false }
                return false
            }
        }, timeout: 1.0)
    }

    func testOverrideIgnoredWhenEqDisabled() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let initialProfile = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: false, eqPresetName: nil
        )
        var initialSettings = AppSettings.default
        initialSettings.outputDeviceUID = "dev-A"
        initialSettings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: initialSettings)
        let engine = MockPlayerEngine()

        let task = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore,
                engine: engine,
                eqPresetStore: eqStore,
                override: override,
                initialProfile: initialProfile
            )
        }
        defer { task.cancel() }

        try await waitUntil({
            let calls = await engine.recordedCalls()
            return calls.contains { call in
                if case .setAudioFilterChain(let chain) = call { return chain == nil }
                return false
            }
        }, timeout: 1.0)

        let priorCount = await engine.recordedCalls().count
        await override.set(EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: 12, q: 1)]
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterCount = await engine.recordedCalls().count
        // Override has no audible effect when EQ is off — the chain should not gain EQ parts
        let recent = await engine.recordedCalls()
        for call in recent.suffix(max(0, afterCount - priorCount)) {
            if case .setAudioFilterChain(let chain) = call {
                XCTAssertFalse(chain?.contains("equalizer") ?? false, "EQ part appeared while EQ disabled")
            }
        }
    }
}
