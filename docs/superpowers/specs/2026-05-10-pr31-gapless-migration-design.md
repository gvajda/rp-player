# PR 31 — Migrate to `api/gapless`

**Status:** Approved (2026-05-10)
**Branch (will be):** `claude/pr31-gapless-migration`

## Problem

The app currently fetches playback content via `api/play` (and `api/get_block` for the Upcoming Program window). Both return a "block" — one audio file containing N songs, where each song's `elapsed` field encodes its absolute offset within the file and `cue` is the listener's tune-in point in the same frame. This forced the coordinator to manage block-relative arithmetic (`startsAt[]`, `currentSongIndex`, `BlockSongs.indexOfSong(at:)`) and the Upcoming Program window to manually stitch consecutive blocks per channel.

A new endpoint, `api/gapless`, returns a flat list of songs where each song is its own self-contained file URL with its own `cue` / `duration` / `event_id`. Promo songs (`type="P"`) are inline-mixed. Backend cursor (`current_event_id`) is authoritative — driven by the existing `update_history` / `update_pause` telemetry. The web player has shipped a backend that already exposes this; the official web client has not migrated yet.

Migrating dissolves the "block" abstraction in the data layer:
- No more `elapsed` offset arithmetic (each song = its own file).
- No more block-stitching in Upcoming (single call per channel returns N songs flat).
- Stale-block detection becomes unnecessary (per-song self-contained URLs make any returned cursor playable).
- mpv `loadfile <url> append-play` queueing maps cleanly to the new model — each song is its own URL.

## Goals

1. Replace `api/play` (and `api/get_block`) with `api/gapless` for both playback and Upcoming Program.
2. Refactor `LivePlaybackCoordinator` from block-centric (`currentBlock` + `orderedSongs[]` + `startsAt[]` + `currentSongIndex`) to queue-centric (`queue: [GaplessSong]`).
3. Simplify `UpcomingProgramViewModel.load` to one `gapless` call per visible channel (was: per-channel multi-block stitching loop).
4. Drop `GetBlock`, `BlockSongs`, `PlayAction`, all `api/play` + `api/get_block` test fixtures.
5. Preserve telemetry (`update_history` / `update_pause` unchanged — drives backend cursor).
6. Preserve PR 30 long-idle stall watchdog (runs against new fetch path).

## Non-goals

- Migrate `PlayListSong.init(from: SongInfo)` (notification-click → past-song popover when click lands post-restart). Stays — `PlayListSong` is kept for that one path with potentially-trimmed fields.
- Change telemetry endpoints / call shapes. Only the `slice_num` source type changes (`String?` → `Int`).
- New favorites behavior. Verify gapless supports chan=99 the same way during implementation; address shape drift if found.
- Optimize mpv playlist depth past "1 ahead." Same pattern as PR 28.
- UI / popover restyle. Visual surface unchanged.

## API surface

### New `RpApiClient` method

```swift
func gapless(channel: Int, bitrate: Int, numSongs: Int) async throws -> GaplessResponse
```

URL: `GET https://api.radioparadise.com/api/gapless?bitrate=<n>&chan=<n>&numSongs=<n>&player_id=<id>`

- Query items sorted alphabetically (matches existing `LiveRpApiClient` convention; `StubURLProtocol` URLs must match).
- Cookies attached (favorites support — chan=99).
- Default `numSongs=20` per coordinator call site (matches the web player URL hint). Upcoming uses `rowCount` (settings-driven).

### Removed `RpApiClient` methods

- `play(channel:bitrate:event:action:audioType:episodeId:sliceNum:)`
- `getBlock(channel:bitrate:event:)`
- `PlayAction` enum

### New types in `Sources/RPPlayer/Api/ApiModels.swift`

```swift
public struct GaplessResponse: Decodable, Sendable, Equatable {
    public let channel: Channel
    public let bitrateTitle: String?       // "flac", "320 mp3", "320k aac" — popover label
    public let ext: String?                // "flac" / "mp3" / "aac"
    public let imageBase: String           // image_base (typo'd imgage_base ignored)
    public let currentEventId: Int
    public let maxGaplessEventId: Int
    public let slideshowPath: String
    public let timeoutMillis: Int
    public let songs: [GaplessSong]
}

public struct GaplessSong: Decodable, Sendable, Equatable {
    public let songId: String              // custom decoder: Int OR String (matches SongInfo)
    public let artist: String
    public let title: String
    public let album: String?              // promo songs omit / empty
    public let year: String?
    public let duration: Int               // ms
    public let cue: Int                    // ms; only first song > 0 typically
    public let coverArt: String?
    public let coverLarge: String?
    public let coverMedium: String?
    public let coverSmall: String?
    public let eventId: Int
    public let gaplessUrl: String
    public let slideshow: [String]
    public let type: String                // "M" or "P"
    public let schedTimeMillis: Int64
    public let userRating: Int             // 0 if unrated
    public let rating: Double
    public let ratingsNum: Int
    public let episodeId: Int
    public let sliceNum: Int               // INT in gapless (was String? in PlayListSong)
    public let isRateable: Bool
    public let isPlayableAfterSkip: Bool
    public let isPlayableOnStart: Bool
    public let updateHistory: Bool         // skip telemetry when false (promo)
    public let skipAllowedMillis: Int64
}
```

Custom `Decodable` init handles `song_id` Int-or-String (mirrors `SongInfo.songId`). `slice_num` decodes via `decodeIfPresent(Int.self, …) ?? 0` to defend against null in favorites response (verify during impl).

Drop the typo'd `imgage_base` field (server emits both keys; only `image_base` is decoded).

### Removed types

- `GetBlock` (struct + Decodable extension)
- `BlockSongs` enum (entire file `Sources/RPPlayer/Playback/BlockSongs.swift` deleted)

### `NowPlaying` shape change

```swift
public struct NowPlaying: Sendable, Equatable {
    public let channelId: Int
    public let song: GaplessSong              // was: PlayListSong
    public let songDurationSeconds: Double    // was: blockDurationSeconds + songEndSeconds
    public var bitrateLabel: String?          // was: blockBitrate
    // Dropped: songIndexInBlock, songStartSeconds, songEndSeconds
}
```

`positionUpdates: AsyncStream<Double>` semantics shift from "block-relative seconds" to "song-relative seconds" — view model math simplifies but the stream signature is unchanged.

## Coordinator refactor

### Property changes (`LivePlaybackCoordinator`)

Drop:
- `currentBlock: GetBlock?`
- `orderedSongs: [PlayListSong]`
- `startsAt: [Double]`
- `currentSongIndex: Int`
- `prefetchedBlock: GaplessSong?`
- `prefetchTask: Task?`
- `queuedToEngine: Bool`

Add:
- `queue: [GaplessSong]`  (queue[0] = currently playing)
- `currentResponse: GaplessResponse?`  (snapshot for `imageBase` + `bitrateTitle`)
- `refetchTask: Task<Void, Never>?`

Keep: `currentChannelId`, `currentPositionSeconds` (semantics now song-relative), `pausedAt`, `pausePositionMs`, `consecutivePlaybackFailures`, all PR 30 stall-watchdog properties.

### Method rewrites

**`play(channelId:)`**
1. `cancelStallWatchdog()`
2. `await ensureEventSubscription()`
3. `bitrate = await bitrateProvider()`
4. `response = try await api.gapless(channel: channelId, bitrate: bitrate, numSongs: 20)`
5. `guard !response.songs.isEmpty else { throw .blockHasNoSongs }`
6. `queue = response.songs; currentResponse = response; currentChannelId = channelId`
7. `let startSeconds: Double? = queue[0].cue > 0 ? Double(queue[0].cue) / 1000.0 : nil`
8. `currentPositionSeconds = startSeconds ?? 0`
9. `await prePlayHook()`
10. `try await engine.play(url: queue[0].gaplessUrl, startSeconds: startSeconds)`
11. `if queue.count >= 2 { try? await engine.queueNext(url: queue[1].gaplessUrl, startSeconds: nil) }`
12. `emitNowPlaying(forSongAt: 0); emitState(.playing)`
13. `fireSongStartTelemetry(song: queue[0], channelId: channelId)`

No stale-block detection — drop entirely. Backend cursor is authoritative; per-song self-contained URLs play correctly even if cursor lagged.

**`handleEngineEvent(.fileStarted)`**
- If `queue.count >= 2`: `queue.removeFirst()`, `currentPositionSeconds = 0`, `emitNowPlaying(forSongAt: 0)`, `fireSongStartTelemetry(song: queue[0])`, then `if queue.count >= 2 { engine.queueNext(queue[1].gaplessUrl) }` and `if queue.count < 3 { kickRefetch() }`.
- If `queue.count < 2`: log + `kickRefetch()` (queue depleted; recovery on refetch result).

**`handleEngineEvent(.fileEnded(.eof))`**
- With "always queue 1 ahead" pattern, EOF without a queued entry means refetch lagged. Try `engine.play(queue[0].gaplessUrl)` if `queue` non-empty; else synchronous refetch + `engine.play(queue[0])`. On both failures: route through `handlePlaybackError` cleanup + error stream.

**`skipForward()`**
1. `cancelStallWatchdog()`
2. Fire `update_history` telemetry for `queue[0]` with current playtime (skipped early).
3. If `queue.count >= 2`: `engine.advanceToQueued()` (`playlist-next force`). The subsequent `.fileStarted` drives the rest.
4. Else: synchronous refetch. If got songs: `queue = response.songs; engine.play(queue[0].gaplessUrl)`. If failed: surface "Cannot skip — try again" via `errorsContinuation`.

**`pause()`**
- Unchanged. `update_pause` telemetry still fires.

**`resume()`**
- Long-idle (≥ 59 min `clock() - pausedAt`) branch: `queue = []; currentResponse = nil; engine.clearPlaylist();` then `play(channelId: currentChannelId)`. PR 30 stall watchdog armed.
- Short-idle branch: `engine.play(currentSongUrl, startSeconds: currentPositionSeconds)` from cached `queue[0]`.

**`changeChannel(to:)`**
- `queue = []; currentResponse = nil; engine.clearPlaylist(); refetchTask?.cancel(); play(channelId: newId)`.

**`stop()` / `shutdown()` / `handlePlaybackError(code:)`**
- Clear `queue`, `currentResponse`, `engine.clearPlaylist()`, cancel `refetchTask`, cancel stall watchdog. Otherwise unchanged.

**`kickRefetch()` (new, replaces `maybeStartPrefetch` + `absorbPrefetchResult`)**
- If `refetchTask != nil`, return.
- Spawn `Task<Void, Never>`: capture `currentChannelId` snapshot + `queue[0].eventId` snapshot. `await api.gapless(channel: snapshot, …)`.
- On result: re-check `currentChannelId == snapshot` (race-guard, matches PR 28 pattern) and `queue.first?.eventId == headEventSnapshot` (currently-playing didn't change mid-fetch). Compute `newSongs = response.songs.filter { $0.eventId > queue[0].eventId }`. Replace tail: `queue = [queue[0]] + newSongs`. If mpv has nothing queued (because we previously had `queue.count < 2`) and `queue.count >= 2`: `engine.queueNext(queue[1].gaplessUrl)`.
- This single policy handles all three refetch shapes: (a) normal overlap — server returns from current cursor, filter strips queue[0], append; (b) gap — server returns later events, our local queue[1..] gets replaced with server's view; (c) backend lag — server returns older events, filter keeps only those > current, may produce empty newSongs (next boundary cross retries).
- On failure: log; another boundary cross will retry.
- Always `refetchTask = nil` at end.

**`handleSongPlaybackError(code:)` (replaces `advancePastUnplayableBlock`)**
- For mpv error codes that are per-song-fatal (`-16` etc.): drop `queue.removeFirst()`. If `queue.isEmpty`: refetch + retry. Else: `engine.play(queue[0].gaplessUrl)`. Log the dropped song's URL + event_id.
- For audio-device / catastrophic codes: existing `handlePlaybackError` cleanup path (clear all state + emit error).

### Logging

`describeBlock(url:songs:starts:)` → `describeQueue(songs:)`. Logs first 5 entries with `eventId`, `cue`, `duration`, `type`, `gaplessUrl` short-hash.

## Upcoming Program migration

`UpcomingProgramViewModel.load`:

**Before:** for each visible channel, sequence of `api.getBlock(channel:bitrate:event:)` calls that stitch consecutive blocks until `rowCount` songs are collected, manually skipping promo songs and handling block boundaries.

**After:** for each visible channel, single `api.gapless(channel: c.chan, bitrate: 4, numSongs: rowCount)` call. Filter `song.type != "P"` inline if hiding promos (preserves current behavior).

`UpcomingColumn.songs: [PlayListSong]` → `[GaplessSong]`. Field mapping for `UpcomingSongRow` (artist/title/album/year/cover/rating/duration/songId) is 1:1 against `GaplessSong`.

Drop `RpApiClient.getBlock` callsite — last user removed by this change.

## Edge cases

1. **Backend cursor lag.** No detection / recovery needed. Per-song URLs are self-contained; `cue` reflects backend's view. Song plays correctly start-to-end.
2. **Empty `songs[]`.** Throw `PlaybackCoordinatorError.blockHasNoSongs` (enum case kept; user-facing message via `LocalizedError`).
3. **Promo at `queue[0]`.** Telemetry skipped when `song.updateHistory == false`. Rating UI disabled when `isRateable == false`.
4. **Skip past end of queue.** `queue.count == 1` + skip = synchronous refetch + `engine.play(queue[0])`. Failure surfaces "Cannot skip — try again."
5. **Refetch dup / older event_ids.** Filter `event_id > queue.last?.eventId ?? 0`. Empty filter → log + retry on next boundary cross.
6. **Refetch gap (e.g. `queue.last.eventId = 100`, `response[0].eventId = 105`).** Trust server. Replace tail of `queue` with response filtered to `event_id > queue[0].eventId` (preserves currently-playing). Refresh mpv `queueNext` if `queue[1]` differs from what's queued.
7. **Race: `play()` + concurrent `changeChannel()`.** `currentChannelId` snapshot at fetch entry; discard result if changed during await (matches PR 28 race-safety pattern).
8. **mpv error -16 on a single song.** `handleSongPlaybackError` drops `queue[0]`, advances. Replaces old `advancePastUnplayableBlock`.
9. **Long-idle stall watchdog (PR 30).** Watchdog armed in long-idle resume branch. Same retry semantics, against new gapless URL.
10. **Favorites (chan=99).** Verification step: hit gapless with chan=99 and capture response. Confirm shape. If `slice_num` is null: decoder defaults to `0`; telemetry sends `"0"`. Document any drift in CLAUDE.md.

## Risks

- **Largest single-PR scope so far.** ~800-line coordinator rewrite + new API types + Upcoming rewrite + ~20+ test files updated. Mitigation: subagent-driven execution with task-level review checkpoints.
- **Test rewrites dominate work.** Coordinator tests are heavy block-shaped; need reauthoring against gapless fixtures. Stale-block tests deleted entirely (concept gone).
- **Telemetry timing.** Boundary-cross `update_history` fires on `.fileStarted` (was `.fileEnded(.eof)` in some paths). May arrive ~1s earlier — tolerable; server tolerates.
- **`PlayListSong` half-stays.** Notification-click `info → PlayListSong` path persists. Keep `PlayListSong` minimal but live.

## Test plan

### `RpApiClientTests`
- Add: gapless success (main mix fixture), gapless favorites (chan=99), gapless error code, query-param ordering, cookies attached, error decoding (`StubURLProtocol`).
- Drop: `play` and `getBlock` test cases.

### `LivePlaybackCoordinatorTests`
- Add: bootstrap fetches gapless; boundary cross (`.fileStarted`) advances queue + queues next + fires telemetry; skip drops queue head + advances; thin-queue refetch on boundary cross; long-idle resume refetches gapless; channel change drops queue + refetches; engine error -16 drops song + advances; refetch dedup by event_id; race-guard on concurrent channel change.
- Drop: stale-block detection tests; prefetch+swap tests (replaced by queue tests); `BlockSongs.isStale` tests.

### `UpcomingProgramViewModelTests`
- Add: single gapless call per channel; promo filter (`type=P` excluded); rowCount maps to numSongs; channel-change reload.
- Drop: multi-block stitching tests.

### `BlockSongsTests`
- Deleted (file removed).

### Stall-watchdog tests (PR 30)
- Stay green. Watchdog logic unchanged; only the fetch path beneath it is gapless.

### Fixtures
- Add: `Tests/RPPlayerTests/Fixtures/Api/gapless_main.json` (sanitised copy of `.temp/gapless.json` — strip real `player_id` from any references).
- Add: `gapless_favorites.json` (capture during impl from chan=99).
- Add: `gapless_promo_first.json` (queue[0] is a promo song).
- Drop: `get_block_*.json`, `play_*.json` fixtures (audit list during impl).

### Anticipated test count delta
~+15 net (new gapless API tests + new coordinator queue tests minus deleted stale + BlockSongs tests). Final count ≈ 450–460.

## Documentation

Per project workflow:
- `CHANGELOG.md` — add `## [Unreleased]` entry under Added / Changed / Removed.
- `CLAUDE.md` — update PR status table, *Test counts by PR* section, *Key technical decisions* (gapless model, queue-based coordinator, new API surface).
- `README.md` — no user-facing changes; skip unless something surfaces during impl.

## Out of scope (deferred)

- Eliminating `PlayListSong` entirely (only used by notification-click `info → PlayListSong` post-restart path; not worth touching here).
- Optimizing mpv playlist past "1 ahead."
- Refreshing slideshow images mid-song based on `slideshow[]` array (gapless gives us this list per song; not currently used).
- Surfacing `max_gapless_event_id` to UI (lookahead horizon indicator — no obvious UX win).
- Migrating `update_history` / `update_pause` `slice_num` parameter type from `String?` to `Int` end-to-end. Conversion at call site (`String(song.sliceNum)`) suffices.
