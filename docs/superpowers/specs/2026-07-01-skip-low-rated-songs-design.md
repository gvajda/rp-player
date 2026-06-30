# Skip low-rated songs — design

Date: 2026-07-01
Status: approved (brainstorming) — ready for implementation plan

## Goal

Let the user auto-skip songs rated below a chosen star threshold. Skip is
immediate when the user rates the currently-playing song below the threshold
(the song advances as soon as the rating API call returns). Already-low-rated
songs that appear in the upcoming list are shown with a "will be skipped"
marking, are auto-skipped when reached, and their audio is never downloaded
(only album art, which the upcoming list fetches anyway for display).

## Rating scale

The app rates songs **1–10** internally (`GaplessSong.userRating`, `0` = unrated;
`RatingMenu` shows `★N`). The threshold is on this same 1–10 scale — no mapping
layer. Promos (`type == "P"`) are unrated and never skipped.

## Core predicate — single source of truth

A small `SkipPolicy` value derived from settings:

```
shouldSkip(userRating) = enabled && userRating > 0 && userRating < threshold
```

- `userRating == 0` (unrated) never skips.
- Strict less-than: default threshold `5` skips ratings 1–4, keeps 5–10.
- Used by every consumer (coordinator, mini-player rate, upcoming list) so the
  rule is defined once.

A song **qualifies** (is playable) when `!shouldSkip(userRating)` — i.e. unrated,
rated ≥ threshold, or a promo.

## 1. Settings

Files: `Sources/RPPlayer/Config/AppSettings.swift`,
`Sources/RPPlayer/Shell/SettingsViewModel.swift`,
`Sources/RPPlayer/Shell/SettingsView.swift`.

Two new persisted fields, following the established Codable pattern (field +
`CodingKeys` case + `decodeIfPresent ?? default` in `init(from:)` + `encode` line):

- `skipLowRatedEnabled: Bool = false`
- `skipRatingThreshold: Int = 5`

`SettingsViewModel`: `@Published private(set)` mirrors of both, setter methods
delegating to `configStore.update { … }`, and sync from the `configStore.changes`
stream in `start()`.

UI (mirrors the existing crossfeed toggle + conditional picker template):

- `Toggle` bound to `skipLowRatedEnabled`.
- A `Picker` shown **only when the toggle is on**, values **2–10**, default 5.
  Threshold 1 is omitted (with strict less-than it would skip nothing).
  Label copy e.g. "Skip songs rated below N".

## 2. Immediate skip on rating the current song

File: `Sources/RPPlayer/Shell/MiniPlayerViewModel.swift` (`rate(_:)`).

After `api.rate(songId:rating:)` returns successfully and `currentRating` is
updated, if `shouldSkip(value)` is true → `await coordinator.skipForward()`.

- Only in `MiniPlayerViewModel` (the currently-playing song).
- `PastSongViewModel.rate(_:)` is untouched — past songs already played; nothing
  to skip.
- Skip is chained after the API success path only (a failed rate does not skip).

## 3. Playback queue — never download skip-bound, two-layer skip

File: `Sources/RPPlayer/Playback/PlaybackCoordinator.swift`.

The coordinator receives the predicate via an injected
`@Sendable (Int) -> Bool` closure (same injection pattern as the existing
`prefetchArt` closure), backed by a settings snapshot kept current from
`configStore.changes`.

**Layer A — fetch/queue time (prevents download).**
Skip-bound songs are dropped from the playback `queue` at gapless-fetch time and
at each advance. Consequences:

- They are never queued into mpv and never handed to `SongFileCache` → audio is
  never downloaded.
- No play telemetry (`update_history`) is emitted for them — they were never
  played.
- `eventId` / path matching in `syncQueueHeadFromMpv` continues to operate only
  on real, played songs.

This filter-the-array approach is chosen over a `SongFileCache` skip-flag because
it keeps the queue/mpv matching logic operating on a clean, playable-only queue.

**Layer B — playback time (safety net).**
When a song becomes the head/current (in `syncQueueHeadFromMpv`), re-check
`shouldSkip` on the new head. If true → immediate `skipForward` past it.

- Covers a song that was queued into mpv *before* a settings or rating change
  (Layer A only filters new fetches). Such a song may start for a brief blip,
  then auto-skips.
- That already-queued song was downloaded when it was queued — accepted cost of
  a mid-playback change. New fetches after the change are filtered pre-download.

**Empty block → stop, no retry.**
If a freshly fetched 20-song gapless block contains **zero** qualifying songs
(every song is `shouldSkip`), playback **ends** (transitions to stopped) and the
coordinator emits a user-facing message via its `errors` stream:

> "No upcoming songs match your rating filter — raise the threshold in Settings."

No refetch loop. A full block with nothing qualifying means the threshold is too
high; retrying would just spin.

## 4. Upcoming list — show marked, art only

Files: `Sources/RPPlayer/Upcoming/UpcomingProgramView.swift`,
`Sources/RPPlayer/Upcoming/UpcomingProgramViewModel.swift`.

The upcoming **display** is a *separate* `api.gapless(...)` fetch from the
playback queue, so skip-bound songs still appear here (the playback queue having
filtered them out is independent).

- `UpcomingSongRow` gains `isSkipped: Bool`, derived from the predicate.
- `UpcomingSongCardView` renders the **Dim + SKIP pill** treatment when
  `isSkipped`: the whole card at ~0.4 opacity, with a small `⏭ SKIP` capsule
  pinned top-right (accent/secondary styling). The existing `★N` rating badge
  still shows.
- "Only album art downloaded for skipped songs" is satisfied for free: the
  upcoming view fetches its own art via `AlbumArtCache`; the playback queue
  filtered these songs out so it downloads neither audio nor art for them.
- The upcoming view re-evaluates `isSkipped` when settings change (subscribe to
  `configStore.changes`, consistent with the rest of the app).

## 5. Tests (~16–18 new)

- `SkipPolicy` boundaries: rating 0, `< T`, `== T`, `> T`; disabled toggle.
- `AppSettings` Codable round-trip + decode defaults for both new fields.
- `SettingsViewModel`: setters persist; reactive sync from `configStore.changes`.
- `MiniPlayerViewModel.rate`: skips when below threshold + enabled; does **not**
  skip when disabled, or when rating ≥ threshold; does not skip on rate failure.
- Coordinator Layer A: skip-bound songs excluded from download/queue; no
  telemetry emitted for them.
- Coordinator Layer B: a head song that became skip-bound after a setting change
  is auto-skipped at playback time.
- Coordinator empty block: a fully-filtered block stops playback and emits the
  message; no refetch.
- Upcoming: `isSkipped` derivation; `UpcomingSongCardView` renders the SKIP pill
  and dim when `isSkipped`.

## Out of scope (YAGNI)

- Rating upcoming songs inline from the upcoming list.
- Half-stars / non-integer thresholds.
- Per-channel thresholds.
- Surgically removing an already-queued skip song from mpv (Layer B handles it at
  playback time instead).
