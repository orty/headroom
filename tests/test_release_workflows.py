"""Workflow regression tests for release publishing behavior.

This fork is Docker-only: PyPI/npm publishing, the cross-platform wheel/sdist
matrix, and release-please were removed. Releases are created by
`mirror-upstream-release.yml` (exact upstream tags) and `alpha-release.yml`
(fork pre-releases `vX.Y.(Z+1)-alpha.N`); `release.yml` reacts to the published
release and builds the Docker images via `docker.yml` (which builds the Rust
wheels from source inside the image — it does not consume any wheel artifact).

The source/Cargo/Dockerfile invariants below still matter because the Docker
image build compiles the same Rust extension from source.
"""

from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def _wf(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")


def test_docker_workflow_normalizes_repository_name_for_signing() -> None:
    content = _wf("docker.yml")

    assert "id: image-name" in content
    assert "tr '[:upper:]' '[:lower:]'" in content
    assert "steps.image-name.outputs.image_name" in content


def test_macos_native_wrapper_dependency_install_retries_pypi_downloads() -> None:
    content = _wf("ci.yml")

    assert "python -m pip install --retries 10 --timeout 60 pytest" in content


def test_ci_commitlint_runs_only_for_pull_requests() -> None:
    content = _wf("ci.yml")

    assert "github.event_name == 'pull_request'" in content


def test_no_openssl_sys_in_wheel_build_tree() -> None:
    """STRUCTURAL INVARIANT: openssl-sys must NOT appear in the resolved
    dependency graph.

    The Docker image build compiles the Rust extension from source, so if
    openssl-sys is back in the resolution graph every from-source surface
    needs system OpenSSL + perl + pkg-config. The cleanest fix is to not
    depend on OpenSSL at all (fastembed rustls features, see below). This
    test runs `cargo tree` so it exercises the resolved feature graph.
    """
    import subprocess

    for crate in ("headroom-py", "headroom-proxy", "headroom-core"):
        try:
            result = subprocess.run(
                [
                    "cargo",
                    "tree",
                    "--target",
                    "x86_64-unknown-linux-gnu",
                    "-p",
                    crate,
                    "-i",
                    "openssl-sys",
                ],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            pytest.skip("cargo is unavailable in this environment")
        not_in_tree = result.returncode != 0 and "did not match any packages" in result.stderr
        if (
            result.returncode != 0
            and "package ID specification `openssl-sys` did not match"
            not in (result.stderr + result.stdout)
        ):
            pytest.skip(
                "cargo dependency tree for the Linux target is unavailable in this environment"
            )
        assert not_in_tree, (
            f"openssl-sys is back in {crate}'s build tree:\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}\n"
            "Find the new native-tls user (likely a default-features=true "
            "on a transitive crate) and disable it."
        )


def test_no_native_tls_in_wheel_build_tree() -> None:
    """The dual of the openssl-sys gate: native-tls is the proximate cause of
    openssl-sys being pulled. Catch it earlier with a specific message.
    """
    import subprocess

    for crate in ("headroom-py", "headroom-proxy", "headroom-core"):
        result = subprocess.run(
            [
                "cargo",
                "tree",
                "--target",
                "x86_64-unknown-linux-gnu",
                "-p",
                crate,
                "-i",
                "native-tls",
            ],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        not_in_tree = result.returncode != 0 and "did not match any packages" in result.stderr
        assert not_in_tree, (
            f"native-tls is back in {crate}'s build tree — likely some "
            f"crate's `default-features = true` re-enabled native-tls "
            f"transitively:\n{result.stdout}"
        )


def test_fastembed_uses_rustls_features() -> None:
    """fastembed's explicit rustls feature selection is what keeps openssl-sys
    out of the build tree (its defaults pull native-tls).
    """
    cargo = (ROOT / "crates" / "headroom-core" / "Cargo.toml").read_text(encoding="utf-8")

    assert "default-features = false" in cargo
    assert '"hf-hub-rustls-tls"' in cargo
    assert '"ort-download-binaries-rustls-tls"' in cargo
    assert '"image-models"' in cargo


def test_fastembed_uses_dynamic_ort_on_windows() -> None:
    """Windows builds must not link Pyke's DirectML ORT binaries (DXCORE/DXGI/
    D3D12 link libs absent on many build hosts); use ORT dynamic loading.
    """
    cargo = (ROOT / "crates" / "headroom-core" / "Cargo.toml").read_text(encoding="utf-8")
    assert "[target.'cfg(windows)'.dependencies]" in cargo
    windows_section = cargo.split("[target.'cfg(windows)'.dependencies]", 1)[1].split(
        "\n[",
        1,
    )[0]
    windows_dependency_lines = "\n".join(
        line for line in windows_section.splitlines() if not line.lstrip().startswith("#")
    )
    assert '"ort-load-dynamic"' in windows_section
    assert "ort-download-binaries" not in windows_dependency_lines


def test_dockerfiles_no_longer_install_openssl_devel() -> None:
    """Once openssl-sys is out of the build tree, Dockerfiles that used to
    install `openssl-devel` / `libssl-dev` for the Rust build can drop them.
    """
    targets = [
        ROOT / "e2e" / "wrap" / "Dockerfile",
        ROOT / "e2e" / "init" / "Dockerfile",
        ROOT / "Dockerfile",
        ROOT / ".devcontainer" / "Dockerfile",
    ]

    forbidden = ["openssl-devel", "libssl-dev"]

    for target in targets:
        content = target.read_text(encoding="utf-8")
        non_comment = "\n".join(
            line for line in content.splitlines() if not line.lstrip().startswith("#")
        )
        for pkg in forbidden:
            assert pkg not in non_comment, (
                f"{target.relative_to(ROOT)} still installs {pkg!r} on a "
                f"non-comment line. The rustls-everywhere refactor removed "
                f"openssl-sys from the build tree; this package is no longer needed."
            )


def test_docker_workflow_builds_on_native_arch_runners() -> None:
    """STRUCTURAL INVARIANT: the docker variant build fans out per arch onto
    native runners — `linux/amd64` on `ubuntu-24.04`, `linux/arm64` on
    `ubuntu-24.04-arm`. No QEMU.
    """
    content = _wf("docker.yml")

    assert "docker-build:" in content, "docker-build fan-out job missing"
    assert "runs_on: ubuntu-24.04, platform: linux/amd64" in content
    assert "runs_on: ubuntu-24.04-arm, platform: linux/arm64" in content
    assert "push-by-digest=true,name-canonical=true,push=true" in content

    non_comment = "\n".join(
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    )
    assert "docker/setup-qemu-action" not in non_comment, (
        "docker.yml must not invoke `docker/setup-qemu-action` — native "
        "arm64 runners replaced QEMU."
    )

    assert "docker-manifest:" in content
    assert "needs: docker-build" in content
    assert "docker buildx imagetools create" in content


def test_docker_per_arch_build_specifies_image_name_in_output() -> None:
    """STRUCTURAL INVARIANT: the per-arch bake's `*.output` spec must include
    `name=<registry>/<image>` — without it buildx fails with the misleading
    `ERROR: tag is needed when pushing to registry`.
    """
    content = _wf("docker.yml")

    output_line_present = (
        "*.output=type=image,name=${{ env.REGISTRY }}/${{ steps.image-name.outputs.image_name }},push-by-digest=true,name-canonical=true,push=true"
        in content
    )
    assert output_line_present, "per-arch bake `*.output` must include `name=<registry>/<image>`."


def test_glibc_compat_shim_present_in_headroom_py() -> None:
    """STRUCTURAL INVARIANT: the headroom-py crate ships a glibc-2.38
    compatibility shim defining weak `__isoc23_*` aliases (issue #355). The
    Docker image build compiles `_core.so` from source, so the shim must ship.
    """
    headroom_py_dir = ROOT / "crates" / "headroom-py"

    shim = headroom_py_dir / "glibc_compat.c"
    assert shim.exists(), (
        "crates/headroom-py/glibc_compat.c is missing — without it, `_core.so` "
        "fails to import on every glibc < 2.38 host. See issue #355."
    )
    shim_content = shim.read_text(encoding="utf-8")
    for sym in ("__isoc23_strtol", "__isoc23_strtoll", "__isoc23_strtoul", "__isoc23_strtoull"):
        assert sym in shim_content, f"shim missing alias for {sym}"

    build_rs = headroom_py_dir / "build.rs"
    assert build_rs.exists(), "crates/headroom-py/build.rs is missing"
    build_rs_content = build_rs.read_text(encoding="utf-8")
    assert "glibc_compat.c" in build_rs_content

    cargo_toml = (headroom_py_dir / "Cargo.toml").read_text(encoding="utf-8")
    assert 'build = "build.rs"' in cargo_toml
    assert "[build-dependencies]" in cargo_toml and 'cc = "1"' in cargo_toml


# ─── Fork release pipeline (Docker-only) ────────────────────────────────────


def test_release_yml_triggers_on_release_published_not_push() -> None:
    """release.yml fires when a release is published (by the mirror or alpha
    workflow), never on a raw push — a per-push trigger used to upload a fresh
    wheel matrix to PyPI on every merge.
    """
    content = _wf("release.yml")
    on_block = content[: content.index("\nconcurrency:")]

    assert "\n  release:\n    types: [published]" in on_block, (
        "release.yml must trigger on the `release: published` event so the "
        "mirror / alpha-release workflows are the only way to publish."
    )
    assert "\n  push:\n    branches: [main]" not in on_block
    assert "\n  push:\n    branches: [main-alpha]" not in on_block


def test_release_yml_resolves_manual_ver_from_release_tag() -> None:
    """On a release event MANUAL_VER must come from the release tag, so
    release_version.py doesn't re-bump past the version just tagged.
    """
    content = _wf("release.yml")

    assert "Resolve MANUAL_VER from trigger" in content
    assert "RELEASE_TAG: ${{ github.event.release.tag_name }}" in content
    assert "${RELEASE_TAG#v}" in content, (
        "Resolver must strip the leading 'v' — release_version.py's SemVer regex rejects 'v0.9.2'."
    )
    assert "MANUAL_VER: ${{ steps.manualver.outputs.value }}" in content


def test_release_yml_is_docker_only() -> None:
    """release.yml builds Docker and nothing else: it calls docker.yml and must
    not contain any PyPI / npm / GitHub-Packages publish surface.
    """
    content = _wf("release.yml")

    assert "uses: ./.github/workflows/docker.yml" in content, (
        "release.yml must build Docker via the reusable docker.yml workflow."
    )

    # Scan non-comment lines only, so explanatory comments that mention the
    # removed PyPI/npm surface don't false-positive.
    non_comment = "\n".join(
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    )
    forbidden = [
        "pypa/gh-action-pypi-publish",
        "npm publish",
        "publish-pypi:",
        "publish-npm:",
        "publish-github-packages:",
        "registry.npmjs.org",
        "npm.pkg.github.com",
    ]
    for token in forbidden:
        assert token not in non_comment, (
            f"release.yml still references {token!r} — the fork is Docker-only; "
            f"PyPI/npm publishing was removed."
        )


def test_runtime_version_prefers_stamped_env_override() -> None:
    """headroom._version must honour the HEADROOM_VERSION env override so a
    published image reports the exact release tag rather than the wheel
    metadata, which can lag a stale pyproject.toml (the 0.26.1a3-vs-alpha.4 bug).
    """
    import importlib.util
    import os

    spec = importlib.util.spec_from_file_location(
        "_hv_under_test", ROOT / "headroom" / "_version.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)

    saved = os.environ.get("HEADROOM_VERSION")
    try:
        os.environ["HEADROOM_VERSION"] = "0.26.1-alpha.4"
        spec.loader.exec_module(module)
        assert module.get_version() == "0.26.1-alpha.4", (
            "get_version() must return the exact HEADROOM_VERSION string."
        )
    finally:
        if saved is None:
            os.environ.pop("HEADROOM_VERSION", None)
        else:
            os.environ["HEADROOM_VERSION"] = saved


def test_image_stamps_resolved_version_for_readyz() -> None:
    """The resolved release version is plumbed from docker.yml into the image as
    HEADROOM_VERSION (build arg -> ENV in both runtime stages) so /readyz reports
    the release tag verbatim, independent of the wheel's pyproject version.
    """
    docker = _wf("docker.yml")
    assert "*.args.HEADROOM_VERSION=${{ steps.version.outputs.version }}" in docker, (
        "docker.yml must pass the resolved version into the bake build as the "
        "HEADROOM_VERSION build arg."
    )

    dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
    assert dockerfile.count("ARG HEADROOM_VERSION") >= 2, (
        "both runtime stages must declare ARG HEADROOM_VERSION."
    )
    assert dockerfile.count("HEADROOM_VERSION=${HEADROOM_VERSION}") >= 2, (
        "both runtime stages must export HEADROOM_VERSION as an ENV."
    )


def test_no_pypi_or_npm_publish_workflows_remain() -> None:
    """The standalone PyPI fallback and release-please workflows were removed."""
    wf_dir = ROOT / ".github" / "workflows"
    assert not (wf_dir / "publish.yml").exists(), (
        "publish.yml (PyPI manual fallback) must be removed — fork is Docker-only."
    )
    assert not (wf_dir / "release-please.yml").exists(), (
        "release-please.yml must be removed — it cut stable fork releases "
        "(e.g. 0.27.0) that don't exist upstream. Fork releases are alphas."
    )
    assert not (ROOT / ".release-please-config.json").exists()
    assert not (ROOT / ".release-please-manifest.json").exists()


def test_docker_yml_builds_only_via_workflow_call() -> None:
    """docker.yml must NOT trigger on `push` or `release` — both would rebuild
    the matrix a second time on top of release.yml's publish-docker
    (workflow_call). Image builds come exclusively through workflow_call (and
    manual workflow_dispatch), so each push/release builds Docker once and
    deploy-to-aca chains off one "Release" run. The rolling `:dev` tag (only
    emitted on push) is dropped with the push trigger.
    """
    content = _wf("docker.yml")
    on_block = content[: content.index("\nenv:")]
    assert "\n  release:" not in on_block, (
        "docker.yml has a `release:` trigger — that double-builds every release."
    )
    assert "\n  push:" not in on_block, (
        "docker.yml has a `push:` trigger — that double-builds every push "
        "(once here for the unused :dev tag, once via release.yml)."
    )
    assert "value=dev" not in content, (
        "the :dev tag is only emitted on push; with the push trigger gone it is "
        "dead and must be removed."
    )


def test_mirror_upstream_release_uses_pat_not_github_token() -> None:
    """The mirror creates fork releases via the GitHub API; releases created
    with GITHUB_TOKEN do not fire `release: published`, so it must use a PAT.
    """
    content = _wf("mirror-upstream-release.yml")

    assert "branches: [main-alpha]" in content
    assert "FORK_RELEASE_PAT" in content, (
        "mirror must authenticate with the FORK_RELEASE_PAT secret so the "
        "mirrored release triggers the downstream Docker build."
    )
    assert "secrets.GITHUB_TOKEN" not in content, (
        "mirror must not use GITHUB_TOKEN — releases it creates would be "
        "suppressed and never trigger release.yml / docker.yml."
    )
    assert "gh release create" in content


def test_alpha_release_cuts_prerelease_with_pat() -> None:
    """alpha-release.yml cuts `vX.Y.(Z+1)-alpha.N` pre-releases on push to
    main-alpha, authenticated with the PAT so the release triggers Docker.
    """
    content = _wf("alpha-release.yml")

    assert "branches: [main-alpha]" in content
    assert "--prerelease" in content, "fork releases must be GitHub pre-releases"
    assert "-alpha." in content, "alpha tag scheme `vX.Y.Z-alpha.N` must be present"
    assert "FORK_RELEASE_PAT" in content, (
        "alpha-release must use FORK_RELEASE_PAT so the created release fires "
        "`release: published` and triggers the Docker build."
    )
    assert "secrets.GITHUB_TOKEN" not in content
    # Pure-upstream states are left to the mirror workflow.
    assert "git diff --quiet origin/main HEAD" in content, (
        "alpha-release must skip when main-alpha carries no fork changes "
        "(identical tree to upstream-synced main)."
    )
    # The base version must come from upstream's latest stable release, queried
    # directly — NOT the fork's mirrored tags (which race with the mirror
    # pushing the new upstream tag in parallel on the same push) and NOT
    # pyproject.toml (which can drift via fork-local edits).
    assert "chopratejas/headroom" in content and "isPrerelease == false" in content, (
        "alpha-release must derive its base from upstream's latest stable "
        "release queried directly (race-free), not the fork's mirrored tags."
    )


def test_deploy_to_aca_resolves_release_tag_not_head_branch() -> None:
    """deploy-to-aca must derive the deploy tag from the published release, not
    workflow_run.head_branch (which is the main-alpha branch and mis-routes to
    the dev image), and must strip the leading 'v' to match the image tag.
    """
    content = _wf("deploy-to-aca.yml")

    assert "workflow_run.head_branch" not in content, (
        "deploy-to-aca must NOT resolve the tag from head_branch — for a "
        "release-triggered run that is the branch (main-alpha), which contains "
        "'-alpha' and deploys the rolling dev image instead of the alpha build."
    )
    assert "gh release list" in content, (
        "deploy-to-aca must resolve the tag from the releases list "
        "(gh release list includes pre-releases; gh release view does not)."
    )
    assert "sort -V | tail -1" in content, (
        "deploy-to-aca must select the HIGHEST-SEMVER release, not the most "
        "recent by time — an upstream bump cuts a stable mirror and a fork "
        "alpha on the same push in non-deterministic order, and the alpha "
        "(higher version) is the one ACA must converge on."
    )
    assert 'TAG="${TAG#v}"' in content, (
        "deploy-to-aca must strip the leading 'v' so the pull reference matches "
        "the image tag docker.yml publishes (without the v)."
    )
    # Alpha tags still route to the fork image.
    assert "${FORK_IMAGE}:${TAG}" in content


def test_sync_from_main_uses_deploy_key_and_push_on_main() -> None:
    """The cascade fires on push to main and pushes via a deploy key (not
    GITHUB_TOKEN) so the push to main-alpha triggers CI/CD.
    """
    content = _wf("sync-from-main.yml")
    on_block = content[: content.index("\npermissions:")]

    assert "\n  push:\n    branches: [main]" in on_block, (
        "sync must fire on push to main so it runs the moment Pull updates main."
    )
    assert "ssh-key: ${{ secrets.SYNC_DEPLOY_KEY }}" in content, (
        "sync must push main-alpha via the SYNC_DEPLOY_KEY deploy key — a "
        "GITHUB_TOKEN push would not trigger the downstream pipelines."
    )
    assert "git push origin main-alpha" in content
