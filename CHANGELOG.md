# Changelog

All notable changes to RP Player are listed here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Section labels: `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`. Only include the sections that apply.

## [Unreleased]

## [v0.5.2] - 2026-05-08

### Changed

- Update panel renders the full release notes (was: truncated to 5 lines). Body is now scrollable and renders Markdown headings (`##`, `###`), bullet lists (`-`, `*`), and inline formatting (`**bold**`, `*italic*`, `` `code` ``). Panel grows to 460×540 to fit the longer body comfortably.

### Fixed

- Update panel line breaks were collapsed because `AttributedString(markdown:)` defaults to inline-only parsing. Replaced with a per-line renderer that splits on `\n`, treats blank lines as spacing, recognises heading + bullet prefixes, and applies inline Markdown to each line.

## [v0.5.1] - 2026-05-08

### Added

- `CHANGELOG.md` (this file). Release notes are now authored here and consumed by the GitHub Actions release job (replaces the auto-generated commit-list notes).

### Changed

- All panel-open paths now dismiss the popover "Update Available" button. Previously only the popover-button click dismissed; menu and Settings paths left the button visible until the next state propagation.
- Settings → Updates section moved between *Upcoming Program* and *Account*.

### Fixed

- Race in Settings → *Open Update…* that opened the panel with the stale cached release info while the version line raced ahead with the new one. The panel now reads the freshest `ReleaseInfo` directly from `UpdateChecker.currentState` after `checkNow` returns instead of going through the `MiniPlayerViewModel` published prop.

## [v0.5.1-rc.1] - 2026-05-08

Pre-release. Same content as v0.5.1; tagged for testing the prerelease filter in `UpdateChecker` (UpdateChecker excludes `prerelease == true` releases from the available-update notification).

## [v0.5.0] - 2026-05-08

### Added

- Update Checker. Automatic GitHub release polling on startup + every 24 hours; notify-only (the user clicks through to the `.dmg` download in the browser — no auto-install, no Sparkle).
- Settings → Updates section: toggle (default ON), *Check Now* / *Open Update…* button, *Last checked* + current-version status lines.
- Mini-player popover: "Update Available" button replaces "RP Player" text when an update is available; dismisses on click and stays dismissed until a higher release ships.
- Hamburger menu: sticky *Update Available…* item between *About* and *Quit*, visible until the running version matches the latest release.
- Update panel: title, relative published-at date, ~5-line markdown release-body preview, *Later* / *View Full Notes* / *Download DMG* buttons. Esc and outside-click dismiss.
- `AppSettings.updateCheckEnabled` (default `true`), `lastUpdateCheckAt`, `dismissedUpdateVersion`, `cachedLatestRelease` persisted across launches.
