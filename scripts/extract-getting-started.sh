#!/usr/bin/env bash
# Extract the `## Getting started` section from README.md as readable text.
#
# Usage:
#   scripts/extract-getting-started.sh             # writes to stdout
#   scripts/extract-getting-started.sh out.txt     # writes to file
#
# Exits non-zero if the section is missing or empty.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [output_file]" >&2
    exit 2
fi

OUT="${1:-}"
README="${README_PATH:-README.md}"

if [[ ! -f "$README" ]]; then
    echo "error: $README not found" >&2
    exit 1
fi

# Slice between `## Getting started` and the next `## ` heading.
BODY="$(awk '
    BEGIN { in_section = 0 }
    /^## / {
        if (in_section) { exit }
        if (tolower($0) == "## getting started") { in_section = 1; next }
    }
    in_section { print }
' "$README")"

if [[ -z "${BODY//[[:space:]]/}" ]]; then
    echo "error: '## Getting started' section is missing or empty in $README" >&2
    exit 1
fi

# Light markdown -> plain text cleanup. Goal: a TextEdit-readable file.
CLEAN="$(printf '%s\n' "$BODY" | awk '
    BEGIN { in_fence = 0 }
    /^```/ { in_fence = !in_fence; next }
    { print }
' | sed -E \
    -e 's/^### +//' \
    -e 's/^## +//' \
    -e 's/^> +//' \
    -e 's/\*\*([^*]+)\*\*/\1/g' \
    -e 's/`([^`]+)`/\1/g' \
    -e 's/\[([^]]+)\]\(([^)]+)\)/\1 (\2)/g' \
| awk '
    # Drop GFM admonition markers (`[!NOTE]`, `[!IMPORTANT]`) AND a trailing
    # blank line if one follows, so we do not leave an orphan gap.
    /^\[![A-Z]+\] *$/ { skip_blank = 1; next }
    skip_blank && /^[[:space:]]*$/ { skip_blank = 0; next }
    { skip_blank = 0; print }
')"

# Trim leading + trailing blank lines.
CLEAN="$(printf '%s\n' "$CLEAN" | awk '
    /[^[:space:]]/ { seen = 1 }
    seen { lines[++n] = $0 }
    END {
        last = n
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        for (i = 1; i <= last; i++) print lines[i]
    }
')"

# Prepend title since the heading line was stripped.
OUTPUT="Getting Started

$CLEAN"

if [[ -n "$OUT" ]]; then
    printf '%s\n' "$OUTPUT" > "$OUT"
else
    printf '%s\n' "$OUTPUT"
fi
