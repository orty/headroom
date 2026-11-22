#!/usr/bin/env bash
# Tests for scripts/fork-alpha-skip.sh against throwaway repos.
# Run: bash scripts/test-fork-alpha-skip.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
skip="$here/fork-alpha-skip.sh"
fail=0

check() { # name expected-first-word actual-output
  local got="${3%%[ $'\n']*}"
  if [ "$got" = "$2" ]; then echo "ok   $1 -> $got"; else echo "FAIL $1: want $2, got: $3"; fail=1; fi
}

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main-alpha
git config user.email t@t; git config user.name t; git config core.autocrlf false
commit() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; git add -A; git commit -qm "$1"; }

commit headroom/proxy.py
check "first run, no alpha tag" release "$(bash "$skip")"

git tag v0.1.1-alpha.1
check "HEAD equals last alpha" skip "$(bash "$skip")"

# Simulate a rebuild: same content, fresh commits (tag no longer an ancestor).
git checkout -q --orphan rebuilt; git commit -qm rebuilt
for p in .github/workflows/sync.yml docs/superpowers/plans/x.md fork-features.yml \
         fork-overlay-paths.txt scripts/fork-rebuild.sh rr-cache/abc/postimage; do commit "$p"; done
out="$(bash "$skip")"
check "overlay-only after rebuild (tag unreachable)" skip "$out"
printf '%s\n' "$out" | grep -qx 'scripts/fork-rebuild.sh' || { echo "FAIL changed paths not listed"; fail=1; }

for p in headroom/proxy.py Dockerfile scripts/install-rustup.sh scripts/fork-x/y.sh \
         pyproject.toml crates/a.rs .dockerignore README.md; do
  git checkout -q -B t rebuilt; commit "$p"
  check "image input $p" release "$(bash "$skip")"
done

git checkout -q -B t rebuilt; commit headroom/x.py; git tag v0.1.1-alpha.2
commit .github/workflows/docker.yml
check "highest version tag wins (alpha.2)" skip "$(bash "$skip")"
git tag v0.1.1-alpha.10 HEAD~1
check "version sort: alpha.10 > alpha.2" skip "$(bash "$skip" | head -1 | grep -q 'alpha.10' && echo skip || echo wrong)"

exit "$fail"
