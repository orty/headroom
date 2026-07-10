#!/usr/bin/env bash
set -euo pipefail

actionlint .github/workflows/*.yml

run_act() {
  local attempt=1
  local max_attempts=3
  local delay_seconds=5

  while true; do
    if "$@"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      return 1
    fi

    echo "act dry-run failed on attempt ${attempt}/${max_attempts}; retrying in ${delay_seconds}s..." >&2
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
    delay_seconds=$((delay_seconds * 2))
  done
}

run_act act workflow_dispatch -W .github/workflows/release.yml -e .github/act/dry-run.json -n
# release.yml's trigger is `release: published`, emitted by
# mirror-upstream-release.yml (upstream stable tags) and alpha-release.yml
# (fork pre-releases). Simulate it here so validation exercises the same
# code path CI fires on.
run_act act release -W .github/workflows/release.yml -e .github/act/release-published.json -n
# The main -> main-alpha sync fires on push to main (push-feat.json is a
# main push). alpha-release / mirror-upstream-release trigger on push to
# main-alpha and are covered by actionlint above.
run_act act push -W .github/workflows/sync-from-main.yml -e .github/act/push-feat.json -n
run_act act pull_request_target -W .github/workflows/pr-health.yml -e .github/act/pr-governance-invalid.json -n
run_act act pull_request_target -W .github/workflows/pr-health.yml -e .github/act/pr-governance-valid.json -n
run_act act pull_request -W .github/workflows/docs.yml -n
run_act act workflow_dispatch -W .github/workflows/docs.yml -n
run_act act workflow_dispatch -W .github/workflows/docker.yml -e .github/act/docker-version.json -n
