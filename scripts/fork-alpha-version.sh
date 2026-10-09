#!/usr/bin/env bash
# Compute the next fork alpha tag: vX.Y.(Z+1)-alpha.N
#
# Usage: fork-alpha-version.sh <stable-x.y.z> <file-with-existing-tags>
#   <stable-x.y.z>          latest upstream STABLE version (leading "v" tolerated)
#   <file-with-existing-tags>  newline-delimited list of existing tags (e.g. `git tag`)
#
# N = highest existing vTARGET-alpha.<N> + 1, where TARGET = X.Y.(Z+1). N resets
# to 1 when the stable base moves up (no alpha tags exist yet for the new target).
set -euo pipefail

base="${1#v}"
tags_file="$2"

echo "$base" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "bad stable version: '$base'" >&2; exit 1; }

IFS='.' read -r major minor patch <<< "$base"
target="${major}.${minor}.$((patch + 1))"

last="$(grep -E "^v${target}-alpha\.[0-9]+$" "$tags_file" 2>/dev/null \
  | sed -E "s/^v${target}-alpha\.//" \
  | sort -n | tail -1 || true)"
n=$(( ${last:-0} + 1 ))
echo "v${target}-alpha.${n}"
