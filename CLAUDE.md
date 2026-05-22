# RP Player — Agent Context

## "Continue work" means: write the next PR plan, get approval, execute it

---

## What this project is

macOS menu-bar app (Swift 6.2, macOS 14, SwiftUI + AppKit) that plays Radio Paradise streams in bit-perfect mode (CoreAudio hog mode acquired directly via `kAudioDevicePropertyHogMode`; libmpv handles decode and shared-mode CoreAudio output). Source of truth: `docs/DESIGN.md`.

**GitHub:** <https://github.com/gvajda/rp-player>

---

## Current state

- Last merged (pending): **PR 43** — EQ preset picker switch while editing + Settings panel UX polish. Picker side: clean change reseeds editor; dirty change shows "Unsaved EQ changes" alert (Keep editing / Discard / Save / Save as new preset…). New `SettingsViewModel.requestPresetSwitch(to:)` + `pendingPresetSwitch` published + 4 resolve methods. Save-as variant lands picker on user's originally-picked target, not on save-as name. Internals: extracted private `writePresetFile(name:)` from `saveEditAs`; private `performSwitch(to:)` does atomic picker change + editor reseed (includes a manual `self.eqPresetName = target` sync hop to avoid configStore-stream-lag reparsing the wrong preset). SwiftUI alert + name sheet on `eqSection`; `savingAsInProgress` `@State` flag gates the alert's `isPresented` setter so Save-as button-tap doesn't auto-cancel pending state before sheet's OK runs. UX polish on the same branch: Settings window vertically resizable (480×400…2000, initial 560); EQ edit panel button row moved above header with divider; Save As pre-fills with current preset name (no `-copy`); `nameSheet` refactored to projected `$saveAsName`/`$renameTarget` bindings + `.onChange` cap (fixes "first-open empty" bug where stale `initialValue` capture in `.onAppear` clobbered button-set pre-fill). 13 new tests. 572 tests.
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
