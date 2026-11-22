#!/usr/bin/env bash
# Decide whether alpha-release.yml may skip cutting an alpha for HEAD.
#
# Usage: fork-alpha-skip.sh [head-ref]   (default HEAD; run inside the repo)
#
# Prints "skip <prev-tag>" followed by the changed paths, one per line, when
# every path changed since the previous fork alpha is fork tooling that cannot
# change the Docker image. Prints "release <reason>" otherwise.
# Always exits 0 unless git itself fails.
#
# Previous alpha = the highest-version v*-alpha.* tag, NOT "the latest tag
# reachable from HEAD": sync.yml regenerates main-alpha (fresh cherry-picks, new
# SHAs) on every rebuild, so after one rebuild the previous alpha is no longer
# an ancestor. The comparison is tree to tree, which works across rebuilds.
#
# Exempt paths, checked against the image build (docker-bake.hcl: context ".",
# Dockerfile): the Dockerfile COPYs only scripts/install-rustup.sh,
# pyproject.toml, uv.lock, README*.md, Cargo.*, rust-toolchain.toml, crates/ and
# headroom/; its bind mount of the context reads .git (revision stamp) and those
# same inputs; .dockerignore drops .github (except .github/plugin, which nothing
# reads) and docs/. None of the paths below is an image input.
set -euo pipefail

head_ref="${1:-HEAD}"

prev="$(git tag -l 'v*-alpha.*' | sort -V | tail -1)"
if [ -z "$prev" ]; then
  echo "release no previous v*-alpha.* tag"
  exit 0
fi

changed="$(git diff --name-only --no-renames "$prev" "$head_ref" --)"
if [ -z "$changed" ]; then
  # Same tree as the last alpha: nothing for an image to pick up.
  echo "skip ${prev}"
  exit 0
fi

while IFS= read -r p; do
  case "$p" in
    .github/*|docs/*|rr-cache/*|fork-overlay-paths.txt|fork-features.yml) ;;
    # scripts/fork-*.sh but not deeper paths (case `*` also matches `/`).
    scripts/fork-*.sh) case "${p#scripts/}" in */*) echo "release image input changed: ${p}"; exit 0 ;; esac ;;
    *) echo "release image input changed: ${p}"; exit 0 ;;
  esac
done <<< "$changed"

echo "skip ${prev}"
printf '%s\n' "$changed"
