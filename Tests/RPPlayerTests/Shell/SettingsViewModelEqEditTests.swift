import XCTest
@testable import RPPlayer

@MainActor
final class SettingsViewModelEqEditTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-eq-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func savePresetFile(_ store: LiveEqPresetStore, name: String) async throws {
        try await store.save(
            name: name,
            text: "Preamp: -1 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n",
            overwrite: false
        )
    }

    private func makeVM(eqStore: any EqPresetStore, override: EqEditingOverride) -> SettingsViewModel {
        var initial = AppSettings.default
        initial.outputDeviceUID = "dev-A"
        initial.audioProfiles["dev-A"] = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "alpha"
        )
        let configStore = StubConfigStore(initial: initial)
        return SettingsViewModel(
            configStore: configStore,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {},
            eqPresetStore: eqStore,
            eqEditingOverride: override
        )
    }

    func testBeginEditCurrentCopiesParsedPresetIntoEditingState() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()

        XCTAssertEqual(vm.editingOriginalName, "alpha")
        XCTAssertNotNil(vm.editingPreset)
        XCTAssertEqual(vm.editingPreset?.bands.count, 1)
        XCTAssertFalse(vm.editingDirty)
        let pushed = await override.snapshot()
        XCTAssertNotNil(pushed)
    }

    func testBeginNewPresetYieldsEmptyDraft() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        XCTAssertNil(vm.editingOriginalName)
        XCTAssertEqual(vm.editingPreset?.bands.count, 0)
        XCTAssertEqual(vm.editingPreset?.preampDb, 0)
        XCTAssertFalse(vm.editingDirty)
    }

    func testSetEditingPreampMarksDirtyAndPushesOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-4)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.editingPreset?.preampDb, -4)
        XCTAssertTrue(vm.editingDirty)
        let snap = await override.snapshot()
        XCTAssertEqual(snap?.preampDb, -4)
    }

    func testAddEditingBandCapsAtTen() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        for _ in 0..<12 { await vm.addEditingBand() }
        XCTAssertEqual(vm.editingPreset?.bands.count, 10)
    }

    func testRemoveEditingBandDropsRow() async {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        await vm.addEditingBand()
        await vm.addEditingBand()
        await vm.removeEditingBand(at: 0)
        XCTAssertEqual(vm.editingPreset?.bands.count, 1)
    }

    func testSaveEditPersistsAndClearsOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-7)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await vm.saveEdit()
        let snap = await override.snapshot()
        XCTAssertNil(snap)
        let onDisk = try await eqStore.loadText(name: "alpha")
        XCTAssertTrue(onDisk.contains("Preamp: -7 dB"))
        XCTAssertNil(vm.editingPreset)
    }

    func testSaveAsCreatesNewFileAndSwitchesActivePreset() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-2)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await vm.saveEditAs(name: "alpha-copy")
        let names = await eqStore.list()
        XCTAssertEqual(names.sorted(), ["alpha", "alpha-copy"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha-copy")
    }

    func testSaveAsCollisionThrowsAndKeepsEditing() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await savePresetFile(eqStore, name: "beta")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        do {
            try await vm.saveEditAs(name: "beta")
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {}
        XCTAssertNotNil(vm.editingPreset)
        let snap = await override.snapshot()
        XCTAssertNotNil(snap)
    }

    func testRenameUpdatesProfilesAndStore() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        try await vm.renamePreset(from: "alpha", to: "alpha2")
        let names = await eqStore.list()
        XCTAssertEqual(names, ["alpha2"])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha2")
        XCTAssertEqual(vm.editingOriginalName, "alpha2")
    }

    func testRenameCollisionRollsBackProfileRefs() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await savePresetFile(eqStore, name: "beta")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        do {
            try await vm.renamePreset(from: "alpha", to: "beta")
            XCTFail("expected error")
        } catch EqPresetStoreError.alreadyExists {}
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.eqPresetName, "alpha")
    }

    func testCancelEditClearsStateAndOverride() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-10)
        try await Task.sleep(nanoseconds: 150_000_000)
        await vm.cancelEdit()
        XCTAssertNil(vm.editingPreset)
        XCTAssertFalse(vm.editingDirty)
        let snap = await override.snapshot()
        XCTAssertNil(snap)
    }

    func testPresetReferenceCountCountsDevicesUsingName() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        var initial = AppSettings.default
        initial.outputDeviceUID = "dev-A"
        initial.audioProfiles["dev-A"] = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "alpha"
        )
        initial.audioProfiles["dev-B"] = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "alpha"
        )
        initial.audioProfiles["dev-C"] = AudioProfile(
            hogModeEnabled: false, releaseHogOnPauseEnabled: false,
            volumeMode: .none, bitrate: 3,
            eqEnabled: true, eqPresetName: "beta"
        )
        let configStore = StubConfigStore(initial: initial)
        let vm = SettingsViewModel(
            configStore: configStore,
            deviceCatalog: StubAudioDeviceCatalog(initial: []),
            auth: StubKeychainAuth(),
            openLoginWindow: {},
            openApplicationData: {},
            eqPresetStore: eqStore,
            eqEditingOverride: override
        )
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        let n = await vm.presetReferenceCount(name: "alpha")
        XCTAssertEqual(n, 2)
        let m = await vm.presetReferenceCount(name: "beta")
        XCTAssertEqual(m, 1)
        let z = await vm.presetReferenceCount(name: "missing")
        XCTAssertEqual(z, 0)
    }

    func testDebounceCoalescesRapidEdits() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        for v in [-1.0, -2.0, -3.0, -4.0, -5.0] {
            await vm.setEditingPreamp(v)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let snap = await override.snapshot()
        XCTAssertEqual(snap?.preampDb, -5)
    }

    func testCancelPendingSwitchClearsPendingWithoutTouchingEditor() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-2)

        // Seed a pending switch directly so this task tests only cancel.
        vm._setPendingPresetSwitchForTesting(SettingsViewModel.PendingPresetSwitch(target: "beta"))
        XCTAssertNotNil(vm.pendingPresetSwitch)

        vm.cancelPendingSwitch()
        XCTAssertNil(vm.pendingPresetSwitch)
        XCTAssertNotNil(vm.editingPreset)
        XCTAssertEqual(vm.eqPresetName, "alpha")
    }

    func testRequestPresetSwitchEditorCleanReseedsToTarget() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        // beta has different bands so we can distinguish.
        try await eqStore.save(
            name: "beta",
            text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain -2 dB Q 0.7\nFilter 2: ON PK Fc 8000 Hz Gain 4 dB Q 1.4\n",
            overwrite: false
        )
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        XCTAssertEqual(vm.editingPreset?.bands.count, 1)
        XCTAssertFalse(vm.editingDirty)

        await vm.requestPresetSwitch(to: "beta")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPresetSwitch)
        XCTAssertEqual(vm.eqPresetName, "beta")
        XCTAssertEqual(vm.editingOriginalName, "beta")
        XCTAssertEqual(vm.editingPreset?.bands.count, 2)
        XCTAssertEqual(vm.editingPreset?.preampDb, -3)
        XCTAssertFalse(vm.editingDirty)
        let pushed = await override.snapshot()
        XCTAssertEqual(pushed?.bands.count, 2)
    }

    func testRequestPresetSwitchEditorClosedSetsPresetWithoutDialog() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()

        await vm.requestPresetSwitch(to: "beta")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.eqPresetName, "beta")
        XCTAssertNil(vm.editingPreset)
        XCTAssertNil(vm.pendingPresetSwitch)
    }

    func testRequestPresetSwitchSameTargetIsNoop() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-5)
        XCTAssertTrue(vm.editingDirty)

        await vm.requestPresetSwitch(to: "alpha")
        XCTAssertNil(vm.pendingPresetSwitch)
        XCTAssertTrue(vm.editingDirty)
        XCTAssertEqual(vm.editingPreset?.preampDb, -5)
    }

    func testRequestPresetSwitchEditorCleanToBypassClosesEditor() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        XCTAssertNotNil(vm.editingPreset)

        await vm.requestPresetSwitch(to: nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.eqPresetName)
        XCTAssertNil(vm.editingPreset)
        XCTAssertNil(vm.editingOriginalName)
        XCTAssertNil(vm.pendingPresetSwitch)
        let pushed = await override.snapshot()
        XCTAssertNil(pushed)
    }

    func testRequestPresetSwitchEditorDirtySetsPendingSwitch() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-7)
        XCTAssertTrue(vm.editingDirty)

        await vm.requestPresetSwitch(to: "beta")

        XCTAssertEqual(vm.pendingPresetSwitch, SettingsViewModel.PendingPresetSwitch(target: "beta"))
        XCTAssertEqual(vm.eqPresetName, "alpha")             // not committed yet
        XCTAssertEqual(vm.editingOriginalName, "alpha")
        XCTAssertEqual(vm.editingPreset?.preampDb, -7)       // edits intact
        XCTAssertTrue(vm.editingDirty)
    }

    func testRequestPresetSwitchWhilePendingActiveIsIgnored() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await eqStore.save(name: "beta", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
        try await eqStore.save(name: "gamma", text: "Preamp: 0 dB\nFilter 1: ON PK Fc 2000 Hz Gain 1 dB Q 1.0\n", overwrite: false)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-3)

        await vm.requestPresetSwitch(to: "beta")
        XCTAssertEqual(vm.pendingPresetSwitch?.target, "beta")

        await vm.requestPresetSwitch(to: "gamma")
        XCTAssertEqual(vm.pendingPresetSwitch?.target, "beta")  // unchanged
    }

    func testResolvePendingSwitchDiscardSwapsAndClearsPending() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await eqStore.save(name: "beta", text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.9\n", overwrite: false)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-9)
        await vm.requestPresetSwitch(to: "beta")
        XCTAssertNotNil(vm.pendingPresetSwitch)

        await vm.resolvePendingSwitchDiscard()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPresetSwitch)
        XCTAssertEqual(vm.eqPresetName, "beta")
        XCTAssertEqual(vm.editingOriginalName, "beta")
        XCTAssertEqual(vm.editingPreset?.preampDb, -3)
        XCTAssertFalse(vm.editingDirty)
    }

    func testResolvePendingSwitchSaveWritesOriginalThenSwaps() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        try await savePresetFile(eqStore, name: "alpha")
        try await eqStore.save(name: "beta", text: "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.9\n", overwrite: false)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await vm.refreshPresets()
        await vm.reloadParsedPreset()
        await vm.beginEditCurrent()
        await vm.setEditingPreamp(-8)
        await vm.requestPresetSwitch(to: "beta")

        try await vm.resolvePendingSwitchSave()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.pendingPresetSwitch)
        XCTAssertEqual(vm.eqPresetName, "beta")
        XCTAssertEqual(vm.editingOriginalName, "beta")
        XCTAssertEqual(vm.editingPreset?.preampDb, -3)

        // Original alpha was saved with the dirty preamp before switching.
        let alphaText = try await eqStore.loadText(name: "alpha")
        XCTAssertTrue(alphaText.contains("Preamp: -8") || alphaText.contains("Preamp: -8.0"))
    }

    func testResolvePendingSwitchSaveNewPresetIsNoop() async throws {
        let eqStore = LiveEqPresetStore(directory: tmpDir)
        let override = EqEditingOverride()
        let vm = makeVM(eqStore: eqStore, override: override)
        await vm.start()
        await vm.beginNewPreset()
        await vm.setEditingPreamp(-2)
        vm._setPendingPresetSwitchForTesting(SettingsViewModel.PendingPresetSwitch(target: "anything"))

        try await vm.resolvePendingSwitchSave()
        XCTAssertNotNil(vm.pendingPresetSwitch)
        XCTAssertNotNil(vm.editingPreset)
        XCTAssertTrue(vm.editingIsNew)
    }
}
