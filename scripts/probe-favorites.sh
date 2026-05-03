#!/usr/bin/env bash
# Probe RP "My Paradise" (channel 99) via nowplaying_list_v2022 with a freshly
# minted player_id. Verifies whether the backend accepts an arbitrary client-
# generated rp3_<uuid> or requires prior registration.
#
# Usage:
#   ./scripts/probe-favorites.sh                 # mint new player_id
#   ./scripts/probe-favorites.sh rp3_<uuid>      # reuse a known player_id
#
# Requires: macOS `security`, `curl`, `python3`. App must be signed-in (cookie
# present in keychain under service=com.gvajda.RPPlayer / account=rp-session-cookie).

set -euo pipefail

SERVICE="com.gvajda.RPPlayer"
ACCOUNT="rp-session-cookie"

cookie="$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || true)"
if [[ -z "$cookie" ]]; then
    echo "ERROR: no cookie in keychain (service=$SERVICE account=$ACCOUNT)." >&2
    echo "Sign in via the app first." >&2
    exit 1
fi

if [[ $# -ge 1 ]]; then
    player_id="$1"
else
    # 8-4-4-4-12 lowercase hex from /dev/urandom, prefixed with rp3_
    raw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    player_id="rp3_${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
fi

url="https://api.radioparadise.com/api/nowplaying_list_v2022?chan=99&player_id=${player_id}&list_num=4"

echo "player_id : $player_id"
echo "url       : $url"
echo "cookie len: ${#cookie}"
echo

http_code="$(curl -sS -o /tmp/rp_probe_body.json -w '%{http_code}' \
    -H "Cookie: $cookie" \
    -H 'User-Agent: RPPlayer-Probe/0.1' \
    -H 'Accept: application/json' \
    "$url")"

echo "HTTP $http_code"
echo "--- body ---"
if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool /tmp/rp_probe_body.json 2>/dev/null || cat /tmp/rp_probe_body.json
else
    cat /tmp/rp_probe_body.json
fi
echo
