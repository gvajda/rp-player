# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

**GitHub:** <https://github.com/gvajda/rp-player>

---

## Current state

- Last merged (pending): **PR 41** — `tryQueueNextOrDefer` helper. Extracts the sync-probe-or-defer pattern from PR 40's `.fileEnded(.eof)` recovery branch into a private method on `PlaybackCoordinator` and converts 5 risk-bearing `await songFileCache.localFile(...)` call sites (`play`, `skipForward` shallow-refetch, `applyBitrateChange`, `handleSongPlaybackError`, `syncQueueHeadFromMpv`). Each converted site stops blocking the coordinator actor on in-flight downloads; on cache miss, queueNext defers + emits `.loading`; existing `tryQueueNextIfPending(landed:)` lifts state when bytes land. Intentionally NOT converted: `skipForward` mid-skip (mpv idle, no risk) + 4 head-resolve sites (precede `engine.play(url:)`, would change cache-or-stream behaviour). Closes the PR 40 deferred tech-debt item. Test setup side-effect: `MockSongFileCache.markDownloaded` signature changed from `Set<Int>` to `[GaplessSong]` so `releasedMirror` stores the song's actual gaplessUrl. 548 tests.
- **Next up:** TBD — pick from the deferred list (`docs/pr-history.md` § Deferred) or brainstorm the next subsystem.

---

## Workflow conventions (locked)

- **Plan cadence:** just-in-time — write plan for next PR, get approval, execute, repeat.
- **Execution:** `superpowers:subagent-driven-development` (fresh subagent per task, spec + quality review after each).
- **Branches:** feature branches off `main` (e.g. `claude/pr13-api-play-migration`). Work happens on the branch directly in the main checkout — no separate worktree directory. Push to GitHub via `git push -u origin <branch>` if remote sync is desired.
- **Merge strategy:** fast-forward only (`git merge --ff-only`) to main after all reviews pass.
- **Test command:** `swift test`
- **Build command:** `swift build`
- **Documentation updates are part of every PR.** When a PR ships, update all four docs:
  - `CHANGELOG.md` — add entries under `## [Unreleased]` (sections: `Added` / `Changed` / `Fixed` / `Removed` / `Deprecated` / `Security`). Before tagging a release, rename the heading to `## [vX.Y.Z] - YYYY-MM-DD` and re-add an empty `## [Unreleased]` above it. CI's release job runs `scripts/extract-changelog.sh "$GITHUB_REF_NAME"` and fails the release if the section is missing or empty.
  - `docs/pr-history.md` — add a row to the PR status table; add any deferred items to the bottom section.
  - `docs/test-counts.md` — append the new test count line.
  - `docs/architecture.md` — only when a PR introduces a non-obvious technical decision (the kind future-you would miss by just reading the code). Most PRs don't need an entry; concrete code changes belong in the codebase, not here.
  - `CLAUDE.md` — refresh the *Current state* block (last merged PR + next up). PR-status table, test counts, and architecture notes do NOT live here anymore.
  - `README.md` — update user-facing instructions, screenshots, and feature lists when a PR changes them.

---

## Comment policy (strict)

- No comments unless the WHY is non-obvious (hidden constraint, workaround, subtle invariant).
- No multi-line docstrings. Single `//` line max.
- Code/commit/PR text: write normal English.

---

## Where things live

- **PR history + status table + deferred tech-debt:** `docs/pr-history.md`
- **Test counts log:** `docs/test-counts.md`
- **Key technical decisions (audio pipeline, libmpv, coordinator, shell, view models, API, auth, persistence, album art, logging, errors, notifications, deployment, CI):** `docs/architecture.md`
- **Design source of truth:** `docs/DESIGN.md` — project-level architecture spec.
- **Plans:** `docs/superpowers/plans/` — written just-in-time before each PR's execution. Gitignored (local only).
- **Specs:** `docs/superpowers/specs/` — design docs from the brainstorming phase. Gitignored (local only).
- **Notes / known-issue handoffs:** `docs/notes/` — committed. Most recent: `docs/notes/pr12-outstanding-2026-05-01.md`.
- **Legacy reference:** `docs/legacy/` — the Windows app's C# code, kept for cross-checking RP API behavior (URLs, cookies, query shapes).
