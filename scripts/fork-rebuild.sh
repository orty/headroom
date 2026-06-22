#!/usr/bin/env bash
# Regenerate a fork alpha branch = UPSTREAM_REF + replayed active features + overlay.
#
# Env:
#   UPSTREAM_REF  rebase base                       (default upstream/main)
#   OVERLAY_REF   branch holding fork-owned files   (default origin/fork-overlay)
#   OUT_REF       ref to write the rebuilt commit   (default refs/heads/main-alpha)
#   COMPARE_REF   idempotency baseline tree         (default $OUT_REF)
#
# Reads fork-features.yml and fork-overlay-paths.txt from OVERLAY_REF.
# Prints the new commit SHA, or NO_CHANGE if the rebuilt tree matches COMPARE_REF.
#
# Overlay files are COPIED whole (never merged), so the rebuild cannot conflict.
# Feature branches must be linear (no merge commits).
set -euo pipefail

UPSTREAM_REF="${UPSTREAM_REF:-upstream/main}"
OVERLAY_REF="${OVERLAY_REF:-origin/fork-overlay}"
OUT_REF="${OUT_REF:-refs/heads/main-alpha}"
COMPARE_REF="${COMPARE_REF:-$OUT_REF}"
# release.yml is the fork's Docker-only orchestrator (fires on release:published,
# calls docker.yml via workflow_call, and is the "Release" workflow deploy-to-aca
# chains off). It is NOT upstream's python-package publisher — keep it.
KEEP=(docker.yml release.yml deploy-to-aca.yml sync.yml alpha-release.yml mirror-upstream-release.yml)

tmpdir="$(mktemp -d)"
manifest="$tmpdir/features.yml"
paths="$tmpdir/paths.txt"
git cat-file blob "$OVERLAY_REF:fork-features.yml"      > "$manifest"
git cat-file blob "$OVERLAY_REF:fork-overlay-paths.txt" > "$paths"

work="$(mktemp -d)"
git worktree add -q --detach "$work" "$UPSTREAM_REF"
cleanup() { git worktree remove --force "$work" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT
cd "$work"

# 1. Replay active features (linear branches only). A feature replays unless its
#    upstream PR is MERGED or active:false. Manifest parsed with awk (no python
#    dependency; portable across CI and local shells). CRs stripped for Windows.
tr -d '\r' < "$manifest" | awk '
  function flush() { if (branch != "" && active != "false") print branch "\t" pr }
  /^[[:space:]]*-[[:space:]]*branch:/ {
    flush(); branch=$0; sub(/.*branch:[[:space:]]*/, "", branch)
    pr="null"; active="true"; next
  }
  /^[[:space:]]*upstream_pr:/ { pr=$0; sub(/.*upstream_pr:[[:space:]]*/, "", pr); next }
  /^[[:space:]]*active:/      { active=$0; sub(/.*active:[[:space:]]*/, "", active); next }
  END { flush() }
' > "$tmpdir/active.txt"

while IFS=$'\t' read -r branch pr; do
  [ -z "$branch" ] && continue
  if [ "$pr" != "null" ]; then
    num="${pr##*#}"; repo="${pr%#*}"
    state="$(gh pr view "$num" --repo "$repo" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    if [ "$state" = "MERGED" ]; then echo "drop $branch (PR $pr MERGED)" >&2; continue; fi
  fi
  base="$(git merge-base "$UPSTREAM_REF" "$branch")"
  echo "replay $branch (${base:0:7}..$branch)" >&2
  git cherry-pick --allow-empty "$base..$branch"
done < "$tmpdir/active.txt"

# 2. Copy fork-owned files whole from the overlay ref (never a merge).
while IFS= read -r p; do
  [ -z "$p" ] && continue
  git checkout "$OVERLAY_REF" -- "$p"
done < "$paths"

# 3. Keep-list trim of workflows + remove wei/pull config.
if [ -d .github/workflows ]; then
  for f in .github/workflows/*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; keep=0
    for k in "${KEEP[@]}"; do [ "$base" = "$k" ] && keep=1; done
    [ "$keep" = 0 ] && git rm -q "$f"
  done
fi
git rm -q --ignore-unmatch .github/pull.yml

# 4. Stage, idempotency check, commit, update OUT_REF.
git add -A
new_tree="$(git write-tree)"
cur_tree="$(git rev-parse -q --verify "${COMPARE_REF}^{tree}" 2>/dev/null || echo none)"
if [ "$new_tree" = "$cur_tree" ]; then
  echo "NO_CHANGE"
  exit 0
fi
git commit -q -m "fork: overlay (CI trim + alpha wiring)"
sha="$(git rev-parse HEAD)"
git update-ref "$OUT_REF" "$sha"
echo "$sha"
