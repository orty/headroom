# Fork rebase-overlay model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fork's merge-based upstream sync with a rebase-overlay model so the
fork delta = `upstream/main` + replayed in-flight feature branches (manifest-tracked) +
**one** additive "fork overlay" commit, with CI trimmed to Docker publishing.

**Architecture:** A `scripts/fork-rebuild.sh` regenerates `main-alpha` from scratch on every
sync: detached `upstream/main` → cherry-pick active (linear) feature branches → copy
fork-owned files from a stable `fork-overlay` branch → delete every workflow not in the
keep-set → one overlay commit → force-push only if the resulting tree changed. Versioning
(`vX.Y.(Z+1)-alpha.N`) and upstream-release mirroring keep their existing dynamic logic,
rewired to `headroomlabs-ai/headroom`. A one-time migration collapses today's 47-commit
divergence into `upstream/main` + the linearized PR #1118 feature + the overlay commit.

**Tech Stack:** Bash, git (worktrees, cherry-pick, ls-tree), GitHub Actions, `gh` CLI.

## Global Constraints

- Upstream is `headroomlabs-ai/headroom`. No `chopratejas` reference may remain in any
  `.github/**` file after this work. Verify with `grep -rn chopratejas .github/` → no hits.
- Releases/tags that must fire `release: published` (→ `docker.yml`) are created with the
  PAT secret `FORK_RELEASE_PAT`, never `GITHUB_TOKEN`. Branch pushes that must trigger
  downstream workflows use the deploy-key secret `SYNC_DEPLOY_KEY`. Both already exist.
- `pyproject.toml` is **never** version-bumped in the fork. Alpha version is computed at
  release time only. The floor overlay touches no upstream-shared content file (only
  fork-owned paths, copied whole).
- `main-alpha` is a rolling, force-pushed branch. Reversibility is provided by backup refs
  pushed to `origin` before any force-push.
- The Windows shell mangles `git show REF:path`; always use `git ls-tree REF -- path` /
  `git cat-file` / `git checkout REF -- path` for ref-relative file access in this repo.
- Keep-set workflows (the only ones that run on the fork): `docker.yml`,
  `release.yml`, `deploy-to-aca.yml`, `sync.yml`, `alpha-release.yml`, `mirror-upstream-release.yml`. (release.yml is the fork Docker-only orchestrator, NOT upstream's python publisher.)
- The manifest names the actual upstream-PR head branch; the rebuild linearizes it on the
  fly (`--no-merges --right-only --cherry-pick`, preferring the `origin/` tracking ref over
  any stale local branch). Feature branches need NOT be pre-linearized. (Supersedes Task 2's
  separate `feat/*` branch approach.)
- Authoritative current `upstream/main` = `95b2333e` (2026-06-21). It contains
  `scripts/version-sync.py`, `pyproject.toml`, and `docker.yml`.

---

## File structure

| Path | Responsibility | Lives on |
|------|----------------|----------|
| `scripts/fork-rebuild.sh` | Regenerate main-alpha (replay + overlay + trim + idempotency) | `fork-overlay` (source) + copied to `main-alpha` |
| `scripts/fork-alpha-version.sh` | Pure version computation `vX.Y.(Z+1)-alpha.N` | same |
| `fork-features.yml` | Feature → upstream PR registry | `fork-overlay` |
| `fork-overlay-paths.txt` | Newline list of fork-owned paths copied each rebuild | `fork-overlay` |
| `.github/workflows/sync.yml` | Scheduled rebuild driver (replaces `sync-from-main.yml`) | overlay |
| `.github/workflows/alpha-release.yml` | Cut `vX.Y.(Z+1)-alpha.N` on push to main-alpha | overlay |
| `.github/workflows/mirror-upstream-release.yml` | Mirror upstream stable releases → fork | overlay |
| `.github/workflows/deploy-to-aca.yml` | ACA deploy (fork-only) | overlay |
| `.github/workflows/docker.yml` | Image build/publish (fork-modified upstream file) | overlay |
| `docs/superpowers/**` | Spec + this plan (survive rebuilds) | overlay |

**Source-of-truth branch `fork-overlay`:** holds the fork-owned files above. The user edits
the fork's wiring here. `main-alpha` is derived and disposable.

---

## Task 1: Safety backups (reversibility floor)

**Files:** none (git refs only).

**Interfaces:**
- Produces: backup refs `backup/main-pre-overlay`, `backup/main-alpha-pre-overlay` on
  `origin`, recoverable by `git push --force origin backup/X:main`.

- [ ] **Step 1: Fetch everything fresh**

```bash
cd /c/Users/SergeARADJ/Projects/headroom
git fetch origin --prune
git fetch upstream --prune
```

- [ ] **Step 2: Create local backup branches at current tips**

```bash
git branch -f backup/main-pre-overlay origin/main
git branch -f backup/main-alpha-pre-overlay main-alpha
```

- [ ] **Step 3: Push backups to origin (so a bad force-push is recoverable)**

```bash
git push origin backup/main-pre-overlay backup/main-alpha-pre-overlay
```

- [ ] **Step 4: Verify both backups exist on origin**

Run: `git ls-remote --heads origin 'backup/*'`
Expected: two lines, `backup/main-pre-overlay` and `backup/main-alpha-pre-overlay`.

---

## Task 2: Linearize the PR #1118 feature branch

**Files:**
- Create (branch): `feat/docker-session-history-persist`

**Interfaces:**
- Consumes: `origin/claude/docker-session-history-persist-ntw1t2` (PR #1118 head, 8 commits
  incl. 2 merge commits), `upstream/main`.
- Produces: linear branch `feat/docker-session-history-persist` whose
  `merge-base(upstream/main, branch)..branch` range is merge-free and cherry-pickable.

- [ ] **Step 1: Create the linear feature branch by rebasing onto upstream/main**

```bash
git branch -f feat/docker-session-history-persist origin/claude/docker-session-history-persist-ntw1t2
git rebase --rebase-merges=no-rebase-cousins --onto upstream/main \
  $(git merge-base upstream/main origin/claude/docker-session-history-persist-ntw1t2) \
  feat/docker-session-history-persist || true
# If conflicts: resolve, `git rebase --continue`. The feature only touches
# Dockerfile / docker-compose.yml / docker/ — conflicts (if any) are small.
```

- [ ] **Step 2: Verify the branch is linear (no merge commits)**

Run: `git log --merges upstream/main..feat/docker-session-history-persist`
Expected: empty output (no merge commits).

- [ ] **Step 3: Verify the feature content is present**

Run: `git diff --name-only upstream/main..feat/docker-session-history-persist`
Expected: includes `Dockerfile` and the session-history persistence change; does NOT
include `docker/aca-containerapp.yaml` as an addition (it is deleted/absent).

- [ ] **Step 4: Verify it cherry-picks cleanly onto a detached upstream/main**

```bash
W=$(mktemp -d); git worktree add --detach "$W" upstream/main
( cd "$W" && git cherry-pick $(git merge-base upstream/main feat/docker-session-history-persist)..feat/docker-session-history-persist )
echo "cherry-pick exit: $?"
git worktree remove --force "$W"
```
Expected: `cherry-pick exit: 0`.

- [ ] **Step 5: Push the linear feature branch to origin**

```bash
git push -f origin feat/docker-session-history-persist
```
(Keep PR #1118's existing head branch as-is so the open PR is undisturbed; this is a
parallel clean branch the rebuild replays from.)

---

## Task 3: Author the `fork-overlay` source branch — wiring workflows

**Files:**
- Create (branch): `fork-overlay` (orphan-style content branch)
- Create: `.github/workflows/sync.yml`
- Modify-into-overlay: `.github/workflows/alpha-release.yml`, `mirror-upstream-release.yml`,
  `deploy-to-aca.yml`, `docker.yml` (rewired copies of current main-alpha versions)

**Interfaces:**
- Produces: branch `fork-overlay` containing fork-owned files, all referencing
  `headroomlabs-ai/headroom`.

- [ ] **Step 1: Seed `fork-overlay` from current main-alpha (carries existing wiring)**

```bash
git branch -f fork-overlay main-alpha
git switch fork-overlay
```

- [ ] **Step 2: Rewire every chopratejas reference → headroomlabs-ai**

```bash
grep -rl chopratejas .github/ | while read f; do
  sed -i 's#chopratejas/headroom#headroomlabs-ai/headroom#g; s#chopratejas:main#headroomlabs-ai:main#g' "$f"
done
```

- [ ] **Step 3: Verify no chopratejas remains**

Run: `grep -rn chopratejas .github/`
Expected: no output (exit 1).

- [ ] **Step 4: Replace `sync-from-main.yml` with the new `sync.yml`**

Delete the old driver and create the new one:

```bash
git rm -q .github/workflows/sync-from-main.yml
```

Create `.github/workflows/sync.yml`:

```yaml
name: Sync (rebuild main-alpha)

# Every 30 min: rebuild main-alpha = upstream/main + replayed features + overlay,
# and mirror fork main to upstream. Runs from the default branch (main-alpha),
# where this file lives, so the schedule fires. Uses SYNC_DEPLOY_KEY (not
# GITHUB_TOKEN) so the force-push to main-alpha triggers alpha-release.yml /
# mirror-upstream-release.yml.

on:
  schedule:
    - cron: '*/30 * * * *'
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: fork-sync
  cancel-in-progress: false

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: main-alpha
          fetch-depth: 0
          ssh-key: ${{ secrets.SYNC_DEPLOY_KEY }}
      - name: Configure git + upstream
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git remote add upstream https://github.com/headroomlabs-ai/headroom.git
          git fetch upstream main
          git fetch origin fork-overlay 'refs/heads/feat/*:refs/heads/feat/*' || true
      - name: Mirror origin/main := upstream/main
        run: |
          if [ "$(git rev-parse upstream/main)" != "$(git rev-parse origin/main)" ]; then
            git push origin upstream/main:refs/heads/main --force
          fi
      - name: Rebuild main-alpha
        env:
          GH_TOKEN: ${{ secrets.FORK_RELEASE_PAT }}
        run: |
          git update-ref -d refs/heads/main-alpha-next 2>/dev/null || true
          # COMPARE_REF = the live branch, so an unchanged rebuild is detected as
          # NO_CHANGE and the temp ref is never created (no spurious alpha).
          UPSTREAM_REF=upstream/main OVERLAY_REF=origin/fork-overlay \
            COMPARE_REF=origin/main-alpha OUT_REF=refs/heads/main-alpha-next \
            bash scripts/fork-rebuild.sh
      - name: Force-push main-alpha if changed
        run: |
          if git rev-parse -q --verify refs/heads/main-alpha-next >/dev/null 2>&1; then
            git push origin refs/heads/main-alpha-next:refs/heads/main-alpha --force
          else
            echo "rebuild reported NO_CHANGE; nothing to push"
          fi
```

- [ ] **Step 5: Decide docker.yml floor inclusion**

Run: `git diff upstream/main:.github/workflows/docker.yml fork-overlay:.github/workflows/docker.yml`
(use `git --no-pager diff <(git cat-file blob upstream/main:.github/workflows/docker.yml) <(git cat-file blob fork-overlay:.github/workflows/docker.yml)` if the `:` form misbehaves on Windows).
Decision: if the diff is only trigger-retarget (to main-alpha release events) and/or
resolved-version stamping for `/readyz`, **keep** fork's `docker.yml` in the overlay.
Otherwise reset it to upstream's and drop it from `fork-overlay-paths.txt` (Task 5).
Record the decision in a comment at the top of `docker.yml`.

- [ ] **Step 6: Commit the wiring onto fork-overlay**

```bash
git add -A
git commit -m "chore(fork): rewire wiring workflows to headroomlabs-ai + new sync driver"
```

---

## Task 4: Feature manifest `fork-features.yml`

**Files:**
- Create: `fork-features.yml` (on `fork-overlay`)

**Interfaces:**
- Produces: manifest consumed by `scripts/fork-rebuild.sh` — top-level `features:` list of
  `{branch: str, upstream_pr: str|null, active: bool}`.

- [ ] **Step 1: Write the manifest**

```yaml
# Fork feature registry. The rebuild replays each feature whose upstream PR is
# still OPEN (or whose upstream_pr is null) AND active != false. When the PR
# merges upstream, the feature stops replaying and the fork delta shrinks.
features:
  - branch: feat/docker-session-history-persist
    upstream_pr: headroomlabs-ai/headroom#1118
    active: true
```

- [ ] **Step 2: Commit**

```bash
git add fork-features.yml
git commit -m "chore(fork): add feature manifest (PR #1118)"
```

---

## Task 5: `fork-overlay-paths.txt`

**Files:**
- Create: `fork-overlay-paths.txt` (on `fork-overlay`)

**Interfaces:**
- Produces: newline-delimited list of fork-owned paths the rebuild copies whole from
  `fork-overlay`. Consumed by `scripts/fork-rebuild.sh`.

- [ ] **Step 1: Write the path list** (omit `docker.yml` if Task 3 Step 5 chose upstream's)

```
.github/workflows/sync.yml
.github/workflows/alpha-release.yml
.github/workflows/mirror-upstream-release.yml
.github/workflows/deploy-to-aca.yml
.github/workflows/docker.yml
scripts/fork-rebuild.sh
scripts/fork-alpha-version.sh
fork-features.yml
fork-overlay-paths.txt
docs/superpowers
```

- [ ] **Step 2: Commit**

```bash
git add fork-overlay-paths.txt
git commit -m "chore(fork): declare overlay-owned paths"
```

---

## Task 6: `scripts/fork-alpha-version.sh` (pure version compute) + test

**Files:**
- Create: `scripts/fork-alpha-version.sh`
- Test: `scripts/test-fork-alpha-version.sh`

**Interfaces:**
- Produces: `fork-alpha-version.sh` reads stdin lines `STABLE=<x.y.z>` and existing tags on
  stdin via `git tag` substitute; CLI: `fork-alpha-version.sh <stable> <existing-tags-file>`
  prints `vX.Y.(Z+1)-alpha.N`. Pure: no network.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-fork-alpha-version.sh`:

```bash
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

echo "ALL PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-fork-alpha-version.sh`
Expected: FAIL (script `fork-alpha-version.sh` does not exist).

- [ ] **Step 3: Write the implementation**

Create `scripts/fork-alpha-version.sh`:

```bash
#!/usr/bin/env bash
# Compute the next fork alpha tag: vX.Y.(Z+1)-alpha.N
# Usage: fork-alpha-version.sh <stable-x.y.z> <file-with-existing-tags>
set -euo pipefail
base="${1#v}"
tags_file="$2"
echo "$base" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "bad stable: $base" >&2; exit 1; }
IFS='.' read -r major minor patch <<< "$base"
target="${major}.${minor}.$((patch + 1))"
last="$(grep -E "^v${target}-alpha\.[0-9]+$" "$tags_file" 2>/dev/null \
  | sed -E "s/^v${target}-alpha\.//" | sort -n | tail -1 || true)"
n=$(( ${last:-0} + 1 ))
echo "v${target}-alpha.${n}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-fork-alpha-version.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit (on fork-overlay)**

```bash
git add scripts/fork-alpha-version.sh scripts/test-fork-alpha-version.sh
git commit -m "feat(fork): pure alpha-version computation + tests"
```

---

## Task 7: `scripts/fork-rebuild.sh` (the rebuild engine)

**Files:**
- Create: `scripts/fork-rebuild.sh`

**Interfaces:**
- Consumes: env `UPSTREAM_REF`, `OVERLAY_REF`, `OUT_REF`; reads `fork-features.yml`,
  `fork-overlay-paths.txt` from `OVERLAY_REF`.
- Produces: writes the rebuilt commit to `OUT_REF` **iff** its tree differs from the current
  `OUT_REF` tree (idempotency). Prints the new SHA or `NO_CHANGE`.

- [ ] **Step 1: Write the implementation**

Create `scripts/fork-rebuild.sh`:

```bash
#!/usr/bin/env bash
# Regenerate a fork alpha branch = UPSTREAM_REF + replayed active features + overlay.
set -euo pipefail

UPSTREAM_REF="${UPSTREAM_REF:-upstream/main}"
OVERLAY_REF="${OVERLAY_REF:-origin/fork-overlay}"
OUT_REF="${OUT_REF:-refs/heads/main-alpha}"
# Idempotency baseline: the tree we compare against to decide "did anything change".
# In CI OUT_REF is a fresh temp ref that does not pre-exist, so comparing against it
# would always look changed. Compare against the LIVE branch instead. Defaults to
# OUT_REF (correct for local back-to-back idempotency tests where OUT_REF persists).
COMPARE_REF="${COMPARE_REF:-$OUT_REF}"
KEEP=(docker.yml release.yml deploy-to-aca.yml sync.yml alpha-release.yml mirror-upstream-release.yml)

tmpdir="$(mktemp -d)"
manifest="$tmpdir/features.yml"
paths="$tmpdir/paths.txt"
git cat-file blob "$OVERLAY_REF:fork-features.yml"     > "$manifest"
git cat-file blob "$OVERLAY_REF:fork-overlay-paths.txt" > "$paths"

work="$(mktemp -d)"
git worktree add --detach "$work" "$UPSTREAM_REF" >/dev/null
cleanup(){ git worktree remove --force "$work" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT
cd "$work"

# 1. Replay active features (linear branches only).
#    A feature replays unless its upstream PR is MERGED or active:false.
python3 - "$manifest" <<'PY' > "$tmpdir/active.txt"
import sys, re
txt = open(sys.argv[1]).read()
# minimal block parser: each "- branch:" starts a feature
blocks = re.split(r'\n\s*-\s+branch:', txt)[1:]
for b in blocks:
    branch = b.splitlines()[0].strip()
    pr = re.search(r'upstream_pr:\s*(\S+)', b)
    active = re.search(r'active:\s*(true|false)', b)
    pr = pr.group(1) if pr else 'null'
    active = (active.group(1) if active else 'true')
    if active == 'true':
        print(f"{branch}\t{pr}")
PY

while IFS=$'\t' read -r branch pr; do
  [ -z "$branch" ] && continue
  # Drop if the upstream PR is merged.
  if [ "$pr" != "null" ]; then
    num="${pr##*#}"; repo="${pr%#*}"
    state="$(gh pr view "$num" --repo "$repo" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    if [ "$state" = "MERGED" ]; then echo "drop $branch (PR $pr MERGED)"; continue; fi
  fi
  base="$(git merge-base "$UPSTREAM_REF" "$branch")"
  echo "replay $branch ($base..$branch)"
  git cherry-pick --allow-empty "$base..$branch"
done < "$tmpdir/active.txt"

# 2. Copy fork-owned files whole from the overlay ref (never a merge).
while IFS= read -r p; do
  [ -z "$p" ] && continue
  git checkout "$OVERLAY_REF" -- "$p"
done < "$paths"

# 3. Keep-list trim of workflows + remove pull.yml.
if [ -d .github/workflows ]; then
  for f in .github/workflows/*; do
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
```

- [ ] **Step 2: Make executable + commit (on fork-overlay)**

```bash
chmod +x scripts/fork-rebuild.sh
git add scripts/fork-rebuild.sh
git commit -m "feat(fork): rebuild engine (replay + overlay + trim + idempotency)"
git push -f origin fork-overlay
```

---

## Task 8: Local end-to-end rebuild verification

**Files:** none (produces scratch ref `refs/heads/_rebuilt-test`).

**Interfaces:**
- Consumes: `scripts/fork-rebuild.sh`, `fork-overlay`, `feat/*`, `upstream/main`.
- Produces: assertions that the rebuilt tree is correct, idempotent, and delta-reducing.

- [ ] **Step 1: Run the rebuild into a scratch ref**

```bash
cd /c/Users/SergeARADJ/Projects/headroom
git update-ref -d refs/heads/_rebuilt-test 2>/dev/null || true
UPSTREAM_REF=upstream/main OVERLAY_REF=fork-overlay OUT_REF=refs/heads/_rebuilt-test \
  bash scripts/fork-rebuild.sh
```
Expected: prints a commit SHA (not `NO_CHANGE`).

- [ ] **Step 2: Assert workflow set == keep-set (5 files)**

Run:
```bash
git ls-tree --name-only refs/heads/_rebuilt-test -- .github/workflows/ | sort
```
Expected exactly:
```
.github/workflows/alpha-release.yml
.github/workflows/deploy-to-aca.yml
.github/workflows/docker.yml
.github/workflows/mirror-upstream-release.yml
.github/workflows/sync.yml
```

- [ ] **Step 3: Assert no chopratejas, pyproject == upstream, feature present, docs kept**

```bash
R=refs/heads/_rebuilt-test
git grep -n chopratejas "$R" -- .github/ ; echo "chopratejas hits exit: $?"   # want exit 1 (none)
[ "$(git rev-parse $R:pyproject.toml)" = "$(git rev-parse upstream/main:pyproject.toml)" ] \
  && echo "pyproject==upstream OK" || echo "pyproject DIFFERS (investigate)"
git ls-tree -r --name-only "$R" -- Dockerfile docs/superpowers | sort
git ls-tree "$R" -- docker/aca-containerapp.yaml | grep . && echo "ACA-CONFIG STILL PRESENT (bad)" || echo "aca-containerapp.yaml absent OK"
```
Expected: no chopratejas hits; `pyproject==upstream OK`; `Dockerfile` and
`docs/superpowers/...` listed; `aca-containerapp.yaml absent OK`.

- [ ] **Step 4: Assert idempotency (second run is NO_CHANGE)**

```bash
UPSTREAM_REF=upstream/main OVERLAY_REF=fork-overlay OUT_REF=refs/heads/_rebuilt-test \
  bash scripts/fork-rebuild.sh
```
Expected: prints `NO_CHANGE`.

- [ ] **Step 5: Assert delta-reduction (simulate PR #1118 merged)**

```bash
# Temporarily flip the manifest active:false on fork-overlay to simulate "merged".
git switch fork-overlay
sed -i 's/active: true/active: false/' fork-features.yml
git commit -am "test: simulate #1118 merged"
git switch -
git update-ref -d refs/heads/_rebuilt-test
UPSTREAM_REF=upstream/main OVERLAY_REF=fork-overlay OUT_REF=refs/heads/_rebuilt-test \
  bash scripts/fork-rebuild.sh
# Floor-only: no feature commits, delta vs upstream is exactly the overlay.
git log --oneline upstream/main..refs/heads/_rebuilt-test
git diff --name-only upstream/main refs/heads/_rebuilt-test | grep -i Dockerfile \
  && echo "FEATURE STILL PRESENT (bad)" || echo "feature dropped OK"
# Revert the simulation.
git switch fork-overlay && git reset --hard HEAD~1 && git switch -
```
Expected: one overlay commit only; `feature dropped OK`.

- [ ] **Step 6: Clean up scratch ref**

```bash
git update-ref -d refs/heads/_rebuilt-test
```

---

## Task 9: Finalize `alpha-release.yml` + `mirror-upstream-release.yml`

**Files:**
- Modify (on `fork-overlay`): `.github/workflows/alpha-release.yml`,
  `.github/workflows/mirror-upstream-release.yml`

**Interfaces:**
- Consumes: `scripts/fork-alpha-version.sh`, `FORK_RELEASE_PAT`.
- Produces: alpha tags `vX.Y.(Z+1)-alpha.N`; mirrored stable releases.

- [ ] **Step 1: Point alpha-release at the extracted version script + drop the obsolete skip**

In `alpha-release.yml`, replace the inline base/target/N computation with:

```bash
base="$(gh release list --repo headroomlabs-ai/headroom --limit 30 \
  --json tagName,isPrerelease,isDraft \
  -q '.[] | select(.isPrerelease==false and .isDraft==false) | .tagName' \
  | sort -V | tail -1)"; base="${base#v}"
git tag -l 'v*-alpha.*' > /tmp/tags.txt
newtag="$(bash scripts/fork-alpha-version.sh "$base" /tmp/tags.txt)"
```
Remove the `git diff --quiet origin/main HEAD` skip (always false under the overlay; the
sync idempotency guard prevents no-op runs). Keep the "HEAD already has a `v*` tag" skip.

- [ ] **Step 2: Verify both files reference only headroomlabs-ai**

Run: `grep -rn 'chopratejas\|UPSTREAM=' .github/workflows/alpha-release.yml .github/workflows/mirror-upstream-release.yml`
Expected: every `UPSTREAM`/repo reference is `headroomlabs-ai/headroom`; no `chopratejas`.

- [ ] **Step 3: Commit + push fork-overlay**

```bash
git add .github/workflows/alpha-release.yml .github/workflows/mirror-upstream-release.yml
git commit -m "chore(fork): alpha-release uses extracted version script; rewire mirror"
git push -f origin fork-overlay
```

---

## Task 10: One-time migration cutover (LIVE, reversible)

**Files:** none (rewrites `origin/main`, `origin/main-alpha`).

**Interfaces:**
- Consumes: Task 1 backups, verified rebuild (Task 8), `fork-overlay`, `feat/*`.
- Produces: `origin/main` == `upstream/main`; `origin/main-alpha` == upstream + #1118 +
  overlay commit; downstream workflows trigger and a fresh alpha is cut.

- [ ] **Step 1: Build the real main-alpha locally**

```bash
git update-ref -d refs/heads/main-alpha-built 2>/dev/null || true
UPSTREAM_REF=upstream/main OVERLAY_REF=fork-overlay OUT_REF=refs/heads/main-alpha-built \
  bash scripts/fork-rebuild.sh
git log --oneline upstream/main..refs/heads/main-alpha-built   # expect: feature commits + 1 overlay commit
```

- [ ] **Step 2: Final pre-flight assertions (re-run Task 8 Steps 2-3 on `main-alpha-built`)**

Expected: keep-set workflows only; no chopratejas; pyproject==upstream; feature + docs
present; aca-containerapp.yaml absent.

- [ ] **Step 3: Mirror origin/main := upstream/main (force)**

```bash
git push origin upstream/main:refs/heads/main --force
```

- [ ] **Step 4: Replace origin/main-alpha with the built branch (force)**

```bash
git push origin refs/heads/main-alpha-built:refs/heads/main-alpha --force
```

- [ ] **Step 5: Update the local working branch to match**

```bash
git switch main-alpha
git reset --hard refs/heads/main-alpha-built
```

- [ ] **Step 6: Verify the push triggered the cascade**

Run: `rtk gh run list --branch main-alpha --limit 5`
Expected: a `Sync`/`alpha-release`/`mirror`/`docker` run appears. If `alpha-release`
succeeds, confirm the new prerelease tag:
Run: `gh release list --repo orty/headroom --limit 3`
Expected: a new `vX.Y.(Z+1)-alpha.N` prerelease.

- [ ] **Step 7: Smoke-check the Docker image reports the release tag**

After `docker.yml` completes, confirm `/readyz` (or the image label) reports the alpha tag,
not a pyproject value. Record the result.

- [ ] **Rollback (only if cutover is wrong):**

```bash
git push --force origin backup/main-pre-overlay:main
git push --force origin backup/main-alpha-pre-overlay:main-alpha
```

---

## Task 11: Cleanup

**Files:** none (deletes stale refs).

- [ ] **Step 1: Delete stale release-please branches on origin**

```bash
git push origin --delete release-please--branches--main release-please--branches--main-alpha 2>/dev/null || true
```

- [ ] **Step 2: Confirm wei/pull no longer in the loop**

`.github/pull.yml` is removed by the rebuild trim. Optionally disable the Pull app from its
dashboard. Verify `git ls-tree main-alpha -- .github/pull.yml` is empty.

- [ ] **Step 3: Verify final state**

Run: `git diff --stat upstream/main main-alpha`
Expected: only the feature files (#1118) + the overlay-owned paths; ~tens of lines, not
hundreds. No node_modules / wiki / docs.mdx / _version.py noise.

---

## Self-review notes

- **Spec coverage:** topology (Task 3,5,7), overlay additive/overwrite (Task 7 step 2),
  keep-list trim (Task 7 step 3), manifest + squash-safe drop (Task 4,7), version logic
  (Task 6,9), trigger matrix (Task 9 + sync.yml), ACA (Task 5 paths + Task 8 assertion),
  migration + noise reset (Task 10 — reset is implicit: rebuild starts from upstream so
  noise never carries), reversibility (Task 1,10 rollback). All covered.
- **docker.yml decision** is deferred to Task 3 Step 5 with explicit criteria — not a
  placeholder, a guarded decision with both branches specified.
- **Idempotency + delta-reduction** are explicitly tested (Task 8 Steps 4-5) before any
  live push (Task 10).
