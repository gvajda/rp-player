# RP Player

Bit-perfect Radio Paradise player for macOS — menu-bar app with desktop notifications and in-app song rating.

## Status

Pre-alpha. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full design and locked decisions, and [`docs/LEGACY.md`](docs/LEGACY.md) for the relationship to the predecessor Windows app.

## Build

Requires Xcode 15+ on macOS 13+.

```sh
swift build
swift test
```

A local `libmpv.dylib` is required to run the player; setup instructions live at `Vendor/libmpv/README.md` (added in PR 5). Until then, `swift build` succeeds without it because no module links against libmpv yet.

## License

MIT — see [`LICENSE`](LICENSE).

## History

This project supersedes the Windows tray app [RP_Notify](https://github.com/gvajda/radio-paradise-song-notification). Scope diff in [`docs/LEGACY.md`](docs/LEGACY.md).
