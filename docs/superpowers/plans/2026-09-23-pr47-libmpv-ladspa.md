# PR 47 — libmpv with LADSPA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a vendored libmpv whose FFmpeg includes the `ladspa` audio filter, so that PR 48 can put `ladspa=file=…:p=rpbridge` in the `af` chain.

**Architecture:**
- Add `--enable-ladspa` to the `audio-encodersgpl` FFmpeg variant in the libmpv fork (`~/git/libmpv-darwin-build`, remote `gvajda/libmpv-darwin-build`).
- FFmpeg's `af_ladspa` needs only `ladspa.h` at build time and `dlopen` at runtime, so no new dylib is added.
- Rebuild the macOS universal `audio-encodersgpl` libs locally with Nix, re-vendor them into `Vendor/libmpv/`, redo the install-name rewrite, and pin the result with a linkage test.

**Tech Stack:** Nix + meson (fork build), FFmpeg 6.0 configure, `install_name_tool` / `codesign` / `otool` / `lipo`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md` (§8, PR 47)

## Global Constraints

- The vendored libmpv stays **macOS universal** (`arm64` + `x86_64`), **audio-only**, **`encodersgpl` flavour**.
- The libmpv API version stays `MPV_MAKE_VERSION(2, 1)` = `131073` (existing `LibmpvLinkageTests.testReportsExpectedApiVersion`).
- `include/mpv/client.h` is unchanged.
- Every dylib's sibling references must be `@loader_path/lib<x>.dylib` after the rewrite (`Vendor/libmpv/README.md`).
- No new runtime dylib. The set of files in `Vendor/libmpv/lib/` stays exactly the current 16.
- No user-visible change. **No CHANGELOG entry** (the CHANGELOG is for end users).
- Comment policy: no comments unless the WHY is non-obvious, and single `//` lines only.
- Test command: `swift test`. Build command: `swift build`.

## Review Focus

1. **The wrong `libavfilter` is loaded at runtime**, because stale nix-store `LC_RPATH` entries win over the vendored copy. Expected: the vendored `libavfilter` with `ladspa` loads. Check: the install-name rewrite, plus the Task 2 `otool` check that no sibling references `@rpath`, plus the Task 2 linkage test, which asserts `bs2b` and `ladspa` together.
2. **A new absolute `/nix/store/…` load command sneaks into a dylib.** Expected: only `@loader_path`, `@rpath` (self), `/usr/lib` and `/System` dependencies. Check: the Task 2 `otool -L` filter step.
3. **Only one slice has LADSPA.** Tests run on the host arch only, so a broken x86_64 slice would pass `swift test`. Expected: both slices were configured with `--enable-ladspa`. Check: the Task 2 per-arch `strings -arch` step.
4. **Playback or EQ/bs2b regress after the re-vendor.** Expected: streams still play, and the existing filters still initialise. Check: `RPSmoke --probe-filters`, plus a short `RPSmoke` stream play in Task 2.
5. **Signatures are invalid after `install_name_tool`.** Expected: every dylib passes `codesign --verify`, and `make-app.sh` still produces a launching app. Check: the Task 2 codesign verify step, plus the Task 3 `make-app.sh` smoke.

---

## File Structure

**Fork (`~/git/libmpv-darwin-build`):**
- Commit the pre-existing, **uncommitted** staged bs2b change first, unchanged.
  - Modify: `nix/packages/mk-out-libs/default.nix`
  - Modify: `nix/packages/mk-pkg-ffmpeg/default.nix`
  - Modify: `nix/packages/mk-pkg-ffmpeg/meson.build`
  - Modify: `packages.lock.nix`
  - Create: `nix/packages/mk-pkg-libbs2b/{default.nix,meson.build,targets.nix}`
- Create: `nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h`, the LADSPA SDK 1.1 header (LGPL-2.1).
- Modify: `nix/packages/mk-pkg-ffmpeg/default.nix`, which copies the header into the patched source tree.
- Modify: `nix/packages/mk-pkg-ffmpeg/meson.build`, which adds the `-I` for the header and `--enable-ladspa` for `encodersgpl`.

**This repo:**
- Replace: `Vendor/libmpv/lib/*.dylib` (same 16 names)
- Modify: `Vendor/libmpv/SHA256SUMS`
- Modify: `Vendor/libmpv/README.md`
- Modify: `Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md` (Current state)

---

### Task 1: Fork — enable LADSPA and build the universal audio-encodersgpl libs

**Files (all in `~/git/libmpv-darwin-build`):**
- Commit: the already-staged bs2b change (listed above)
- Create: `nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h`
- Modify: `nix/packages/mk-pkg-ffmpeg/default.nix` (`patchedSource` block)
- Modify: `nix/packages/mk-pkg-ffmpeg/meson.build` (after `flavor = get_option('flavor')`, and `audio_encodersgpl_options`)

**Interfaces:**
- Consumes: nothing.
- Produces: `~/git/libmpv-darwin-build/result/libmpv-libs_develop_macos-universal-audio-encodersgpl.tar.gz`, whose `libavfilter.dylib` exports the `ladspa` filter in both slices. Task 2 consumes it.

- [ ] **Step 1: Commit the pending bs2b work as its own commit**

The bs2b change that PR 38 vendored was built from this working tree but never committed. Commit it unchanged, so that the fork history matches the libmpv that is already vendored.

```bash
cd ~/git/libmpv-darwin-build
git status --short        # expect only the bs2b files, all staged (M / A)
git commit -m "feat(ffmpeg): add libbs2b and --enable-libbs2b to audio-encodersgpl"
```

If `git status` shows anything besides the bs2b files listed in the File Structure, stop and report it. Do not commit unrelated changes.

- [ ] **Step 2: Add the LADSPA header**

```bash
cd ~/git/libmpv-darwin-build
mkdir -p nix/packages/mk-pkg-ffmpeg/ladspa
curl -fsSL https://www.ladspa.org/ladspa_sdk/ladspa.h.txt -o nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h
grep -n 'LADSPA_VERSION "1.1"' nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h
grep -n 'ladspa_descriptor' nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h
```

Expected: both `grep`s match. If ladspa.org is unreachable, take `ladspa.h` from the nixpkgs `ladspaH` source (`nix build nixpkgs#ladspaH && cp result/include/ladspa.h …`) and run the same checks.

- [ ] **Step 3: Copy the header into the patched FFmpeg source**

In `nix/packages/mk-pkg-ffmpeg/default.nix`, inside `patchedSource`, add the header copy after the two `cp ${./meson…}` lines and before `cp -r $src $out`:

```nix
    cp ${./meson.build} $src/meson.build
    cp ${./meson.options} $src/meson.options

    mkdir -p $src/rp-ladspa
    cp ${./ladspa/ladspa.h} $src/rp-ladspa/ladspa.h

    cp -r $src $out
```

- [ ] **Step 4: Pass the include path and enable the filter**

In `nix/packages/mk-pkg-ffmpeg/meson.build`, directly after `flavor = get_option('flavor')`:

```meson
# ladspa.h has no pkg-config file; af_ladspa needs only the header (plugins are dlopen'ed at runtime)
if flavor == 'encodersgpl'
    c_args += ['-I' + (meson.current_source_dir() / 'rp-ladspa')]
endif
```

In `audio_encodersgpl_options`, after the `--enable-libbs2b` line:

```meson
    '--enable-ladspa', # LADSPA host filter; RP Player bridges it to Audio Units
```

- [ ] **Step 5: Build the universal target**

```bash
cd ~/git/libmpv-darwin-build
nix develop -c make XCODE_PATH=/Applications/Xcode.app TARGET=mk-out-archive-libs-macos-universal-audio-encodersgpl
ls -la result/
```

Expected: `result/libmpv-libs_develop_macos-universal-audio-encodersgpl.tar.gz` with a new timestamp. The build compiles FFmpeg for both arches, so it can take tens of minutes. Run it in the background, and wait for it to finish rather than polling in a loop.

If configure fails with `ERROR: ladspa.h not found`, the `-I` did not reach configure's checks. Check that `c_args` from Step 4 is defined *before* the `mod.add_project` call that reads it, and that `$src/rp-ladspa/ladspa.h` exists in the patched source (`nix build .#…` then inspect the `patched-source` store path).

- [ ] **Step 6: Verify LADSPA is in both slices**

```bash
T=$(mktemp -d) && tar -xzf ~/git/libmpv-darwin-build/result/libmpv-libs_develop_macos-universal-audio-encodersgpl.tar.gz -C "$T"
AVF=$(find "$T" -name libavfilter.dylib | head -1)
lipo -archs "$AVF"                                    # expect: x86_64 arm64 (any order)
for a in arm64 x86_64; do
  echo "$a: $(strings -arch $a "$AVF" | grep -c -- '--enable-ladspa') configure-string hits, $(strings -arch $a "$AVF" | grep -cx 'ladspa') filter-name hits"
done
```

Expected: both arches report at least 1 hit on each count. Keep `$T` for Task 2, or re-extract it there.

- [ ] **Step 7: Commit the fork change**

```bash
cd ~/git/libmpv-darwin-build
git add nix/packages/mk-pkg-ffmpeg/ladspa/ladspa.h nix/packages/mk-pkg-ffmpeg/default.nix nix/packages/mk-pkg-ffmpeg/meson.build
git commit -m "feat(ffmpeg): enable the ladspa filter in audio-encodersgpl

Adds the LADSPA SDK 1.1 header (LGPL-2.1) and --enable-ladspa. af_ladspa
dlopens plugins at runtime, so no new library is linked."
```

**Do not push.** The controller asks the user before pushing the fork (Task 3).

---

### Task 2: Re-vendor libmpv and pin LADSPA with a linkage test

**Files:**
- Modify: `Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift`
- Replace: `Vendor/libmpv/lib/*.dylib`
- Modify: `Vendor/libmpv/SHA256SUMS`

**Interfaces:**
- Consumes: the Task 1 tarball.
- Produces: a vendored `libavfilter.dylib` in which `avfilter_get_by_name("ladspa") != NULL`. PR 48 relies on this.

- [ ] **Step 1: Write the failing test**

Add to `LibmpvLinkageTests` (add `import Darwin` if it is not implied by `XCTest`):

```swift
    // libmpv loads libavfilter from Vendor/libmpv/lib via @loader_path, so dlopen by that path returns the same image.
    func testVendoredAvfilterHasLadspaAndBs2b() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Vendor/libmpv/lib/libavfilter.dylib").path
        let handle = try XCTUnwrap(dlopen(path, RTLD_NOW | RTLD_LOCAL),
                                   dlerror().map { String(cString: $0) } ?? "dlopen failed")
        defer { dlclose(handle) }
        let sym = try XCTUnwrap(dlsym(handle, "avfilter_get_by_name"))
        typealias GetByName = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
        let getByName = unsafeBitCast(sym, to: GetByName.self)
        XCTAssertNotNil(getByName("bs2b"), "vendored libavfilter lost bs2b — wrong flavour or wrong image")
        XCTAssertNotNil(getByName("ladspa"), "vendored libavfilter lacks ladspa — rebuild with --enable-ladspa")
    }
```

- [ ] **Step 2: Run it and confirm it fails against the current vendor**

Run: `swift test --filter LibmpvLinkageTests`
Expected: `testVendoredAvfilterHasLadspaAndBs2b` FAILS on the `ladspa` assertion only. The `bs2b` assertion passes. If `bs2b` also fails, the test is loading the wrong image, so stop and investigate.

- [ ] **Step 3: Replace the dylibs**

```bash
cd /Users/gergely/git/rp-player
T=$(mktemp -d) && tar -xzf ~/git/libmpv-darwin-build/result/libmpv-libs_develop_macos-universal-audio-encodersgpl.tar.gz -C "$T"
NEWLIB=$(dirname "$(find "$T" -name libmpv.dylib | head -1)")
diff <(ls Vendor/libmpv/lib | sort) <(ls "$NEWLIB" | grep '\.dylib$' | sort)   # expect: no output
cp "$NEWLIB"/*.dylib Vendor/libmpv/lib/
chmod u+w Vendor/libmpv/lib/*.dylib
```

If the `diff` shows any difference in the dylib set, stop and report it. The constraint is the same 16 files.

Also confirm that the header did not change:

```bash
NEWHDR=$(find "$T" -name client.h | head -1); [ -n "$NEWHDR" ] && diff "$NEWHDR" Vendor/libmpv/include/mpv/client.h && echo "client.h unchanged"
```

- [ ] **Step 4: Rewrite install names and re-sign (from `Vendor/libmpv/README.md`)**

```bash
cd /Users/gergely/git/rp-player/Vendor/libmpv/lib
for f in *.dylib; do
    otool -L "$f" | grep -oE "@rpath/lib[a-zA-Z0-9_-]+\.dylib" | sort -u \
    | while read dep; do
        base=$(basename "$dep")
        if [ -f "./$base" ]; then
            install_name_tool -change "$dep" "@loader_path/$base" "$f" \
                < /dev/null 2>/dev/null
        fi
      done
done
for f in *.dylib; do codesign --force --sign - "$f"; done
```

- [ ] **Step 5: Verify load commands, signatures and slices (Review Focus 1, 2, 3, 5)**

```bash
cd /Users/gergely/git/rp-player/Vendor/libmpv/lib
# 1: sibling refs are @loader_path; the only @rpath entry per dylib is its own install name
for f in *.dylib; do n=$(otool -L "$f" | tail -n +2 | grep -c "@rpath/"); [ "$n" -le 1 ] || echo "BAD rpath refs in $f"; done
# 2: no absolute nix-store (or other non-system) dependencies
otool -L *.dylib | grep -vE '^\S|@loader_path|@rpath|/usr/lib/|/System/' && echo "BAD: unexpected dependency above" || echo "deps OK"
# 5: signatures
for f in *.dylib; do codesign --verify "$f" || echo "BAD signature $f"; done
# 3: both slices, ladspa in both
for f in *.dylib; do lipo -archs "$f" | grep -q x86_64 && lipo -archs "$f" | grep -q arm64 || echo "BAD slices $f"; done
for a in arm64 x86_64; do strings -arch $a libavfilter.dylib | grep -qx ladspa && echo "$a ladspa OK" || echo "BAD $a no ladspa"; done
```

Expected: no `BAD` lines, `deps OK`, `arm64 ladspa OK` and `x86_64 ladspa OK`.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter LibmpvLinkageTests`
Expected: both tests PASS. `testReportsExpectedApiVersion` still reports 2.1.

Run: `swift test`
Expected: all tests pass. The count is the previous count (606) + 1 = **607**. Record the exact number from the output for Task 3.

- [ ] **Step 7: Playback and filter smoke (Review Focus 4)**

```bash
cd /Users/gergely/git/rp-player
swift run RPSmoke --probe-filters
```

Expected: every `set-af probes` line reads `OK` (equalizer, lowshelf, highshelf, volume, crossfeed, bs2b).

```bash
swift run RPSmoke   # streams mp3-320; stop with Ctrl-C after audio is confirmed playing
```

Expected: the stream starts and plays, with no dyld errors and no `No such filter`. In a non-interactive context, run it with `timeout 20 swift run RPSmoke`. Pass criterion: the log shows playback started (`playback-restart` / audio reconfig) and no errors.

- [ ] **Step 8: Regenerate checksums**

```bash
cd /Users/gergely/git/rp-player/Vendor/libmpv
shasum -a 256 include/mpv/client.h lib/*.dylib > SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

Expected: every line reports `OK`, and the `client.h` hash is unchanged (`287181025de3…`).

- [ ] **Step 9: Commit**

```bash
cd /Users/gergely/git/rp-player
git add Vendor/libmpv/lib Vendor/libmpv/SHA256SUMS Tests/RPPlayerTests/Player/LibmpvLinkageTests.swift
git commit -m "build(libmpv): re-vendor with the FFmpeg ladspa filter enabled

Rebuilt from the gvajda/libmpv-darwin-build fork with --enable-ladspa in
audio-encodersgpl. Install names rewritten to @loader_path and re-signed
as before. LibmpvLinkageTests now pins both bs2b and ladspa."
```

---

### Task 3: Docs, app-bundle smoke, fork push

**Files:**
- Modify: `Vendor/libmpv/README.md`
- Modify: `docs/pr-history.md`
- Modify: `docs/test-counts.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the Task 1 fork commits, and the Task 2 test count.
- Produces: nothing code-facing.

- [ ] **Step 1: App-bundle smoke (Review Focus 5)**

```bash
cd /Users/gergely/git/rp-player
./scripts/make-app.sh debug
codesign --verify --deep "build/RP Player.app" && echo "bundle signature OK"
otool -L "build/RP Player.app/Contents/Frameworks/libavfilter.dylib" | grep -c "@loader_path"
```

Expected: the script succeeds, the bundle signature is OK, and the `@loader_path` count is ≥ 1. Launching the app by hand to hear a stream is done by the user during review. Say so in the task report instead of claiming it.

- [ ] **Step 2: Update `Vendor/libmpv/README.md`**

In the **Source** section, change the fork parenthetical to:

```markdown
- Origin: forked from <https://github.com/media-kit/libmpv-darwin-build>
  (built from `develop` branch with `--enable-libbs2b` and `--enable-ladspa`
  added to the `audio-encodersgpl` FFmpeg variant — see the fork at
  <https://github.com/gvajda/libmpv-darwin-build>). Build target:
  `make TARGET=mk-out-archive-libs-macos-universal-audio-encodersgpl`.
```

After the paragraph that starts "`bs2b` is the Bauer stereo-to-binaural filter…", add:

```markdown
`ladspa` is FFmpeg's LADSPA host filter (PR 47). It needs only the
`ladspa.h` header at build time (LADSPA SDK 1.1, LGPL-2.1, vendored in the
fork at `nix/packages/mk-pkg-ffmpeg/ladspa/`) and `dlopen`s plugins at
runtime, so it adds no dylib here. RP Player uses it to host its own
bridge library, which forwards audio to an Audio Unit (see
`docs/superpowers/specs/2026-09-23-au-plugin-support-design.md`).
`LibmpvLinkageTests.testVendoredAvfilterHasLadspaAndBs2b` fails if a
re-vendor drops either filter.
```

- [ ] **Step 3: Update `docs/pr-history.md`**

Add a row after the PR 46 row, using the table's existing column format (`| PR | branch | status | summary |`):

```markdown
| 47   | claude/pr47-au-plugins | ⏳ | libmpv re-vendored with FFmpeg `--enable-ladspa` (fork `gvajda/libmpv-darwin-build`: LADSPA SDK 1.1 header vendored under `mk-pkg-ffmpeg/ladspa/`, `-I` via meson `c_args` for `encodersgpl`; also commits the previously uncommitted PR 38 bs2b fork change). No new dylib (af_ladspa dlopens at runtime). Install names rewritten + re-signed per `Vendor/libmpv/README.md`. `LibmpvLinkageTests.testVendoredAvfilterHasLadspaAndBs2b` dlopens the vendored `libavfilter` and asserts `avfilter_get_by_name` finds `bs2b` and `ladspa`. Foundation for Audio Unit plugin support (spec `2026-09-23-au-plugin-support-design.md`, PRs 47–50). Also adds the AU research note + design spec. <N> tests. |
```

Replace `<N>` with the exact count from Task 2 Step 6.

- [ ] **Step 4: Update `docs/test-counts.md`**

Append one line in the file's existing format, using the exact count from Task 2 Step 6. The last line is PR 46's `- 2026-09-05: 600 → 606 (+6) — …`. Append this, using the real date and count:

```markdown
- 2026-09-23: 606 → 607 (+1) — PR 47 libmpv with FFmpeg ladspa filter. `LibmpvLinkageTests`: vendored libavfilter has ladspa and bs2b (1).
```

- [ ] **Step 5: Update `CLAUDE.md` Current state**

Replace the **Next up** bullet with:

```markdown
- **In progress:** Audio Unit plugin support, PRs 47–50 (spec `docs/superpowers/specs/2026-09-23-au-plugin-support-design.md`). PR 47 = libmpv with FFmpeg `ladspa` filter. Next: PR 48 = `RPBridge` LADSPA→AU bridge dylib + `PluginBridge`.
```

Leave the **Last merged** and **Released** bullets alone until the PR merges.

- [ ] **Step 6: Commit the docs**

```bash
cd /Users/gergely/git/rp-player
git add Vendor/libmpv/README.md docs/pr-history.md docs/test-counts.md CLAUDE.md docs/superpowers/plans/2026-09-23-pr47-libmpv-ladspa.md
git commit -m "docs: PR 47 libmpv ladspa re-vendor"
```

- [ ] **Step 7: Controller only — ask before pushing**

Ask the user before running either of these. Both are outward-facing, and the fork push triggers the fork's full CI matrix:

```bash
git -C ~/git/libmpv-darwin-build push origin main
git -C /Users/gergely/git/rp-player push -u origin claude/pr47-au-plugins
```
