"""Server-side GitHub Copilot ingress detection and routing.

When a client points its Copilot API base at a Headroom proxy (VS Code Copilot
Chat via ``github.copilot.advanced.debug.overrideCapiUrl``, or the Copilot CLI in
subscription mode), the request arrives Copilot-shaped: either carrying the
Copilot editor headers, or bearing a GitHub Copilot session token. This module
recognizes such traffic and resolves the upstream Copilot API host so the proxy
forwards to GitHub's Copilot API instead of the default OpenAI host.

Detection is intentionally header-first (cheap, unambiguous for Copilot Chat)
with a token fallback for the Copilot CLI, which sends no editor headers but
carries a GitHub Copilot session token (a plaintext ``key=value;...`` string
prefixed ``tid=`` and containing ``;sku=``). The token is HMAC-signed but not
encrypted, so the proxy can read its non-secret routing/classification fields
without trusting them for any security decision.

No token exchange happens here: the client already presents a valid Copilot
bearer, so the proxy forwards it (and the Copilot headers) verbatim.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from contextvars import ContextVar

# Per-request flag: set when a request was routed to GitHub's Copilot API so the
# dashboard/telemetry funnel can label the provider "copilot" instead of the
# wire-compatible "openai"/"anthropic". A ContextVar is task-local — each request
# runs in its own asyncio task, so concurrent requests never see each other's
# value and there is nothing to reset.
_copilot_routed: ContextVar[bool] = ContextVar("headroom_copilot_routed", default=False)


def mark_copilot_routed() -> None:
    """Record that the current request is being routed to the Copilot API."""
    _copilot_routed.set(True)


def copilot_routed() -> bool:
    """Return True when the current request was routed to the Copilot API."""
    return _copilot_routed.get()

# GitHub's generic public Copilot API host. Serves the full model set (including
# newer models on the responses API) and matches what the official Copilot
# clients route with. Enterprise / data-residency tenants on a dedicated host
# override via GITHUB_COPILOT_API_URL (see copilot_upstream_base).
DEFAULT_COPILOT_API_URL = "https://api.githubcopilot.com"

_COPILOT_UPSTREAM_ENV_VARS = ("GITHUB_COPILOT_API_URL", "COPILOT_TARGET_API_URL")

# Copilot-exclusive request paths. Copilot Chat's connectivity ping (`GET /_ping`)
# and some `/agents/*` control calls carry NO Copilot markers and no bearer, so
# per-header/token detection misses them. These paths are unique to GitHub's
# Copilot API — no OpenAI/Anthropic/Gemini client uses them — so routing them by
# path is safe even on a shared multi-provider proxy (unlike a blanket
# "treat everything as Copilot" mode, which would hijack Claude Code /v1/messages).
_COPILOT_ONLY_EXACT = frozenset({"/_ping", "/agents"})
_COPILOT_ONLY_PREFIXES = ("/agents/",)

# Headers the official Copilot clients always send. `copilot-integration-id`
# alone is definitive; `editor-version` + `x-github-api-version` corroborate.
_COPILOT_INTEGRATION_HEADER = "copilot-integration-id"
_EDITOR_VERSION_HEADER = "editor-version"
_GITHUB_API_VERSION_HEADER = "x-github-api-version"


def _hget(headers: Mapping[str, str], name: str) -> str | None:
    """Case-insensitive header lookup."""
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered:
            return value
    return None


def _bearer_token(headers: Mapping[str, str]) -> str:
    raw = _hget(headers, "authorization") or ""
    raw = raw.strip()
    if " " in raw:
        return raw.split(" ", 1)[1].strip()
    return raw


def is_copilot_token(token: str) -> bool:
    """Return True for a GitHub Copilot session token (``tid=...;sku=...``)."""
    return token.startswith("tid=") and ";sku=" in token


def is_copilot_request(headers: Mapping[str, str]) -> bool:
    """Return True when the request originates from a GitHub Copilot client.

    Covers both environments:
      * Copilot Chat (VS Code) — always sends ``copilot-integration-id`` (plus
        ``editor-version`` / ``x-github-api-version``).
      * Copilot CLI (subscription) — sends no editor headers, but its bearer is
        a Copilot session token (``tid=...;sku=...``).
    """
    if _hget(headers, _COPILOT_INTEGRATION_HEADER):
        return True
    if _hget(headers, _EDITOR_VERSION_HEADER) and _hget(headers, _GITHUB_API_VERSION_HEADER):
        return True
    return is_copilot_token(_bearer_token(headers))


def is_copilot_path(path: str) -> bool:
    """Return True for a request path served only by GitHub's Copilot API.

    Used to route marker-less Copilot control traffic (the `/_ping` connectivity
    check, `/agents/*` calls) to the Copilot upstream without a global mode that
    would also capture other providers' traffic.
    """
    clean = path.split("?", 1)[0]
    if clean in _COPILOT_ONLY_EXACT:
        return True
    return any(clean.startswith(prefix) for prefix in _COPILOT_ONLY_PREFIXES)


def copilot_upstream_base(headers: Mapping[str, str] | None = None, *, default: str | None = None) -> str:
    """Resolve the upstream Copilot API base URL.

    Precedence: ``GITHUB_COPILOT_API_URL`` / ``COPILOT_TARGET_API_URL`` env (for
    Enterprise Cloud data-residency or an egress proxy) → ``default`` → the
    generic public host. ``headers`` is accepted for future per-request host
    derivation (e.g. from the token's ``proxy-ep``); unused today.
    """
    del headers  # reserved for future GHE host derivation from the token
    for env_var in _COPILOT_UPSTREAM_ENV_VARS:
        value = os.environ.get(env_var, "").strip()
        if value:
            return value.rstrip("/")
    return (default or DEFAULT_COPILOT_API_URL).rstrip("/")


def copilot_token_fields(headers: Mapping[str, str]) -> dict[str, str]:
    """Parse non-secret routing/classification fields from the Copilot token.

    Returns a dict with any of ``sku`` (seat/plan), ``st`` (dotcom vs GHE) and
    ``org`` (present when the seat is org-assigned). The token id, signature and
    privacy-sensitive fields (``ip``, ``asn``) are never returned. Empty dict
    when the bearer is not a Copilot token.
    """
    token = _bearer_token(headers)
    if not is_copilot_token(token):
        return {}
    fields: dict[str, str] = {}
    for part in token.split(";"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        if key == "sku":
            fields["sku"] = value
        elif key == "st":
            fields["st"] = value
        elif key in ("ol", "ort"):
            fields["org"] = "present"
    return fields


def copilot_seat_class(headers: Mapping[str, str]) -> str | None:
    """Classify the Copilot seat from the token's ``sku``.

    Returns ``"enterprise"``, ``"business"``, ``"individual"`` or ``None`` when
    unknown / not a Copilot token.
    """
    sku = copilot_token_fields(headers).get("sku", "")
    if not sku:
        return None
    lowered = sku.lower()
    if "enterprise" in lowered:
        return "enterprise"
    if "business" in lowered:
        return "business"
    if "individual" in lowered or "free" in lowered or "pro" in lowered:
        return "individual"
    return None
