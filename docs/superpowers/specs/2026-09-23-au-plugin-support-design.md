# Audio Unit plugin support — design

**Date:** 2026-09-23
**Status:** approved 2026-09-23
**Research:** `docs/notes/au-plugin-research-2026-09-23.md` (background, rejected alternatives, sources)
**PRs:** 47–50 (see §8)

## 1. Goal

Let a user insert one AUv2 effect plugin into the playback chain (between EQ and crossfeed), per output device. Users import `.component` bundles into the app's own folder, choose one from a dropdown, edit its parameters in the plugin's own window (or a generic one), and delete it. Settings and plugin state survive a relaunch.

**Success:** an imported Airwindows AU can be heard on the RP stream. Its parameters persist across relaunch. Switching plugins or editing parameters does not rebuild mpv's filter graph. With the plugin toggle off, the chain is exactly what it is today, so bit-perfect output is unaffected.

**Decided in brainstorming:**
- Plugins come from **app-folder import only**. System-installed AUs are not listed.
- Plugin settings are **per device**, like EQ and crossfeed. Parameter state belongs to the imported plugin and is shared across devices.
- Chain order is **EQ (incl. preamp) → Plugin → Crossfeed**. Most imported plugins are tone or dynamics effects that belong on the plain stereo mix, and crossfeed stays the final headphone step. FFmpeg inserts a lossless float repack between the bridge (planar float) and bs2b (packed) automatically.
- The Settings section is named **"Audio Unit"**.
- The app `dlopen`s the bridge at runtime. It does not link it (§3.1).

**Out of scope:** VST2/VST3, AUv3 app extensions, system-installed AUs, more than one plugin at a time, out-of-process loading and crash isolation, plugin latency compensation.

## 2. Signal path

```
libmpv decode → lavfi[ EQ… , ladspa=file=<escaped path>:p=rpbridge , bs2b… ] → coreaudio AO (hog)
                                              │
                                   libRPBridge.dylib run()
                                              │ AudioUnitRender
                                          imported AU
```

The `ladspa=` part is present **only** when `profile.pluginEnabled && profile.pluginId != nil && bridge loaded && bridge.filterPart != nil`. A permanently present bridge would force float conversion and lose bit-perfect output even with everything off. Turning the plugin on or off therefore rebuilds the graph, the same as toggling EQ. Switching plugins or editing parameters only changes what the bridge renders into, so the `af` string does not change.

## 3. Components

### 3.1 `RPBridge` — C dynamic library (new SwiftPM target + `.library(type: .dynamic)` product)

**Why the app does not link it:** in SwiftPM, a target that depends on another target in the same package links it statically. The executable would carry its own copy of the bridge's globals, and FFmpeg's `dlopen` would load a second image. The app instead `dlopen`s the bridge at the same absolute path that goes into the `file=` option. `dlopen` of an image that is already loaded returns that image, so the app and FFmpeg share one copy.

**Exports:**
- `ladspa_descriptor(index)` → one descriptor with label `rpbridge`, 2 audio input ports, 2 audio output ports, no control ports, and `Properties = LADSPA_PROPERTY_INPLACE_BROKEN`. Without it, FFmpeg 6.0's `af_ladspa` reuses the input frame as the output frame when it's writable and input/output port counts match (`out = in`), aliasing the bridge's input and output port buffers — that breaks the passthrough copy (self-memcpy) and the per-chunk render-error fallback (would output partially rendered audio). Setting it makes FFmpeg allocate a separate output frame, at negligible cost.
- `void rpbridge_set_unit(AudioUnit _Nullable unit)`.
- `uint64_t rpbridge_frames_processed(void)`: the total frames through `run()`, used by tests and diagnostics.

**State:** file-scope globals guarded by one `pthread_mutex_t`:
- the current `AudioUnit`
- the rate the unit is configured for
- the rate the unit last failed to configure at
- a monotonically increasing `Float64` sample-time counter
- a "needs `AudioUnitReset`" flag, set by `activate`
- a "render error already logged" flag
- a total-frames-processed counter, for tests and diagnostics

**Format ownership:** the bridge configures the AU, because only the bridge knows the rate FFmpeg negotiated. The rate is given to `instantiate`. Configuration runs lazily at the start of `run()` whenever the current unit is not yet configured for the instance's rate. That covers a new unit from `set_unit`, and a rate change. A rate whose configuration failed is not retried until the unit or the rate changes. `activate` only marks the unit for `AudioUnitReset` at the next `run()`.
1. `AudioUnitUninitialize`.
2. Set the stream format to Float32, non-interleaved, 2 channels at that rate, on input scope and output scope.
3. Set `kAudioUnitProperty_MaximumFramesPerSlice` to 4096.
4. Set `kAudioUnitProperty_SetRenderCallback` so that input is read from the current LADSPA input buffers.
5. `AudioUnitInitialize`.
6. `AudioUnitReset`.

If configuration fails, the bridge keeps the unit — it does not drop it — and records the failed rate, so `run()` passes audio through (no unit is configured for the instance's rate) without retrying configuration on every subsequent call. The failed rate is only cleared by a new `set_unit` or a further rate change; it logs the failure via `os_log`, under the app's `com.gvajda.RPPlayer` subsystem (see `AppLogger.subsystem`), category `bridge`.

**Lifecycle:** `instantiate`, `activate` and `cleanup` never create or destroy the AU. `activate` only marks the unit for reset; the next `run()` performs the `AudioUnitReset`, and any reconfiguration the rate needs.

**`run(n)`:**
1. Lock the mutex.
2. If there is no unit, copy input to output.
3. Otherwise, render in chunks of at most 4096 frames. For each chunk, point the render-callback context at the input slices, call `AudioUnitRender` into the output slices, and advance `mSampleTime`.
4. If a chunk fails to render, copy that chunk's input to its output. Log the first failure per unit via `os_log`.
5. Unlock.

The filter runs on mpv's filter thread, not the CoreAudio real-time thread, so holding a mutex there is acceptable.

**`set_unit`:**
1. Lock the mutex. This waits for any render in progress.
2. Swap the unit. The new unit's configuration happens lazily at the next `run()`.
3. Unlock.

Once `set_unit` returns, the caller can free the previous unit safely.

Because configuration also happens lazily inside `run()` under the same mutex, `rpbridge_set_unit` may block until an in-progress `run()` — including one that is in the middle of a lazy configure (`AudioUnitInitialize` of a third-party AU, which can take an arbitrary amount of time) — finishes. Callers must not call it from the main thread.

### 3.2 `PluginBridge` — Swift, `Sources/RPPlayer/Audio/`

- `static let fileName = "libRPBridge.dylib"`.
- `static func defaultPath(bundle: Bundle = .main) -> String?` finds the dylib path: `Contents/Frameworks/libRPBridge.dylib` in the app bundle, else next to the executable (dev builds, tests). Returns nil if neither exists.
- `static func load(path: String, logger: (any Logging)?) -> PluginBridge?` resolves symlinks, `dlopen`s that path, then `dlsym`s `rpbridge_set_unit`. If either fails, it logs and returns nil — the caller holds no `PluginBridge` instance, and the plugin feature stays inert. There is no `isAvailable` flag; absence of an instance is the signal.
- `let path: String` — the resolved path `load` opened, exposed so `filterPart` can use it.
- `func setUnit(_ unit: AudioUnit?)`.
- `var filterPart: String?` and the equivalent `static func filterPart(path:) -> String?` build `ladspa=file=<escaped>:p=rpbridge` (no surrounding quotes — mpv's `af` option value is not a quoted string). Escaping: lavfi unescapes the string twice, once while splitting the graph (where `[],;` are separators) and once while parsing filter options (where `:` is). So the path is backslash-escaped for `\':` and the result is escaped again for `\'[],;`. Paths containing `[` or `]` return `nil`, because mpv's `lavfi=[…]` bracket quoting has no escape.

### 3.3 `PluginStore` — actor, `Sources/RPPlayer/Config/`, shaped like `LiveEqPresetStore`

**Layout:** `~/Library/Application Support/RP Player/Plugins/<uuid>/<Name>.component` and `…/<uuid>/state.plist`.

**API:**
- `list() -> [ImportedPlugin]`, where `ImportedPlugin` has `id` (the folder uuid), `bundleURL`, and `component: PluginComponent`. `PluginComponent` carries `type`, `subtype`, `manufacturer` (the raw `OSType` four-char codes), `name`, `manufacturerName`, `version` (packed `UInt32`), `factoryFunction`, plus the derived `componentDescription: AudioComponentDescription` and `versionString: String` (`X.Y.Z`, unpacked from `version`).
- `plugin(id:) -> ImportedPlugin?`.
- `importComponent(from: URL) throws -> ImportedPlugin` (renamed from `import(from:)`, since `import` is a keyword).
- `delete(id:)`.
- `loadState(id:) -> Data?` and `saveState(id:_:)` take `Data` — a binary plist. The host converts `fullState` to/from `Data` with `PropertyListSerialization`, not the store.
- Errors are one enum, `PluginStoreError`: `notAComponent`, `notAnEffect`, `wrongArchitecture`, `duplicate(name:)`, `notFound`, `ioFailure`.

**Validation** is a pure function, `PluginValidator.validate(infoPlist:architectures:existing:)`. The store feeds it the bundle's Info.plist dictionary and an injected architecture reader, `architectures: (URL) -> [Int]` (not `Bundle.executableArchitectures` directly, so it's testable). It rejects a bundle with a typed error when:
- `.notAComponent`: there is no `AudioComponents` array, as in bundles that only support the legacy Component Manager.
- `.notAnEffect`: the type is not `aufx` or `aumf`.
- `.wrongArchitecture`: the executable has no slice for the host architecture. arm64 on Apple silicon, x86_64 on Intel.
- `.duplicate(name)`: an imported plugin already has the same type, subtype and manufacturer. `AudioComponentRegister` cannot be undone, so two registrations of the same description would be ambiguous. The user has to delete the old one first.

The first valid `AudioComponents` entry wins. A bundle that fails validation is never copied. Folder ids must parse as UUIDs, so a config value can't be used to reach outside the plugins directory.

**Copy:** copy into a temporary sibling folder, then rename it into place. The staging folder's name does not parse as a UUID, so `list()` ignores it — a partial copy is never seen as an imported plugin. A failed copy leaves nothing behind.

### 3.4 `PluginHost` — `@MainActor`, `Sources/RPPlayer/Audio/`

- `select(_ id: String?) async`. For a non-nil id:
  1. Look up the plugin in the store.
  2. Skip registration when `AudioComponentFindNext` already finds the description (registered earlier in this process, or installed system-wide). Otherwise load the `Bundle`, resolve `factoryFunction` with `CFBundleGetFunctionPointerForName`, and call `AudioComponentRegister`. Never unload the bundle.
  3. Call `AVAudioUnit.instantiate(with:options: [])`, which loads the plugin in-process.
  4. Restore the saved `fullState`, if there is one.
  5. Call `setUnit(avUnit.audioUnit)`.
  6. Release the previous unit.

  `select(nil)` calls `setUnit(nil)` and then releases the unit.

  `select` is serialized inside the host as a task chain (each call awaits the previous one before running): an overlapping select sees the true previous unit rather than a torn handoff, and the last request wins. `select` saves the outgoing plugin's `fullState` before releasing it, so config-driven switches (dropdown, device change, DAC unplug) never lose edits; the editor only needs `saveCurrentState()` on panel close and at app quit.

  `setUnit` is an injected `@escaping @Sendable (AudioUnit?) -> Void` (the app passes `pluginBridge?.setUnit`), not a direct call to `bridge.setUnit`, so the host doesn't depend on `PluginBridge` at compile time. Steps 5 and 6 do not run on the main actor. `rpbridge_set_unit` can block until an in-progress `run()` — possibly in the middle of a lazy `AudioUnitInitialize` of a third-party AU that takes an arbitrary amount of time, and could itself hop to the main queue and deadlock — finishes, so `select` hands the `setUnit` call to a `detached` `Task` and awaits it before returning. Only after that does it release the previous unit, back on the main actor; releasing it doesn't touch the bridge mutex, so it can't block. `AudioUnit` is a non-`Sendable` `OpaquePointer`; carry it across the actor boundary in a small `@unchecked Sendable` box, not by widening `PluginHost` itself off the main actor.
- Publishes `current: ImportedPlugin?` and `loadError: String?` for the UI.
- Exposes the current `AUAudioUnit` for the editor.
- On a load, instantiate or registration failure, the bridge stays at NULL and passes audio through, and `loadError` is set. When a failed load looks like a Gatekeeper or quarantine block, the error adds: "Open the plugin once in Finder, or check that it is signed." Quarantine is never stripped silently.
- `saveCurrentState() async`, which the editor (PR 50) calls to persist the current unit's `fullState` (converted to `Data` via `PropertyListSerialization`) through `store.saveState`.

### 3.5 Config: `AudioProfile`

- Add `pluginEnabled: Bool`, which defaults to false, and `pluginId: String?`, which defaults to nil. Add both to `CodingKeys`, decode them with `decodeIfPresent`, and encode them.
- **Targeted fix:** the volume/hog binder's profile write-back (`AppContainer.swift`, around line 629) rebuilds `AudioProfile(...)` field by field, so any newly added field silently resets to its default. Change it to `var p = existing` and assign only the four fields it owns. This fixes the plugin fields now and any fields added later.

### 3.6 Binder wiring

- The binder builds the chain with `buildAudioFilterChain(store:profile:override:pluginPart:)`, which appends `pluginPart` after the EQ parts and before the crossfeed part when `profile.pluginEnabled && profile.pluginId != nil && pluginPart != nil`. The chain then goes EQ → plugin → crossfeed.
- The binder takes `pluginPart: String?` and a `selectPlugin: (@Sendable (String?) async -> Void)?` closure rather than a `PluginBridge`/`PluginHost` directly, which keeps it testable without a host. `live()` passes `pluginBridge?.filterPart` and `{ id in await pluginHost.select(id) }`.
- It writes `af` only when the built chain string differs from the last write, so a plugin swap only calls `selectPlugin` — mpv's graph is untouched. `selectPlugin` itself is only invoked when the effective plugin id (`profile.pluginEnabled ? profile.pluginId : nil`) changes.

### 3.7 Settings: "Audio Unit" section, per device

The UI never calls `host.select` directly — only the binder (§3.6) does, driven by config. Every action below only ever writes config; the binder's existing subscription picks the change up and selects or deselects through the host.

- Toggle "Audio Unit plugin", with the tooltip "Bit-perfect is off while a plugin is active."
- Dropdown entries read `Name — Manufacturer vX.Y.Z`, using `ImportedPlugin.component.versionString`. With nothing imported, it shows "No plugins imported".
- **Import…** opens an `NSOpenPanel` limited to `.component`. The store validates and copies. On success, the view model writes `pluginId = <new id>` and `pluginEnabled = true` to the current device's profile — the binder picks up the change and selects it. On failure an alert shows the typed error in plain language; nothing is written to config.
- **Edit…** is enabled when a plugin is loaded, and opens the editor.
- **Delete** asks for confirmation, then: clear `pluginId` on every profile that references the id (the binder deselects on every device that had it active), then `store.delete(id:)`. If the delete call fails, show the error — config is already cleared at that point, so nothing points at the id any more regardless.
- The host's `loadError` appears as a secondary-colour line under the dropdown.
- With no output device selected (`outputDeviceUID == nil`), the whole section is disabled with a short note, the same way the per-device EQ/crossfeed setters no-op without a device (`guard let uid = s.outputDeviceUID else { return }` in `SettingsViewModel`).
- The section is also disabled with a note when the Audio Unit bridge is unavailable, via an `isPluginBridgeAvailable: Bool` flag `live()` passes into the view model (true only when `PluginBridge.load` succeeded).

### 3.8 Editor: `PluginEditorPanel`, an `NSPanel` following the `EqEditPanel` pattern

- The view comes from `auAudioUnit.requestViewController`. If that returns nil, the panel uses CoreAudioKit's **`AUGenericView(audioUnit:)`**, the built-in generic parameter UI for AUv2. No custom slider list is written.
- State is saved from `fullState` every 5 s while the panel is open, only when `fullState` changed since the last save, saved again on close, and saved at app quit. Config-driven switches (dropdown, device change, DAC unplug) are handled by the host itself (§3.4) — the panel does not need to save before them.
- **Amendment (PR 50):** implemented as a standalone floating `NSPanel` (`PluginEditorController`), not an inline view like `EqEditPanel`. Quit-time save is a synchronous main-actor snapshot taken in `AppDelegate.applicationWillTerminate` (`AppContainer.preparePluginQuitSave()` → `PluginHost.stateSnapshot()`) before the main thread blocks on shutdown; the actual write happens through the `PluginStore` actor inside the detached shutdown task, not in `coordinatorShutdown` — awaiting the `@MainActor` host there deadlocked against the blocking wait.
- The panel holds its own `AVAudioUnit` reference (`AUGenericView` doesn't retain the raw unit) and closes synchronously when `host.current` changes: `PluginHost`'s `$current` publish happens at the start of `perform`, before the previous unit is released, so the panel is guaranteed to close before its unit goes away.
- Re-importing an updated version of a plugin whose old registration is still process-local (its old id was deleted earlier in the session) keeps running the stale registered code until relaunch, because `AudioComponentRegister` can't be undone — documented as a README limitation rather than surfaced as an in-app note after import.

## 4. Error handling summary

| Failure | Result |
|---|---|
| Bridge dylib missing or `dlsym` fails | Feature inert; `ladspa=` never added; logged |
| Bridge path contains `[` or `]` | Feature inert (`filterPart` nil); `ladspa=` never added; logged |
| Import validation fails | Alert; nothing copied |
| Register or instantiate fails | Passthrough; `loadError` shown; logged |
| Bridge cannot configure the unit (format/initialize rejected at the negotiated rate) | Passthrough; `os_log` (bridge); not retried until the unit or rate changes — no synchronous error channel, so no `loadError` |
| `AudioUnitRender` error | Passthrough for that chunk; logged once per unit via `os_log` |
| Plugin crashes | App crashes (accepted; no out-of-process loading for process-local registrations) |
| Plugin id in config no longer exists | Treated as a load failure: passthrough plus `loadError` |

## 5. Testing

- **`AudioProfile` codec:** old JSON decodes with `pluginEnabled=false` and `pluginId=nil`. Round-trip. Add to the existing migration-test style.
- **Write-back:** the volume/hog write-back preserves `plugin*` and `crossfeed*`.
- **Chain builder** (`AppContainerAudioFilterBinderTests`): the plugin part sits after EQ and before crossfeed (with each of EQ and crossfeed on and off). It is omitted when the plugin is disabled, when there is no id, and when the bridge is unavailable. A path with a space and a `'` is escaped correctly.
- **Validator:** pure-function cases for not a component, not an effect, wrong architecture, duplicate, and valid `aufx` and `aumf`.
- **Store:** import, list, delete and state round-trip in a temp directory, with a fixture bundle that contains only a plist. The architecture check is injected.
- **Bridge** (dlopen the built dylib and drive the LADSPA descriptor directly):
  - A NULL unit gives output identical to the input.
  - With Apple's `AUHipass` (`kAudioUnitSubType_HighPassFilter`), a DC input decays to about 0.
  - A 10,000-frame `run` is chunked correctly.
  - Re-activating at a new rate reconfigures the unit.
  - The descriptor sets `LADSPA_PROPERTY_INPLACE_BROKEN`.
- `swift test` builds every product, including `libRPBridge.dylib` next to the `.xctest` bundle (verified 2026-09-24), so tests `dlopen` the fresh dylib. The test target imports `RPBridge` for the C types only. It links a static copy, so every function has to come from `dlsym` on the dylib handle.
- mpv end-to-end (`RPBridgeMpvIntegrationTests`): plays a generated WAV through `lavfi=[ladspa=…]`, with the bridge copied to a path containing spaces, `'`, `:`, `,` and `;`, and asserts that the bridge's frame counter moved. This replaces the planned RPSmoke check, because it runs in CI without the network.
- **Manual:** import an Airwindows AU, hear it, edit it, relaunch, and confirm that the state and selection persist. Delete it and confirm that the profile is cleared.

## 6. Risks and limitations

These are carried over from the research note, §7:
- A plugin crash takes the app down.
- Plugins that need iLok, a vendor daemon or support files may fail after a bare copy. Self-contained plugins work best.
- Gatekeeper may block quarantined or unsigned bundles. The user gets a hint, and quarantine is not stripped.
- Bit-perfect output is lost while a plugin is enabled.
- `AudioComponentRegister` cannot be undone. A plugin deleted during a session stays registered until the app relaunches, which is harmless.

## 7. Documentation

- **CHANGELOG** (end users): in PR 50 only — "Use an Audio Unit effect plugin on playback", plus the self-contained-plugin caveat.
- **`docs/architecture.md`:**
  - the LADSPA bridge
  - why the app `dlopen`s the bridge instead of linking it
  - why the bridge owns the AU format
  - why `ladspa=` appears only when enabled
- **README:** the Audio Unit section and its limitations.
- **`Vendor/libmpv/README.md`:** `--enable-ladspa`.

## 8. PR split

1. **PR 47 — libmpv with LADSPA.**
   - Add `--enable-ladspa` in the fork's `audio-encodersgpl` FFmpeg variant, with the `ladspaH` header.
   - Re-vendor, rewrite install names, re-sign and regenerate `SHA256SUMS`.
   - `LibmpvLinkageTests` asserts that the `ladspa` filter exists.
   - Update `Vendor/libmpv/README.md`.
   - No user-visible change.
2. **PR 48 — `RPBridge` dylib and `PluginBridge`.**
   - The C target with passthrough, AU render and format setup.
   - The dynamic product.
   - `make-app.sh` copies `libRPBridge.dylib` into `Contents/Frameworks/`.
   - `PluginBridge` path resolution and escaping.
   - Bridge tests against Apple AUs.
   - RPSmoke passthrough check.
   - This merges research PRs 2 and 3, because Apple AUs make render testable without a store.
3. **PR 49 — Store, host and config.**
   - `PluginValidator`, `PluginStore` and `PluginHost`.
   - The `AudioProfile` fields and the write-back fix.
   - Binder wiring.
   - No UI yet.
4. **PR 50 — Settings section, editor and docs.**
   - The "Audio Unit" section and `PluginEditorPanel`.
   - README and architecture notes.
   - CHANGELOG entry, and cut **v1.2.0** in the same PR (released on merge).
