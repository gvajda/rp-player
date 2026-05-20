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
`@rpath/libbs2b.dylib` dependency).

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
