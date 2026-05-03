# RP Player

Bit-perfect Radio Paradise player for macOS — menu-bar app with desktop notifications and in-app song rating.

## Download

Grab the latest `RP Player-<version>.zip` from [Releases](../../releases). Unzip and drag `RP Player.app` to `/Applications`.

**First launch:** macOS blocks apps that are not notarized. Right-click `RP Player.app` in Finder and choose **Open**, then confirm.

Or via terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/RP Player.app"
open "/Applications/RP Player.app"
```

## Build from source

Requires Xcode 16+ on macOS 14+.

```sh
swift build
swift test
```

## Status

Pre-alpha. See `docs/DESIGN.md` for the full design, `docs/LEGACY.md` for the relationship to the predecessor Windows app.

## License

MIT — see `LICENSE`.

## History

This project supersedes the Windows tray app [RP_Notify](https://github.com/gvajda/radio-paradise-song-notification). Scope diff in `docs/LEGACY.md`.
