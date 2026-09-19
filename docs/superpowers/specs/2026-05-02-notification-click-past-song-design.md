# Notification Click → Past-Song Popover — Design

Date: 2026-05-02
Status: Approved (design phase)
Branch base: `main` (latest signed-app + notifications-working baseline).

## Goals

1. Clicking a song notification opens a popover for that exact song.
2. If the notification's song is currently playing → existing main popover.
3. Otherwise → new compact `PastSongView` popover with album art, title row (artist / title / album), and the existing rating dropdown. No channel row, no transport buttons, no progress bar.
4. Past-song view rates via `api.rate(songId:rating:)` (already exists).

## Non-goals

- No notification action buttons (no rating from the notification UI itself).
- No queue / history list.
- No persisted song registry — in-memory only.
- No "back to current" toggle in the past-song popover.

## Architecture

### Notification identifier

Format: `"\(UUID().uuidString)|\(songId)"`. Two segments, `|` separator. UUID prefix guarantees unique ids in `usernoted`'s store (so a re-played song doesn't replace a still-pending older notification). Suffix is the integer song id used by `api.rate` and `api.info`.

`LiveNotificationService.notify` gains an optional `identifierSuffix: String?` parameter. If provided, the request id becomes `"\(UUID().uuidString)|\(suffix)"`. Default `nil` keeps old behavior. `NotificationCoordinator.handle` always passes `np.song.songId`.

Decoder helper: `static func extractSongId(from requestIdentifier: String) -> String?` on `LiveNotificationService` — splits on `|`, returns the suffix if present and non-empty, else `nil`.

### Song registry

New `actor SongRegistry` in `Sources/RPPlayer/Notifications/SongRegistry.swift`:

```swift
public actor SongRegistry {
    private var ring: [(songId: String, song: PlayListSong)] = []
    private let capacity: Int

    public init(capacity: Int = 100) { self.capacity = capacity }

    public func record(_ song: PlayListSong) {
        // Move-to-front on duplicate id; FIFO eviction past capacity.
    }

    public func lookup(songId: String) -> PlayListSong? { … }
}
```

`NotificationCoordinator.handle` calls `await registry.record(np.song)` before notifying. In-memory only — does not survive an app restart.

### Click delegate + routing

New `@MainActor final class NotificationClickRouter: NSObject, UNUserNotificationCenterDelegate` in `Sources/RPPlayer/Notifications/NotificationClickRouter.swift`. Holds:

- `coordinator: any PlaybackCoordinator` (to read `nowPlaying.song.songId`)
- `registry: SongRegistry`
- `api: any RpApiClient` (for fallback fetch)
- `pastSongPresenter: @Sendable @MainActor (PlayListSong) -> Void`
- `mainPresenter: @Sendable @MainActor () -> Void`

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completion: @escaping () -> Void) {
    let songId = LiveNotificationService.extractSongId(
        from: response.notification.request.identifier)
    Task { @MainActor in
        defer { completion() }
        guard let songId else { return }
        if let np = await coordinator.nowPlaying, np.song.songId == songId {
            mainPresenter()
            return
        }
        if let cached = await registry.lookup(songId: songId) {
            pastSongPresenter(cached)
            return
        }
        guard let id = Int(songId) else { return }
        do {
            let info = try await api.info(songId: id)
            pastSongPresenter(PlayListSong(from: info))
        } catch {
            mainPresenter()
        }
    }
}
```

`AppContainer.live()` instantiates the router and assigns `UNUserNotificationCenter.current().delegate = router` (only when `Bundle.main.bundleIdentifier != nil`).

Routing decision: only one popover may be visible at a time. If the main popover is already shown when a past-song popover is requested, dismiss it first (and vice versa).

### `SongInfo → PlayListSong` adapter

Add `init(from info: SongInfo)` to `PlayListSong`:

- `songId`, `artist`, `title`, `album`, `userRating` map directly (1:1).
- `cover` ← `info.largeCover ?? info.medCover` (whichever non-nil).
- `duration` ← `info.length` if present, else `0`.
- All other fields: `nil` / defaults.

This keeps `PastSongView` polymorphic on a single `PlayListSong` value regardless of source.

### `PastSongPopoverController`

New file `Sources/RPPlayer/Shell/PastSongPopoverController.swift`. Mirrors `PopoverController`:

- Borderless `NSPanel` (style `[.borderless, .nonactivatingPanel]`, level `.statusBar`).
- 10pt corner radius + `masksToBounds` on the content view's layer.
- Anchors to the status item (same screen position as the main popover).
- Outside-click dismissal via `NSEvent.addGlobalMonitorForEvents`.
- Esc dismissal via local key-down monitor.

Reuses the `StatusItemController` reference for positioning. Mutual exclusion: when `show(song:)` is called, dismiss any visible main popover first.

### `PastSongView` + `PastSongViewModel`

New SwiftUI view in `Sources/RPPlayer/Shell/PastSongView.swift`:

```swift
struct PastSongView: View {
    @ObservedObject var viewModel: PastSongViewModel

    var body: some View {
        VStack(spacing: 0) {
            albumArt
            VStack(spacing: 12) {
                titleRow
            }
            .padding(12)
        }
        .frame(width: 342)
        .task { await viewModel.start() }
    }

    private var albumArt: some View {
        // 342×342 with scaledToFill+clipped + music.note placeholder.
        // Same structure as MiniPlayerView.albumArt.
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.song.title) … // headline
                Text(viewModel.song.artist) … // subheadline
                if let album = viewModel.song.album, !album.isEmpty {
                    Text(album) … // caption
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RatingMenu(currentRating: viewModel.currentRating,
                       isSignedIn: viewModel.isSignedIn) { value in
                Task { await viewModel.rate(value) }
            }
        }
        .frame(width: 318)
    }
}
```

`PastSongViewModel` (new file) is a tiny `@MainActor final class: ObservableObject`:

- `let song: PlayListSong`
- `@Published var currentArt: NSImage?`
- `@Published var currentRating: Int?`
- `@Published var isSignedIn: Bool`
- `init(song:albumArtCache:auth:api:)`
- `func start() async`:
  - Sets `currentRating` from `song.userRating` via the existing rating-parser pattern (string → Int).
  - Sets `isSignedIn = auth.isLoggedIn`.
  - If `song.cover` non-nil, calls `await albumArtCache.image(for: cover)` and assigns to `currentArt`. **The existing `LiveAlbumArtCache.image(for:)` already handles cache-hit-on-disk vs. download-on-miss transparently — we get the cached file for free if it exists from when the song was the now-playing track, and a fresh download otherwise.**
- `func rate(_ value: Int) async`:
  - Calls `api.rate(songId: Int(song.songId)!, rating: value)`.
  - On success: `currentRating = value`.
  - On failure: leave `currentRating` unchanged (no error UI in this minimal view).

Reuses `RatingMenu` exactly as it appears in `MiniPlayerView`.

### Wire-up in `AppContainer.live()`

1. Construct `let registry = SongRegistry(capacity: 100)`.
2. `NotificationCoordinator.init` gains a `registry: SongRegistry` parameter; `handle` calls `await registry.record(np.song)` before `service.notify(...)`.
3. Construct `let pastSongController = PastSongPopoverController(statusItemController: statusItemController, …)`.
4. Construct `let router = NotificationClickRouter(coordinator: coordinator, registry: registry, api: api, mainPresenter: { popoverController.show(...) }, pastSongPresenter: { song in pastSongController.show(song: song, albumArtCache: cache, auth: keychainAuth, api: api) })`.
5. If `Bundle.main.bundleIdentifier != nil`, assign `UNUserNotificationCenter.current().delegate = router`. Hold the router strongly on `AppContainer` (the delegate property is `weak`).

### Tests

- **`SongRegistryTests`** — record + lookup; capacity eviction (oldest first); duplicate id → move to front (no duplicate entry).
- **`LiveNotificationServiceTests`** — notify with `identifierSuffix: "1234"` produces a request id matching `"<UUID>|1234"`; `extractSongId(from:)` parses correctly + returns `nil` for legacy ids without `|` + returns `nil` for empty suffix.
- **`NotificationClickRouterTests`** — four cases via stub coordinator + stub registry + stub api:
  1. Notification id matches current playing song → `mainPresenter` called, `pastSongPresenter` not.
  2. Cached past song → `pastSongPresenter` called with the cached song.
  3. Not cached, `api.info` succeeds → `pastSongPresenter` called with the converted song.
  4. Not cached, `api.info` throws → `mainPresenter` called as fallback.
- **`PastSongViewModelTests`** — `start()` hydrates `currentRating` + `isSignedIn` + `currentArt` (with stub cache); `rate(_:)` calls `api.rate` + updates `currentRating`.
- **`PastSongViewTests`** — `NSHostingController` smoke renders.
- **`PastSongPopoverControllerTests`** — show/hide smoke (mirrors existing `PopoverControllerTests`).

### Manual smoke

1. Play. Notification fires on song change. Click notification → main popover opens with current song.
2. Skip forward to a new song. Earlier notification still in Notification Center → click → past-song popover with that earlier song (album art cache hit, no network); rate → digit updates and persists.
3. Switch channel. Click an earlier-channel notification → past-song popover with the cross-channel song.
4. Quit app + relaunch + click an old notification still in Notification Center → past-song popover; album art may need to be re-downloaded if the cache evicted it; song info fetched via `api/info`.
5. Sign out → click any notification → past-song popover renders, rating dropdown disabled (`☆`, greyed).

### Files touched

| Path | Change |
|---|---|
| `Sources/RPPlayer/Notifications/NotificationService.swift` | Add `identifierSuffix:` to `notify`; add `extractSongId(from:)` static helper. |
| `Sources/RPPlayer/Notifications/SongRegistry.swift` | **New**. Bounded ring buffer keyed by song id. |
| `Sources/RPPlayer/Notifications/NotificationCoordinator.swift` | Take `registry`; record before notify; pass `np.song.songId` as identifier suffix. |
| `Sources/RPPlayer/Notifications/NotificationClickRouter.swift` | **New**. `UNUserNotificationCenterDelegate` impl; routing logic. |
| `Sources/RPPlayer/Api/ApiModels.swift` | Add `extension PlayListSong { init(from info: SongInfo) }`. |
| `Sources/RPPlayer/Shell/PastSongView.swift` | **New**. Stripped-down popover view. |
| `Sources/RPPlayer/Shell/PastSongViewModel.swift` | **New**. Mini ObservableObject (rating + art + sign-in state). |
| `Sources/RPPlayer/Shell/PastSongPopoverController.swift` | **New**. Borderless NSPanel host (mirrors `PopoverController`). |
| `Sources/RPPlayer/App/AppContainer.swift` | Wire registry + router + past-song controller; assign `UN.current().delegate`. |
| `Tests/RPPlayerTests/Notifications/SongRegistryTests.swift` | **New**. |
| `Tests/RPPlayerTests/Notifications/NotificationServiceTests.swift` | Add identifier-suffix + extractSongId cases (or new file if missing). |
| `Tests/RPPlayerTests/Notifications/NotificationClickRouterTests.swift` | **New**. |
| `Tests/RPPlayerTests/Shell/PastSongViewModelTests.swift` | **New**. |
| `Tests/RPPlayerTests/Shell/PastSongViewTests.swift` | **New** smoke. |
| `Tests/RPPlayerTests/Shell/PastSongPopoverControllerTests.swift` | **New** smoke. |
| `CLAUDE.md` | Bump test count; note notification routing + SongRegistry + past-song popover. |

### Risk / open questions

- **`api/info` cookie auth.** `api.info` shares the same `cookieProvider` as the rest of `LiveRpApiClient`, so the auth cookie path is consistent. No special handling needed.
- **App-restart latency.** First click on a stale notification after a restart triggers an `api/info` round-trip (~100–300ms). Acceptable; popover appears immediately after fetch resolves.
- **Cache hit vs download.** `LiveAlbumArtCache.image(for:)` handles both transparently — disk-cache hit for songs that were recent now-playing tracks, network download for older ones. View renders placeholder until the image arrives.
- **Mutual exclusion.** Past-song popover and main popover share status-item anchor. The presenter wiring must dismiss the other before showing.
- **Notification Center retention.** macOS retains notifications across restarts unless the user dismisses them. Stale-id clicks just hit the `api/info` fallback path. No proactive cleanup needed.
