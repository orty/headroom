"""Tests for server-side GitHub Copilot ingress detection and routing."""

from __future__ import annotations

import pytest

from headroom.providers.copilot.ingress import (
    DEFAULT_COPILOT_API_URL,
    copilot_seat_class,
    copilot_token_fields,
    copilot_upstream_base,
    is_copilot_path,
    is_copilot_request,
    is_copilot_token,
)

# A representative Copilot session token (structure only; not a real secret).
_BUSINESS_TOKEN = (
    "tid=abc123;ol=99;exp=1783415708;sku=copilot_for_business_seat_quota;"
    "st=dotcom;chat=1;deadbeefsig"
)
_ENTERPRISE_TOKEN = "tid=z;exp=1;sku=copilot_for_enterprise_seat;st=dotcom;sig"
_INDIVIDUAL_TOKEN = "tid=z;exp=1;sku=copilot_individual;st=dotcom;sig"


class TestIsCopilotRequest:
    def test_detects_by_integration_id_header(self):
        assert is_copilot_request({"Copilot-Integration-Id": "vscode-chat"})

    def test_detects_by_editor_plus_api_version(self):
        assert is_copilot_request(
            {"Editor-Version": "vscode/1.128.0", "X-GitHub-Api-Version": "2026-06-01"}
        )

    def test_editor_version_alone_is_not_enough(self):
        assert not is_copilot_request({"Editor-Version": "vscode/1.128.0"})

    def test_detects_by_copilot_token(self):
        assert is_copilot_request({"Authorization": f"Bearer {_BUSINESS_TOKEN}"})

    def test_case_insensitive_headers(self):
        assert is_copilot_request({"copilot-integration-id": "vscode-chat"})

    def test_plain_openai_request_is_not_copilot(self):
        assert not is_copilot_request(
            {"Authorization": "Bearer sk-proj-abcdef", "User-Agent": "OpenAI/JS 5.20.1"}
        )

    def test_github_oauth_token_is_not_copilot(self):
        # Copilot CLI BYOK / raw OAuth token must NOT be misclassified.
        assert not is_copilot_request({"Authorization": "Bearer gho_16charsx7qeY"})

    def test_no_headers_is_not_copilot(self):
        assert not is_copilot_request({})


class TestIsCopilotToken:
    def test_true_for_tid_with_sku(self):
        assert is_copilot_token(_BUSINESS_TOKEN)

    def test_false_without_sku(self):
        assert not is_copilot_token("tid=abc;exp=1;sig")

    def test_false_for_non_tid(self):
        assert not is_copilot_token("sk-proj-abcdef")


class TestCopilotUpstreamBase:
    def test_default_public_host(self, monkeypatch):
        monkeypatch.delenv("GITHUB_COPILOT_API_URL", raising=False)
        monkeypatch.delenv("COPILOT_TARGET_API_URL", raising=False)
        assert copilot_upstream_base({}) == DEFAULT_COPILOT_API_URL

    def test_env_override_for_ghe(self, monkeypatch):
        monkeypatch.setenv("GITHUB_COPILOT_API_URL", "https://copilot-api.acme.ghe.com/")
        assert copilot_upstream_base({}) == "https://copilot-api.acme.ghe.com"

    def test_legacy_env_var(self, monkeypatch):
        monkeypatch.delenv("GITHUB_COPILOT_API_URL", raising=False)
        monkeypatch.setenv("COPILOT_TARGET_API_URL", "https://example.test")
        assert copilot_upstream_base({}) == "https://example.test"

    def test_explicit_default_arg(self, monkeypatch):
        monkeypatch.delenv("GITHUB_COPILOT_API_URL", raising=False)
        monkeypatch.delenv("COPILOT_TARGET_API_URL", raising=False)
        assert copilot_upstream_base({}, default="https://x.test/") == "https://x.test"


class TestSeatClassification:
    def test_fields_extracts_sku_st_org(self):
        fields = copilot_token_fields({"Authorization": f"Bearer {_BUSINESS_TOKEN}"})
        assert fields["sku"] == "copilot_for_business_seat_quota"
        assert fields["st"] == "dotcom"
        assert fields["org"] == "present"

    def test_fields_never_leak_secrets(self):
        fields = copilot_token_fields({"Authorization": f"Bearer {_BUSINESS_TOKEN}"})
        assert "tid" not in fields
        assert "ip" not in fields and "asn" not in fields

    @pytest.mark.parametrize(
        "token,expected",
        [
            (_BUSINESS_TOKEN, "business"),
            (_ENTERPRISE_TOKEN, "enterprise"),
            (_INDIVIDUAL_TOKEN, "individual"),
        ],
    )
    def test_seat_class(self, token, expected):
        assert copilot_seat_class({"Authorization": f"Bearer {token}"}) == expected

    def test_seat_class_none_for_non_copilot(self):
        assert copilot_seat_class({"Authorization": "Bearer sk-proj-x"}) is None


class TestDashboardLabel:
    def test_routed_flag_defaults_false(self):
        from headroom.providers.copilot.ingress import copilot_routed

        assert copilot_routed() is False

    def test_mark_is_task_local(self):
        # mark_copilot_routed sets a ContextVar; running it in a copied context
        # must not leak into the parent (concurrent requests stay isolated).
        import contextvars

        from headroom.providers.copilot.ingress import copilot_routed, mark_copilot_routed

        def inner():
            mark_copilot_routed()
            return copilot_routed()

        assert contextvars.copy_context().run(inner) is True
        assert copilot_routed() is False


class TestCopilotPath:
    @pytest.mark.parametrize(
        "path",
        ["/_ping", "/agents", "/agents/swe/models", "/agents/swe/v1/jobs/x/y/enabled",
         "/_ping?foo=bar"],
    )
    def test_copilot_only_paths(self, path):
        assert is_copilot_path(path) is True

    @pytest.mark.parametrize(
        "path",
        ["/v1/messages", "/chat/completions", "/v1/chat/completions", "/models",
         "/v1/models", "/responses", "/agentsfoo", "/"],
    )
    def test_non_copilot_paths(self, path):
        assert is_copilot_path(path) is False


class TestPassthroughRouting:
    def _proxy(self):
        # Minimal stand-in exposing the provider_runtime surface used by the
        # non-Copilot branch of _select_passthrough_base_url.
        class _Runtime:
            def model_metadata_provider(self, headers):
                from headroom.providers.registry import _is_anthropic_auth

                return "anthropic" if _is_anthropic_auth(headers) else "openai"

            def api_target(self, name):
                return {
                    "openai": "https://api.openai.com",
                    "anthropic": "https://api.anthropic.com",
                }[name]

        class _DummyProxy:
            provider_runtime = _Runtime()
            OPENAI_API_URL = "https://api.openai.com"
            ANTHROPIC_API_URL = "https://api.anthropic.com"

        return _DummyProxy()

    def test_select_passthrough_routes_copilot_header_to_capi(self, monkeypatch):
        monkeypatch.delenv("GITHUB_COPILOT_API_URL", raising=False)
        monkeypatch.delenv("COPILOT_TARGET_API_URL", raising=False)
        from headroom.providers.proxy_routes import _select_passthrough_base_url

        base = _select_passthrough_base_url(
            self._proxy(), {"copilot-integration-id": "vscode-chat"}, "/models"
        )
        assert base == DEFAULT_COPILOT_API_URL

    def test_copilot_only_path_routes_to_capi_without_markers(self, monkeypatch):
        # /_ping carries no markers but is Copilot-only -> route by path.
        monkeypatch.delenv("GITHUB_COPILOT_API_URL", raising=False)
        from headroom.providers.proxy_routes import _select_passthrough_base_url

        base = _select_passthrough_base_url(self._proxy(), {}, "/_ping")
        assert base == DEFAULT_COPILOT_API_URL

    def test_shared_proxy_claude_code_stays_anthropic(self):
        # Claude Code /v1/messages (anthropic auth, no Copilot signals) must NOT
        # be hijacked to Copilot — the shared-proxy regression that motivated the
        # removal of a global ingress mode.
        from headroom.providers.proxy_routes import _select_passthrough_base_url

        base = _select_passthrough_base_url(
            self._proxy(),
            {"x-api-key": "sk-ant-xxx", "anthropic-version": "2023-06-01"},
            "/v1/messages",
        )
        assert "anthropic" in base

    def test_markerless_non_copilot_path_stays_openai(self):
        from headroom.providers.proxy_routes import _select_passthrough_base_url

        base = _select_passthrough_base_url(self._proxy(), {}, "/v1/models")
        assert base == "https://api.openai.com"
