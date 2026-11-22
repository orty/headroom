"""Pseudonymous account tag for /v1/messages requests.

Claude Code sends ``metadata.user_id`` on every request. It names the
claude.ai account, the device and the session. The proxy logs a short,
stable hash of the account (or device) so requests sharing one upstream
token can be told apart, without ever logging the raw ids.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
from collections.abc import Mapping
from typing import Any

logger = logging.getLogger("headroom.proxy")

_HASH_LEN = 12
# Older clients: user_<hex>_account_<uuid>_session_<uuid>
_LEGACY_USER_ID = re.compile(
    r"^user_(?P<device>[0-9a-fA-F]*)_account_(?P<account>[^_]*)_session_(?P<session>.*)$"
)
_UNSAFE_LOG_CHARS = re.compile(r"[\s\x00-\x1f\x7f]+")


def _short_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:_HASH_LEN]


def _ids_from_user_id(user_id: str) -> tuple[str, str]:
    """Return (account_uuid, device_id) from either user_id format."""
    text = user_id.strip()
    if text.startswith("{"):
        parsed = json.loads(text)
        if not isinstance(parsed, dict):
            return "", ""
        account = parsed.get("account_uuid")
        device = parsed.get("device_id")
        return (
            account if isinstance(account, str) else "",
            device if isinstance(device, str) else "",
        )
    match = _LEGACY_USER_ID.match(text)
    if match is None:
        return "", ""
    return match.group("account"), match.group("device")


def account_tag(body: Any) -> dict[str, str]:
    """Return ``{"acct": h}``, ``{"dev": h}`` or ``{}`` for a request body.

    Never returns raw ids and never raises: bad input gives ``{}``.
    """
    try:
        metadata = body.get("metadata") if isinstance(body, Mapping) else None
        user_id = metadata.get("user_id") if isinstance(metadata, Mapping) else None
        if not isinstance(user_id, str) or not user_id:
            return {}
        account, device = _ids_from_user_id(user_id)
        if account.strip():
            return {"acct": _short_hash(account.strip())}
        if device.strip():
            return {"dev": _short_hash(device.strip())}
    except Exception:
        return {}
    return {}


def _log_value(value: str | None) -> str:
    """One space-free token per field so a header can't forge log fields."""
    if not value:
        return "-"
    cleaned = _UNSAFE_LOG_CHARS.sub("_", value.strip())[:128]
    return cleaned or "-"


def log_account_tag(headers: Mapping[str, str], body: Any, request_id: str) -> None:
    """Log one ``account_tag`` INFO line for a request. Never raises."""
    try:
        gateway_user = headers.get("x-headroom-user")
        principal = headers.get("x-headroom-principal")
        app = headers.get("x-headroom-app")
        # App-only tokens carry no user claim; the gateway still sets principal and app.
        route = "gateway" if gateway_user or principal or app else "legacy"
        ip = None
        if route == "legacy":
            ip = headers.get("x-envoy-external-address")
            if not ip:
                forwarded = headers.get("x-forwarded-for") or ""
                ip = forwarded.split(",")[0]
        tag = account_tag(body)
        logger.info(
            "account_tag route=%s user=%s principal=%s app=%s acct=%s dev=%s ip=%s request_id=%s",
            route,
            _log_value(gateway_user),
            _log_value(principal),
            _log_value(app),
            tag.get("acct", "-"),
            tag.get("dev", "-"),
            _log_value(ip),
            _log_value(request_id),
        )
    except Exception:
        logger.debug("account_tag logging failed", exc_info=False)
