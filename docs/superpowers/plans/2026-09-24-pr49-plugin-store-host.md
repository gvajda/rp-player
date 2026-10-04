# PR 49 — Plugin store, host, config and binder wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make imported Audio Unit effects actually play. That needs a per-device `pluginEnabled` / `pluginId` on `AudioProfile`, a `PluginStore` for imported `.component` bundles, a `PluginHost` that registers and instantiates the chosen plugin and hands it to the bridge, and the filter binder inserting the bridge between EQ and crossfeed. There is no UI yet (PR 50).

**Architecture:**
- `PluginStore` (actor) owns `Application Support/RP Player/Plugins/<uuid>/<Name>.component` + `state.plist`. Its validation is a pure function, `PluginValidator`.
- `PluginHost` (`@MainActor`, `ObservableObject`):
  - It finds or registers the component. `AudioComponentRegister` is process-local.
  - It instantiates the AU with `AVAudioUnit` and restores `fullState`.
  - It hands the raw `AudioUnit` to the bridge through an injected `setUnit` closure, off the main thread.
- The binder builds the chain, writes `af` only when the chain string changes (so a plugin swap never rebuilds mpv's graph), and calls `select` only when the effective plugin id changes.

**Tech Stack:** Swift 6.2, AudioToolbox (`AudioComponentRegister`, `AudioComponentFindNext`, CFBundle), AVFAudio (`AVAudioUnit`, `AUAudioUnit.fullState`), Foundation, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md` (§3.3–§3.6, §4, §5, §8 PR 49)

## Global Constraints

- **Chain order:** EQ parts, then the plugin part, then the crossfeed part.
- **When the plugin part is present:** only when `profile.pluginEnabled && profile.pluginId != nil && pluginPart != nil`, where `pluginPart` is `PluginBridge.filterPart`, and nil when the bridge failed to load or its path contains `[`/`]`.
- **Switching plugins must not rebuild the graph.** The binder skips `setAudioFilterChain` when the new chain string equals the last one written.
- **Accepted component types:** `aufx` and `aumf` only. The first valid `AudioComponents` entry wins. A duplicate is a matching type + subtype + manufacturer.
- **Store layout:** `ConfigPaths.pluginsDirectory` = `applicationSupportRoot/Plugins`. Each plugin folder is named with a UUID string, holds the copied `<Name>.component` and an optional `state.plist` (binary plist of `fullState`). Anything not named as a UUID is ignored and can never be deleted by id.
- **`rpbridge_set_unit` is never called on the main thread.** It is reached through the injected `setUnit` closure, run in a detached task. The previous `AVAudioUnit` is kept alive until that call returns.
- **Plugin load / register / instantiate failures:** the bridge gets `nil` (passthrough), and `loadError` is set. A bundle-load failure adds the hint "Open the plugin once in Finder, or check that it is signed." Quarantine is never stripped.
- **`AudioProfile`:** `pluginEnabled: Bool = false` and `pluginId: String? = nil`, decoded with `decodeIfPresent`.
- **Profile write-back:** the volume/hog binder's write-back copies the existing profile and assigns only `hogModeEnabled`, `releaseHogOnPauseEnabled`, `volumeMode` and `bitrate`.
- **Comment policy:** no comments unless the WHY is non-obvious, and single `//` lines only.
- **Test command:** `swift test`. Baseline is **619**.
- **No CHANGELOG entry.** Nothing is user-visible until PR 50.
- Do not push, and do not merge to `main`.

## Review Focus

1. **A plugin swap rewrites `af`, and mpv rebuilds the graph** (an audible glitch, and it contradicts the spec's success criterion). Expected: only `select` runs. Task 4's swap test asserts that no new `setAudioFilterChain` call happens.
2. **A saved `pluginId` points at a deleted folder** (for example, the folder was removed outside the app). Expected: passthrough plus `loadError`, and no crash. Task 3's unknown-id test covers this.
3. **A config-supplied id escapes the plugins folder** (`../..`). Expected: rejected. Task 2's delete test covers this with a non-UUID id.
4. **A malformed or half-written import leaves a folder behind**, which then shows up in `list()`. Expected: nothing is copied on validation failure, and staging folders are invisible to `list()`. Task 2 tests this.
5. **An unsigned or quarantined plugin fails to load.** Expected: a readable error with the Finder/signing hint. Task 3's unregistered-bundle test (a bundle with no executable) asserts the hint.

---

## File Structure

- Modify: `Sources/RPPlayer/Config/AudioProfile.swift` (two fields + Codable)
- Modify: `Sources/RPPlayer/App/AppContainer.swift`, for:
  - the write-back helper
  - `buildAudioFilterChain` in place of `applyAudioFilterState`
  - chain dedupe and plugin select in `runAudioFilterBinder` and `_BinderState`
  - the store, bridge and host in `live()`
- Modify: `Sources/RPPlayer/Config/ConfigPaths.swift` (`pluginsDirectory`)
- Create: `Sources/RPPlayer/Config/PluginModels.swift` (`PluginComponent`, `ImportedPlugin`, `PluginStoreError`, FourCC and version helpers)
- Create: `Sources/RPPlayer/Config/PluginValidator.swift`
- Create: `Sources/RPPlayer/Config/PluginStore.swift`
- Create: `Sources/RPPlayer/Audio/PluginHost.swift`
- Tests:
  - Create: `Tests/RPPlayerTests/Config/AudioProfilePluginTests.swift`
  - Create: `Tests/RPPlayerTests/Config/PluginValidatorTests.swift`
  - Create: `Tests/RPPlayerTests/Config/PluginStoreTests.swift`
  - Create: `Tests/RPPlayerTests/Helpers/PluginFixtures.swift`
  - Create: `Tests/RPPlayerTests/Audio/PluginHostTests.swift`
  - Modify: `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`
- Docs: the spec, `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md`

---

### Task 1: `AudioProfile` plugin fields and write-back fix

**Files:**
- Modify: `Sources/RPPlayer/Config/AudioProfile.swift`
- Modify: `Sources/RPPlayer/App/AppContainer.swift` (the write-back at about line 629, inside the volume/hog binder)
- Create: `Tests/RPPlayerTests/Config/AudioProfilePluginTests.swift`

**Interfaces:**
- Produces:
  - `AudioProfile.pluginEnabled: Bool`
  - `AudioProfile.pluginId: String?`
  - `static func AppContainer.profileWritingDeviceSettings(_ settings: AppSettings, onto existing: AudioProfile?) -> AudioProfile`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

Run: `swift test --filter AudioProfilePluginTests`. Expected: a compile failure (`pluginEnabled` is undefined). That is the RED state.

If `AppSettings` names any of `hogModeEnabled`, `releaseHogOnPauseEnabled`, `volumeMode` or `bitrate` differently, use its real names. They are the four values the current write-back reads from `s`.

- [ ] **Step 2: Add the fields**

In `AudioProfile`:
- Add `public var pluginEnabled: Bool` and `public var pluginId: String?` after `crossfeedFeedDb`.
- Add the init parameters `pluginEnabled: Bool = false, pluginId: String? = nil` at the end, and assign them.
- Add the `CodingKeys` cases `pluginEnabled` and `pluginId` (before the legacy keys).
- In `init(from:)`, add:

```swift
        self.pluginEnabled = try c.decodeIfPresent(Bool.self, forKey: .pluginEnabled) ?? false
        self.pluginId = try c.decodeIfPresent(String.self, forKey: .pluginId)
```

- In `encode(to:)`, add:

```swift
        try c.encode(pluginEnabled, forKey: .pluginEnabled)
        try c.encodeIfPresent(pluginId, forKey: .pluginId)
```

- [ ] **Step 3: Replace the field-by-field write-back**

Add to `AppContainer`, next to the other `internal static` helpers such as `runAudioFilterBinder`:

```swift
    // Copies the profile so fields owned by other binders (EQ, crossfeed, plugin) survive a device-settings write.
    internal static func profileWritingDeviceSettings(_ settings: AppSettings, onto existing: AudioProfile?) -> AudioProfile {
        var profile = existing ?? .safeDefault
        profile.hogModeEnabled = settings.hogModeEnabled
        profile.releaseHogOnPauseEnabled = settings.releaseHogOnPauseEnabled
        profile.volumeMode = settings.volumeMode
        profile.bitrate = settings.bitrate
        return profile
    }
```

Replace the `s.audioProfiles[uid] = AudioProfile(…)` block (about lines 629–641, including the `let existing = …` line) with:

```swift
                        try? await store.update { s in
                            s.audioProfiles[uid] = AppContainer.profileWritingDeviceSettings(s, onto: s.audioProfiles[uid])
                        }
```

- [ ] **Step 4: Run and commit**

Run: `swift test --filter AudioProfilePluginTests`. Expected: 3/3 PASS.
Run: `swift test`. Expected: **622** tests, 0 failures. `testDebounceCoalescesRapidEdits` is a known pre-existing timing flake. If it alone fails, re-run once and report both runs.

```bash
git add Sources/RPPlayer/Config/AudioProfile.swift Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/Config/AudioProfilePluginTests.swift
git commit -m "feat(config): per-device pluginEnabled/pluginId; write-back keeps unowned fields

The volume/hog binder's profile write-back rebuilt AudioProfile field by
field, silently resetting any field it didn't list. It now copies the
existing profile and assigns only the four device settings it owns."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 2: Plugin models, validator and store

**Files:**
- Create: `Sources/RPPlayer/Config/PluginModels.swift`
- Create: `Sources/RPPlayer/Config/PluginValidator.swift`
- Create: `Sources/RPPlayer/Config/PluginStore.swift`
- Modify: `Sources/RPPlayer/Config/ConfigPaths.swift`
- Create: `Tests/RPPlayerTests/Helpers/PluginFixtures.swift`
- Create: `Tests/RPPlayerTests/Config/PluginValidatorTests.swift`
- Create: `Tests/RPPlayerTests/Config/PluginStoreTests.swift`

**Interfaces:**
- Produces (Tasks 3, 4 and PR 50 rely on these exact names):

```swift
public struct PluginComponent: Equatable, Sendable {
    public let type: OSType, subtype: OSType, manufacturer: OSType
    public let name: String              // "Console7Channel" from "Airwindows: Console7Channel"
    public let manufacturerName: String  // "Airwindows"; the manufacturer FourCC string when the name has no "Maker: " prefix
    public let version: UInt32
    public let factoryFunction: String
    public var componentDescription: AudioComponentDescription { get }
    public var versionString: String { get }  // "1.2.3" from 0x00010203
}
public struct ImportedPlugin: Equatable, Sendable, Identifiable {
    public let id: String                // folder UUID string
    public let bundleURL: URL            // …/Plugins/<id>/<Name>.component
    public let component: PluginComponent
}
public enum PluginStoreError: Error, Equatable, Sendable {
    case notAComponent, notAnEffect, wrongArchitecture, duplicate(name: String), notFound, ioFailure(String)
}
public enum PluginValidator {
    public static var hostArchitecture: Int { get }
    public static func validate(infoPlist: [String: Any], architectures: [Int], existing: [PluginComponent]) -> Result<PluginComponent, PluginStoreError>
}
public actor PluginStore {
    public init(directory: URL, logger: (any Logging)? = nil, architectures: @escaping @Sendable (URL) -> [Int] = PluginStore.bundleArchitectures)
    public static let bundleArchitectures: @Sendable (URL) -> [Int]
    public func list() -> [ImportedPlugin]
    public func plugin(id: String) -> ImportedPlugin?
    public func importComponent(from source: URL) throws -> ImportedPlugin
    public func delete(id: String) throws
    public func loadState(id: String) -> Data?
    public func saveState(id: String, _ data: Data) throws
}
extension ConfigPaths { public static var pluginsDirectory: URL }  // add inside the enum, not as an extension
```

- Also produces the test helper `PluginFixtures`:
  - `componentEntry(type:subtype:manufacturer:name:version:factory:) -> [String: Any]`
  - `makeComponent(in:named:entries:) throws -> URL`, which writes a plist-only `.component` bundle

- [ ] **Step 1: Test fixtures**

Create `Tests/RPPlayerTests/Helpers/PluginFixtures.swift`:

```swift
import Foundation

enum PluginFixtures {
    static func componentEntry(type: String = "aufx", subtype: String = "Cn7c", manufacturer: String = "Dthr",
                               name: String = "Airwindows: Console7Channel", version: Int = 0x0001_0203,
                               factory: String = "Console7ChannelFactory") -> [String: Any] {
        ["type": type, "subtype": subtype, "manufacturer": manufacturer, "name": name,
         "version": version, "factoryFunction": factory]
    }

    // Plist-only bundle: enough for validation/import; it has no executable, so it can never be registered.
    static func makeComponent(in dir: URL, named name: String = "Console7Channel",
                              entries: [[String: Any]]? = [componentEntry()]) throws -> URL {
        let bundle = dir.appendingPathComponent("\(name).component")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "com.example.\(name)", "CFBundlePackageType": "BNDL"]
        if let entries { plist["AudioComponents"] = entries }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}
```

- [ ] **Step 2: Write the failing validator tests**

Create `Tests/RPPlayerTests/Config/PluginValidatorTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class PluginValidatorTests: XCTestCase {
    private let host = [PluginValidator.hostArchitecture]

    private func validate(_ entries: [[String: Any]]?, architectures: [Int]? = nil,
                          existing: [PluginComponent] = []) -> Result<PluginComponent, PluginStoreError> {
        var plist: [String: Any] = [:]
        if let entries { plist["AudioComponents"] = entries }
        return PluginValidator.validate(infoPlist: plist, architectures: architectures ?? host, existing: existing)
    }

    func testValidEffectParsesNameManufacturerAndVersion() throws {
        let c = try validate([PluginFixtures.componentEntry()]).get()
        XCTAssertEqual(c.name, "Console7Channel")
        XCTAssertEqual(c.manufacturerName, "Airwindows")
        XCTAssertEqual(c.versionString, "1.2.3")
        XCTAssertEqual(c.factoryFunction, "Console7ChannelFactory")
        XCTAssertEqual(c.componentDescription.componentType, kAudioUnitType_Effect)
        XCTAssertEqual(c.componentDescription.componentSubType, 0x436E_3763) // "Cn7c"
        XCTAssertEqual(c.componentDescription.componentManufacturer, 0x4474_6872) // "Dthr"
    }

    func testMusicEffectAcceptedAndFirstValidEntryWins() throws {
        let c = try validate([
            ["type": "aufx"],  // incomplete entry is skipped
            PluginFixtures.componentEntry(type: "aumf", name: "NoPrefixName"),
            PluginFixtures.componentEntry(subtype: "Othr"),
        ]).get()
        XCTAssertEqual(c.componentDescription.componentType, kAudioUnitType_MusicEffect)
        XCTAssertEqual(c.name, "NoPrefixName")
        XCTAssertEqual(c.manufacturerName, "Dthr")
    }

    func testMissingAudioComponentsIsNotAComponent() {
        XCTAssertEqual(validate(nil), .failure(.notAComponent))
        XCTAssertEqual(validate([]), .failure(.notAComponent))
    }

    func testInstrumentIsNotAnEffect() {
        XCTAssertEqual(validate([PluginFixtures.componentEntry(type: "aumu")]), .failure(.notAnEffect))
    }

    func testMissingHostSliceIsWrongArchitecture() {
        let other = PluginValidator.hostArchitecture == NSBundleExecutableArchitectureARM64
            ? NSBundleExecutableArchitectureX86_64 : NSBundleExecutableArchitectureARM64
        XCTAssertEqual(validate([PluginFixtures.componentEntry()], architectures: [other]), .failure(.wrongArchitecture))
    }

    func testSameDescriptionAsImportedPluginIsDuplicate() throws {
        let existing = try validate([PluginFixtures.componentEntry(name: "Airwindows: Old Name")]).get()
        XCTAssertEqual(validate([PluginFixtures.componentEntry()], existing: [existing]),
                       .failure(.duplicate(name: "Old Name")))
    }
}
```

Run: `swift test --filter PluginValidatorTests`. Expected: a compile failure (RED).

- [ ] **Step 3: Implement the models and validator**

Create `Sources/RPPlayer/Config/PluginModels.swift`:

```swift
import AudioToolbox
import Foundation

public struct PluginComponent: Equatable, Sendable {
    public let type: OSType
    public let subtype: OSType
    public let manufacturer: OSType
    public let name: String
    public let manufacturerName: String
    public let version: UInt32
    public let factoryFunction: String

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    public var versionString: String { "\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)" }

    func sameDescription(as other: PluginComponent) -> Bool {
        type == other.type && subtype == other.subtype && manufacturer == other.manufacturer
    }
}

public struct ImportedPlugin: Equatable, Sendable, Identifiable {
    public let id: String
    public let bundleURL: URL
    public let component: PluginComponent
}

public enum PluginStoreError: Error, Equatable, Sendable {
    case notAComponent
    case notAnEffect
    case wrongArchitecture
    case duplicate(name: String)
    case notFound
    case ioFailure(String)
}

enum FourCC {
    static func code(_ s: String) -> OSType? {
        let bytes = Array(s.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }

    static func string(_ code: OSType) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
    }
}
```

Create `Sources/RPPlayer/Config/PluginValidator.swift`:

```swift
import AudioToolbox
import Foundation

public enum PluginValidator {
    public static var hostArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    private static let effectTypes: Set<OSType> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]

    public static func validate(infoPlist: [String: Any], architectures: [Int],
                                existing: [PluginComponent]) -> Result<PluginComponent, PluginStoreError> {
        guard let entries = infoPlist["AudioComponents"] as? [[String: Any]], !entries.isEmpty else {
            return .failure(.notAComponent)
        }
        let parsed = entries.compactMap(parse)
        guard !parsed.isEmpty else { return .failure(.notAComponent) }
        guard let component = parsed.first(where: { effectTypes.contains($0.type) }) else {
            return .failure(.notAnEffect)
        }
        guard architectures.contains(hostArchitecture) else { return .failure(.wrongArchitecture) }
        if let clash = existing.first(where: { $0.sameDescription(as: component) }) {
            return .failure(.duplicate(name: clash.name))
        }
        return .success(component)
    }

    private static func parse(_ entry: [String: Any]) -> PluginComponent? {
        guard let type = (entry["type"] as? String).flatMap(FourCC.code),
              let subtype = (entry["subtype"] as? String).flatMap(FourCC.code),
              let manufacturer = (entry["manufacturer"] as? String).flatMap(FourCC.code),
              let fullName = entry["name"] as? String,
              let factory = entry["factoryFunction"] as? String else { return nil }
        let version = (entry["version"] as? NSNumber)?.uint32Value ?? 0
        let parts = fullName.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let (maker, name) = parts.count == 2 ? (parts[0], parts[1]) : (FourCC.string(manufacturer), fullName)
        return PluginComponent(type: type, subtype: subtype, manufacturer: manufacturer, name: name,
                               manufacturerName: maker, version: version, factoryFunction: factory)
    }
}
```

Run: `swift test --filter PluginValidatorTests`. Expected: 6/6 PASS.

- [ ] **Step 4: Write the failing store tests**

Create `Tests/RPPlayerTests/Config/PluginStoreTests.swift`:

```swift
import XCTest
@testable import RPPlayer

final class PluginStoreTests: XCTestCase {
    private var root: URL!
    private var sources: URL!
    private var store: PluginStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-store-\(UUID().uuidString)")
        sources = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImportCopiesBundleAndListsIt() async throws {
        let source = try PluginFixtures.makeComponent(in: sources)
        let imported = try await store.importComponent(from: source)

        XCTAssertNotNil(UUID(uuidString: imported.id))
        XCTAssertEqual(imported.bundleURL.lastPathComponent, "Console7Channel.component")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.bundleURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(imported.component.name, "Console7Channel")
        let listed = await store.list()
        XCTAssertEqual(listed, [imported])
        let lookedUp = await store.plugin(id: imported.id)
        XCTAssertEqual(lookedUp, imported)
    }

    func testRejectedImportCopiesNothing() async throws {
        let notEffect = try PluginFixtures.makeComponent(in: sources, named: "Synth",
                                                         entries: [PluginFixtures.componentEntry(type: "aumu")])
        do {
            _ = try await store.importComponent(from: notEffect)
            XCTFail("expected notAnEffect")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .notAnEffect)
        }
        let first = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        let again = try PluginFixtures.makeComponent(in: sources.appendingPathComponent("v2"))
        do {
            _ = try await store.importComponent(from: again)
            XCTFail("expected duplicate")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .duplicate(name: "Console7Channel"))
        }
        let listed = await store.list()
        XCTAssertEqual(listed, [first])
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Plugins").path)
        XCTAssertEqual(folders, [first.id], "a rejected import left something behind")
    }

    func testDeleteRemovesFolderAndRejectsNonUuidIds() async throws {
        let imported = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        try await store.delete(id: imported.id)
        let listed = await store.list()
        XCTAssertEqual(listed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.bundleURL.deletingLastPathComponent().path))
        do {
            try await store.delete(id: "../sources")
            XCTFail("expected notFound")
        } catch let error as PluginStoreError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.path))
    }

    func testStateRoundTrip() async throws {
        let imported = try await store.importComponent(from: try PluginFixtures.makeComponent(in: sources))
        let noState = await store.loadState(id: imported.id)
        XCTAssertNil(noState)
        let data = try PropertyListSerialization.data(fromPropertyList: ["gain": 3.5], format: .binary, options: 0)
        try await store.saveState(id: imported.id, data)
        let loaded = await store.loadState(id: imported.id)
        XCTAssertEqual(loaded, data)
    }
}
```

Run: `swift test --filter PluginStoreTests`. Expected: a compile failure (RED).

- [ ] **Step 5: Implement the store and path**

In `ConfigPaths`, add after `eqPresetsDirectory`:

```swift
    public static var pluginsDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Plugins", isDirectory: true)
    }
```

Create `Sources/RPPlayer/Config/PluginStore.swift`:

```swift
import Foundation

public actor PluginStore {
    public static let bundleArchitectures: @Sendable (URL) -> [Int] = { url in
        Bundle(url: url)?.executableArchitectures?.map(\.intValue) ?? []
    }

    public let directory: URL
    private let fm = FileManager.default
    private let logger: (any Logging)?
    private let architectures: @Sendable (URL) -> [Int]

    public init(directory: URL, logger: (any Logging)? = nil,
                architectures: @escaping @Sendable (URL) -> [Int] = PluginStore.bundleArchitectures) {
        self.directory = directory
        self.logger = logger
        self.architectures = architectures
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger?.error("PluginStore: failed to create \(directory.path): \(error)")
        }
    }

    public func list() -> [ImportedPlugin] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { plugin(id: $0) }
            .sorted { $0.component.name.localizedCaseInsensitiveCompare($1.component.name) == .orderedAscending }
    }

    public func plugin(id: String) -> ImportedPlugin? {
        guard let folder = folder(for: id),
              let bundleName = (try? fm.contentsOfDirectory(atPath: folder.path))?.first(where: { $0.hasSuffix(".component") }) else {
            return nil
        }
        let bundleURL = folder.appendingPathComponent(bundleName)
        guard case .success(let component) = PluginValidator.validate(
            infoPlist: Self.infoPlist(of: bundleURL), architectures: [PluginValidator.hostArchitecture], existing: []) else {
            return nil
        }
        return ImportedPlugin(id: id, bundleURL: bundleURL, component: component)
    }

    public func importComponent(from source: URL) throws -> ImportedPlugin {
        let component = try PluginValidator.validate(
            infoPlist: Self.infoPlist(of: source), architectures: architectures(source),
            existing: list().map(\.component)).get()
        let id = UUID().uuidString
        // Staging names are not UUIDs, so list() never shows a half-copied import.
        let staging = directory.appendingPathComponent(".staging-\(id)")
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
            try fm.moveItem(at: staging, to: directory.appendingPathComponent(id))
        } catch {
            try? fm.removeItem(at: staging)
            logger?.error("PluginStore: import of \(source.path) failed: \(error)")
            throw PluginStoreError.ioFailure("\(error)")
        }
        logger?.info("PluginStore: imported \(component.manufacturerName): \(component.name) as \(id)")
        return ImportedPlugin(id: id, bundleURL: directory.appendingPathComponent(id).appendingPathComponent(source.lastPathComponent),
                              component: component)
    }

    public func delete(id: String) throws {
        guard let folder = folder(for: id) else { throw PluginStoreError.notFound }
        do {
            try fm.removeItem(at: folder)
        } catch {
            throw PluginStoreError.ioFailure("\(error)")
        }
    }

    public func loadState(id: String) -> Data? {
        guard let folder = folder(for: id) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("state.plist"))
    }

    public func saveState(id: String, _ data: Data) throws {
        guard let folder = folder(for: id) else { throw PluginStoreError.notFound }
        do {
            try data.write(to: folder.appendingPathComponent("state.plist"), options: .atomic)
        } catch {
            throw PluginStoreError.ioFailure("\(error)")
        }
    }

    // Ids come from config; only UUID-named folders that exist are reachable, so "../x" can't escape the directory.
    private func folder(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let url = directory.appendingPathComponent(id, isDirectory: true)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private static func infoPlist(of bundle: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }
}
```

Run: `swift test --filter 'PluginStoreTests|PluginValidatorTests'`. Expected: 10/10 PASS.

- [ ] **Step 6: Full suite and commit**

Run: `swift test`. Expected: **632** tests, 0 failures.

```bash
git add Sources/RPPlayer/Config/PluginModels.swift Sources/RPPlayer/Config/PluginValidator.swift Sources/RPPlayer/Config/PluginStore.swift Sources/RPPlayer/Config/ConfigPaths.swift Tests/RPPlayerTests/Helpers/PluginFixtures.swift Tests/RPPlayerTests/Config/PluginValidatorTests.swift Tests/RPPlayerTests/Config/PluginStoreTests.swift
git commit -m "feat(plugins): PluginStore with pure import validation

Imports .component bundles into Application Support/RP Player/Plugins/
<uuid>/ via a staging folder (never visible to list()). Validation
accepts aufx/aumf only, first valid AudioComponents entry wins,
requires the host architecture slice, rejects duplicate descriptions.
Ids must be UUIDs, so config can't reach outside the folder. State is
stored as a binary plist next to the bundle."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 3: `PluginHost`

**Files:**
- Create: `Sources/RPPlayer/Audio/PluginHost.swift`
- Create: `Tests/RPPlayerTests/Audio/PluginHostTests.swift`

**Interfaces:**
- Consumes (Task 2): `PluginStore`, `ImportedPlugin`, `PluginComponent.componentDescription`, `PluginFixtures`.
- Produces (Task 4 and PR 50):

```swift
@MainActor public final class PluginHost: ObservableObject {
    @Published public private(set) var current: ImportedPlugin?
    @Published public private(set) var loadError: String?
    public private(set) var audioUnit: AVAudioUnit?
    public init(store: PluginStore, setUnit: @escaping @Sendable (AudioUnit?) -> Void, logger: (any Logging)? = nil)
    public func select(_ id: String?) async
    public func saveCurrentState() async
}
```

**Registration rule:** if `AudioComponentFindNext` already finds the description, the host does not register it again. This covers two cases: a description registered earlier in this process, and one that is also installed system-wide. This is what lets the tests use Apple's built-in AUHipass through an imported plist-only bundle.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RPPlayerTests/Audio/PluginHostTests.swift`:

```swift
import AudioToolbox
import AVFAudio
import XCTest
@testable import RPPlayer

@MainActor
final class PluginHostTests: XCTestCase {
    private final class UnitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var units: [AudioUnit?] = []
        func record(_ unit: AudioUnit?) { lock.withLock { units.append(unit) } }
        var calls: [AudioUnit?] { lock.withLock { units } }
    }

    private var root: URL!
    private var store: PluginStore!
    private var recorder: UnitRecorder!
    private var host: PluginHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-host-\(UUID().uuidString)")
        store = PluginStore(directory: root.appendingPathComponent("Plugins"),
                            architectures: { _ in [PluginValidator.hostArchitecture] })
        recorder = UnitRecorder()
        let recorder = recorder!
        host = PluginHost(store: store, setUnit: { recorder.record($0) })
    }

    override func tearDown() async throws {
        await host.select(nil)
        try? FileManager.default.removeItem(at: root)
    }

    // A plist-only bundle declaring Apple's AUHipass: FindNext finds the system unit, so no registration is needed.
    private func importAppleHipass() async throws -> ImportedPlugin {
        let src = root.appendingPathComponent("src")
        let bundle = try PluginFixtures.makeComponent(in: src, named: "Hipass", entries: [
            PluginFixtures.componentEntry(type: "aufx", subtype: "hpas", manufacturer: "appl",
                                          name: "Apple: AUHipass", factory: "unused"),
        ])
        return try await store.importComponent(from: bundle)
    }

    private func cutoff() -> AudioUnitParameterValue {
        var value: AudioUnitParameterValue = 0
        XCTAssertEqual(AudioUnitGetParameter(host.audioUnit!.audioUnit, kHipassParam_CutoffFrequency,
                                             kAudioUnitScope_Global, 0, &value), noErr)
        return value
    }

    func testSelectLoadsUnitHandsItToBridgeAndRestoresSavedState() async throws {
        let plugin = try await importAppleHipass()
        await host.select(plugin.id)
        XCTAssertEqual(host.current, plugin)
        XCTAssertNil(host.loadError)
        let unit = try XCTUnwrap(host.audioUnit?.audioUnit)
        XCTAssertEqual(recorder.calls.last!, unit)

        XCTAssertEqual(AudioUnitSetParameter(unit, kHipassParam_CutoffFrequency, kAudioUnitScope_Global, 0, 1234, 0), noErr)
        await host.saveCurrentState()
        await host.select(nil)
        await host.select(plugin.id)
        XCTAssertEqual(cutoff(), 1234, accuracy: 0.5)
    }

    func testSelectNilClearsBridgeAndCurrent() async throws {
        let plugin = try await importAppleHipass()
        await host.select(plugin.id)
        await host.select(nil)
        XCTAssertNil(host.current)
        XCTAssertNil(host.audioUnit)
        XCTAssertNil(recorder.calls.last!)
    }

    func testUnknownIdSetsLoadErrorAndPassesThrough() async {
        await host.select("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertNil(host.current)
        XCTAssertNotNil(host.loadError)
        XCTAssertNil(recorder.calls.last!)
    }

    func testUnloadableBundleReportsSigningHint() async throws {
        let src = root.appendingPathComponent("src")
        let bundle = try PluginFixtures.makeComponent(in: src, named: "Ghost", entries: [
            PluginFixtures.componentEntry(subtype: "Zzzz", manufacturer: "Zzzz", name: "Ghost: Nothing", factory: "GhostFactory"),
        ])
        let plugin = try await store.importComponent(from: bundle)
        await host.select(plugin.id)
        XCTAssertNil(host.current)
        XCTAssertTrue(host.loadError?.contains("Open the plugin once in Finder, or check that it is signed.") ?? false,
                      host.loadError ?? "no error")
        XCTAssertNil(recorder.calls.last!)
    }
}
```

Run: `swift test --filter PluginHostTests`. Expected: a compile failure (RED).

`kHipassParam_CutoffFrequency` comes from AudioToolbox (`AudioUnitParameters.h`). If the Swift overlay doesn't expose it, use the literal `0` with a `// kHipassParam_CutoffFrequency` comment.

- [ ] **Step 2: Implement the host**

Create `Sources/RPPlayer/Audio/PluginHost.swift`:

```swift
import AudioToolbox
import AVFAudio
import Foundation

@MainActor
public final class PluginHost: ObservableObject {
    @Published public private(set) var current: ImportedPlugin?
    @Published public private(set) var loadError: String?
    public private(set) var audioUnit: AVAudioUnit?

    private let store: PluginStore
    private let setUnit: @Sendable (AudioUnit?) -> Void
    private let logger: (any Logging)?

    public init(store: PluginStore, setUnit: @escaping @Sendable (AudioUnit?) -> Void, logger: (any Logging)? = nil) {
        self.store = store
        self.setUnit = setUnit
        self.logger = logger
    }

    public func select(_ id: String?) async {
        let previous = audioUnit
        audioUnit = nil
        current = nil
        loadError = nil
        if let id {
            do {
                let (plugin, unit) = try await load(id: id)
                audioUnit = unit
                current = plugin
                logger?.info("plugin host: loaded \(plugin.component.manufacturerName): \(plugin.component.name)")
            } catch {
                loadError = Self.message(for: error)
                logger?.error("plugin host: loading \(id) failed: \(error)")
            }
        }
        let handoff = UnitHandoff(unit: audioUnit?.audioUnit)
        let setUnit = self.setUnit
        // rpbridge_set_unit can wait on a lazy AudioUnitInitialize inside run(); never block the main thread on it.
        await Task.detached { setUnit(handoff.unit) }.value
        withExtendedLifetime(previous) {}
    }

    public func saveCurrentState() async {
        guard let current, let state = audioUnit?.auAudioUnit.fullState else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            try await store.saveState(id: current.id, data)
        } catch {
            logger?.error("plugin host: saving state for \(current.id) failed: \(error)")
        }
    }

    private func load(id: String) async throws -> (ImportedPlugin, AVAudioUnit) {
        guard let plugin = await store.plugin(id: id) else { throw PluginHostError.notFound }
        var desc = plugin.component.componentDescription
        if AudioComponentFindNext(nil, &desc) == nil {
            try register(plugin)
        }
        let unit = try await AVAudioUnit.instantiate(with: desc, options: [])
        if let data = await store.loadState(id: id),
           let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.auAudioUnit.fullState = state
        }
        return (plugin, unit)
    }

    // Process-local registration: invisible to other apps, cannot be undone, and the bundle stays loaded.
    private func register(_ plugin: ImportedPlugin) throws {
        guard let bundle = CFBundleCreate(nil, plugin.bundleURL as CFURL) else {
            throw PluginHostError.bundleLoadFailed("the bundle could not be opened")
        }
        var cfError: Unmanaged<CFError>?
        guard CFBundleLoadExecutableAndReturnError(bundle, &cfError) else {
            throw PluginHostError.bundleLoadFailed(cfError?.takeRetainedValue().localizedDescription ?? "unknown error")
        }
        guard let pointer = CFBundleGetFunctionPointerForName(bundle, plugin.component.factoryFunction as CFString) else {
            throw PluginHostError.factoryMissing(plugin.component.factoryFunction)
        }
        let factory = unsafeBitCast(pointer, to: AudioComponentFactoryFunction.self)
        var desc = plugin.component.componentDescription
        let name = "\(plugin.component.manufacturerName): \(plugin.component.name)" as CFString
        guard AudioComponentRegister(&desc, name, plugin.component.version, factory) != nil else {
            throw PluginHostError.registrationFailed
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case PluginHostError.notFound:
            return "The selected plugin is no longer installed."
        case PluginHostError.bundleLoadFailed(let reason):
            return "The plugin could not be loaded (\(reason)). Open the plugin once in Finder, or check that it is signed."
        case PluginHostError.factoryMissing, PluginHostError.registrationFailed:
            return "The plugin is not a usable Audio Unit."
        default:
            return "The plugin could not be started (\(error.localizedDescription))."
        }
    }
}

enum PluginHostError: Error {
    case notFound
    case bundleLoadFailed(String)
    case factoryMissing(String)
    case registrationFailed
}

private struct UnitHandoff: @unchecked Sendable {
    let unit: AudioUnit?
}
```

Swift 6 notes:
- If `AVAudioUnit.instantiate(with:options:) async` triggers a Sendable diagnostic (because `AVAudioUnit` is returned across isolation), wrap the completion-handler variant in `withCheckedThrowingContinuation` and pass the unit out through `UnitHandoff`-style `@unchecked Sendable` boxing.
- Keep the behaviour identical.

Run: `swift test --filter PluginHostTests`. Expected: 4/4 PASS.

- [ ] **Step 3: Full suite and commit**

Run: `swift test`. Expected: **636** tests, 0 failures.

```bash
git add Sources/RPPlayer/Audio/PluginHost.swift Tests/RPPlayerTests/Audio/PluginHostTests.swift
git commit -m "feat(plugins): PluginHost registers, instantiates and hands units to the bridge

Finds or process-locally registers the imported component, instantiates
it in-process with AVAudioUnit, restores saved fullState, and passes the
raw AudioUnit to the bridge off the main thread (rpbridge_set_unit can
wait on a lazy configure). Failures leave the bridge in passthrough and
publish loadError, with a Finder/signing hint when the bundle won't load."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

---

### Task 4: Binder wiring, composition root, docs

**Files:**
- Modify: `Sources/RPPlayer/App/AppContainer.swift`, specifically:
  - `runAudioFilterBinder` and `applyAudioFilterState`, at about lines 710–780
  - `_BinderState`, at about line 871
  - `live()`: the store, bridge and host setup near `eqPresetStore` (about line 162), and the binder spawn (about line 353)
- Modify: `Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift`
- Modify: the spec, `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md` and `CLAUDE.md`

**Interfaces:**
- Consumes:
  - `PluginBridge` (PR 48): `defaultPath()`, `load(path:logger:)`, `filterPart`, `setUnit`
  - `PluginStore` (Task 2) and `ConfigPaths.pluginsDirectory`
  - `PluginHost` (Task 3): `select(_:)`
- Produces the new binder signature (existing call sites keep compiling through the defaults):

```swift
internal static func runAudioFilterBinder(
    store: any ConfigStore, engine: any PlayerEngine, eqPresetStore: any EqPresetStore,
    override: EqEditingOverride, initialProfile: AudioProfile,
    pluginPart: String? = nil,
    selectPlugin: (@Sendable (String?) async -> Void)? = nil
) async
internal static func buildAudioFilterChain(
    store: any EqPresetStore, profile: AudioProfile, override: EqPreset?, pluginPart: String?
) async -> String?
```

- [ ] **Step 1: Write the failing binder tests**

Append these to `AppContainerAudioFilterBinderTests`, reusing the file's existing setup style (`StubConfigStore`, `MockPlayerEngine`, `EqEditingOverride`, `waitUntil`, `tmpDir`). Read the existing tests first. Only `@MainActor` isolation and helper names matter, and they must match.

```swift
    private final class SelectRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String?] = []
        func record(_ id: String?) { lock.withLock { ids.append(id) } }
        var calls: [String?] { lock.withLock { ids } }
    }

    private static let part = "ladspa=file=/x/libRPBridge.dylib:p=rpbridge"
    private static let idA = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private static let idB = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"

    private func chains(_ engine: MockPlayerEngine) async -> [String?] {
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

        try await waitUntil({ await !self.chains(engine).isEmpty }, timeout: 1.0)
        let chain = try XCTUnwrap(await chains(engine).last ?? nil)
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
        try await waitUntil({ await !self.chains(engine1).isEmpty }, timeout: 1.0)
        XCTAssertEqual(await chains(engine1), [nil])
        try await waitUntil({ recorder1.calls == [nil] }, timeout: 1.0)

        var noBridge = AudioProfile.safeDefault
        noBridge.pluginEnabled = true
        noBridge.pluginId = Self.idA
        let (_, engine2, _, task2) = startBinder(profile: noBridge, pluginPart: nil)
        defer { task2.cancel() }
        try await waitUntil({ await !self.chains(engine2).isEmpty }, timeout: 1.0)
        XCTAssertEqual(await chains(engine2), [nil])
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
        XCTAssertEqual(await chains(engine), ["lavfi=[\(Self.part)]"], "a plugin swap must not rewrite af")
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
        try await waitUntil({ await self.chains(engine) == ["lavfi=[\(Self.part)]", nil] }, timeout: 1.0)
    }
```

If `waitUntil` returns a `Bool` rather than throwing on timeout, wrap each call as `XCTAssertTrue(try await waitUntil(…))` (see `Tests/RPPlayerTests/Helpers/WaitUntil.swift`). If `recordedCalls()` or the `.setAudioFilterChain` case look different in `MockPlayerEngine`, follow its real shape. The assertions must stay the same.

Run: `swift test --filter AppContainerAudioFilterBinderTests`. Expected: a compile failure (the new parameters don't exist yet). That is RED.

- [ ] **Step 2: Implement the binder changes**

1. Rename `applyAudioFilterState(engine:store:profile:override:)` to `buildAudioFilterChain(store:profile:override:pluginPart:) async -> String?`. It keeps the same EQ logic, then adds the plugin part, then crossfeed, and returns the chain instead of writing it:

```swift
        if profile.pluginEnabled, profile.pluginId != nil, let pluginPart {
            parts.append(pluginPart)
        }
        if profile.crossfeedEnabled { /* existing crossfeed append, unchanged */ }
        return parts.isEmpty ? nil : "lavfi=[" + parts.joined(separator: ",") + "]"
```

2. In `_BinderState`, add:

```swift
    private var lastChain: String??
    private var lastPlugin: String??
    // Same af string twice would make mpv rebuild the graph; a plugin swap must only change the bridge's unit.
    func recordChain(_ chain: String?) -> Bool {
        if lastChain == .some(chain) { return false }
        lastChain = .some(chain)
        return true
    }
    func recordPlugin(_ id: String?) -> Bool {
        if lastPlugin == .some(id) { return false }
        lastPlugin = .some(id)
        return true
    }
```

3. In `runAudioFilterBinder`:
   - Add the two new parameters, with `nil` defaults.
   - Replace the three `applyAudioFilterState` calls with calls to one local helper:

```swift
        @Sendable func apply(_ p: AudioProfile, _ o: EqPreset?) async {
            let chain = await buildAudioFilterChain(store: eqPresetStore, profile: p, override: o, pluginPart: pluginPart)
            if await state.recordChain(chain) {
                try? await engine.setAudioFilterChain(chain)
            }
            if let selectPlugin, await state.recordPlugin(p.pluginEnabled ? p.pluginId : nil) {
                await selectPlugin(p.pluginEnabled ? p.pluginId : nil)
            }
        }
```

   - Adjust capture and `Sendable` annotations as the compiler requires. The two task-group children call `apply`.

4. Run: `swift test --filter AppContainerAudioFilterBinderTests`. Expected: all pass, both the existing tests and the 4 new ones.

   The existing tests must pass unchanged. The chain dedupe removes only identical consecutive writes, and none of them expects one. If an existing test fails, report it rather than editing the test.

- [ ] **Step 3: Wire the composition root**

In `AppContainer.live()`, after `let eqEditingOverride = EqEditingOverride()`:

```swift
        let pluginLogger = AppLogger.fileBacked(category: "plugins", directory: ConfigPaths.logsDirectory)
        let pluginStore = PluginStore(directory: ConfigPaths.pluginsDirectory, logger: pluginLogger)
        let pluginBridge = PluginBridge.defaultPath().flatMap { PluginBridge.load(path: $0, logger: pluginLogger) }
        if pluginBridge == nil {
            pluginLogger.error("plugin bridge unavailable; Audio Unit plugins disabled")
        } else if pluginBridge?.filterPart == nil {
            pluginLogger.error("plugin bridge path contains [ or ]; Audio Unit plugins disabled")
        }
        let pluginHost = PluginHost(store: pluginStore, setUnit: { pluginBridge?.setUnit($0) }, logger: pluginLogger)
```

In the binder spawn, add `pluginHost` to the capture list and pass:

```swift
                    pluginPart: pluginBridge?.filterPart,
                    selectPlugin: { id in await pluginHost.select(id) }
```

If `AppLogger.fileBacked` has a different signature, mirror the `eqLogger` line. If `setVerbose` is applied to the other loggers in the settings loop, apply it to `pluginLogger` the same way.

Run: `swift build`. Expected: success, with no new warnings.

- [ ] **Step 4: Amend the spec to match what was built**

In `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md`:

- **§3.3 API:**
  - `importComponent(from:)` replaces `import(from:)`, since `import` is a keyword.
  - Add `plugin(id:)`.
  - `loadState(id:) -> Data?` and `saveState(id:_:)` take `Data` (a binary plist). The host converts `fullState` with `PropertyListSerialization`.
  - Errors are one enum, `PluginStoreError` (`notAComponent`, `notAnEffect`, `wrongArchitecture`, `duplicate(name:)`, `notFound`, `ioFailure`).
  - The architecture reader is injected (`architectures: (URL) -> [Int]`).
  - Folder ids must parse as UUIDs.
  - Imports copy through a non-UUID staging folder, so `list()` never sees a partial copy.
- **§3.4:**
  - Replace the "Keep a description → registered map" sentence with: "Skip registration when `AudioComponentFindNext` already finds the description (registered earlier in this process, or installed system-wide)."
  - `setUnit` is an injected `@Sendable (AudioUnit?) -> Void` (the app passes `pluginBridge?.setUnit`), run in a detached task. The previous `AVAudioUnit` is released on the main actor after that call returns. Releasing it doesn't touch the bridge mutex, so it can't block.
  - Add `saveCurrentState()`, which the editor (PR 50) calls.
- **§3.6:**
  - The binder builds the chain (`buildAudioFilterChain`) and writes `af` only when the string differs from the last write, so a plugin swap only calls `select`.
  - The binder takes `pluginPart` and a `selectPlugin` closure, which keeps it testable without a host.

- [ ] **Step 5: `docs/architecture.md`, `docs/pr-history.md`, `docs/test-counts.md`, `CLAUDE.md`**

Add this bullet to the `## Audio pipeline` list, after the PR 48 bridge bullet:

```markdown
- **Plugin store + host (PR 49).** Imported AUs live in `Application Support/RP Player/Plugins/<uuid>/` (`PluginStore`; ids must parse as UUIDs so a config value can't reach outside; imports copy via a non-UUID `.staging-*` folder that `list()` ignores). `PluginHost` (`@MainActor`) skips `AudioComponentRegister` when `AudioComponentFindNext` already finds the description — covers re-selection in-process (registrations can't be undone) and system-installed duplicates — otherwise loads the bundle with CFBundle, resolves `factoryFunction`, registers process-locally, instantiates in-process via `AVAudioUnit`, restores `fullState` (binary plist `state.plist`), and hands the raw `AudioUnit` to the bridge through an injected `setUnit` closure in a detached task (the bridge mutex may be held by a lazy configure). The filter binder writes `af` only when the chain string changes — a plugin swap calls `select` and leaves mpv's graph alone; this dedupe also stopped rewriting identical chains on unrelated profile changes (e.g. bitrate). The volume/hog binder's profile write-back now copies the existing profile (`AppContainer.profileWritingDeviceSettings`) instead of rebuilding it field by field, which used to reset any field it didn't list.
```

In `docs/pr-history.md`, add after the PR 48 row. `<N>` is the exact final test count:

```markdown
| 49   | claude/pr47-au-plugins | ⏳ | Plugin store, host, config, binder: `AudioProfile.pluginEnabled`/`pluginId` (Codable defaults); write-back copies the existing profile (`profileWritingDeviceSettings`). `PluginValidator` (aufx/aumf, first valid AudioComponents entry, host arch slice, duplicate type/subtype/manufacturer) + `PluginStore` actor (`Plugins/<uuid>/`, staging-folder import, UUID-only ids, `state.plist` as Data). `PluginHost` (`@MainActor` ObservableObject: `current`, `loadError`, `audioUnit`; FindNext-before-register; CFBundle + `AudioComponentRegister`; `AVAudioUnit` in-process; `fullState` restore; `saveCurrentState`; `setUnit` off main; Finder/signing hint on bundle-load failure). Binder: `buildAudioFilterChain` (EQ → plugin → crossfeed), `af` write only on chain change, `selectPlugin` only on effective-id change; `live()` wires store + bridge + host. No UI yet. <N> tests. |
```

In `docs/test-counts.md`, append this line, adjusting it if the real count differs:

```markdown
- 2026-09-24: 619 → 640 (+21) — PR 49 plugin store/host/config/binder. `AudioProfilePluginTests`: legacy JSON decodes plugin disabled (1), round trip (1), device-settings write-back keeps filter/plugin fields (1). `PluginValidatorTests`: valid effect parses name/maker/version (1), aumf accepted + first valid entry wins (1), missing AudioComponents (1), instrument rejected (1), wrong arch (1), duplicate (1). `PluginStoreTests`: import + list (1), rejected import copies nothing (1), delete + non-UUID id rejected (1), state round trip (1). `PluginHostTests`: select loads, hands unit to bridge, restores state (1), select nil clears (1), unknown id → loadError (1), unloadable bundle → signing hint (1). `AppContainerAudioFilterBinderTests`: plugin part between EQ and crossfeed (1), no part without id or bridge (1), swap selects without rewriting af (1), disabling deselects and drops part (1).
```

In `CLAUDE.md`, in the **In progress** bullet, change `Done: PR 47 (libmpv \`ladspa\`), PR 48 (\`RPBridge\` dylib + \`PluginBridge\`).` to also list `PR 49 (store + host + binder)`, and change `Next:` to `PR 50 = Settings "Audio Unit" section + editor panel + README/CHANGELOG, cut v1.2.0.`

- [ ] **Step 6: Full suite and commit**

Run: `swift test`. Expected: **640** tests, 0 failures. Use the exact number in the docs.

```bash
git add Sources/RPPlayer/App/AppContainer.swift Tests/RPPlayerTests/App/AppContainerAudioFilterBinderTests.swift docs/superpowers/specs/2026-09-23-au-plugin-support-design.md docs/architecture.md docs/pr-history.md docs/test-counts.md CLAUDE.md docs/superpowers/plans/2026-09-24-pr49-plugin-store-host.md
git commit -m "feat(plugins): binder inserts the bridge between EQ and crossfeed

buildAudioFilterChain adds the bridge part when the device profile has
a plugin enabled and selected and the bridge loaded. The binder writes
af only when the chain changes, so switching plugins only swaps the
bridge's unit (PluginHost.select) without rebuilding mpv's graph.
live() wires PluginStore, PluginBridge and PluginHost."
```

End the commit message with the trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
