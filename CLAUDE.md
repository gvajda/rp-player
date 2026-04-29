# RP Player — Agent Context

## "Continue work" means: write the PR 4 plan, get approval, execute it.

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 13, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode via libmpv). Source of truth: `docs/DESIGN.md`.

---

## PR status

| PR | Branch | Status | Contents |
|----|--------|--------|----------|
| 1 | merged to main | ✅ | Scaffold, AppLogger, RotatingFileSink, AppSettings, ConfigStore |
| 2 | merged to main | ✅ | RpApiClient, ApiModels, CookieProvider, StubURLProtocol, fixtures |
| 3 | merged to main | ✅ | KeychainStore, KeychainCookieProvider, LoginWindowController |
| 4 | **next** | ⬜ | AudioDeviceCatalog |
| 5 | pending | ⬜ | PlayerEngine (libmpv Swift actor) |
| 6 | pending | ⬜ | PlaybackCoordinator |
| 7 | pending | ⬜ | AppKit shell (NSStatusItem + NSPopover) |
| 8 | pending | ⬜ | MiniPlayerView (SwiftUI) |
| 9 | pending | ⬜ | NotificationCenterWrapper + AlbumArtCache |
| 10 | pending | ⬜ | SettingsView |
| 11 | pending | ⬜ | AppContainer (composition root) |
| 12 | pending | ⬜ | Distribution CI workflow |

PR 4 scope (from DESIGN.md §4): `AudioDeviceCatalog` — lists CoreAudio output devices (name, UID, transport type). Watches `kAudioHardwarePropertyDevices` for hot-plug changes, emits updates via `AsyncStream<[AudioDevice]>`. Used by `SettingsView` for the output device picker.

---

## Workflow conventions (locked)

- **Plan cadence:** just-in-time — write plan for next PR, get approval, execute, repeat.
- **Execution:** `superpowers:subagent-driven-development` (fresh subagent per task, spec + quality review after each).
- **Worktrees:** sibling-directory pattern — `/Users/gergely/git/rp-player-pr04`, etc.
- **Merge strategy:** fast-forward only (`git merge --ff-only`) to main after all reviews pass.
- **Test command:** `swift test`
- **Build command:** `swift build`

---

## Key technical decisions (non-obvious, not in code)

- `kSecUseDataProtectionKeychain: true` causes `errSecMissingEntitlement (-34018)` in unsigned `swift test` processes on macOS 26 beta (Darwin 25.3.0). Do not add it until the app is codesigned.
- `WKHTTPCookieStoreObserver` callbacks are not `@MainActor` — always call `getAllCookies(_:)` (completion-handler form, macOS 13 compat) on the delivery thread before hopping to `@MainActor`. Do not capture `WKHTTPCookieStore` across actor boundaries.
- `ConfigStore.changes` is an actor-isolated `async` property (not `nonisolated`) — registration is synchronous within actor isolation to eliminate a race window.
- `JSONDecoder.rpDecoder` is a shared `static let` (snake_case → camelCase). Use it for all RP API decodes.
- Query items in `LiveRpApiClient` are sorted alphabetically — `StubURLProtocol` test URLs must match this order.
- `GetBlock.chan` is `String` (live API returns `"0"`, not `Int`). `GetBlock.endEvent` is `String?` (same reason).
- `SongInfo.songId` has a custom `init(from:)` that handles both `Int` and `String` JSON values.

---

## Comment policy (strict)

- No comments unless the WHY is non-obvious (hidden constraint, workaround, subtle invariant).
- No multi-line docstrings. Single `//` line max.
- Code/commit/PR text: write normal English.

---

## Test counts by PR

- After PR 1: 13 tests
- After PR 2: 18 tests
- After PR 3: 35 tests
- After PR 4: TBD

---

## Plan files

All plans live in `docs/superpowers/plans/`. Written just-in-time before each PR's execution.
