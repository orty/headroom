"""Pseudonymous account tag: hashes only, never the raw Claude Code ids."""

from __future__ import annotations

import hashlib
import json
import logging

import httpx
import pytest

from headroom.proxy.account_pseudonym import account_tag, log_account_tag

ACCOUNT = "4f6c2a1e-1111-4222-8333-944455556666"
DEVICE = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
SESSION = "9e8d7c6b-aaaa-4bbb-8ccc-ddddeeeeffff"
RAW = (ACCOUNT, DEVICE, SESSION)


def _h(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:12]


def _json_body(account: str = ACCOUNT, device: str = DEVICE) -> dict:
    user_id = json.dumps({"device_id": device, "account_uuid": account, "session_id": SESSION})
    return {"model": "claude-sonnet-4-6", "metadata": {"user_id": user_id}}


def _legacy_body(account: str = ACCOUNT) -> dict:
    return {"metadata": {"user_id": f"user_{DEVICE}_account_{account}_session_{SESSION}"}}


def test_json_user_id_gives_account_hash() -> None:
    assert account_tag(_json_body()) == {"acct": _h(ACCOUNT)}


def test_legacy_user_id_gives_account_hash() -> None:
    assert account_tag(_legacy_body()) == {"acct": _h(ACCOUNT)}


def test_empty_account_falls_back_to_device() -> None:
    assert account_tag(_json_body(account="")) == {"dev": _h(DEVICE)}
    assert account_tag(_legacy_body(account="")) == {"dev": _h(DEVICE)}


@pytest.mark.parametrize(
    "body",
    [
        None,
        "text",
        [],
        {},
        {"metadata": None},
        {"metadata": "x"},
        {"metadata": {}},
        {"metadata": {"user_id": 42}},
        {"metadata": {"user_id": ""}},
        {"metadata": {"user_id": "{not json"}},
        {"metadata": {"user_id": "[1, 2]"}},
        {"metadata": {"user_id": '{"account_uuid": 5, "device_id": null}'}},
        {"metadata": {"user_id": "some-other-format"}},
    ],
)
def test_missing_or_garbage_metadata_gives_empty(body: object) -> None:
    assert account_tag(body) == {}


def test_hash_is_stable_and_never_raw() -> None:
    first = account_tag(_json_body())
    assert first == account_tag(_json_body(device="other-device"))
    assert first == account_tag(_legacy_body())
    assert ACCOUNT not in json.dumps(first)


def _account_lines(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [r.getMessage() for r in caplog.records if r.getMessage().startswith("account_tag ")]


def _assert_no_raw(caplog: pytest.LogCaptureFixture) -> None:
    text = caplog.text + "\n".join(r.getMessage() for r in caplog.records)
    for raw in RAW:
        assert raw not in text


def test_log_line_gateway_request(caplog: pytest.LogCaptureFixture) -> None:
    headers = {"x-headroom-user": "alice", "x-forwarded-for": "203.0.113.9"}
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag(headers, _json_body(), "req-1")
    assert _account_lines(caplog) == [
        f"account_tag route=gateway user=alice principal=- app=- acct={_h(ACCOUNT)} dev=- ip=- request_id=req-1"
    ]
    _assert_no_raw(caplog)


def test_log_line_app_only_gateway_request(caplog: pytest.LogCaptureFixture) -> None:
    principal = "11111111-2222-3333-4444-555555555555"
    app = "66666666-7777-8888-9999-000000000000"
    headers = {
        "x-headroom-principal": principal,
        "x-headroom-app": app,
        "x-forwarded-for": "203.0.113.9",
    }
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag(headers, _json_body(), "req-5")
    assert _account_lines(caplog) == [
        f"account_tag route=gateway user=- principal={principal} app={app}"
        f" acct={_h(ACCOUNT)} dev=- ip=- request_id=req-5"
    ]
    _assert_no_raw(caplog)


@pytest.mark.parametrize("header", ["x-headroom-principal", "x-headroom-app"])
def test_log_line_any_gateway_header_means_gateway(
    caplog: pytest.LogCaptureFixture, header: str
) -> None:
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag({header: "abc", "x-forwarded-for": "203.0.113.9"}, {}, "req-6")
    (line,) = _account_lines(caplog)
    assert line.startswith("account_tag route=gateway user=- ")
    assert " ip=- " in line


def test_log_line_legacy_request(caplog: pytest.LogCaptureFixture) -> None:
    headers = {"x-forwarded-for": "198.51.100.7, 10.0.0.1"}
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag(headers, _json_body(account=""), "req-2")
        log_account_tag({"x-envoy-external-address": "192.0.2.4", **headers}, {}, "req-3")
    assert _account_lines(caplog) == [
        f"account_tag route=legacy user=- principal=- app=- acct=- dev={_h(DEVICE)}"
        " ip=198.51.100.7 request_id=req-2",
        "account_tag route=legacy user=- principal=- app=- acct=- dev=- ip=192.0.2.4 request_id=req-3",
    ]
    _assert_no_raw(caplog)


def test_log_line_header_cannot_forge_fields(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag({"x-headroom-user": "bob acct=forged"}, {}, "req-4")
    (line,) = _account_lines(caplog)
    assert "user=bob_acct=forged principal=- app=- acct=-" in line


def test_log_line_principal_and_app_cannot_forge_fields(caplog: pytest.LogCaptureFixture) -> None:
    headers = {"x-headroom-principal": "p acct=forged", "x-headroom-app": "a\tip=1.2.3.4"}
    with caplog.at_level(logging.INFO, logger="headroom.proxy"):
        log_account_tag(headers, {}, "req-7")
    (line,) = _account_lines(caplog)
    assert "principal=p_acct=forged app=a_ip=1.2.3.4 acct=- dev=- ip=- " in line
    assert line.count(" acct=") == 1
    assert line.count(" ip=") == 1


class _OkTransport(httpx.AsyncBaseTransport):
    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "content": [{"type": "text", "text": "ok"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        )


@pytest.mark.parametrize(
    ("extra_headers", "expected"),
    [
        ({"x-headroom-user": "alice"}, "route=gateway user=alice principal=- app=-"),
        (
            {"x-headroom-principal": "p-guid", "x-headroom-app": "a-guid"},
            "route=gateway user=- principal=p-guid app=a-guid",
        ),
        ({"x-envoy-external-address": "192.0.2.4"}, "route=legacy user=- principal=- app=-"),
    ],
)
def test_messages_handler_logs_account_tag(
    caplog: pytest.LogCaptureFixture, extra_headers: dict[str, str], expected: str
) -> None:
    pytest.importorskip("fastapi")
    from fastapi.testclient import TestClient

    from headroom.proxy.server import ProxyConfig, create_app

    config = ProxyConfig(
        optimize=False,
        cache_enabled=False,
        rate_limit_enabled=False,
        cost_tracking_enabled=False,
        log_requests=False,
        ccr_inject_tool=False,
        ccr_handle_responses=False,
        ccr_context_tracking=False,
        image_optimize=False,
    )
    app = create_app(config)
    body = {**_json_body(), "max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]}
    with caplog.at_level(logging.INFO), TestClient(app) as client:
        app.state.proxy.http_client = httpx.AsyncClient(transport=_OkTransport())
        response = client.post(
            "/v1/messages",
            headers={"x-api-key": "test-key", "anthropic-version": "2023-06-01", **extra_headers},
            content=json.dumps(body).encode(),
        )
    assert response.status_code == 200
    (line,) = _account_lines(caplog)
    assert line.startswith(f"account_tag {expected} acct={_h(ACCOUNT)} dev=- ip=")
    if "x-envoy-external-address" in extra_headers:
        assert " ip=192.0.2.4 " in line
    else:
        assert " ip=- " in line
    _assert_no_raw(caplog)
