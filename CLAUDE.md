# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

**GitHub:** <https://github.com/gvajda/rp-player>

---

## Current state

- Last merged (pending): **PR 37** — Device reattach when hog. On disconnect while `hogModeEnabled`, preserve `outputDeviceUID` + hog + Force Max; auto-re-acquire on reattach via a one-shot catalog watcher; friendly "DeviceName disconnected — waiting for it to come back." banner in place of the hearing-safety reset message for the preserve path; picker shows "(disconnected)" row for the held UID. Startup-clear path unchanged. 500 tests.
- **Next up:** TBD — pick from the deferred list (`docs/pr-history.md` § Deferred) or brainstorm the next subsystem.
- On branch `claude/bs2b-crossfeed-upgrade` (not yet merged) — **BS2B Crossfeed Upgrade**. Replaces FFmpeg `crossfeed` filter with FFmpeg `bs2b` (Bauer stereo-to-binaural) for proper ITD modeling. New `CrossfeedProfile` enum (`bs2bDefault`/`cmoy`/`jmeier`/`custom`); `AudioProfile` schema swap (`crossfeedStrength`/`crossfeedRange` → `crossfeedProfile` + `crossfeedFcut: Int` + `crossfeedFeedDb: Double`) with legacy-key fallback to Chu Moy defaults on decode; UI replaces 2 sliders with a 4-button profile picker (Default / Chu Moy / Jan Meier / Custom) + custom-mode fcut/feed numeric inputs; `RPSmoke --probe-filters` extends to `bs2b: OK`; vendored libmpv rebuilt with `--enable-libbs2b` from `gvajda/libmpv-darwin-build` fork (`libbs2b.dylib` added to `Vendor/libmpv/lib/`). Chain order locked: Preamp → EQ → bs2b. 498 tests. **Vendor rpath fix included** (final commit `ac2fef0`): the fork tarball shipped with poisoned `LC_RPATH` entries pointing at a stale audio-default nix-store dir; under runtime `@rpath` fallback, dyld silently loaded the wrong `libavfilter.dylib` (no bs2b/volume filters) — manifested as cold-start "No such filter" errors. Rewrote every `@rpath/lib<sibling>.dylib` reference across all 16 `Vendor/libmpv/lib/*.dylib` to `@loader_path/lib<sibling>.dylib` + ad-hoc re-signed (see `Vendor/libmpv/README.md` for the procedure — required on every re-vendor until the fork emits clean install names upstream). Final PR number TBD; main has its own "PR 37" entries (device-reattach-on-hog work) — renumber before merge.
- **Next up:** finalize bs2b branch (rename PR number, manual audible smoke + rebase against current main since main has moved 13 commits ahead). Or pick from deferred list while waiting.

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
