"""Package version metadata."""

from __future__ import annotations

import os
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

UNKNOWN_VERSION = "unknown"


def _source_root() -> Path | None:
    """Return the repository root when imported from a git checkout."""
    root = Path(__file__).resolve().parents[1]
    if (root / ".git").exists() and (root / "pyproject.toml").exists():
        return root
    return None


def _source_tree_version(root: Path) -> str | None:
    """Compute the version release automation would assign to this checkout."""
    try:
        from headroom.release_version import (
            compute_release_version,
            determine_bump_level,
            get_canonical_version,
            list_release_commits,
            list_release_tags,
        )

        tags = list_release_tags(root)
        previous_tag = compute_release_version(
            canonical_version=get_canonical_version(root),
            level="patch",
            tags=tags,
        ).previous_tag
        commits = list_release_commits(root, previous_tag)
        level = determine_bump_level(commits)
        return compute_release_version(
            canonical_version=get_canonical_version(root),
            level=level,
            tags=tags,
        ).version
    except Exception:
        return None


def get_version() -> str:
    """Return Headroom's runtime version."""
    # Explicit override stamped into the container image at build time
    # (docker.yml passes the resolved release version as HEADROOM_VERSION).
    # This is authoritative in published images and is immune to stale
    # pyproject.toml / build-cache: importlib.metadata reflects the *wheel*
    # version, which on a fork build can lag the release tag (e.g. /readyz
    # showed 0.26.1a3 for the 0.26.1-alpha.4 image because pyproject was not
    # bumped). The stamp also avoids needing a .git checkout at runtime.
    env_version = os.environ.get("HEADROOM_VERSION", "").strip()
    if env_version:
        return env_version

    root = _source_root()
    if root is not None:
        source_version = _source_tree_version(root)
        if source_version:
            return source_version

    try:
        return version("headroom-ai")
    except PackageNotFoundError:
        return UNKNOWN_VERSION


__version__ = get_version()
