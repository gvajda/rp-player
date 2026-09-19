# Upcoming Program — Design Spec

**Date:** 2026-05-03  
**Target PR:** 19

---

## Context

RP Player currently shows what is playing now on the active channel. Users have no way to browse what is coming up across all channels before deciding to switch. This feature adds an "Upcoming Program" window: a read-only, multi-column table showing the next N songs per channel, fetched on demand.

---

## Feature Overview

- New regular `NSWindow` (closeable, independent of the main popover) titled "Upcoming Program".
- Opened via a new "Upcoming Program…" item in the hamburger menu inside the popover.
- Each column represents one enabled channel; columns scroll horizontally.
- Each row is a compact song card: flush album art left, ambient colour gradient background, title + artist + album text, and `★ n` rating when the user has rated the song.
- Data loads on window open and on manual refresh (↻ button). No automatic refresh.
- Skeleton loading state shown while fetching.
- Row count (3–10) and visible channels are configurable in Settings → Upcoming Program.

---

## Architecture

### New types

**`UpcomingProgramViewModel`** — `@MainActor final class: ObservableObject`

```swift
init(api, albumArtCache, configStore, paletteExtractor)
@Published var columns: [UpcomingColumn]
@Published var isLoading: Bool
@Published var lastUpdated: Date?
@Published var errorMessage: String?
func load() async          // fetch all enabled channels concurrently, then load art
func refresh()             // re-runs load()
```

- `load()` uses `withTaskGroup` to call `api.play(channel:bitrate:event:0 action:.start audioType:nil episodeId:nil sliceNum:nil)` for each enabled channel concurrently.
- Fetched block songs are extracted with `BlockSongs.orderedSongs(from:)` and capped at `upcomingRowCount`.
- Art loading and palette extraction run concurrently after all blocks are fetched (same pattern as `MiniPlayerViewModel.loadArt`).
- On any per-channel fetch error: that column gets an empty `songs` array and `errorMessage` is set to a generic string; other columns still render.
- `bitrate` is pulled once at `load()` start via `await configStore.settings.bitrate` (same pull pattern as `LivePlaybackCoordinator`).
- `upcomingRowCount` and `upcomingEnabledChannelIds` are also read from `configStore.settings` at `load()` start.

**`UpcomingColumn`** — `struct, Identifiable`

```swift
let id: Int            // channel.chan as Int
let channel: Channel
let songs: [UpcomingSongRow]
```

**`UpcomingSongRow`** — `struct, Identifiable`

```swift
let id: String              // PlayListSong.songId
let song: PlayListSong
var art: NSImage?
var ambientColor: Color     // default Color(nsColor: .windowBackgroundColor)
```

**`UpcomingProgramView`** — SwiftUI root view

- `ScrollView(.horizontal)` → `LazyHStack(spacing: 6)` of `UpcomingColumnView`.
- Shows skeleton (animated grey placeholder cards) while `isLoading`.
- Toolbar-style header row inside the scroll area is replaced by a per-column header `Text` above each `LazyVStack`.
- Window title bar provided by AppKit; contains a native toolbar with the ↻ refresh button and "Updated X ago" / "Loading…" label.

**`UpcomingColumnView`** — column header + `VStack(spacing: 4)` of `UpcomingSongCardView`

**`UpcomingSongCardView`** — single song card

- `HStack(spacing: 0)`, height 68 pt, `cornerRadius(8)`, `clipped()`.
- Left: album art `Image`, 68×68, `scaledToFill`, `clipped` — fully flush (no inset, no radius on the image itself; card's own `cornerRadius` + `clipped()` rounds the outer left corners).
- Right: `VStack(spacing: 0)` with `LinearGradient(colors: [ambientColor.opacity(0.28), Color(nsColor:.windowBackgroundColor)], startPoint: .leading, endPoint: .trailing)` background.
  - Title row: `HStack` — title `Text` (11pt semibold, `lineLimit(1)`) + `★ n` `Text` (10pt, `.yellow`) when `Int(song.userRating ?? "") ?? 0 > 0`.
  - Artist: 10pt, `.secondary`, `lineLimit(1)`.
  - Album: 9pt, `.secondary`, `lineLimit(1)`, shown only when `song.album` is non-nil and non-empty.
- No interaction (read-only display; no rating action, no tap-to-play).

**`UpcomingWindowController`**

- Wraps `NSHostingController<UpcomingProgramView>` in an `NSWindow` with `[.titled, .closable, .miniaturizable, .resizable]` style mask.
- Initial size: `(720, 480)`. Minimum size: `(480, 300)`.
- Remembers frame between opens via `setFrameAutosaveName("UpcomingProgram")`.
- `func show()` — `makeKeyAndOrderFront(nil)`.
- No global-click-monitor needed (standard window dismiss behaviour).

### Changes to existing types

**`AppSettings`** — two new fields:

```swift
var upcomingRowCount: Int = 5
var upcomingHiddenChannelIds: [Int] = []   // channels the user has unchecked
```

Default is 5 rows, all channels shown (blocklist model: empty = nothing hidden). Chan 42 and 99 are excluded from the UI regardless of this value, not stored here.

Backward-compat: old JSON without these keys decodes to the defaults above.

**`SettingsView` / `SettingsViewModel`** — new "Upcoming Program" `Section`:

- **Row count** — `Stepper("Rows: \(upcomingRowCount)", value: $upcomingRowCount, in: 3...10)`.
- **Channel checkboxes** — one `Toggle` per channel from `listChannels()` result, excluding chan IDs 42 and 99. Checked = channel is visible. Toggle mutates `upcomingHiddenChannelIds` in `configStore`.
- `SettingsViewModel` fetches channels via `api.listChannels()` from `start()` (already done for the channel picker; reuse the same `channels` array, filtered to exclude 42/99).

**`LiveAlbumArtCache`** — bump `maxFiles` from 20 to 100 (unchanged `maxBytes = 10 MB`).

**`MiniPlayerView` hamburger menu** — add `Button("Upcoming Program…") { upcomingAction() }` as a new item in the first `Section` alongside "Settings…". `upcomingAction` is a `@MainActor () -> Void` closure injected into `MiniPlayerViewModel` (same late-binding pattern as `showPopoverIfNeeded`).

**`AppContainer`** — new stored property `upcomingWindowController: UpcomingWindowController`. Created in `live()` and wired: `viewModel.upcomingAction = { [weak self] in self?.upcomingWindowController.show() }`.

---

## API Usage

Block fetches use a **restored** `api/get_block` endpoint — a read-only fetch that carries no playback-started telemetry side-effect. `api/play` must not be used here because it records a "playback started" event on the server.

`RpApiClient` gains a new method (removed in PR 13, re-added here):

```swift
func getBlock(channel: Int, bitrate: Int) async throws -> GetBlock
```

`LiveRpApiClient` implementation:

```text
GET api/get_block?bitrate=X&chan=N&info=true
```

Query items sorted alphabetically (consistent with existing `LiveRpApiClient` convention). `info=true` is always sent so song metadata and user ratings are included. No `event` parameter — always returns the block from the beginning (song index 0).

`UpcomingProgramViewModel.load()` calls `api.getBlock(channel:bitrate:)` for each enabled channel concurrently via `withTaskGroup`.

- `BlockSongs.orderedSongs(from:)` sorts the `[String: PlayListSong]` dict by integer key — songs are already in playback order.
- Songs are capped at `upcomingRowCount` — `Array(orderedSongs.prefix(upcomingRowCount))`.
- Promo songs (`song.type == "P"` or `song.songId == "0"`) are displayed like any other song; the upcoming view is read-only so no rating guard is needed.

---

## Data Flow

```text
window.show()
  → viewModel.load()
      → isLoading = true, columns = []
      → withTaskGroup: api.play(chan=0), api.play(chan=1), ... (all enabled channels, parallel)
      → for each result: BlockSongs.orderedSongs → prefix(rowCount) → UpcomingSongRow stubs
      → withTaskGroup: albumArtCache.image(for:) + paletteExtractor.extract(from:) per row (parallel)
      → columns = fully assembled (art + colours included)
      → isLoading = false, lastUpdated = Date()   ← skeleton disappears, all cards render at once

refresh button tap
  → viewModel.refresh() → same as load()
```

---

## Settings Integration

`UpcomingProgramViewModel.load()` reads settings at call time:

```swift
let settings = await configStore.settings
let rowCount = settings.upcomingRowCount
let hiddenIds = Set(settings.upcomingHiddenChannelIds)
let bitrate = settings.bitrate
let channels = await api.listChannels()
let enabledChannels = channels.filter { 
    guard let id = Int($0.chan) else { return false }
    return id != 42 && id != 99 && !hiddenIds.contains(id)
}
```

No live-reactive subscription — settings take effect on next refresh.

---

## Testing

New test targets / additions:

- **`StubRpApiClient`** gains a `getBlock` handler closure (same pattern as existing `playHandler`).
- **`UpcomingProgramViewModelTests`**: stub `api`, `albumArtCache`, `paletteExtractor`, `configStore`.
  - `testLoadPopulatesColumns` — verifies column count and song count match fixture + row limit.
  - `testLoadSkipsHiddenChannels` — set `upcomingHiddenChannelIds = [1]`, verify channel 1 absent.
  - `testLoadSetsIsLoadingThenClears` — isLoading true during fetch, false after.
  - `testLoadSetsLastUpdated` — `lastUpdated` is non-nil after successful load.
  - `testRefreshReloadsData` — calling `refresh()` replaces columns with fresh data.
  - `testChannelFetchErrorProducesEmptyColumn` — one stub channel throws; others succeed; `errorMessage` set.

- **`AppSettingsTests`**: decode JSON without `upcomingRowCount`/`upcomingHiddenChannelIds` keys → defaults to 5 and `[]`.

- **`LiveAlbumArtCacheTests`**: existing test updated to reflect `maxFiles = 100`.

- Manual UI verification: open Upcoming Program window, confirm skeleton → cards, ↻ refreshes, Settings row-count + channel-filter take effect on next open/refresh.

---

## Files to create

| File | Purpose |
| ------ | ------- |
| `Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift` | VM |
| `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift` | SwiftUI root + column + card views |
| `Sources/RPPlayer/Upcoming/UpcomingWindowController.swift` | NSWindow wrapper |
| `Tests/RPPlayerTests/UpcomingProgramViewModelTests.swift` | Unit tests |

## Files to modify

| File | Change |
| ------ | ------ |
| `Sources/RPPlayer/Api/RpApiClient.swift` | Re-add `getBlock(channel:bitrate:)` to protocol + `LiveRpApiClient` |
| `Sources/RPPlayer/Config/AppSettings.swift` | Add `upcomingRowCount`, `upcomingHiddenChannelIds` |
| `Sources/RPPlayer/Shell/SettingsView.swift` | Add "Upcoming Program" settings section |
| `Sources/RPPlayer/Shell/SettingsViewModel.swift` | Expose row count + hidden channel IDs + channel list |
| `Sources/RPPlayer/Shell/MiniPlayerView.swift` | Add "Upcoming Program…" hamburger menu item |
| `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` | Add `upcomingAction: @MainActor () -> Void` closure |
| `Sources/RPPlayer/Notifications/AlbumArtCache.swift` | Bump `maxFiles` to 100 |
| `Sources/RPPlayer/App/AppContainer.swift` | Wire `UpcomingWindowController`, bind `upcomingAction` |
| `Tests/RPPlayerTests/AppSettingsTests.swift` | Backward-compat decode tests |
| `Tests/RPPlayerTests/LiveAlbumArtCacheTests.swift` | Update `maxFiles` assertion |
