# CI Node.js 20 Deprecation — Action Required by 2026-06-02

**Source:** GitHub Actions runner annotation surfaced on every CI run starting around v0.2.1 (2026-05-04 UTC). Anchor announcement: <https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/>

## Timeline

- **2026-06-02** — Actions are forced to run on Node.js 24 by default. `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` is no longer needed; `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION=true` becomes the temporary opt-out.
- **2026-09-16** — Node.js 20 removed from the runner. Any pinned-to-Node-20 action stops working.

## Affected actions in this repo

All in [.github/workflows/ci.yml](.github/workflows/ci.yml):

| Line | Action | Current pin | Status |
| ---- | ------ | ----------- | ------ |
| 16   | `actions/checkout@v4` | v4 | Node.js 20 — needs check for v5 / Node-24-ready release |
| 26   | `sersoft-gmbh/swift-coverage-action@v4` | v4 | Node.js 20 — community action, may lag upstream |
| 32   | `codecov/codecov-action@v4` | v4 | Node.js 20 — codecov ships v5; bumping to v5 is the fix |
| 45   | `actions/checkout@v4` (release job) | v4 | same as line 16 |

## Why action

Doing nothing is fine through **2026-06-02**: workflows run, just with the deprecation annotation. After that date, runs auto-promote to Node 24, and any action that hasn't shipped a Node-24-compatible release will start failing or producing unsupported behavior. Goal: bump pins before then, in a controllable PR rather than during a release-time fire drill.

## Recommended path

Single follow-up PR that:

1. Confirms a Node-24-ready major exists for each action (check release notes).
2. Bumps `codecov/codecov-action@v4` → `@v5` (codecov has shipped v5; v5 is Node 20 too at time of writing — re-check before PR).
3. Bumps `actions/checkout@v4` → `@v5` if v5 is out, else stays on v4 (the v5 deprecation milestone is its own thing — `v4` stays usable until Node 20 is removed).
4. Re-pins `sersoft-gmbh/swift-coverage-action@v4` — confirm a Node-24-compatible major exists; if not, evaluate whether the action is still needed or replace with inline `xcrun llvm-cov export` + tar steps (the action is a thin wrapper).
5. Verifies CI green on both `test` and `release` jobs (push branch + push a throwaway tag like `v0.2.2-rc1` then delete).

## Out of scope for this note

- The OIDC + tokenless Codecov upload pattern from PR 20 stays as-is — `codecov-action@v5` keeps OIDC support.
- `codecov.yml` (project + patch thresholds set in v0.2.1 fix) is unrelated.

## Status

Filed 2026-05-05 after release of v0.2.1. No action taken yet. Track here until addressed.
