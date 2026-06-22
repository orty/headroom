# Fork rebase-overlay model — design spec

**Date:** 2026-06-22
**Status:** Approved (design), pending implementation plan
**Repo:** `orty/headroom` (fork) tracking `headroomlabs-ai/headroom` (upstream)

## Problem

This fork early-publishes changes proposed as PRs upstream. Today it tracks upstream
with a **merge-based** sync: every 30 min `sync-from-main.yml` does
`git merge upstream/main` into `main-alpha`, producing a `chore(sync): merge` commit.
Consequences:

- The fork delta only ever **grows** (currently 68 commits ahead of upstream), never
  shrinks — even after a fork feature is accepted upstream, its commits remain in the
  fork's history forever.
- `pyproject.toml` and workflow files are edited in-line in the divergence, causing
  recurring rebase/merge conflicts (the version field has already conflicted).
- The fork runs the full upstream CI/CD matrix (~23 workflows) when it only needs to
  publish a Docker image.
- Upstream identity has moved: the workflows hardcode the dead `chopratejas/headroom`,
  but the definitive upstream is now `headroomlabs-ai/headroom`.

## Goals

1. Fork delta = `upstream/main` + replayed in-flight feature branches + **exactly one**
   permanent "overlay" commit. That overlay is the irreducible floor: no upstream PR can
   ever absorb it, so it is the only thing that keeps the fork diverging.
2. When a fork feature is merged upstream, it **stops replaying** and the delta shrinks —
   automatically and reliably, even though upstream **squash-merges** PRs.
3. The overlay never causes merge/rebase conflicts.
4. Pre-releases (`vX.Y.(Z+1)-alpha.N`) published on every change to upstream main or to
   `main-alpha`; stable upstream releases mirrored and become the new alpha base.
5. CI/CD trimmed to Docker image publishing (+ ACA deploy) only.

## Non-goals

- Owning or seeding either upstream repo (the user owns neither). `headroomlabs-ai/main`
  is the rebase base **as-is**; any chopratejas-only commits currently in the fork are
  dropped. As headroomlabs-ai's maintainers absorb upstream PRs, the fork picks them up
  via sync.
- Preserving `main-alpha` history (it is a rolling, force-pushed branch).
- Python package / docs / eval / e2e publishing.

## Constraints & facts

- Upstream = `headroomlabs-ai/headroom`. `chopratejas/headroom` is dead; 6 files still
  hardcode it (`pull.yml`, `alpha-release.yml`, `deploy-to-aca.yml`,
  `mirror-upstream-release.yml`, `sync-from-main.yml`, `plugin/marketplace.json`).
- Upstream **squash-merges** PRs (commits like `(#1190)`, `(#1274)`), so patch-id based
  auto-drop on `git rebase` is unreliable.
- `main-alpha` is the fork's **default branch**; GitHub reads scheduled-workflow
  definitions from the default branch, so the wiring workflows must be present there.
- Releases must be created with a PAT (`FORK_RELEASE_PAT`), not `GITHUB_TOKEN` — releases
  created by `GITHUB_TOKEN` are suppressed by GitHub and never fire `release: published`
  (which is what triggers `docker.yml`). Branch pushes that must trigger workflows use a
  deploy key (`SYNC_DEPLOY_KEY`) for the same reason.
- Both secrets already exist in the repo.

## Chosen approach: Overlay rebuild (Approach A)

`main-alpha` is **regenerated from scratch** on every sync, not patched in place:

```
base   = upstream/main
      + cherry-pick(active feature branches, linearized)
      + materialize additive overlay files (copied, not patched)
      + rm(trim-list workflows)
      = one "fork: overlay" commit
→ force-push main-alpha
```

Because overlay files are **copied onto the tree** rather than applied as a diff, the
overlay can never conflict. Deletions (CI trim) are **re-derived each run** by an `rm`
list in the sync script, not stored as a fragile diff — so upstream editing a deleted
file never conflicts; it is simply deleted again.

Rejected alternatives:
- **B — Pure `git rebase --onto`:** simplest, but squash-merge breaks auto-drop and
  in-line wiring edits conflict on every upstream touch. Fails goals 2 & 3.
- **C — Patch queue (StGit/quilt):** powerful but adds non-GitHub-native tooling and a
  learning curve. Unnecessary for one overlay + a handful of features.

## Branch topology & source-of-truth refs

| Ref | Role | Mutation |
|---|---|---|
| `upstream/main` (headroomlabs-ai) | rebase base, read-only | — |
| `main` (fork) | pure mirror of `upstream/main` | hard-reset, force-push |
| `main-alpha` (fork, **default**) | `upstream/main` + replayed features + 1 overlay commit | regenerated + force-pushed each sync |
| `feat/*` / `claude/*` (fork) | one branch per in-flight feature, linearizable onto `upstream/main`; PR'd to upstream cross-repo | maintained by user |
| `fork-overlay` (fork) | holds the **additive** fork-only files + the `fork-features.yml` manifest; never edits an upstream-tracked file | edited directly by user |

## The overlay commit (irreducible floor)

One commit, **overwrite-only**: the rebuild *copies* each fork-owned file's full content
onto the base tree (never applies a diff), so it cannot raise a git conflict — regardless
of whether the same path also exists upstream. The overlay is therefore a **set of
fork-owned paths**, not a patch.

Floor overlay set (verified against current `upstream/main` = `95b2333e`, 2026-06-21):

- `.github/workflows/alpha-release.yml`, `mirror-upstream-release.yml`, `deploy-to-aca.yml`
  — fork-**added** (absent upstream).
- `.github/workflows/sync.yml` — fork-added, renamed from the current `sync-from-main.yml`
  and rewritten for the overlay-rebuild algorithm.
- `.github/workflows/docker.yml` — upstream file the fork **modified** (trigger retarget +
  resolved-version stamping for `/readyz`). Carried in the floor **only if** the fork delta
  vs upstream's `docker.yml` is functionally required (verified during migration); else use
  upstream's and drop it from the floor.
- `fork-features.yml` (manifest, see below).
- `docs/superpowers/**` — the spec + this plan, kept so fork planning docs survive rebuilds.
- All rewired → `headroomlabs-ai/headroom`.
- **No** `pyproject.toml` version bump — pyproject stays identical to upstream; the alpha
  version is computed at release time only (see Versioning).

Everything else currently diverging (~50 files: node_modules READMEs, `wiki/**`,
`docs/content/**.mdx`, `CHANGELOG.md`, `headroom/_version.py`, `release_version.py`,
`README.md`, etc.) is **noise from the old merge history** and is **reset to upstream**
during migration — it is not fork-owned.

Overwrite semantics: if the base ships a same-named file the fork owns (e.g. its own
`docker.yml`), the overlay copy wins last-write — a file copy, not a merge, so still
conflict-free. The fork's version is authoritative; the tradeoff is the fork may shadow
upstream improvements to that file (revisited per-file during migration).

The CI **trim** is not part of the committed diff — it is a **keep-list exclusion**
executed by `sync.yml` during rebuild (delete every `.github/workflows/*` whose basename
is not in the keep-set, plus `.github/pull.yml`), so it stays correct no matter which
workflows upstream adds over time. Non-workflow dead files (`.release-please-config.json`,
`.release-please-manifest.json`) are left in place — harmless without their workflow, and
not deleting them keeps the floor free of delete/modify conflicts.

## Sync / rebuild algorithm (`sync.yml`)

Trigger: `schedule: '*/30 * * * *'` + `workflow_dispatch`. Runs from default branch
(`main-alpha`). Uses `SYNC_DEPLOY_KEY` so pushes fire downstream workflows.

```
fetch upstream/main

# 1. mirror main
force-push origin/main := upstream/main      # only if changed

# 2. rebuild main-alpha
checkout --detach upstream/main
for feat in fork-features.yml:
    skip if feat.upstream_pr is MERGED or CLOSED (query gh pr) OR feat.active == false
    linearize feat onto upstream/main (git rebase --onto upstream/main <merge-base> feat),
        dropping merge commits, then cherry-pick the resulting patches
copy additive files from fork-overlay tree onto working tree
rm <trim-list>
git add -A
git commit -m "fork: overlay (CI trim + alpha wiring)"

# Idempotency guard: only force-push if the rebuilt TREE differs from the
# current origin/main-alpha tree. A no-op rebuild yields a new commit SHA but
# an identical tree; pushing it would trigger a spurious alpha. Compare trees,
# not SHAs.
if rebuilt tree == origin/main-alpha tree: skip push
else: force-push origin/main-alpha := HEAD     # triggers alpha-release + mirror
```

Merged-upstream detection is authoritative via `gh pr view <pr> --json state`
(MERGED → drop). `active: false` is an optional manual override.

Feature cherry-pick conflicts (upstream changed touched files) stop the run and are
surfaced for manual resolution — features are small and few.

## Manifest format (`fork-features.yml`)

```yaml
features:
  - branch: claude/docker-session-history-persist-ntw1t2
    upstream_pr: headroomlabs-ai/headroom#1118   # null until the PR is opened
    active: true        # set false to force-drop without consulting PR state
```

Initial state has exactly one entry: PR
[#1118](https://github.com/headroomlabs-ai/headroom/pull/1118) —
*"fix(docker): persist session history across container revisions"* (author `orty`,
cross-repo branch `claude/docker-session-history-persist-ntw1t2`, OPEN, 8 commits incl.
2 merge commits that linearization drops). The fork PR and the upstream PR are the same
cross-repo branch, so replayed content == PR content by construction.

## Versioning & release triggers

- **`alpha-release.yml`** (on push to `main-alpha`): keep the existing dynamic logic —
  `base` = upstream latest **stable** release version (queried from upstream), `target` =
  `major.minor.(patch+1)`, `N` = highest existing `vTARGET-alpha.*` + 1 → tag
  `vX.Y.(Z+1)-alpha.N`, `--prerelease`, created with `FORK_RELEASE_PAT`.
  **Skip guard change:** the existing `alpha-release` "skip if `main-alpha` tree ==
  `origin/main`" check is **removed** — in the overlay model `main-alpha` always carries
  the additive overlay, so that condition is never true. The no-fork-delta case is instead
  prevented upstream of release: `sync.yml`'s idempotency guard does not force-push when
  the rebuilt tree is unchanged, so `alpha-release` only fires on a genuine change. The
  only retained skip is "HEAD already has a `v*` release tag" (re-run / no-op safety).
- **`mirror-upstream-release.yml`** (on push to `main-alpha` + dispatch): mirror upstream
  stable tags + published releases onto the fork (this fires `docker.yml`). Rewired →
  headroomlabs-ai.
- **Trigger matrix:**
  - upstream main push → `sync.yml` (≤30 min cron) → `main` mirrored + `main-alpha`
    rebuilt & force-pushed → `alpha-release` → `vX.Y.(Z+1)-alpha.(N+1)`.
  - `main-alpha` push (feature work) → `alpha-release` → new alpha.
  - upstream stable `vX.Y.Z` released → mirror publishes the stable tag (docker builds it)
    + sync rebuilds onto the new base → next alpha = `vX.Y.(Z+1)-alpha.1` (base moved up,
    no alpha tags exist yet for the new target).
- **CD = Docker only:** `docker.yml` fires on `release: published` (works because releases
  use the PAT). `release.yml` (python package) disabled. `/readyz` must report the
  resolved release **tag** stamped at Docker build time, not the pyproject version.

## CI trim (keep-list exclusion)

The trim is expressed as a **keep-list**, not an enumerated denylist, so it stays correct
as the rebase base adds workflows over time.

**Keep-set** (overlay-provided, fork-owned): `docker.yml`, `release.yml`, `deploy-to-aca.yml`, `sync.yml`,
`alpha-release.yml`, `mirror-upstream-release.yml`.

**Trim rule** (run each rebuild): delete every file under `.github/workflows/` whose
basename is not in the keep-set; also delete `.github/pull.yml` (wei/pull replaced by
`sync.yml`) and `.github/dependabot.yml`. For reference, today's base would shed
`ci.yml`, `rust.yml`, `eval.yml`, `docs.yml`, `devcontainers.yml`, `release.yml`,
`network-diff-capture.yml`, `pr-health.yml`, `stale.yml`, and the e2e/init/wrap/install
set — but the rule, not this list, is authoritative.

## ACA artifacts

- `deploy-to-aca.yml` is **fork-only** → lives in the floor overlay (additive copy).
- `docker/aca-containerapp.yaml` (101-line app config) is **not referenced** by
  `deploy-to-aca.yml` (the workflow uses `az containerapp update --name/--resource-group`
  with image selection, no yaml config) → **removed completely**. PR #1118 already deletes
  it, so the deletion rides with the feature; the floor only carries `deploy-to-aca.yml`.

## One-time migration

1. **Identify genuine fork work** in the current 68-commit delta: the PR #1118 feature
   branch is the only product feature. Fork-infra commits (Docker-only pipeline, readyz
   alpha-version fix) fold into the overlay/wiring. Everything else is chopratejas-only
   upstream noise → dropped.
2. **Linearize** `claude/docker-session-history-persist-ntw1t2` onto `upstream/main`
   (drop the 2 merge commits); keep it as the replay source matching PR #1118.
3. **Build `fork-overlay`** branch: additive workflow files (rewired to headroomlabs-ai),
   `fork-features.yml`, trim-list + manifest baked into `sync.yml`.
4. **Run the rebuild once:** `main` := `upstream/main` (force-push); `main-alpha` :=
   `upstream/main` + linearized feature + 1 overlay commit (force-push). Collapses 68 →
   feature commits + 1 overlay.
5. **Cleanup:** delete `release-please--branches--*` refs; remove `.github/pull.yml`;
   confirm secrets `FORK_RELEASE_PAT`, `SYNC_DEPLOY_KEY` present.
6. **Verify:** alpha tag computes correctly; Docker image builds; `/readyz` reports the
   release tag.

## Risks & edge cases

- **Feature cherry-pick conflicts** when upstream changes touched files — manual
  resolution; rare given small features.
- **30-min latency** on upstream main pushes (cron, not webhook — the user does not
  control upstream to send `repository_dispatch`). Manual `workflow_dispatch` available.
- **readyz/version stamping** must read the resolved tag at Docker build, not pyproject,
  since pyproject is no longer bumped in-repo.
- **Stable-base race:** `alpha-release` resolves the stable base directly from upstream
  (not from fork-mirrored tags) to avoid racing the mirror workflow on the same push —
  preserved from the existing implementation.
- **Squash-merge with content drift:** if upstream alters a PR before squashing, the
  manifest still drops it on MERGED state (PR-number based, not content based), so no
  duplicate — correct.
