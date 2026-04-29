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
