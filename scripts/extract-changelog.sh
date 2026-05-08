#!/usr/bin/env bash
# Extract the body of a `## [<tag>]` section from CHANGELOG.md.
#
# Usage:
#   scripts/extract-changelog.sh v0.5.1            # writes to stdout
#   scripts/extract-changelog.sh v0.5.1 notes.md   # writes to file
#
# Exits non-zero if the section is missing or empty (no entries under it).
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <tag> [output_file]" >&2
    exit 2
fi

TAG="$1"
OUT="${2:-}"
CHANGELOG="${CHANGELOG_PATH:-CHANGELOG.md}"

if [[ ! -f "$CHANGELOG" ]]; then
    echo "error: $CHANGELOG not found" >&2
    exit 1
fi

# awk picks the body between `## [<tag>]` and the next `## ` heading.
BODY="$(awk -v tag="$TAG" '
    BEGIN { in_section = 0 }
    /^## \[/ {
        if (in_section) { exit }
        if (index($0, "[" tag "]") > 0) { in_section = 1; next }
    }
    in_section { print }
' "$CHANGELOG")"

# Strip leading + trailing blank lines to avoid noisy release notes.
BODY="$(printf '%s\n' "$BODY" | awk '
    /[^[:space:]]/ { seen = 1 }
    seen { lines[++n] = $0 }
    END {
        last = n
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i]
    }
')"

if [[ -z "$BODY" ]]; then
    echo "error: changelog section for $TAG is missing or empty in $CHANGELOG" >&2
    echo "       add a '## [$TAG] - YYYY-MM-DD' heading with at least one entry before tagging." >&2
    exit 1
fi

if [[ -n "$OUT" ]]; then
    printf '%s\n' "$BODY" > "$OUT"
else
    printf '%s\n' "$BODY"
fi
