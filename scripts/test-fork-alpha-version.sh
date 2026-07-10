#!/usr/bin/env bash
set -euo pipefail
here="$(dirname "$0")"
tmp="$(mktemp)"

# Case 1: stable 0.27.0, no existing alpha tags -> v0.27.1-alpha.1
printf '' > "$tmp"
got="$(bash "$here/fork-alpha-version.sh" 0.27.0 "$tmp")"
[ "$got" = "v0.27.1-alpha.1" ] || { echo "FAIL c1: got $got"; exit 1; }

# Case 2: stable 0.27.0, existing alpha.1 and alpha.2 -> v0.27.1-alpha.3
printf 'v0.27.1-alpha.1\nv0.27.1-alpha.2\n' > "$tmp"
got="$(bash "$here/fork-alpha-version.sh" 0.27.0 "$tmp")"
[ "$got" = "v0.27.1-alpha.3" ] || { echo "FAIL c2: got $got"; exit 1; }

# Case 3: new stable 0.28.0 resets the alpha counter -> v0.28.1-alpha.1
printf 'v0.27.1-alpha.5\n' > "$tmp"
got="$(bash "$here/fork-alpha-version.sh" 0.28.0 "$tmp")"
[ "$got" = "v0.28.1-alpha.1" ] || { echo "FAIL c3: got $got"; exit 1; }

# Case 4: leading-v stable arg tolerated; gaps ignored (alpha.10 > alpha.9)
printf 'v0.27.1-alpha.9\nv0.27.1-alpha.10\n' > "$tmp"
got="$(bash "$here/fork-alpha-version.sh" v0.27.0 "$tmp")"
[ "$got" = "v0.27.1-alpha.11" ] || { echo "FAIL c4: got $got"; exit 1; }

echo "ALL PASS"
