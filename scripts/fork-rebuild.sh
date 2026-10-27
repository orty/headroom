#!/usr/bin/env bash
# Regenerate a fork alpha branch = UPSTREAM_REF + replayed active features + overlay.
#
# Env:
#   UPSTREAM_REF       rebase base                      (default upstream/main)
#   FEATURE_BASE_REF   ref whose commits count as "already upstream" when
#                      linearizing features            (default $UPSTREAM_REF)
#   OVERLAY_REF        branch holding fork-owned files  (default origin/fork-overlay)
#   OUT_REF            ref to write the rebuilt commit  (default refs/heads/main-alpha)
#   COMPARE_REF        idempotency baseline tree        (default $OUT_REF)
#
# UPSTREAM_REF is the BASE the alpha sits on; FEATURE_BASE_REF is what gets
# excluded from feature replay. They differ when the base is pinned to a release
# tag (so the alpha only moves on upstream releases) while features are still
# branched off bleeding-edge upstream/main: setting FEATURE_BASE_REF=upstream/main
# keeps intervening post-release upstream commits OUT of the alpha (only genuine
# feature commits replay onto the tag). Equal by default for plain main-based use.
#
# Reads fork-features.yml and fork-overlay-paths.txt from OVERLAY_REF.
# Prints the new commit SHA, or NO_CHANGE if the rebuilt tree matches COMPARE_REF.
#
# Overlay files are COPIED whole (never merged), so the rebuild cannot conflict.
#
# Features replay commit by commit. If that conflicts -- the base moved under an
# older commit, or the PR's conflict resolution lives in a merge commit that
# --no-merges drops -- the feature is rolled back and replayed ONCE MORE as a
# single commit carrying its net change: the diff from its merge-base with
# FEATURE_BASE_REF to its current head, applied 3-way. For a feature with an
# upstream PR the head is refs/pull/N/head, i.e. exactly what reviewers see.
# Only if that conflicts too does the rebuild fail.
#
# A feature whose PR has MERGED drops out only once the base contains the merge
# commit. Until then (the base is a release tag cut before the merge) the rebuild
# carries exactly what upstream merged, so main-alpha keeps the fix across the
# merge-to-release window. Requires `gh` access to the upstream repo; without it
# the PR state reads as unknown and the feature replays from its branch.
#
# STORED CONFLICT RESOLUTIONS (git rerere). Some conflicts are textual only: the
# base and the PR disagree about lines next to an insertion, and no merge strategy
# can tell where the line belongs. Resolve such a conflict ONCE and store it as
# rr-cache/<hash>/{preimage,postimage} on the overlay ref; every rebuild restores
# these into the work repo and replays with rerere on, so a conflict whose text
# matches EXACTLY a stored one is resolved the same way, with no human. Entries
# are keyed on the conflicting text, not on commit ids, so they survive new pushes
# to the PR that leave that hunk alone; an entry that no longer matches is unused.
# Applies to commit-by-commit replay and to the carry step's cherry-pick retry
# (not to the net-change fallback, which uses `git apply`). rr-cache/ stays on the
# overlay branch and is not copied into main-alpha. To record a resolution:
#   git worktree add --detach /tmp/rec <failing base>; cd /tmp/rec
#   git -c rerere.enabled=true cherry-pick <the feature's commits>   # stops
#   <edit the file to resolve>; git add <file>
#   git -c rerere.enabled=true cherry-pick --continue --no-edit      # records it
#   cp -r "$(git rev-parse --path-format=absolute --git-path rr-cache)/<hash>" \
#         <fork-overlay checkout>/rr-cache/        # preimage + postimage; commit
set -euo pipefail

UPSTREAM_REF="${UPSTREAM_REF:-upstream/main}"
FEATURE_BASE_REF="${FEATURE_BASE_REF:-$UPSTREAM_REF}"
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

# Stored conflict resolutions: restore rr-cache/ from the overlay ref into this
# repo's rerere cache (see the header).
RR=(-c rerere.enabled=true -c rerere.autoupdate=true)
rr_dir="$(git rev-parse --path-format=absolute --git-path rr-cache)"
rr_n=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "${f##*/}" in preimage|postimage) ;; *) continue ;; esac
  d="$rr_dir/$(basename "$(dirname "$f")")"
  mkdir -p "$d"
  git cat-file blob "$OVERLAY_REF:$f" > "$d/${f##*/}"
  [ "${f##*/}" = postimage ] && rr_n=$((rr_n + 1))
done < <(git ls-tree -r --name-only "$OVERLAY_REF" -- rr-cache 2>/dev/null)
[ "$rr_n" -gt 0 ] && echo "rr-cache: restored $rr_n stored conflict resolution(s)" >&2

# cherry-pick "$@" with rerere on. When every conflict was resolved from the
# cache (nothing left unmerged; autoupdate has staged it) finish the pick with
# --continue, repeating for a multi-commit range. Returns non-zero, leaving the
# state for the caller to abort, if anything is still unresolved.
pick() {
  local out rc=0 n=0
  out="$(git "${RR[@]}" cherry-pick "$@" 2>&1)" || rc=$?
  while [ "$rc" -ne 0 ] && [ "$n" -lt 100 ]; do
    [ -z "$(git diff --name-only --diff-filter=U)" ] || return "$rc"
    [ -e "$(git rev-parse --path-format=absolute --git-path CHERRY_PICK_HEAD)" ] || return "$rc"
    echo "::notice::applied with a stored conflict resolution (rr-cache)" >&2
    rc=0; out="$(git "${RR[@]}" cherry-pick --continue --no-edit 2>&1)" || rc=$?
    n=$((n + 1))
  done
  return "$rc"
}

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

# The main-line commit just before PR <num> landed as <mc>. A merge commit's
# first parent; for a single-parent merge (squash or rebase), walk back while
# GitHub still attributes the commit to the same PR, so a rebase merge that
# landed as several commits is carried whole.
pre_merge_base() {
  local repo="$1" num="$2" mc="$3" b n=0
  if [ "$(git rev-list --parents -n1 "$mc" | wc -w)" -gt 2 ]; then
    git rev-parse "${mc}^1"; return
  fi
  b="$(git rev-parse "${mc}^")"
  while [ "$n" -lt 200 ] && gh api "repos/${repo}/commits/${b}/pulls" -q '.[].number' 2>/dev/null </dev/null | grep -qx "$num"; do
    b="$(git rev-parse "${b}^")"; n=$((n + 1))
  done
  echo "$b"
}

# Replay exactly what upstream merged for a PR the base does not contain yet.
carry_feature() {
  local branch="$1" pr="$2" num="$3" repo="$4" mc="$5" from
  from="$(pre_merge_base "$repo" "$num" "$mc")"
  local start; start="$(git rev-parse HEAD)"
  git diff --binary "$from" "$mc" > "$tmpdir/carry.patch"
  if ! git apply --3way --index "$tmpdir/carry.patch" >/dev/null 2>"$tmpdir/apply.err"; then
    # git apply never consults rerere. Retry as real cherry-picks so a stored
    # resolution can apply: -m 1 for a merge commit, else the range of commits
    # GitHub attributes to the PR (one for a squash). Squashed back into one
    # commit below, so the result looks the same as a clean apply.
    git diff --name-only --diff-filter=U > "$tmpdir/carry.conflicts" || true
    git reset -q --hard "$start"
    local ok=1
    if [ "$(git rev-list --parents -n1 "$mc" | wc -w)" -gt 2 ]; then
      pick --allow-empty -m 1 "$mc" || ok=0
    else
      pick --allow-empty "${from}..${mc}" || ok=0
    fi
    if [ "$ok" = 1 ]; then
      git reset -q --soft "$start"
    else
      git cherry-pick --abort 2>/dev/null || true
      git reset -q --hard "$start"
      echo "::error::${branch}: ${pr} merged upstream as $(git rev-parse --short "$mc"), but that change does not apply on $(git rev-parse --short "$UPSTREAM_REF"), which predates it, and no stored resolution covers the conflict. Conflicting files:" >&2
      cat "$tmpdir/carry.conflicts" >&2
      cat "$tmpdir/apply.err" >&2
      exit 1
    fi
  fi
  if git diff --cached --quiet; then
    echo "::notice::${branch}: ${pr} adds nothing on top of $(git rev-parse --short "$UPSTREAM_REF"); nothing to carry" >&2
    return 0
  fi
  git commit -q -m "$(git log -1 --format=%s "$mc")" \
    -m "Carried from upstream ${mc} (${pr}, merged): the base $(git rev-parse --short "$UPSTREAM_REF") predates the merge. Drops automatically once a base contains it."
  echo "::notice::${branch}: carrying ${pr} (merged upstream as $(git rev-parse --short "$mc")) until a release base contains it" >&2
}

while IFS=$'\t' read -r branch pr; do
  [ -z "$branch" ] && continue

  # Drop the feature once its upstream PR has merged AND the base contains the
  # merge (keyed on the PR NUMBER, not the branch name) -- the delta-reduction
  # mechanism. Merged but not yet in the base (the base is a release tag cut
  # before the merge): CARRY exactly what upstream merged instead, so main-alpha
  # never loses a fix in the window between merge and release.
  if [ "$pr" != "null" ]; then
    num="${pr##*#}"; repo="${pr%#*}"
    state="$(gh pr view "$num" --repo "$repo" --json state -q .state 2>/dev/null </dev/null || echo UNKNOWN)"
    if [ "$state" = "MERGED" ]; then
      mc="$(gh pr view "$num" --repo "$repo" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null </dev/null || true)"
      if [ -z "$mc" ] || ! git cat-file -e "${mc}^{commit}" 2>/dev/null; then
        echo "::warning::${branch}: ${pr} is MERGED but its merge commit (${mc:-unknown}) is not available here; dropped without checking whether ${UPSTREAM_REF} contains it" >&2
        continue
      fi
      if git merge-base --is-ancestor "$mc" "$UPSTREAM_REF"; then
        echo "drop $branch (PR $pr MERGED, base contains $(git rev-parse --short "$mc"))" >&2
        continue
      fi
      carry_feature "$branch" "$pr" "$num" "$repo" "$mc"
      continue
    fi
  fi

  # Resolve the branch ref, preferring the origin tracking ref — that is the
  # authoritative PR head. A stale LOCAL branch of the same name (e.g. an old dev
  # checkout) must never shadow it, or the fork replays outdated feature content.
  # Only needed from here on: a MERGED PR is carried by number above and needs no
  # fork branch, so an upstream PR the fork did not author can be carried too.
  ref="origin/$branch"
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || ref="$branch"
  git rev-parse --verify -q "$ref^{commit}" >/dev/null \
    || { echo "::error::feature branch not found: $branch" >&2; exit 1; }

  echo "replay $branch via $ref (linearize on the fly)" >&2
  # Genuine feature commits only: --no-merges drops merge commits, and
  # --right-only --cherry-pick drops commits already upstream (by patch-id), so
  # the PR head branch can be replayed directly even though it contains merges.
  # Exclude against FEATURE_BASE_REF (= upstream/main in release-pinned mode) so
  # post-release upstream commits are NOT replayed onto the release-tag base.
  commits="$(git rev-list --reverse --no-merges --right-only --cherry-pick "$FEATURE_BASE_REF...$ref")"
  start="$(git rev-parse HEAD)"
  failed=""
  for c in $commits; do
    if ! pick --allow-empty "$c"; then
      failed="$c"
      git cherry-pick --abort 2>/dev/null || true
      break
    fi
  done
  [ -z "$failed" ] && continue

  # Fallback: net change of the feature's current head, as one commit.
  git reset -q --hard "$start"
  src="$ref"; label="$branch"
  if [ "$pr" != "null" ]; then
    if git fetch -q "https://github.com/${repo}.git" "+refs/pull/${num}/head:refs/fork-rebuild/pr/${num}" 2>/dev/null; then
      src="refs/fork-rebuild/pr/${num}"; label="$pr"
    else
      echo "::warning::could not fetch ${pr} head; using ${ref} for the net-change replay" >&2
    fi
  fi
  mb="$(git merge-base "$src" "$FEATURE_BASE_REF")"
  git diff --binary "$mb" "$src" > "$tmpdir/net.patch"
  if [ ! -s "$tmpdir/net.patch" ]; then
    echo "::notice::${branch}: net change of ${label} is empty; nothing to replay" >&2
    continue
  fi
  if ! git apply --3way --index "$tmpdir/net.patch" >/dev/null 2>"$tmpdir/apply.err"; then
    echo "::error::${branch}: commit $(git rev-parse --short "$failed") conflicts, and the net change of ${label} does not apply on $(git rev-parse --short "$UPSTREAM_REF") either. Conflicting files:" >&2
    git diff --name-only --diff-filter=U >&2 || true
    cat "$tmpdir/apply.err" >&2
    exit 1
  fi
  subject="$(git log -1 --format=%s "$(echo "$commits" | head -1)")"
  git commit -q -m "$subject" -m "Net change of ${label} at $(git rev-parse --short "$src"), replayed as one commit: commit $(git rev-parse --short "$failed") did not apply on this base."
  echo "::warning::${branch}: commit replay conflicted at $(git rev-parse --short "$failed"); replayed the net change of ${label} ($(git rev-parse --short "$src")) as one commit instead" >&2
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
