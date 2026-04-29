# Legacy: RP_Notify (Windows)

This project supersedes [RP_Notify](https://github.com/gvajda/radio-paradise-song-notification), a Windows tray app that displayed Radio Paradise song notifications and accepted ratings.

## Scope diff

**Dropped from RP_Notify**

- Tracker mode (polling `api/nowplaying*` and `api/sync_v2` to follow external sessions).
- foobar2000 (`foo_beefweb`) integration.
- MusicBee (`MusicBeeIPC`) integration.

**Added in RP Player**

- In-app audio playback via libmpv.
- Bit-perfect output: CoreAudio hog mode + integer mode passthrough to a user-selected output device.
- Skip-forward within Radio Paradise's 4-song block API.

## Source of truth

[`DESIGN.md`](DESIGN.md) is the source of truth for the new project. The legacy code in [`legacy/`](legacy/) is reference material only — do not port the C# line-by-line.
