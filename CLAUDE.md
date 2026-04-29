# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

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
| 4 | merged to main | ✅ | AudioDeviceCatalog |
| 5a | merged to main | ✅ | libmpv vendoring + RPSmoke CLI |
| 5b | merged to main | ✅ | PlayerEngine (libmpv Swift actor) |
| 6 | **next** | ⬜ | PlaybackCoordinator |
| 7 | pending | ⬜ | AppKit shell (NSStatusItem + NSPopover) |
| 8 | pending | ⬜ | MiniPlayerView (SwiftUI) |
| 9 | pending | ⬜ | NotificationCenterWrapper + AlbumArtCache |
| 10 | pending | ⬜ | SettingsView |
| 11 | pending | ⬜ | AppContainer (composition root) |
| 12 | pending | ⬜ | Distribution CI workflow |

PR 6 scope: orchestrate playback via `LivePlaybackCoordinator` actor — fetches blocks, drives `PlayerEngine`, tracks song boundary, prefetches the next block when `currentSongIndex == lastIndex` and remaining time < 10 s, and swaps gaplessly on EOF. Out of scope (deferred to a follow-up PR): network retry-with-backoff, hog-mode fallback, auth-expiry detection, block-expiration recovery after long pause.

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
- libmpv is vendored in `Vendor/libmpv/` from `media-kit/libmpv-darwin-build` v0.6.3 (audio-default, universal). The public `client.h` is pinned to mpv v0.36.0 (commit `3996724d3fa1c51cc7998f3de2e22e2c99e6d270`). Reported API version: 2.1. Refreshing the dylibs requires updating both the binaries and `client.h` to a matching upstream tag, then bumping the assertion in `LibmpvLinkageTests`.
- `RPSmoke` and `RPPlayerTests` link libmpv with two `@loader_path`-relative rpaths baked in (3-deep for executables, 6-deep for xctest bundles). No `DYLD_LIBRARY_PATH` is needed for `swift test` or `swift run RPSmoke`. Production `.app` packaging (PR 12) will install dylibs under `Contents/Frameworks/` and use a single `@loader_path/../Frameworks` rpath instead.
- All vendored dylibs use `@rpath/<name>.dylib` install names so a single rpath into `Vendor/libmpv/lib/` resolves the entire transitive graph. Verify after refresh: `otool -D Vendor/libmpv/lib/*.dylib` — every line after the path must read `@rpath/<name>.dylib`. If a future upstream rebuild ships absolute or `@executable_path/...` install names, the rpath approach silently breaks; rewrite via `install_name_tool -id` before committing.
- `LibmpvPlayerEngine` runs a single detached event-pump task that calls `mpv_wait_event` with a 0.5s timeout in a loop. The pump exits when `mpv_terminate_destroy` triggers `MPV_EVENT_SHUTDOWN` or when the actor cancels the task. Shutdown ordering is `mpv_wakeup → await pumpTask → mpv_terminate_destroy → emit synthetic .shutdown → finish continuations` because `mpv_terminate_destroy` does not reliably wake an in-flight `mpv_wait_event` on the same handle. mpv's client API is thread-safe except for `mpv_wait_event` (only one thread at a time) — the pump is the only caller.
- `LibmpvPlayerEngine` cannot start its detached pump task from inside `init` because Swift 6.2 strict concurrency forbids capturing `self` (even `[weak self]`) into a `Task.detached` closure during a non-isolated init. Bootstrap pattern: `init` schedules `Task { await self.startPump() }` (an unstructured Task on the actor's executor), and `startPump()` then spawns the detached pump. The handle is wrapped in a private `HandleBox: @unchecked Sendable` to cross the detached-task boundary.
- `LivePlaybackCoordinator` triggers the next-block prefetch when `currentSongIndex == orderedSongs.count - 1` AND `(totalDurationSeconds - currentPositionSeconds) < 10.0`. The 10-second window matches DESIGN.md §5.6 and gives the network round-trip plenty of margin before EOF. Only one prefetch per block (guarded by `prefetchedBlock == nil && prefetchTask == nil`).
- `LivePlaybackCoordinator.play(channelId:)` issues the cue tune-in by waiting for `PlayerEvent.fileLoaded`, then calling `engine.seek(to: cueSeconds)`. The cue seek is bypassed for prefetch-driven block swaps and for skip-forward-past-last-song — both intentionally start the new block from offset 0.
- `LivePlaybackCoordinator` lazy-subscribes to `PlayerEngine.events` from inside `play()` via `await ensureEventSubscription()`, NOT from `init`. This is deterministic: by the time `play()` issues the engine command, the actor has already registered an `events` continuation, so events fired by the engine cannot race ahead of the subscription. The init-time `Task { ... }` bootstrap pattern was rejected here because subscription order matters.

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
- After PR 4: 47 tests
- After PR 5a: 48 tests
- After PR 5b: 67 tests
- After PR 6: 93 tests

---

## Plan files

All plans live in `docs/superpowers/plans/`. Written just-in-time before each PR's execution.
