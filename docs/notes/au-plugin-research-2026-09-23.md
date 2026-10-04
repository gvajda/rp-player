# Audio Unit plugin support — research note

**Date:** 2026-09-23
**Status:** research complete, AU-only scope accepted, ready for brainstorming → spec
**Scope:** one AUv2 effect plugin inserted into the playback chain; users import plugins into the app folder, pick one from a dropdown, edit its parameters, delete it.

> Superseded in places by the design spec `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md` (bridge wiring, format ownership, generic editor, chain position (EQ → Plugin → Crossfeed), PR split). This note is kept as the research record.

---

## 1. Problem

RP Player's audio path is: libmpv decode → FFmpeg `lavfi` filter graph (via mpv's `af` property) → CoreAudio (`coreaudio` AO, hog mode owned by `HogModeController`). EQ and crossfeed are lavfi filter strings written through `PlayerEngine.setAudioFilterChain(_:)`.

- **libmpv has no API that hands raw audio samples to the app.** The only render API is for video. There is nowhere in Swift to process PCM between decode and output.
- **FFmpeg can host only `ladspa` and `lv2` plugins.** It cannot host AU or VST.
- **The vendored FFmpeg has neither.** It is built with `--disable-autodetect` and no `--enable-ladspa` or `--enable-lv2` (checked via `strings Vendor/libmpv/lib/libavfilter.dylib`).

## 2. Chosen approach: LADSPA bridge → AU

1. **Rebuild libmpv with `--enable-ladspa`** in the fork (`github.com/gvajda/libmpv-darwin-build`), the same way `--enable-libbs2b` was added. It needs only the `ladspa.h` header (LGPL, single file; nixpkgs `ladspaH`) plus `dlopen`, and no new runtime dylib.
2. **Ship a small bridge dylib**, a separate C/ObjC dynamic-library target (e.g. `librpbridge.dylib` in `Contents/Frameworks/`). It exports one LADSPA descriptor, label `rpbridge`, with 2 audio inputs and 2 audio outputs.
   - `run()` forwards the non-interleaved float buffers to whichever AU the app has handed it. With no AU set, or bypass on, it copies input to output.
   - The app links the bridge, so it is already loaded, and passes it the AU through an exported C function, e.g. `rpbridge_set_unit(AudioUnit _Nullable)`.
3. **Append to the lavfi chain:** `ladspa=file=<abs path to librpbridge.dylib>:p=rpbridge`.
   - FFmpeg `af_ladspa` accepts absolute paths (`dl_name[0] == '/'` → `dlopen(RTLD_LOCAL|RTLD_NOW)`).
   - `dlopen` of an image that is already loaded returns the same image, so the app and FFmpeg share the bridge's globals.
   - Get the bridge's real path at runtime via `dladdr` on one of its symbols.

**Why this works well:**
- The filter runs on mpv's decode/filter thread, not the real-time CoreAudio IO thread, so a plain mutex around the "current AU" pointer is acceptable.
- Swapping or disabling the plugin only changes the bridge's target. The `af` string does not change, so mpv does not rebuild the graph.
- Parameter changes are heard after mpv's output buffer delay, roughly 0.2–1 s. That's fine for a radio player.

### Rejected alternatives

| Option | Why rejected |
|---|---|
| FFmpeg `lv2` filter | Few Mac LV2 plugins, no plugin windows, and parameters only via lavfi option strings. |
| Replace mpv output with AVAudioEngine | Needs its own decoder and HTTP/gapless/prefetch pipeline; throws away the `PlaybackCoordinator` + mpv prefetch work. |
| Virtual loopback device (BlackHole-style) | Requires installing a driver, and the extra device hop conflicts with the hog-mode design. |
| VST3 | Deferred. The SDK is MIT since v3.8 (Oct 2025), but it needs C++ interop and custom editor-view hosting. Almost all Mac plugins also ship AU. |
| VST2 | SDK discontinued/withdrawn. Never. |

## 3. Bridge details

- **Instance lifecycle:** FFmpeg calls `instantiate` / `activate` whenever it re-creates the filter (every `af` write, format change) and `cleanup` in `uninit`. These must **not** create or destroy the AU. The AU is owned by the app. On `activate`: `AudioUnitReset` plus a check of the sample rate.
- **AU setup (app side):**
  - Stream format: Float32, non-interleaved, 2 channels, at the rate given to `instantiate` (RP = 44.1 kHz), set on input and output scope.
  - Set `kAudioUnitProperty_MaximumFramesPerSlice` to e.g. 4096. The bridge splits `run(sample_count)` into chunks no larger than that.
  - Call `AudioUnitInitialize`. If the rate changes, uninitialize, re-set the format and re-initialize.
- **Rendering:**
  - Input comes through `kAudioUnitProperty_SetRenderCallback`, which returns the LADSPA input port buffers.
  - The bridge calls `AudioUnitRender` into the output port buffers.
  - `AudioTimeStamp.mSampleTime` must increase monotonically, so keep a counter in the bridge.
  - If render returns an error, pass the input through and log once, rather than every buffer.
- **Plugin latency/tail** (lookahead limiters, reverbs) is irrelevant for streaming. No delay compensation is needed.

## 4. Loading an imported AU from the app folder

- **Storage layout:** `~/Library/Application Support/RP Player/Plugins/<uuid>/<Name>.component`, plus `state.plist` in the same folder.
- **Import validation:**
  - The bundle's Info.plist has an `AudioComponents` array; read `type`, `subtype`, `manufacturer`, `name`, `version` and `factoryFunction` from it. Reject old Component Manager-only bundles.
  - Accept only effect types (`aufx`, optionally `aumf`). Reject instruments and generators.
  - Architecture check: `Bundle.executableArchitectures` must include arm64 on Apple silicon (x86_64 on Intel). Intel-only plugins cannot load in-process under arm64, so give a clear error.
  - Must accept a 2-in/2-out channel configuration.
- **Registration:**
  - Load the bundle and resolve `factoryFunction` via `CFBundleGetFunctionPointerForName`.
  - Call `AudioComponentRegister(&desc, name, version, factory)`. This registers the plugin **only for this process**, so it stays invisible to Logic and other apps.
- **Instantiation:**
  - `AVAudioUnit.instantiate(with: desc, options: [])`, which is in-process.
  - `.audioUnit` → the AudioUnit handle given to the bridge.
  - `.auAudioUnit` → editor window and state.
- **Out-of-process loading** (crash isolation) is **not possible** for process-local registrations. Accepted risk: a buggy plugin crashes the app.

## 5. Parameters, editor and state

- **Editor window:** `auAudioUnit.requestViewController` → host the view in an `NSWindow` / `NSPanel`, the same pattern as `EqEditPanel`. This works for AUv2 through the AUAudioUnit bridge.
- **No view:** fall back to a generic list of parameter sliders from the `parameterTree`.
- **State:**
  - Save `auAudioUnit.fullState` as a binary plist via `PropertyListSerialization` to `state.plist` when the editor closes, and debounce saves while it is open.
  - Restore the state before handing the AU to the bridge.
- **Config:**
  - Store it per device on `AudioProfile`, like EQ: `pluginEnabled: Bool` (default false) and `pluginId: String?` (the folder uuid).
  - Needs a Codable migration default and passthrough in the volume/hog binder's profile write-back, the same as the `crossfeed*` fields.

## 6. Settings UI ("Plugins" section)

- **Enable toggle** (per device, like EQ).
- **Dropdown** of imported plugins, showing name, manufacturer and version.
- **Buttons:**
  - **Import…** opens `NSOpenPanel` limited to `.component` bundles; it validates, then copies into the folder.
  - **Edit…** opens the editor window.
  - **Delete** asks for confirmation, then removes the bundle and state. If any profile references the plugin, clear it.
- **Bit-perfect note:** the tooltip should say bit-perfect is lost while a plugin is active, alongside the existing "Bit-perfect when EQ is off".

## 7. Known limitations and risks

- **Crash isolation:** a plugin crash takes the app down (see §4).
- **Plugins with external dependencies:** many commercial plugins rely on licence managers (iLok, vendor daemons) or on support files in `/Library/Application Support/<vendor>`. A bare copy of the `.component` may fail to authorise or load its content. Self-contained plugins (Airwindows, TDR, many freeware) work best.
- **Gatekeeper:** quarantined, unsigned or un-notarized bundles may be blocked on load. `scripts/entitlements.plist` already disables library validation, so signed third-party code loads. Decide whether to show a hint when the load fails; do not strip quarantine silently.
- **Bit-perfect** is lost while a plugin is enabled, the same as EQ.
- **Escaping in the lavfi string:** the bridge path contains a space (`/Applications/RP Player.app/...`), and the chain is a lavfi string, so quote or escape the `file=` value correctly (lavfi `'…'` quoting / `\` escaping). Cover this with a test.
- **GPL:** the bundled build is already GPL (`encodersgpl`). The bridge, `ladspa.h` (LGPL) and AudioToolbox add no new licence conflict.

## 8. Open questions for brainstorming

1. Where does the plugin sit in the chain? Suggested: at the tail, Preamp → EQ → Crossfeed → **Plugin**.
2. Should the dropdown also list AUs **already installed** on the system (`AVAudioUnitComponentManager`, effect types)? That avoids the licence and support-file problems in §7, and those can be loaded out-of-process for crash isolation.
3. Per-device (like EQ) or global?
4. Section name: "Plugins" or "Audio Units"?

## 9. Suggested PR breakdown

1. **libmpv rebuild with `--enable-ladspa`** and a new libmpv in `Vendor/`. Update `Vendor/libmpv/README.md` and `LibmpvLinkageTests`. Add an RPSmoke check that a pass-through bridge in the chain plays audio.
2. **Bridge dylib, pass-through only:** SwiftPM target, packaging into `Contents/Frameworks/` via `scripts/make-app.sh`, path resolution and escaping, chain builder tests.
3. **Bridge → AU rendering:** loader (`AudioComponentRegister` + `AVAudioUnit`), format setup, chunking, sample-time counter. Manual test with a free AU (e.g. Airwindows).
4. **Plugin store:** import validation, copy, delete, state save/restore, `AudioProfile` fields and migration. Store tests modelled on `EqPresetStoreTests`.
5. **Settings section and editor window;** README, CHANGELOG and architecture updates.

## Sources

- FFmpeg 6.0 `af_ladspa.c` (absolute path loading, lifecycle, buffer layout): https://github.com/FFmpeg/FFmpeg/blob/release/6.0/libavfilter/af_ladspa.c
- VST 3.8 SDK under MIT (why VST3 is deferred, not blocked): https://www.kvraudio.com/news/steinberg-moves-vst-3-sdk-to-mit-open-source-license-asio-now-gplv3-65179
- VST 3 licence page: https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License.html
- Apple: `AudioComponentRegister`, `AVAudioUnit.instantiate(with:options:)`, `AUAudioUnit.requestViewController`, `AUAudioUnit.fullState` (AudioToolbox / AVFAudio docs)
