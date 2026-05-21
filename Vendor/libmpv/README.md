# Vendored libmpv

Self-contained libmpv runtime for RP Player. macOS universal binary
(`arm64` + `x86_64`), audio-only build, dynamically linked.

## Source

- Tarball: `libmpv-libs_develop_macos-universal-audio-encodersgpl.tar.gz`
- Origin: forked from <https://github.com/media-kit/libmpv-darwin-build>
  (built from `develop` branch with `--enable-libbs2b` added to the
  `audio-encodersgpl` FFmpeg variant — see the fork at
  <https://github.com/gvajda/libmpv-darwin-build>).
- License: **GPL-2.0-or-later** — built with FFmpeg `--enable-gpl`. The MIT
  source license of RP Player is unchanged, but distributing the bundled
  `.app` triggers GPL terms (provide source on request, no proprietary
  derivative-by-distribution). `libbs2b` itself is MIT — no new license
  conflict.

This variant ships the full FFmpeg audio filter set (`volume`, `equalizer`,
`lowshelf`, `highshelf`, `crossfeed`, `bs2b`, `bass`, `treble`, `biquad`,
`firequalizer`, `headphone`, …) which parametric EQ (PR 35), crossfeed
(PR 36), and the BS2B crossfeed upgrade depend on. The previous
`audio-default` flavour stripped all of these except `equalizer`, so EQ
presets with shelves or preamp failed at filter init.

`bs2b` is the Bauer stereo-to-binaural filter linked via `libbs2b.dylib`
(also shipped in `lib/`, loaded indirectly via `libavfilter.dylib`'s
`@loader_path/libbs2b.dylib` dependency).

## Install-name rewrite (REQUIRED on every re-vendor)

The fork's nix build emits dylibs with two problems:

1. Sibling-dylib references use `@rpath/lib<x>.dylib` (e.g. `libmpv.dylib`
   references `@rpath/libavfilter.dylib`).
2. `libmpv.dylib` and `libfftools-ffi.dylib` carry baked-in `LC_RPATH`
   entries pointing at the build-host's absolute nix-store path
   (e.g. `/nix/store/…audio-default-6.0/lib/`). On some hosts this dir
   exists from a prior fork build of a different flavour and contains a
   stripped-down `libavfilter.dylib` (no bs2b, only equalizer). If the
   consumer's own `@rpath` fails to resolve cleanly, dyld falls through to
   the baked-in nix-store rpath and silently loads the WRONG
   `libavfilter.dylib` — causing cold-start filter-graph init errors like
   `AVFilterGraph: No such filter: 'volume'`.

Fix: rewrite every sibling reference to `@loader_path/lib<x>.dylib` so the
dylib resolves siblings from its own directory, bypassing rpath search
entirely. Self-references (each dylib's own install_name) stay
`@rpath/…` so consumers can still locate them via standard rpath search.

Run this after every fresh tarball drop (before re-signing + regenerating
SHA256SUMS):

```sh
cd Vendor/libmpv/lib
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

Verify: `otool -L Vendor/libmpv/lib/libavfilter.dylib | grep @rpath` should
only show the dylib's own self-install_name (e.g.
`@rpath/libavfilter.dylib`), nothing else.

The poisoned nix-store `LC_RPATH` entries are left in place — once all
sibling references are `@loader_path/…`, dyld never consults the rpath
chain for siblings and the bad entries become inert. (They could be
stripped via `install_name_tool -delete_rpath`, but it requires per-arch
processing on the universal binary and offers no runtime benefit.)

Upstream fix (TODO): the fork's `mk-pkg-libmpv` Nix derivation should emit
clean install names — either `@loader_path/lib<x>.dylib` references
directly, or `@rpath/…` references with no leftover absolute build-host
rpaths. Once upstream emits clean dylibs, this rewrite step can be
dropped.

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

```sh
cd Vendor/libmpv && shasum -a 256 -c SHA256SUMS
```
