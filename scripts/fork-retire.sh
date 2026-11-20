#!/usr/bin/env bash
# Retire manifest entries whose upstream PR has merged AND whose merge commit the
# release base already contains: set `active: false` and record why, as a commit
# pushed to the overlay branch.
#
# Env:
#   BASE_REF       the base the rebuild is about to use (required)
#   BASE_TAG       its release tag, for the history note (default: BASE_REF)
#   REMOTE         remote holding the overlay branch      (default origin)
#   OVERLAY_BRANCH overlay branch name                    (default fork-overlay)
#
# Purely bookkeeping: fork-rebuild.sh already drops such a feature on its own, so
# a failure here (gh unavailable, a concurrent push winning the lease) changes
# nothing in main-alpha. It warns and exits 0; the next sync retries.
#
# The condition only becomes true when the base moves to a release containing the
# merge, and that rebuild changes the tree anyway, so retiring in the same run
# costs no extra alpha.
set -uo pipefail

: "${BASE_REF:?BASE_REF is required}"
BASE_TAG="${BASE_TAG:-$BASE_REF}"
REMOTE="${REMOTE:-origin}"
OVERLAY_BRANCH="${OVERLAY_BRANCH:-fork-overlay}"
warn() { echo "::warning::fork-retire: $*" >&2; }

lease_ref="refs/fork-retire/base"
if ! git fetch -q "$REMOTE" "+refs/heads/${OVERLAY_BRANCH}:${lease_ref}"; then
  warn "could not fetch ${REMOTE}/${OVERLAY_BRANCH}; skipping"
  exit 0
fi
old="$(git rev-parse "$lease_ref")"

tmpdir="$(mktemp -d)"
cleanup() { git worktree remove --force "$tmpdir/wt" 2>/dev/null || true; rm -rf "$tmpdir"; git update-ref -d "$lease_ref" 2>/dev/null || true; }
trap cleanup EXIT

# Same parser as fork-rebuild.sh: branch, pr, active. CRs stripped.
git cat-file blob "${old}:fork-features.yml" | tr -d '\r' | awk '
  function flush() { if (branch != "") print branch "\t" pr "\t" active }
  /^[[:space:]]*-[[:space:]]*branch:/ {
    flush(); branch=$0; sub(/.*branch:[[:space:]]*/, "", branch)
    pr="null"; active="true"; next
  }
  /^[[:space:]]*upstream_pr:/ { pr=$0; sub(/.*upstream_pr:[[:space:]]*/, "", pr); next }
  /^[[:space:]]*active:/      { active=$0; sub(/.*active:[[:space:]]*/, "", active); next }
  END { flush() }
' > "$tmpdir/manifest.tsv"

: > "$tmpdir/retire.tsv"
# gh drains stdin: read the manifest on FD 3 and give gh /dev/null.
while IFS=$'\t' read -r branch pr active <&3; do
  [ -z "$branch" ] || [ "$pr" = "null" ] || [ "$active" = "false" ] && continue
  num="${pr##*#}"; repo="${pr%#*}"
  state="$(gh pr view "$num" --repo "$repo" --json state -q .state 2>/dev/null </dev/null)"
  [ "$state" = "MERGED" ] || continue
  mc="$(gh pr view "$num" --repo "$repo" --json mergeCommit -q .mergeCommit.oid 2>/dev/null </dev/null)"
  if [ -z "$mc" ] || ! git cat-file -e "${mc}^{commit}" 2>/dev/null; then
    warn "${branch}: ${pr} is MERGED but its merge commit (${mc:-unknown}) is not available; left active"
    continue
  fi
  git merge-base --is-ancestor "$mc" "$BASE_REF" || continue   # still being carried
  printf '%s\t%s\t%s\n' "$branch" "$pr" "$mc" >> "$tmpdir/retire.tsv"
done 3< "$tmpdir/manifest.tsv"

if [ ! -s "$tmpdir/retire.tsv" ]; then
  echo "fork-retire: nothing to retire against ${BASE_TAG}"
  exit 0
fi

git worktree add -q --detach "$tmpdir/wt" "$old" || { warn "could not check out ${OVERLAY_BRANCH}; skipping"; exit 0; }
today="$(date -u +%Y-%m-%d)"
subjects=""
while IFS=$'\t' read -r branch pr mc; do
  note="Retired automatically ${today}: ${pr} merged as $(git rev-parse --short=8 "$mc"), released in ${BASE_TAG}."
  # Within this entry's block (from its `- branch:` line to the next one): set
  # `active: false`, adding the key after `upstream_pr:` if absent, and put the
  # history note above the `- branch:` line at the same indentation.
  awk -v target="$branch" -v note="$note" '
    function finish() {
      if (inblk && !seen_active && pr_line != "") { lines[pr_idx] = lines[pr_idx] "\n" pr_indent "active: false" }
      inblk = 0
    }
    {
      line = $0
      if (match(line, /^[[:space:]]*-[[:space:]]*branch:[[:space:]]*/)) {
        finish()
        name = substr(line, RLENGTH + 1); sub(/[[:space:]]+$/, "", name)
        if (name == target) {
          ind = line; sub(/-.*/, "", ind)
          lines[++n] = ind "# " note
          inblk = 1; seen_active = 0; pr_line = ""
        }
        lines[++n] = line; next
      }
      if (inblk && match(line, /^[[:space:]]*active:/)) {
        pre = line; sub(/active:.*/, "", pre)
        line = pre "active: false"; seen_active = 1
      }
      if (inblk && match(line, /^[[:space:]]*upstream_pr:/)) {
        pr_line = line; pr_indent = line; sub(/upstream_pr:.*/, "", pr_indent); pr_idx = n + 1
      }
      lines[++n] = line
    }
    END { finish(); for (i = 1; i <= n; i++) print lines[i] }
  ' "$tmpdir/wt/fork-features.yml" > "$tmpdir/features.new" && mv "$tmpdir/features.new" "$tmpdir/wt/fork-features.yml"
  subjects="${subjects}${subjects:+, }${pr##*/}"
done < "$tmpdir/retire.tsv"

# Verify the edit through the same parser before committing anything.
while IFS=$'\t' read -r branch pr mc; do
  got="$(tr -d '\r' < "$tmpdir/wt/fork-features.yml" | awk -v t="$branch" '
    /^[[:space:]]*-[[:space:]]*branch:/ { b=$0; sub(/.*branch:[[:space:]]*/, "", b); sub(/[[:space:]]+$/, "", b); cur=(b==t) }
    cur && /^[[:space:]]*active:/ { a=$0; sub(/.*active:[[:space:]]*/, "", a); print a; exit }')"
  if [ "$got" != "false" ]; then
    warn "${branch}: edit did not produce active: false (got '${got}'); nothing pushed"
    exit 0
  fi
done < "$tmpdir/retire.tsv"

(
  cd "$tmpdir/wt" &&
  git add fork-features.yml &&
  git commit -q -m "fork(features): retire ${subjects} (released in ${BASE_TAG})" \
    -m "Automatic: merged upstream and contained in the release base ${BASE_TAG}, so the rebuild no longer replays or carries it. Entry kept as history." &&
  git push -q "$REMOTE" "HEAD:refs/heads/${OVERLAY_BRANCH}" --force-with-lease="refs/heads/${OVERLAY_BRANCH}:${old}"
) || { warn "could not commit or push the retirement of ${subjects} (a concurrent push to ${OVERLAY_BRANCH}?); the next sync retries"; exit 0; }

echo "fork-retire: retired ${subjects} (released in ${BASE_TAG}) on ${OVERLAY_BRANCH}"
