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

    private final class SelectRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String?] = []
        func record(_ id: String?) { lock.withLock { ids.append(id) } }
        var calls: [String?] { lock.withLock { ids } }
    }

    private nonisolated static let part = "ladspa=file=/x/libRPBridge.dylib:p=rpbridge"
    private nonisolated static let idA = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private nonisolated static let idB = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"

    private static func chains(_ engine: MockPlayerEngine) async -> [String?] {
        await engine.recordedCalls().compactMap { call in
            if case .setAudioFilterChain(let chain) = call { return .some(chain) }
            return nil
        }
    }

    private func startBinder(profile: AudioProfile, pluginPart: String?) -> (StubConfigStore, MockPlayerEngine, SelectRecorder, Task<Void, Never>) {
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = profile
        let configStore = StubConfigStore(initial: settings)
        let engine = MockPlayerEngine()
        let recorder = SelectRecorder()
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let task = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore, engine: engine, eqPresetStore: eqStore, override: EqEditingOverride(),
                initialProfile: profile, pluginPart: pluginPart, selectPlugin: { recorder.record($0) })
        }
        return (configStore, engine, recorder, task)
    }

    func testPluginPartSitsBetweenEqAndCrossfeed() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(name: "p", text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n", overwrite: false)
        var profile = AudioProfile.safeDefault
        profile.eqEnabled = true
        profile.eqPresetName = "p"
        profile.crossfeedEnabled = true
        profile.pluginEnabled = true
        profile.pluginId = Self.idA
        let (_, engine, recorder, task) = startBinder(profile: profile, pluginPart: Self.part)
        defer { task.cancel() }

        try await waitUntil({ await !Self.chains(engine).isEmpty }, timeout: 1.0)
        let lastChain = await Self.chains(engine).last ?? nil
        let chain = try XCTUnwrap(lastChain)
        let eq = try XCTUnwrap(chain.range(of: "equalizer"))
        let plugin = try XCTUnwrap(chain.range(of: Self.part))
        let bs2b = try XCTUnwrap(chain.range(of: "bs2b"))
        XCTAssertTrue(eq.upperBound <= plugin.lowerBound && plugin.upperBound <= bs2b.lowerBound, chain)
        try await waitUntil({ recorder.calls == [Self.idA] }, timeout: 1.0)
    }

    func testNoPluginPartWithoutIdOrBridge() async throws {
        var noId = AudioProfile.safeDefault
        noId.pluginEnabled = true
        let (_, engine1, recorder1, task1) = startBinder(profile: noId, pluginPart: Self.part)
        defer { task1.cancel() }
        try await waitUntil({ await !Self.chains(engine1).isEmpty }, timeout: 1.0)
        let chains1 = await Self.chains(engine1)
        XCTAssertEqual(chains1, [nil])
        try await waitUntil({ recorder1.calls == [nil] }, timeout: 1.0)

        var noBridge = AudioProfile.safeDefault
        noBridge.pluginEnabled = true
        noBridge.pluginId = Self.idA
        let (_, engine2, recorder2, task2) = startBinder(profile: noBridge, pluginPart: nil)
        defer { task2.cancel() }
        try await waitUntil({ await !Self.chains(engine2).isEmpty }, timeout: 1.0)
        let chains2 = await Self.chains(engine2)
        XCTAssertEqual(chains2, [nil])
        try await waitUntil({ recorder2.calls == [nil] }, timeout: 1.0)
    }

    func testSwappingPluginSelectsWithoutRewritingChain() async throws {
        var profile = AudioProfile.safeDefault
        profile.pluginEnabled = true
        profile.pluginId = Self.idA
        let (configStore, engine, recorder, task) = startBinder(profile: profile, pluginPart: Self.part)
        defer { task.cancel() }
        try await waitUntil({ recorder.calls == [Self.idA] }, timeout: 1.0)

        try await configStore.update { $0.audioProfiles["dev-A"]?.pluginId = Self.idB }
        try await waitUntil({ recorder.calls == [Self.idA, Self.idB] }, timeout: 1.0)
        let finalChains = await Self.chains(engine)
        XCTAssertEqual(finalChains, ["lavfi=[\(Self.part)]"], "a plugin swap must not rewrite af")
    }

    func testUnrelatedProfileChangeDoesNotReselectPlugin() async throws {
        var profile = AudioProfile.safeDefault
        profile.pluginEnabled = true
        profile.pluginId = Self.idA
        let (configStore, engine, recorder, task) = startBinder(profile: profile, pluginPart: Self.part)
        defer { task.cancel() }
        try await waitUntil({ recorder.calls == [Self.idA] }, timeout: 1.0)

        try await configStore.update { $0.audioProfiles["dev-A"]?.crossfeedEnabled = true }
        try await waitUntil({
            await Self.chains(engine).last.flatMap { $0 }?.contains("bs2b") ?? false
        }, timeout: 1.0)

        XCTAssertEqual(recorder.calls, [Self.idA])
    }

    func testDisablingPluginDeselectsAndDropsPart() async throws {
        var profile = AudioProfile.safeDefault
        profile.pluginEnabled = true
        profile.pluginId = Self.idA
        let (configStore, engine, recorder, task) = startBinder(profile: profile, pluginPart: Self.part)
        defer { task.cancel() }
        try await waitUntil({ recorder.calls == [Self.idA] }, timeout: 1.0)

        try await configStore.update { $0.audioProfiles["dev-A"]?.pluginEnabled = false }
        try await waitUntil({ recorder.calls == [Self.idA, nil] }, timeout: 1.0)
        try await waitUntil({ await Self.chains(engine) == ["lavfi=[\(Self.part)]", nil] }, timeout: 1.0)
    }

    func testRapidMixedUpdatesEndOnLatestChain() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await eqStore.save(name: "p", text: "Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1.0\n", overwrite: false)
        var initialProfile = AudioProfile.safeDefault
        initialProfile.eqEnabled = true
        initialProfile.eqPresetName = "p"
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        settings.audioProfiles["dev-A"] = initialProfile
        let configStore = StubConfigStore(initial: settings)
        let engine = MockPlayerEngine()
        let override = EqEditingOverride()

        let task = Task {
            await AppContainer.runAudioFilterBinder(
                store: configStore, engine: engine, eqPresetStore: eqStore, override: override,
                initialProfile: initialProfile)
        }
        defer { task.cancel() }

        try await waitUntil({ await !Self.chains(engine).isEmpty }, timeout: 1.0)

        let overridePreset = EqPreset(
            name: nil, preampDb: 0,
            bands: [EqBand(enabled: true, type: .peak, fcHz: 1000, gainDb: -9, q: 1)]
        )
        async let setOverride: Void = override.set(overridePreset)
        async let toggleCrossfeed: Void = configStore.update { $0.audioProfiles["dev-A"]?.crossfeedEnabled = true }
        _ = try await (setOverride, toggleCrossfeed)

        var expectedProfile = initialProfile
        expectedProfile.crossfeedEnabled = true
        let expectedChain = await AppContainer.buildAudioFilterChain(
            store: eqStore, profile: expectedProfile, override: overridePreset, pluginPart: nil)

        try await waitUntil({ await Self.chains(engine).last ?? nil == expectedChain }, timeout: 1.0)
        let finalChain = await Self.chains(engine).last ?? nil
        XCTAssertEqual(finalChain, expectedChain)
    }
}
