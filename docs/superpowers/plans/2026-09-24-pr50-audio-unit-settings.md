# PR 50 — "Audio Unit" Settings section, plugin editor, v1.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users import, pick, enable, edit and delete an Audio Unit effect per output device from Settings, then ship the feature as v1.2.0.

**Architecture:**
- `AudioUnitSettingsModel` (`@MainActor` `ObservableObject`) is the section's view model. It mirrors the current device's `pluginEnabled`/`pluginId` from config, lists the store, and changes config. Selection only ever happens through config; the PR 49 binder calls `PluginHost.select`.
- `AudioUnitSection` is a SwiftUI view that sits in the device settings section between Equalizer and Crossfeed, the same order as the audio chain.
- `PluginEditorController` is an AppKit `NSPanel` that hosts the plugin's own view (`requestViewController`), or `AUGenericView` when the plugin has none. It closes the moment `host.current` changes, autosaves while open, and saves on close. The app also saves at quit.

**Tech Stack:** SwiftUI, AppKit (`NSPanel`, `NSOpenPanel`), CoreAudioKit (`AUGenericView`), AVFAudio, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md` (§3.7, §3.8, §6, §7, §8 PR 50)

## Global Constraints

- **Config is the only driver of selection.** The UI never calls `PluginHost.select`.
  - Import writes `pluginId = <new id>` and `pluginEnabled = true` on the current device's profile.
  - Delete first clears `pluginId` on every profile that references the plugin, then calls `store.delete(id:)`.
- **Section placement and labels:**
  - The section is titled "Audio Unit" and sits in `deviceSettingsSection` after `eqSection` and before `crossfeedSection`.
  - Toggle tooltip ends with "Bit-perfect is off while a plugin is active."
  - Dropdown rows read `Name — Manufacturer vX.Y.Z` (`component.versionString`). With nothing imported, the dropdown shows "No plugins imported".
- **Disabled states:**
  - No output device selected: the section is disabled, with the note "Select an output device to use Audio Unit plugins."
  - Bridge unavailable: the section is disabled, with the note "Audio Unit hosting is unavailable. See the log for details."
- **`host.loadError`** is shown as a secondary-colour line under the row.
- **Editor panel:**
  - It holds its own `AVAudioUnit` reference.
  - It closes synchronously on any change of `host.current`. The host has already saved the outgoing state.
  - It autosaves every 5 s while open, but only when `fullState` changed since the last save.
  - It saves on user close, and the app saves at quit through `coordinatorShutdown`.
- **Bundle picker:** `NSOpenPanel` restricted to `.component` bundles (`UTType(filenameExtension: "component")`). Packages are treated as files (`treatsFilePackagesAsDirectories = false`).
- **CHANGELOG is for end users:** plain language, the feature first, no internal symbols. This PR cuts **v1.2.0** (rename `## [Unreleased]` → `## [v1.2.0] - 2026-09-24`, and re-add an empty `## [Unreleased]` above it).
- **Comment policy:** no comments unless the WHY is non-obvious. Single `//` lines only.
- **Tests:** `swift test`. Baseline 644. Known flake: `testDebounceCoalescesRapidEdits`. If it alone fails, re-run once.
- Don't push. Don't merge to `main`.

## Review Focus

1. **A device switch or DAC unplug while the editor is open.** The host releases the previous unit right after publishing `current = nil`. Expected: the panel is already closed, with no dangling `AUGenericView`, and no crash. Task 2 closes the panel synchronously in the `$current` sink. The sink skips its first, replayed value and closes on the next change.
2. **Import while no device is selected.** Expected: the import button is disabled, so the profile is never written against a nil device. Task 1's model test covers the no-device path.
3. **Deleting a plugin that other devices use.** Expected: every referencing profile is cleared before the folder is removed. Task 1 has a test for this.
4. **Importing a non-effect, a duplicate or an Intel-only bundle.** Expected: a plain-language alert and nothing copied. Task 1 tests the message mapping.
5. **Quit with the editor open.** Expected: the edits are saved. Task 3 wires `saveCurrentState()` into `coordinatorShutdown`. Manual check.

---

## File Structure

- Create: `Sources/RPPlayer/Shell/AudioUnitSettingsModel.swift`
- Create: `Sources/RPPlayer/Shell/PluginEditorController.swift`
- Create: `Sources/RPPlayer/Shell/AudioUnitSection.swift`
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`, which gets the new `audioUnits` property and places the section
- Modify: `Sources/RPPlayer/Shell/SettingsWindowController.swift`, whose init takes the model
- Modify: `Sources/RPPlayer/App/AppContainer.swift`, for the `live()` wiring and the save at quit
- Create: `Tests/RPPlayerTests/Shell/AudioUnitSettingsModelTests.swift`
- Docs: `README.md`, `CHANGELOG.md`, the spec, `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md`

---

### Task 1: `AudioUnitSettingsModel`

**Files:**
- Create: `Sources/RPPlayer/Shell/AudioUnitSettingsModel.swift`
- Create: `Tests/RPPlayerTests/Shell/AudioUnitSettingsModelTests.swift`

**Interfaces:**
- Consumes:
  - `ConfigStore` (`settings`, `changes`, `update`)
  - `PluginStore` (`list`, `importComponent`, `delete`)
  - `PluginHost` (only passed through for the view)
  - `PluginStoreError`
  - Test helpers: `StubConfigStore` (Tests/RPPlayerTests/Shell/SettingsTestStubs.swift), `PluginFixtures`, `waitUntil`
- Produces (for Tasks 3 and 4):

```swift
@MainActor final class AudioUnitSettingsModel: ObservableObject {
    @Published private(set) var plugins: [ImportedPlugin]
    @Published private(set) var pluginEnabled: Bool
    @Published private(set) var pluginId: String?
    @Published private(set) var hasOutputDevice: Bool
    let isBridgeAvailable: Bool
    let host: PluginHost
    init(configStore: any ConfigStore, store: PluginStore, host: PluginHost, isBridgeAvailable: Bool, logger: (any Logging)? = nil)
    func start() async
    func stop()
    func refreshPlugins() async
    func setEnabled(_ value: Bool) async
    func setPluginId(_ id: String?) async
    func importComponent(from url: URL) async throws
    func deletePlugin(id: String) async throws
    static func message(for error: Error) -> String
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import RPPlayer

@MainActor
final class AudioUnitSettingsModelTests: XCTestCase {
    private var root: URL!
    private var store: PluginStore!
    private var config: StubConfigStore!
    private var model: AudioUnitSettingsModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("au-model-\(UUID().uuidString)")
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
        var settings = AppSettings.default
        settings.outputDeviceUID = "dev-A"
        config = StubConfigStore(initial: settings)
        let host = PluginHost(store: store, setUnit: { _ in })
        model = AudioUnitSettingsModel(configStore: config, store: store, host: host, isBridgeAvailable: true)
        await model.start()
    }

    override func tearDown() async throws {
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String = "Console7Channel", entries: [[String: Any]] = [PluginFixtures.componentEntry()]) throws -> URL {
        try PluginFixtures.makeComponent(in: root.appendingPathComponent("src-\(UUID().uuidString)"), named: name, entries: entries)
    }

    func testImportSelectsAndEnablesOnCurrentDevice() async throws {
        try await model.importComponent(from: try source())
        let profile = try XCTUnwrap(config.settings.audioProfiles["dev-A"])
        XCTAssertTrue(profile.pluginEnabled)
        XCTAssertEqual(profile.pluginId, model.plugins.first?.id)
        XCTAssertEqual(model.plugins.count, 1)
        try await waitUntil({ await MainActor.run { self.model.pluginEnabled && self.model.pluginId != nil } }, timeout: 1.0)
    }

    func testSettersWriteCurrentDeviceProfile() async throws {
        await model.setPluginId("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        await model.setEnabled(true)
        let profile = try XCTUnwrap(config.settings.audioProfiles["dev-A"])
        XCTAssertEqual(profile.pluginId, "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertTrue(profile.pluginEnabled)
    }

    func testNoDeviceWritesNothing() async throws {
        try await config.update { $0.outputDeviceUID = nil }
        try await waitUntil({ await MainActor.run { !self.model.hasOutputDevice } }, timeout: 1.0)
        await model.setEnabled(true)
        XCTAssertTrue(config.settings.audioProfiles.isEmpty)
    }

    func testDeleteClearsEveryReferenceThenRemovesPlugin() async throws {
        try await model.importComponent(from: try source())
        let id = try XCTUnwrap(model.plugins.first?.id)
        try await config.update {
            var other = AudioProfile.safeDefault
            other.pluginEnabled = true
            other.pluginId = id
            $0.audioProfiles["dev-B"] = other
        }
        try await model.deletePlugin(id: id)
        XCTAssertNil(config.settings.audioProfiles["dev-A"]?.pluginId)
        XCTAssertNil(config.settings.audioProfiles["dev-B"]?.pluginId)
        XCTAssertEqual(model.plugins, [])
        let remaining = await store.list()
        XCTAssertEqual(remaining, [])
    }

    func testImportErrorsHavePlainMessages() {
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.notAnEffect),
                       "This plugin is an instrument or generator. Only effect plugins can be used.")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.duplicate(name: "Console7")),
                       "\u{201C}Console7\u{201D} is already imported. Delete it first to import another copy.")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.wrongArchitecture),
                       "This plugin doesn't support this Mac's processor (it may be Intel-only).")
        XCTAssertEqual(AudioUnitSettingsModel.message(for: PluginStoreError.notAComponent),
                       "This isn't an Audio Unit plugin (.component).")
    }
}
```

`StubConfigStore` exposes `settings` synchronously. Check its real API in `SettingsTestStubs.swift`. If `settings` or `update` differ, adapt the calls, not the assertions.

Run: `swift test --filter AudioUnitSettingsModelTests`. Expected: compile failure (RED).

- [ ] **Step 2: Implement**

```swift
import Foundation

@MainActor
final class AudioUnitSettingsModel: ObservableObject {
    @Published private(set) var plugins: [ImportedPlugin] = []
    @Published private(set) var pluginEnabled = false
    @Published private(set) var pluginId: String?
    @Published private(set) var hasOutputDevice = false

    let isBridgeAvailable: Bool
    let host: PluginHost

    private let configStore: any ConfigStore
    private let store: PluginStore
    private let logger: (any Logging)?
    private var configTask: Task<Void, Never>?

    init(configStore: any ConfigStore, store: PluginStore, host: PluginHost, isBridgeAvailable: Bool,
         logger: (any Logging)? = nil) {
        self.configStore = configStore
        self.store = store
        self.host = host
        self.isBridgeAvailable = isBridgeAvailable
        self.logger = logger
    }

    func start() async {
        stop()
        apply(await configStore.settings)
        let stream = await configStore.changes
        configTask = Task { [weak self] in
            for await settings in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(settings)
            }
        }
        await refreshPlugins()
    }

    func stop() {
        configTask?.cancel()
        configTask = nil
    }

    func refreshPlugins() async {
        plugins = await store.list()
    }

    func setEnabled(_ value: Bool) async {
        await updateCurrentProfile { $0.pluginEnabled = value }
    }

    func setPluginId(_ id: String?) async {
        await updateCurrentProfile { $0.pluginId = id }
    }

    func importComponent(from url: URL) async throws {
        let imported = try await store.importComponent(from: url)
        await refreshPlugins()
        await updateCurrentProfile {
            $0.pluginId = imported.id
            $0.pluginEnabled = true
        }
    }

    // Config first: the binder deselects before the folder disappears, so nothing points at a deleted bundle.
    func deletePlugin(id: String) async throws {
        try await configStore.update { settings in
            for (uid, var profile) in settings.audioProfiles where profile.pluginId == id {
                profile.pluginId = nil
                settings.audioProfiles[uid] = profile
            }
        }
        try await store.delete(id: id)
        await refreshPlugins()
    }

    static func message(for error: Error) -> String {
        switch error {
        case PluginStoreError.notAComponent: return "This isn't an Audio Unit plugin (.component)."
        case PluginStoreError.notAnEffect: return "This plugin is an instrument or generator. Only effect plugins can be used."
        case PluginStoreError.wrongArchitecture: return "This plugin doesn't support this Mac's processor (it may be Intel-only)."
        case PluginStoreError.duplicate(let name): return "\u{201C}\(name)\u{201D} is already imported. Delete it first to import another copy."
        case PluginStoreError.notFound: return "The plugin is no longer installed."
        case PluginStoreError.ioFailure(let reason): return "The plugin couldn't be copied (\(reason))."
        default: return error.localizedDescription
        }
    }

    private func apply(_ settings: AppSettings) {
        let profile = settings.outputDeviceUID.flatMap { settings.audioProfiles[$0] }
        hasOutputDevice = settings.outputDeviceUID != nil
        pluginEnabled = profile?.pluginEnabled ?? false
        pluginId = profile?.pluginId
    }

    private func updateCurrentProfile(_ mutate: @escaping @Sendable (inout AudioProfile) -> Void) async {
        do {
            try await configStore.update { s in
                guard let uid = s.outputDeviceUID else { return }
                var p = s.audioProfiles[uid] ?? .safeDefault
                mutate(&p)
                s.audioProfiles[uid] = p
            }
        } catch {
            logger?.error("AudioUnitSettingsModel: config update failed: \(error)")
        }
    }
}
```

If `configStore.settings` is not `async`, drop the `await`. Mirror `SettingsViewModel`'s access pattern.

Run: `swift test --filter AudioUnitSettingsModelTests`. Expected: 5/5 PASS.

- [ ] **Step 3: Full suite and commit**

Run: `swift test`. Expected: **649**, 0 failures.

```bash
git add Sources/RPPlayer/Shell/AudioUnitSettingsModel.swift Tests/RPPlayerTests/Shell/AudioUnitSettingsModelTests.swift
git commit -m "feat(settings): AudioUnitSettingsModel drives plugin choice through config

Import selects and enables the new plugin on the current device; delete
clears every profile reference before removing the bundle; setters are
no-ops without an output device. Plain-language import error messages."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 2: `PluginEditorController`

**Files:**
- Create: `Sources/RPPlayer/Shell/PluginEditorController.swift`

**Interfaces:**
- Consumes: `PluginHost` (`current`, `$current`, `audioUnit`, `saveCurrentState()`).
- Produces:
  - `@MainActor final class PluginEditorController: NSObject, NSWindowDelegate`
  - `init(host: PluginHost)`
  - `func open()`
  - `func close()`

There are no unit tests. This is AppKit windowing around a live AU. It is verified by build, the app smoke in Task 4, and manual review.

- [ ] **Step 1: Implement**

```swift
import AppKit
import AVFAudio
import Combine
import CoreAudioKit

@MainActor
final class PluginEditorController: NSObject, NSWindowDelegate {
    private let host: PluginHost
    private var panel: NSPanel?
    private var unit: AVAudioUnit?
    private var currentSink: AnyCancellable?
    private var autosaveTimer: Timer?
    private var lastSavedState: Data?

    init(host: PluginHost) {
        self.host = host
        super.init()
    }

    func open() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let plugin = host.current, let unit = host.audioUnit else { return }
        self.unit = unit
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "\(plugin.component.manufacturerName) \(plugin.component.name)"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        // The host publishes current = nil before releasing the old unit; closing here keeps the view off a freed unit.
        currentSink = host.$current.dropFirst().sink { [weak self] _ in self?.close() }
        unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async { self?.install(controller) }
        }
        lastSavedState = stateData()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.close()
        teardown(save: true)
    }

    func windowWillClose(_ notification: Notification) {
        teardown(save: true)
    }

    private func install(_ controller: NSViewController?) {
        guard let panel, let unit else { return }
        if let controller {
            panel.contentViewController = controller
            if controller.preferredContentSize != .zero { panel.setContentSize(controller.preferredContentSize) }
        } else {
            let generic = AUGenericView(audioUnit: unit.audioUnit)
            generic.showsExpertParameters = true
            panel.contentView = generic
            panel.setContentSize(generic.frame.size)
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func autosave() {
        guard let data = stateData(), data != lastSavedState else { return }
        lastSavedState = data
        Task { await host.saveCurrentState() }
    }

    private func stateData() -> Data? {
        guard let state = unit?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func teardown(save: Bool) {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        currentSink = nil
        panel = nil
        unit = nil
        if save { Task { await host.saveCurrentState() } }
    }
}
```

Notes:
- After a host switch, `host.current` is already nil when `close()` runs, so `saveCurrentState()` is a no-op. The host saved the outgoing state itself. That is intended.
- If `AUGenericView(audioUnit:)` imports with a different label in Swift (for example `init(audioUnit:)` taking `AudioUnit` directly), use the real signature.
- `showsExpertParameters` is optional. Drop it if it isn't available.
- If `Timer`'s closure plus `MainActor.assumeIsolated` triggers a Swift 6 diagnostic, use `Task { @MainActor in self?.autosave() }` inside the timer closure instead.

Run: `swift build`. Expected: success, no new warnings.

- [ ] **Step 2: Commit**

```bash
git add Sources/RPPlayer/Shell/PluginEditorController.swift
git commit -m "feat(settings): plugin editor panel (plugin view or AUGenericView)

Floating panel hosting the plugin's own view, or CoreAudioKit's generic
parameter view when it has none. Holds its own AVAudioUnit reference,
closes as soon as the host switches plugins, autosaves every 5 s when
state changed, and saves on close."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 3: `AudioUnitSection`, Settings and app wiring

**Files:**
- Create: `Sources/RPPlayer/Shell/AudioUnitSection.swift`
- Modify: `Sources/RPPlayer/Shell/SettingsView.swift`
- Modify: `Sources/RPPlayer/Shell/SettingsWindowController.swift`
- Modify: `Sources/RPPlayer/App/AppContainer.swift`

**Interfaces:**
- Consumes:
  - `AudioUnitSettingsModel` (Task 1)
  - `PluginEditorController` (Task 2)
  - `PluginHost` (`current`, `loadError`)
  - `HoverInfoIcon(text:)`
- Produces:
  - `struct AudioUnitSection: View` with `init(model: AudioUnitSettingsModel, editor: PluginEditorController)`
  - `SettingsView(viewModel:audioUnits:pluginEditor:)`
  - `SettingsWindowController(viewModel:audioUnits:pluginEditor:)`

- [ ] **Step 1: The section view**

Create `Sources/RPPlayer/Shell/AudioUnitSection.swift`:

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudioUnitSection: View {
    @ObservedObject var model: AudioUnitSettingsModel
    @ObservedObject var host: PluginHost
    let editor: PluginEditorController
    @State private var importError: String?
    @State private var deleteTarget: ImportedPlugin?

    init(model: AudioUnitSettingsModel, editor: PluginEditorController) {
        self.model = model
        self.host = model.host
        self.editor = editor
    }

    private var usable: Bool { model.isBridgeAvailable && model.hasOutputDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Audio Unit")
                HoverInfoIcon(text: tooltip)
                Spacer(minLength: 8)
                if model.pluginEnabled && usable {
                    picker
                    Button { editor.open() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .disabled(host.current == nil)
                        .help("Open the plugin's controls")
                    Button { showImportPanel() } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .help("Import an Audio Unit (.component)")
                    Button { deleteTarget = model.plugins.first { $0.id == model.pluginId } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(model.pluginId == nil)
                        .help("Delete the selected plugin")
                }
                Toggle("", isOn: Binding(get: { model.pluginEnabled && usable },
                                         set: { v in Task { await model.setEnabled(v) } }))
                    .labelsHidden()
                    .disabled(!usable)
            }
            if let note = disabledNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else if model.pluginEnabled, let error = host.loadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await model.start() }
        .alert("Couldn't import plugin", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(item: $deleteTarget) { plugin in
            Alert(title: Text("Delete \u{201C}\(plugin.component.name)\u{201D}?"),
                  message: Text("Every output device using it will play without a plugin."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task {
                          do { try await model.deletePlugin(id: plugin.id) }
                          catch { importError = AudioUnitSettingsModel.message(for: error) }
                      }
                  },
                  secondaryButton: .cancel())
        }
    }

    private var picker: some View {
        Picker("", selection: Binding<String?>(get: { model.pluginId },
                                               set: { id in Task { await model.setPluginId(id) } })) {
            if model.plugins.isEmpty {
                Text("No plugins imported").tag(String?.none)
            } else {
                Text("None").tag(String?.none)
                ForEach(model.plugins) { plugin in
                    Text("\(plugin.component.name) — \(plugin.component.manufacturerName) v\(plugin.component.versionString)")
                        .tag(Optional(plugin.id))
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }

    private var disabledNote: String? {
        if !model.isBridgeAvailable { return "Audio Unit hosting is unavailable. See the log for details." }
        if !model.hasOutputDevice { return "Select an output device to use Audio Unit plugins." }
        return nil
    }

    private var tooltip: String {
        """
        Runs one Audio Unit effect (an AUv2 .component) on playback, after the equalizer and before crossfeed.

        Imported plugins are copied into RP Player's own folder and aren't visible to other apps. Self-contained plugins (for example Airwindows) work best; plugins that need iLok or a vendor installer may not load. A plugin that crashes will close RP Player.

        Bit-perfect is off while a plugin is active.
        """
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "component") ?? .bundle]
        panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Audio/Plug-Ins/Components")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.importComponent(from: url) }
            catch { importError = AudioUnitSettingsModel.message(for: error) }
        }
    }
}
```

If `ImportedPlugin` is not `Identifiable` in a way that `.alert(item:)` accepts, it already conforms to `Identifiable` (PR 49), so this works as written.

- [ ] **Step 2: Settings view and window**

In `SettingsView`:
- Add `@ObservedObject var audioUnits: AudioUnitSettingsModel` and `let pluginEditor: PluginEditorController` below `viewModel`.
- In `deviceSettingsSection`, insert `AudioUnitSection(model: audioUnits, editor: pluginEditor)` between `eqSection` and `crossfeedSection`.

In `SettingsWindowController.init`, add the parameters `audioUnits: AudioUnitSettingsModel, pluginEditor: PluginEditorController` and pass them to `SettingsView(viewModel:audioUnits:pluginEditor:)`.

- [ ] **Step 3: App wiring and save at quit**

In `AppContainer.live()`, after `pluginHost` is created (PR 49):

```swift
        let audioUnitSettings = AudioUnitSettingsModel(
            configStore: store ?? NoopConfigStore(), store: pluginStore, host: pluginHost,
            isBridgeAvailable: pluginBridge?.filterPart != nil, logger: pluginLogger)
        let pluginEditor = PluginEditorController(host: pluginHost)
```

- Pass both to `SettingsWindowController(viewModel: settingsViewModel, audioUnits: audioUnitSettings, pluginEditor: pluginEditor)`.
- Change the `coordinatorShutdown` closure to save plugin state first:

```swift
            coordinatorShutdown: { await pluginHost.saveCurrentState(); await coordinator.shutdown(); await hogController.release() },
```

- If `pluginHost` or `pluginStore` are declared inside a narrower scope than these uses, move their declarations up so they are in scope. Keep their behaviour identical.

Run: `swift build`. Expected: success, no new warnings.
Run: `swift test`. Expected: **649**, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPPlayer/Shell/AudioUnitSection.swift Sources/RPPlayer/Shell/SettingsView.swift Sources/RPPlayer/Shell/SettingsWindowController.swift Sources/RPPlayer/App/AppContainer.swift
git commit -m "feat(settings): Audio Unit section in output device settings

Toggle, plugin dropdown, edit/import/delete between Equalizer and
Crossfeed. Disabled with a note when no output device is selected or
the bridge is unavailable; shows the host's load error. Plugin state
is saved at quit."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 4: README, CHANGELOG v1.2.0, docs, app smoke

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: the spec, `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md`

- [ ] **Step 1: README**

1. In `## Features` → `### Audio`, add a bullet after the **Crossfeed** bullet:

```markdown
- **Audio Unit plugins** (per device):
  - Run one Audio Unit effect (AUv2 `.component`) on playback — for example an Airwindows console or tape plugin. Settings → Audio Unit → import the `.component`, pick it, and open its controls with the sliders button.
  - Imported plugins are copied into RP Player's own folder and stay invisible to other apps. Settings are remembered per plugin.
  - Self-contained plugins work best. Plugins that depend on iLok or a vendor installer may fail to load, and a plugin that crashes takes RP Player down with it. Re-importing an updated version of a plugin takes effect after relaunching RP Player.
  - Signal order is **EQ → Audio Unit → Crossfeed**. Bit-perfect output is off while a plugin is active.
```

2. In that same Audio section, change the Crossfeed bullet's "Filter chain order is locked at **Preamp → EQ → Crossfeed**" to "Filter chain order is locked at **Preamp → EQ → Audio Unit → Crossfeed**".
3. In `### Files on disk`, add a bullet after `SongFileCache/`:

```markdown
- `Plugins/` — imported Audio Unit plugins, one folder per plugin holding the copied `.component` and its saved settings (`state.plist`). Deleting a plugin in Settings removes its folder.
```

4. In the per-device audio settings bullet, change "(hog mode, release-on-pause, volume mode, bitrate)" to "(hog mode, release-on-pause, volume mode, bitrate, EQ, Audio Unit, crossfeed)".

- [ ] **Step 2: CHANGELOG (end users), cut v1.2.0**

Replace the line `## [Unreleased]` with:

```markdown
## [Unreleased]

## [v1.2.0] - 2026-09-24

### Added

- **Audio Unit plugins.** Run an Audio Unit effect on the stream, per output device: Settings → Audio Unit → import a `.component` file (for example an Airwindows plugin), pick it and turn it on. The sliders button opens the plugin's own controls (or a generic list of its parameters), and your settings are remembered. Plugins are copied into RP Player's own folder, so installing one here doesn't affect other apps. It sits between the equalizer and crossfeed, and bit-perfect playback is off while a plugin is active. Self-contained plugins work best — ones that need iLok or a vendor installer may not load.
```

The existing `## [v1.1.0] - 2026-09-06` section stays directly below. Verify with `scripts/extract-changelog.sh v1.2.0` that the new section is non-empty. Read the script first for its argument format. If it needs a second output-path argument, pass one under the scratchpad or `/tmp`.

- [ ] **Step 3: Spec, architecture, history, counts, CLAUDE.md**

- **Spec §3.8:** state that the editor autosaves every 5 s while open, only when `fullState` changed, rather than a 1 s debounce, and that the panel is a standalone floating `NSPanel` (`PluginEditorController`), not an inline view like `EqEditPanel`.
- **`docs/architecture.md`:** add one bullet after the PR 49 bullet:

```markdown
- **Plugin editor + settings (PR 50).** The Settings "Audio Unit" row (`AudioUnitSection` + `AudioUnitSettingsModel`) never calls `PluginHost.select`: import writes `pluginId` + `pluginEnabled` to the current device's profile, delete clears every referencing profile first and only then removes the folder — the binder does all selecting, so its dedupe record can't drift from the host. `PluginEditorController` is a floating `NSPanel` holding its own `AVAudioUnit` reference; it closes from a `host.$current` sink (skipping the replayed initial value) because the host publishes `current = nil` before releasing the old unit, and `AUGenericView` does not retain the raw `AudioUnit`. State saves: host on every switch, editor on close + 5 s autosave when `fullState` changed, app at quit via `coordinatorShutdown`.
```

- **`docs/pr-history.md`:** add after the PR 49 row, using the real count:

```markdown
| 50   | claude/pr47-au-plugins | ⏳ | Audio Unit Settings + editor, cut v1.2.0: `AudioUnitSettingsModel` (config-only selection — import selects + enables on current device, delete clears references then removes; no-op without device; plain-language import errors), `AudioUnitSection` between Equalizer and Crossfeed (toggle, dropdown `Name — Maker vX.Y.Z`, edit/import/delete, disabled notes for no device / bridge unavailable, host `loadError` line), `PluginEditorController` (`NSPanel`; plugin view via `requestViewController`, else `AUGenericView`; closes on `host.$current` change; 5 s autosave on change; save on close), plugin state saved at quit. README Audio Unit section + `Plugins/` on disk; CHANGELOG v1.2.0. 649 tests. |
```

- **`docs/test-counts.md`:** append:

```markdown
- 2026-09-24: 644 → 649 (+5) — PR 50 Audio Unit settings. `AudioUnitSettingsModelTests`: import selects + enables on current device (1), setters write current device profile (1), no device writes nothing (1), delete clears every reference then removes plugin (1), import errors have plain messages (1).
```

- **`CLAUDE.md` Current state:** replace the **In progress** bullet with:

```markdown
- **Ready for PR:** Audio Unit plugin support, PRs 47–50 on branch `claude/pr47-au-plugins` (spec `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md`); CHANGELOG cut as **v1.2.0**, which CI publishes when the branch merges to `main`. Open one GitHub PR for the branch.
```

Keep **Last merged** and **Released** unchanged, because nothing has merged yet.

- [ ] **Step 4: App smoke**

```bash
cd /Users/gergely/git/rp-player
./scripts/make-app.sh debug
/bin/ls "build/RP Player.app/Contents/Frameworks/libRPBridge.dylib"
codesign --verify --deep "build/RP Player.app" && echo "bundle signature OK"
```

Then launch the built app briefly and check the log for the bridge/host lines. Use `/usr/bin/log`, not zsh's `log` builtin:

```bash
open "build/RP Player.app"; sleep 5
grep -iE "plugin|bridge" ~/Library/Application\ Support/RP\ Player/Logs/RPPlayer.log | tail -5
osascript -e 'quit app "RP Player"'
```

Expected: no "plugin bridge unavailable" error line. Record what was seen.

If launching the app isn't possible non-interactively, say so in the report. Don't claim a UI check that didn't happen.

- [ ] **Step 5: Full suite and commit**

Run: `swift test`. Expected: **649**, 0 failures.

```bash
git add README.md CHANGELOG.md docs/superpowers/specs/2026-09-23-au-plugin-support-design.md docs/architecture.md docs/pr-history.md docs/test-counts.md CLAUDE.md docs/superpowers/plans/2026-09-24-pr50-audio-unit-settings.md
git commit -m "docs: Audio Unit plugins in README; CHANGELOG v1.2.0"
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
