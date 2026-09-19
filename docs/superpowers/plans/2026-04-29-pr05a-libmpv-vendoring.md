# PR 5a: libmpv Vendoring + Smoke CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vendor a self-contained libmpv (universal binary, audio-only build) plus its public C header, wire it into SwiftPM via a system-library target, and ship a `rpsmoke` CLI that opens an HTTP audio URL through libmpv to validate the audio path before any Swift actor work.

**Architecture:** libmpv is shipped as a precompiled universal `.dylib` (arm64 + x86_64) plus 9 dependency dylibs (ffmpeg + mbedtls), sourced from the LGPL `media-kit/libmpv-darwin-build` v0.6.3 audio-default release. The public C header `client.h` comes from upstream mpv tag `v0.36.0` (matching API version 2.1 reported by the dylib). A SwiftPM `systemLibrary` target named `CMpv` exposes the header to Swift via a `module.modulemap`. The `rpsmoke` executable target uses the C API directly (no Swift wrapper — that lands in PR 5b) and is run with `DYLD_LIBRARY_PATH` pointing at `Vendor/libmpv/lib`. An XCTest verifies link-time + load-time correctness by calling `mpv_client_api_version()`.

**Tech Stack:** SwiftPM 6.2, libmpv (LGPL-2.1, dynamically linked), upstream mpv v0.36.0 `client.h` (ISC-licensed), `media-kit/libmpv-darwin-build` v0.6.3, XCTest.

---

## File map

**New (vendored binaries + headers):**
- `Vendor/libmpv/lib/libmpv.dylib` (~6.8 MB)
- `Vendor/libmpv/lib/libavcodec.dylib` (~2.8 MB)
- `Vendor/libmpv/lib/libavfilter.dylib` (~376 KB)
- `Vendor/libmpv/lib/libavformat.dylib` (~1.3 MB)
- `Vendor/libmpv/lib/libavutil.dylib` (~924 KB)
- `Vendor/libmpv/lib/libswresample.dylib` (~200 KB)
- `Vendor/libmpv/lib/libswscale.dylib` (~716 KB)
- `Vendor/libmpv/lib/libmbedcrypto.dylib` (~1.7 MB)
- `Vendor/libmpv/lib/libmbedtls.dylib` (~668 KB)
- `Vendor/libmpv/lib/libmbedx509.dylib` (~272 KB)
- `Vendor/libmpv/include/mpv/client.h` (libmpv public C API, mpv tag v0.36.0)
- `Vendor/libmpv/SHA256SUMS` — checksums for all 10 dylibs + the header
- `Vendor/libmpv/README.md` — provenance and version pin

**New (sources):**
- `Sources/CMpv/module.modulemap` — SwiftPM system-library bridge
- `Sources/RPSmoke/main.swift` — the smoke-test CLI

**New (tests):**
- `Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift` — XCTest verifying the dylib is found and reports the expected API version.

**Modified:**
- `Package.swift` — add `.systemLibrary("CMpv")`, add `.executableTarget("RPSmoke")`, attach `CMpv` to test target, set the linker rpath flags.
- `.gitignore` — remove the existing `Vendor/libmpv/*.dylib` exclusion line.
- `CLAUDE.md` — record libmpv version pin, env-var requirement for `swift test` and `swift run rpsmoke`, and bump the PR table.

---

## Provenance and integrity

The dylibs come from a single upstream release. Pin them with both the upstream URL and a SHA256 manifest committed to the repo:

| File | SHA256 |
|---|---|
| libavcodec.dylib | `39cde1d283892d5e0ca01037e774d3d1b834c525fcae9c166b61c495966684e7` |
| libavfilter.dylib | `b5a6d2a6e588d6aeaac11050c7191ee92e88a177f825b45951394875537112c6` |
| libavformat.dylib | `6f2e6e05f802bba3ecaffa2269d8829d8c268df89c82042aef1cefbe90d8437c` |
| libavutil.dylib | `225d437d5cd3ba8d27a7c0f6639f36fda285cbac92334846d142caf4d559518a` |
| libmbedcrypto.dylib | `e89c04411cb21c18d0ba75e387145c3a98c323a53e34f25a2b7faf46c1177d5e` |
| libmbedtls.dylib | `c2933fbb47cc0d783651182694c3e3903303a44c3aa4c084c2119285affa0a92` |
| libmbedx509.dylib | `b422a3b0987b7f9b5bf6e6c2e9eae0348482a24c0831de49401ed642ab3a7a09` |
| libmpv.dylib | `1e539e9a9263f7927d385abc84d762af69bae5c153f2b2878032cd27533c3b60` |
| libswresample.dylib | `f017c31b1c91268e9709c470a82913ba9a601f5f440988edf4347bd080666b8a` |
| libswscale.dylib | `3b3244aaed6dc56010271796cb634f19af0a161eba60f38000f887e8feecdf46` |
| `client.h` (mpv v0.36.0 — ref `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`) | `287181025de368777fa30f6f636c1915e77cc551ffe132993528f08ff4a64ae4` |

`mpv_client_api_version()` reported by `libmpv.dylib`: `2.1` (= `MPV_MAKE_VERSION(2, 1)` = `0x00020001` = `131073`). This is the source of truth — Task 4's automated test asserts it.

---

## Task 1: Vendor the dylibs

**Files:**
- Create: `Vendor/libmpv/lib/*.dylib` (10 files)
- Create: `Vendor/libmpv/SHA256SUMS`
- Create: `Vendor/libmpv/README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Create the directory and download the upstream tarball**

```bash
mkdir -p Vendor/libmpv/lib Vendor/libmpv/include/mpv
cd /tmp && rm -rf rpplayer-libmpv && mkdir rpplayer-libmpv && cd rpplayer-libmpv
gh release download v0.6.3 --repo media-kit/libmpv-darwin-build \
    -p 'libmpv-libs_v0.6.3_macos-universal-audio-default*'
tar -xzf libmpv-libs_v0.6.3_macos-universal-audio-default.tar.gz
ls libmpv-libs_v0.6.3_macos-universal-audio-default/
```

Expected output: 10 `.dylib` files (libmpv + libav* + libsw* + libmbed*).

- [ ] **Step 2: Verify SHA256 sums match the manifest above**

```bash
cd /tmp/rpplayer-libmpv/libmpv-libs_v0.6.3_macos-universal-audio-default
shasum -a 256 *.dylib
```

Compare each line to the table above. If any line mismatches, abort — the upstream artifact has been altered. Do not proceed.

- [ ] **Step 3: Copy dylibs into `Vendor/libmpv/lib/`**

Run from the repo root:

```bash
cp /tmp/rpplayer-libmpv/libmpv-libs_v0.6.3_macos-universal-audio-default/*.dylib Vendor/libmpv/lib/
ls -la Vendor/libmpv/lib/
```

Expected: 10 `.dylib` files, total ~16 MB.

- [ ] **Step 4: Verify each dylib is universal**

```bash
file Vendor/libmpv/lib/libmpv.dylib
```

Expected: `Mach-O universal binary with 2 architectures: [x86_64:...] [arm64]`. Repeat sanity-check for one or two of the dependencies.

- [ ] **Step 5: Lift the `Vendor/libmpv/*.dylib` exclusion from `.gitignore`**

Edit `.gitignore`. Find this exact line:

```
Vendor/libmpv/*.dylib
```

Delete it. Save.

Verify there is no other rule excluding the same path:

```bash
git check-ignore -v Vendor/libmpv/lib/libmpv.dylib
```

Expected: empty output (file is no longer ignored).

- [ ] **Step 6: Write `Vendor/libmpv/SHA256SUMS`**

Create `Vendor/libmpv/SHA256SUMS` with content (paths relative to the file's location):

```
39cde1d283892d5e0ca01037e774d3d1b834c525fcae9c166b61c495966684e7  lib/libavcodec.dylib
b5a6d2a6e588d6aeaac11050c7191ee92e88a177f825b45951394875537112c6  lib/libavfilter.dylib
6f2e6e05f802bba3ecaffa2269d8829d8c268df89c82042aef1cefbe90d8437c  lib/libavformat.dylib
225d437d5cd3ba8d27a7c0f6639f36fda285cbac92334846d142caf4d559518a  lib/libavutil.dylib
e89c04411cb21c18d0ba75e387145c3a98c323a53e34f25a2b7faf46c1177d5e  lib/libmbedcrypto.dylib
c2933fbb47cc0d783651182694c3e3903303a44c3aa4c084c2119285affa0a92  lib/libmbedtls.dylib
b422a3b0987b7f9b5bf6e6c2e9eae0348482a24c0831de49401ed642ab3a7a09  lib/libmbedx509.dylib
1e539e9a9263f7927d385abc84d762af69bae5c153f2b2878032cd27533c3b60  lib/libmpv.dylib
f017c31b1c91268e9709c470a82913ba9a601f5f440988edf4347bd080666b8a  lib/libswresample.dylib
3b3244aaed6dc56010271796cb634f19af0a161eba60f38000f887e8feecdf46  lib/libswscale.dylib
287181025de368777fa30f6f636c1915e77cc551ffe132993528f08ff4a64ae4  include/mpv/client.h
```

(The `client.h` line is included now even though Task 2 will create that file. The presence of this file in `SHA256SUMS` is verified at the end of Task 2.)

Verify the dylib lines match:

```bash
cd Vendor/libmpv && shasum -a 256 -c SHA256SUMS 2>&1 | tee /tmp/sums.txt | grep -v ': OK$'
```

Expected: only `include/mpv/client.h: No such file or directory` (the header arrives in Task 2). All 10 dylib lines should be `OK`. If any other line fails, fix it before continuing.

- [ ] **Step 7: Write `Vendor/libmpv/README.md`**

Create `Vendor/libmpv/README.md`:

```markdown
# Vendored libmpv

Self-contained libmpv runtime for RP Player. macOS universal binary
(`arm64` + `x86_64`), audio-only build, dynamically linked.

## Source

- Tarball: `libmpv-libs_v0.6.3_macos-universal-audio-default.tar.gz`
- Origin: <https://github.com/media-kit/libmpv-darwin-build/releases/tag/v0.6.3>
- License: LGPL-2.1 (no GPL components in the audio-default flavour).

## Public header

- File: `include/mpv/client.h`
- Origin: <https://github.com/mpv-player/mpv/blob/v0.36.0/libmpv/client.h>
- Upstream commit: `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`
- License: ISC (header file is permissively licensed even though libmpv itself is LGPL).

## API version

`mpv_client_api_version()` reports `MPV_MAKE_VERSION(2, 1)` = `131073`. Verified
at runtime by `LibmpvLinkageTests.testReportsExpectedApiVersion`. Replacing the
dylib bundle requires verifying the upstream API version still matches and either
keeping the same `client.h` or refreshing it from the matching mpv tag.

## Integrity

`SHA256SUMS` lists the expected checksum for every file in this directory.
Verify with:

```
cd Vendor/libmpv && shasum -a 256 -c SHA256SUMS
```
```

- [ ] **Step 8: Commit**

```bash
git add .gitignore Vendor/libmpv/lib/ Vendor/libmpv/SHA256SUMS Vendor/libmpv/README.md
git status
git commit -m "feat(pr05a): vendor libmpv universal dylibs (media-kit v0.6.3, audio-default)"
```

Expected: `git status` should show only the files above as added; the commit should succeed.

---

## Task 2: Vendor the public C header

**Files:**
- Create: `Vendor/libmpv/include/mpv/client.h`

- [ ] **Step 1: Download `client.h` from upstream mpv at the pinned tag**

```bash
curl -sL --fail \
    https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/libmpv/client.h \
    -o Vendor/libmpv/include/mpv/client.h
```

- [ ] **Step 2: Verify the digest**

```bash
shasum -a 256 Vendor/libmpv/include/mpv/client.h
```

Expected first column: `287181025de368777fa30f6f636c1915e77cc551ffe132993528f08ff4a64ae4`. If it does not match, the upstream file was rotated; abort and resolve before continuing.

Also rerun the full manifest check:

```bash
cd Vendor/libmpv && shasum -a 256 -c SHA256SUMS 2>&1 | tail -5
```

Expected: every line ends with `: OK`.

- [ ] **Step 3: Sanity-check the API version macro in the header**

```bash
grep "MPV_CLIENT_API_VERSION MPV_MAKE_VERSION" Vendor/libmpv/include/mpv/client.h
```

Expected exactly: `#define MPV_CLIENT_API_VERSION MPV_MAKE_VERSION(2, 1)`.

- [ ] **Step 4: Commit**

```bash
git add Vendor/libmpv/include/mpv/client.h
git commit -m "feat(pr05a): vendor mpv client.h (upstream v0.36.0, API 2.1)"
```

---

## Task 3: SwiftPM CMpv system-library target

**Files:**
- Create: `Sources/CMpv/module.modulemap`
- Modify: `Package.swift`

The `systemLibrary` target type lets SwiftPM expose a C library (header + module map) to Swift. We build a `CMpv` module that imports `client.h` from the vendored path.

- [ ] **Step 1: Create `Sources/CMpv/module.modulemap`**

```bash
mkdir -p Sources/CMpv
```

Create `Sources/CMpv/module.modulemap`:

```
module CMpv {
    header "../../Vendor/libmpv/include/mpv/client.h"
    link "mpv"
    export *
}
```

The relative `../../Vendor/...` path resolves from `Sources/CMpv/` up two levels to the package root.

- [ ] **Step 2: Update `Package.swift`**

Replace the entire contents of `Package.swift` with:

```swift
// swift-tools-version: 6.2

import PackageDescription

let libmpvLib = "Vendor/libmpv/lib"

// Linker flags shared by every target that loads libmpv at runtime: tell the
// linker where the dylibs live, link the umbrella, and bake an `@loader_path`
// rpath so binaries can find the dylibs without a DYLD_LIBRARY_PATH override.
// The depth of `@loader_path/...` differs per-target binary location and is
// documented inline below.
let mpvLinker: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(libmpvLib)",
        "-lmpv",
    ]),
]

let package = Package(
    name: "RPPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv"
        ),
        .executableTarget(
            name: "RPPlayer",
            path: "Sources/RPPlayer"
        ),
        .executableTarget(
            name: "RPSmoke",
            dependencies: ["CMpv"],
            path: "Sources/RPSmoke",
            linkerSettings: mpvLinker
        ),
        .testTarget(
            name: "RPPlayerTests",
            dependencies: ["RPPlayer", "CMpv"],
            path: "Tests/RPPlayerTests",
            resources: [.copy("Fixtures")],
            linkerSettings: mpvLinker
        ),
    ]
)
```

Keep the existing `RPPlayer` executable target unchanged — it does not depend on `CMpv` yet (PR 5b adds that dependency when it introduces `PlayerEngine`).

- [ ] **Step 3: Verify the package resolves and builds**

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!`. If the build fails with `library not found for -lmpv`, the relative `-L\(libmpvLib)` path was not honoured — verify the working directory is the package root.

- [ ] **Step 4: Commit**

```bash
git add Sources/CMpv/module.modulemap Package.swift
git commit -m "build(pr05a): add CMpv system library target wired to vendored libmpv"
```

---

## Task 4: Linkage test — verify dylib loads and reports the expected API version

**Files:**
- Create: `Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift`

Tests run via `swift test`. Because the `RPPlayerTests` target depends on `CMpv` and links `-lmpv`, the test bundle binary will dynamic-load `libmpv.dylib` at launch — but only if the loader can find it. The `-L Vendor/libmpv/lib` flag at link time is not enough at runtime. Use `DYLD_LIBRARY_PATH` to point the loader at the vendored dir.

- [ ] **Step 1: Write the failing test**

Create `Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift`:

```swift
import XCTest
import CMpv

final class LibmpvLinkageTests: XCTestCase {
    /// Asserts the linker found `libmpv.dylib` and the runtime loader matched it.
    /// Pinned API version: 2.1 — see `Vendor/libmpv/README.md`. Bump this
    /// expectation whenever the vendored libmpv is updated.
    func testReportsExpectedApiVersion() {
        let v = mpv_client_api_version()
        let major = (v >> 16) & 0xFFFF
        let minor = v & 0xFFFF
        XCTAssertEqual(major, 2, "expected libmpv API major version 2")
        XCTAssertEqual(minor, 1, "expected libmpv API minor version 1")
    }
}
```

- [ ] **Step 2: Run the test (expect it to fail at runtime if `DYLD_LIBRARY_PATH` is not set, or to fail at compile time if `CMpv` is not wired)**

```bash
swift test --filter LibmpvLinkageTests 2>&1 | tail -20
```

If the failure is `dyld: Library not loaded: @rpath/libmpv.dylib`, that is the expected runtime failure — `DYLD_LIBRARY_PATH` is the missing piece. Continue with Step 3.

- [ ] **Step 3: Re-run with `DYLD_LIBRARY_PATH` set**

```bash
DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib" swift test --filter LibmpvLinkageTests 2>&1 | tail -10
```

Expected: `Executed 1 test, with 0 failures`. The test prints nothing else.

- [ ] **Step 4: Run the full suite the same way**

```bash
DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib" swift test 2>&1 | tail -10
```

Expected: `Executed 48 tests, with 0 failures` (47 from PR 4 + 1 added here).

- [ ] **Step 5: Commit**

```bash
git add Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift
git commit -m "test(pr05a): assert vendored libmpv reports API version 2.1"
```

---

## Task 5: rpsmoke executable — minimal C-API playback

**Files:**
- Create: `Sources/RPSmoke/main.swift`

The executable is intentionally narrow — no Swift wrapper, no actor, no event-pump abstraction. It exists to confirm the audio path end-to-end on a developer's machine. PR 5b replaces all of this with `PlayerEngine`.

The smoke CLI takes a single argument (an audio URL), opens libmpv, plays for ~6 seconds, prints `time-pos` updates, then quits. This is sufficient evidence that:
- The link rpath/DYLD path works at runtime;
- libmpv finds CoreAudio and produces sound;
- `mpv_observe_property` and the event loop work as documented.

- [ ] **Step 1: Create `Sources/RPSmoke/main.swift`**

```swift
import CMpv
import Foundation

@main
struct RPSmoke {
    static func main() {
        let url = CommandLine.arguments.dropFirst().first ?? "https://stream.radioparadise.com/aac-320"
        guard let handle = mpv_create() else {
            fputs("mpv_create returned nil\n", stderr)
            exit(1)
        }
        defer { mpv_terminate_destroy(handle) }

        let apiVersion = mpv_client_api_version()
        fputs("libmpv API \((apiVersion >> 16) & 0xFFFF).\(apiVersion & 0xFFFF)\n", stderr)

        // Minimal config: no video, no input handling. Bit-perfect details and
        // device pinning land in PlayerEngine (PR 5b).
        let initialOptions: [(String, String)] = [
            ("vid", "no"),
            ("video", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("audio-display", "no"),
        ]
        for (key, value) in initialOptions {
            let status = mpv_set_option_string(handle, key, value)
            if status < 0 {
                fputs("mpv_set_option_string(\(key)) failed: \(String(cString: mpv_error_string(status)))\n", stderr)
                exit(1)
            }
        }

        let initStatus = mpv_initialize(handle)
        if initStatus < 0 {
            fputs("mpv_initialize failed: \(String(cString: mpv_error_string(initStatus)))\n", stderr)
            exit(1)
        }

        // Observe time-pos so the event loop has something to surface.
        _ = mpv_observe_property(handle, /*reply_userdata*/ 0, "time-pos", MPV_FORMAT_DOUBLE)

        var loadCmd = ["loadfile", url]
        loadCmd.withCStringPointers { cargv in
            let cmdStatus = mpv_command(handle, cargv)
            if cmdStatus < 0 {
                fputs("mpv_command(loadfile) failed: \(String(cString: mpv_error_string(cmdStatus)))\n", stderr)
                exit(1)
            }
        }

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            guard let eventPtr = mpv_wait_event(handle, /*timeout*/ 0.5) else { break }
            let event = eventPtr.pointee
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                fputs("event: shutdown\n", stderr)
                return
            case MPV_EVENT_END_FILE:
                fputs("event: end-file\n", stderr)
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                let propPtr = event.data.assumingMemoryBound(to: mpv_event_property.self)
                let prop = propPtr.pointee
                if prop.format == MPV_FORMAT_DOUBLE,
                   let dataPtr = prop.data?.assumingMemoryBound(to: Double.self) {
                    let pos = dataPtr.pointee
                    let name = String(cString: prop.name)
                    fputs("event: property-change \(name)=\(String(format: "%.2f", pos))\n", stderr)
                }
            default:
                break
            }
        }

        fputs("rpsmoke: time elapsed, exiting cleanly\n", stderr)
    }
}

private extension Array where Element == String {
    /// Builds a NULL-terminated `argv` for libmpv command APIs that take
    /// `const char**`. The closure receives a pointer that is valid for its
    /// duration only.
    func withCStringPointers<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let cstrings = self.map { strdup($0)! }
        var argv = cstrings.map { UnsafePointer<CChar>?($0) }
        argv.append(nil)
        defer {
            for s in cstrings { free(s) }
        }
        return argv.withUnsafeBufferPointer { buf in body(buf.baseAddress!) }
    }
}
```

- [ ] **Step 2: Build the smoke executable**

```bash
swift build --product RPSmoke 2>&1 | tail -10
```

Expected: `Build complete!`. The product binary lives at `.build/<arch>-apple-macosx/debug/RPSmoke` (or `.build/debug/RPSmoke` depending on toolchain).

- [ ] **Step 3: Run the smoke test against a public RP stream**

The Radio Paradise main mix MP3 stream is a stable, no-auth audio URL — short enough latency for a 6-second probe.

```bash
DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib" \
    swift run RPSmoke https://stream.radioparadise.com/mp3-320 2>&1 | tail -15
```

Expected (audible audio for ~6 seconds, then process exits):
- A `libmpv API 2.1` line on stderr.
- Several `event: property-change time-pos=N.NN` lines, with the value increasing.
- A final `rpsmoke: time elapsed, exiting cleanly` line.

If you do not hear audio:
- Verify the system output device is selected and unmuted in System Settings → Sound.
- Re-run and watch for `mpv_initialize failed` or any `mpv_command(loadfile) failed` lines.

- [ ] **Step 4: Commit**

```bash
git add Sources/RPSmoke/main.swift
git commit -m "feat(pr05a): add RPSmoke CLI to validate libmpv audio path"
```

---

## Task 6: Documentation updates (CLAUDE.md)

**Files:**
- Modify: `CLAUDE.md`

The agent context file needs three updates:
1. Bump the PR table — mark PR 4 ✅ and split PR 5 into 5a (this PR) and 5b (PlayerEngine actor).
2. Document the libmpv pin so a future agent doesn't refresh the dylibs blindly.
3. Document the env-var requirement for `swift test` and `swift run RPSmoke`.

- [ ] **Step 1: Update the PR status table**

Open `CLAUDE.md` and locate the PR status table. Replace the row:

```markdown
| 4   | **next**       | ⬜      | AudioDeviceCatalog                                                |
| 5   | pending        | ⬜      | PlayerEngine (libmpv Swift actor)                                 |
```

with:

```markdown
| 4   | merged to main | ✅      | AudioDeviceCatalog                                                |
| 5a  | **next**       | ⬜      | libmpv vendoring + RPSmoke CLI                                    |
| 5b  | pending        | ⬜      | PlayerEngine (libmpv Swift actor)                                 |
```

(Keep the rest of the table — PRs 6–12 — unchanged.)

Also update the "Continue work" line near the top:

```markdown
## "Continue work" means: write the PR 4 plan, get approval, execute it
```

→

```markdown
## "Continue work" means: write the next PR plan, get approval, execute it
```

- [ ] **Step 2: Add libmpv pin and env-var requirement to "Key technical decisions"**

Append the following bullets to the existing "Key technical decisions" section:

```markdown
- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). The public `client.h` is pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`). Reported API version: 2.1. Refreshing the dylibs requires updating both the binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `swift test` and `swift run RPSmoke` need `DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib"` so the loader can find the vendored dylibs. Production `.app` packaging (PR 12) will install them under `Contents/Frameworks/` and use a baked rpath instead.
```

- [ ] **Step 3: Update the test-counts section**

Append:

```markdown
- After PR 5a: 48 tests
```

to the existing "Test counts by PR" list.

- [ ] **Step 4: Build and test (sanity check after the doc edits — no behavioural change expected)**

```bash
DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib" swift test 2>&1 | tail -5
```

Expected: `Executed 48 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(pr05a): record libmpv pin, env-var requirement, post-PR5a test count"
```

---

## Self-review

**Spec coverage check:**

| Goal of PR 5a | Covered by |
|---|---|
| Slim, self-contained libmpv (no Homebrew at install time) | Task 1 vendors all 10 dylibs from media-kit v0.6.3 audio-default |
| Universal binary (arm64 + x86_64) | Task 1 Step 4 verifies `file` output |
| LGPL-2.1 licensed (per DESIGN.md decision) | Task 1 Step 7 documents the licence in `Vendor/libmpv/README.md` |
| Public C API exposed to Swift | Task 2 vendors `client.h`; Task 3 wires the `CMpv` system-library target |
| Smoke-test CLI that proves audio path works | Task 5 (`RPSmoke`) plays a public RP stream and prints position events |
| Decision: commit binary vs. fetch from CI artefact | Decided in this plan: commit binaries (≈16 MB total) — DESIGN.md §10 open question resolved as "commit" for hobby-project simplicity |
| Linker rpath / runtime resolution | Tasks 3–5 use `DYLD_LIBRARY_PATH` for dev. Production `.app` packaging deferred to PR 12 (DESIGN.md §11.4 milestone 12) |
| Automated verification of link correctness | Task 4 `LibmpvLinkageTests.testReportsExpectedApiVersion` |

**Placeholder scan:** Searched for "TBD", "TODO", "implement later", "fill in details", "add appropriate", "similar to", "etc." — none found. Every code block, command, and expected output is concrete.

**Type / signature consistency:**
- `CMpv` module name used in Tasks 3, 4, 5 ✓
- `RPSmoke` target name used in Tasks 3, 5 ✓
- `Vendor/libmpv/lib/` path used consistently across Tasks 1, 3, 4, 5, 6 ✓
- `Vendor/libmpv/include/mpv/client.h` path matches the relative `../../Vendor/...` reference in `Sources/CMpv/module.modulemap` (Task 3 Step 1) ✓
- `mpv_client_api_version()` expected = 2.1, matched by the dylib (verified earlier) and by the header `#define` (Task 2 Step 3) ✓
- `DYLD_LIBRARY_PATH="$(pwd)/Vendor/libmpv/lib"` invocation identical in Tasks 4, 5, 6 ✓

**Test-count math:** PR 4 final = 47. PR 5a adds 1 (`LibmpvLinkageTests.testReportsExpectedApiVersion`). Total 48. Reflected in Task 4 Step 4, Task 6 Step 3, and Task 6 Step 4.

**Risk register:**
- The smoke-test step (Task 5 Step 3) requires audio hardware on the dev Mac. There is no automated assertion that audio actually played — only that the process exited cleanly. Acceptable for a manual smoke test.
- If `media-kit/libmpv-darwin-build` ever rotates the v0.6.3 release artefacts (rare but possible), the SHA256SUMS check in Task 1 Step 2 will trip. The plan instructs to abort and resolve before continuing; that is the right behaviour.
- The `DYLD_LIBRARY_PATH` env-var requirement is a developer-ergonomics smell. It is acceptable for PR 5a (single-developer hobby project, local builds only) and gets retired by PR 12 (.app packaging with bundled `Contents/Frameworks/`).
