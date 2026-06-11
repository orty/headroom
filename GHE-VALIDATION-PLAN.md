# GitHub Enterprise API URL Auto-Detection: Validation Plan

**Status:** Design phase for Phase 0 implementation. This plan outlines how to validate GHE tenant auto-detection against a real GitHub Enterprise Cloud tenant with Copilot Enterprise.

**Session:** See online session `01HQX5niZvUdar9Vp5JRLFbK` for prior discussion of the bearer token passthrough fix and this plan's context.

---

## Problem Statement

Today, `headroom proxy` routes all OpenAI-wire traffic to a single statically configured upstream (`OPENAI_TARGET_API_URL`, default `api.openai.com`). For GitHub Enterprise Cloud tenants with Copilot, the correct upstream is a tenant-specific host (e.g., `api.<tenant>.githubcopilot.com` or `api.<tenant>.ghe.com` for data-residency deployments).

The infrastructure to *learn* the tenant host exists but is unused:
- `CopilotTokenProvider._exchange_token()` already invokes `/copilot_internal/v2/token` and stores `endpoints.api` on the returned `CopilotAPIToken.api_url` (copilot_auth.py:591).
- The response field `endpoints.api` is populated by GitHub and points to the correct tenant host.
- Upstream issue #610 documented why auto-detection was removed: the *individual* segmented host (`api.individual.githubcopilot.com`) breaks newer models on the responses API. Whether *enterprise* hosts have the same defect is unknown and requires real-tenant testing.

**Goal:** Validate that inferring the upstream host from the token exchange response reliably routes all request types to the correct tenant endpoint without regressions.

---

## Phase 0 — Code: Per-Request Inference (no tenant needed)

### 0.1 Copilot Request Classification

The proxy must recognize "this OpenAI-wire request is Copilot traffic" without relying on env vars.

**Signals in priority order:**
1. `Editor-Version` header — Copilot clients always send it (e.g., `Editor-Version: vscode/1.104.1`).
2. `User-Agent` — `GitHubCopilotChat/`, `copilot/`, etc. (already tracked in `SUBSCRIPTION_UA_PREFIXES`, auth_mode.py:60).
3. Inbound token shape:
   - GitHub OAuth: `gho_` or `ghu_` prefix
   - Copilot session token: semicolon-delimited metadata (`tid=…;exp=…;…`)

**Implementation:** New helper in copilot_auth.py, consulted when `is_copilot_api_url()` returns False but the request carries a Copilot-shaped credential.

### 0.2 Host Inference by Token Type

#### Case A: GitHub OAuth Token (Copilot CLI)
- The proxy performs token exchange: `POST /copilot_internal/v2/token` with the inbound token.
- Consumes `endpoints.api` from the response → routes to that host.
- The scaffolding exists in `CopilotTokenProvider._exchange_token()` (already implemented).
- **Change:** Use the inbound OAuth token for the exchange; consume and cache `token.api_url` for routing.

#### Case B: Already-Exchanged Session Token (VS Code)
- VS Code exchanges internally and sends the session token (shape: `tid=…;exp=…;proxy-ep=…`).
- Hypothesis to test: session token metadata includes `proxy-ep=proxy.<tenant>.githubcopilot.com` (or similar), from which `api.<tenant>.githubcopilot.com` can be derived.
- If metadata is absent, fallback to default public host — this is a finding, not a failure, and surfaces as a documented limitation.

**Implementation:** Parse session token format; extract and validate `proxy-ep` field if present.

### 0.3 Plumbing Requirements

1. **Per-token exchange cache:**
   - Key: SHA256 digest of token (never store raw value)
   - Entry: `(api_url, expires_at, refresh_in)`
   - Evict on expiry or if `refresh_in` elapsed; no cache hits for expired tokens
   - Isolated from the existing `CopilotTokenProvider._cached` (which caches the *API* token for local resolution only)

2. **Precedence (unchanged):**
   - Explicit overrides (`GITHUB_COPILOT_API_URL`, `OPENAI_TARGET_API_URL`) always win
   - Matches the #610 policy: no auto-inference trumps operator intent

3. **Observability:**
   - One `logger.info` per host resolution, format: `"Resolved Copilot tenant host: <host> (from <source>)"` where source is `oauth_exchange`, `session_metadata`, or `env_override`
   - **Never log token values** — only host, source, and freshness
   - This log line is the primary telemetry for Phase 2 validation

4. **Gate behind existing flag:**
   - `GITHUB_COPILOT_USE_TOKEN_EXCHANGE` (copilot_auth.py:94) controls token exchange already
   - Extend to also gate per-request inference: if False, behave as today (no per-request exchange, fall back to local resolution or env var)
   - New flag `GITHUB_COPILOT_INFER_TENANT_HOST` (default: False) to enable the full inference path for Phase 1 testing

### 0.4 Lab Testing (before any real credential)

Use `GITHUB_COPILOT_TOKEN_EXCHANGE_URL` override (copilot_auth.py:87) to point at a fake endpoint:

```python
# conftest.py or test fixture
@pytest.fixture
def fake_exchange(monkeypatch):
    responses = {
        "oauth_token_public": {
            "token": "copilot-api-public",
            "expires_at": int(time.time()) + 3600,
            "endpoints": {"api": "https://api.githubcopilot.com"},
        },
        "oauth_token_enterprise": {
            "token": "copilot-api-enterprise",
            "expires_at": int(time.time()) + 3600,
            "endpoints": {"api": "https://api.acme.githubcopilot.com"},
        },
    }
    # Mock the endpoint to return responses[token] based on input token
    monkeypatch.setenv("GITHUB_COPILOT_TOKEN_EXCHANGE_URL", "http://localhost:9999/token")
    # Start a test server or monkeypatch urlopen
```

**Test matrix:**
- Public tenant: inferred host == `api.githubcopilot.com`
- Enterprise tenant: inferred host == `api.acme.githubcopilot.com`
- Cache hit: second request with same token re-uses cached host, no second exchange
- Cache eviction: expired token triggers fresh exchange
- Precedence: env var `OPENAI_TARGET_API_URL` overrides inferred host
- Token shape rejection: malformed token doesn't crash, falls back to env/default
- Session token parsing: extracts proxy-ep correctly (or reports missing)
- Cross-contamination: Anthropic bearer never triggers Copilot inference

---

## Phase 1 — Real Tenant Prerequisites

### 1.1 Access & Authorization
- GHE Cloud tenant with **Copilot Enterprise** seats (not just Copilot Pro)
- Ideally **with data residency** enabled, since that's where `endpoints.api` differs most and most interesting for testing
- Dedicated test account (not personal)
- Written approval from org admin (this is a real credential + traffic inspection scenario)

### 1.2 Ground Truth Capture
Before involving headroom, establish the baseline:

```bash
# With the test account, authenticated to the tenant:
gh auth login --hostname enterprise.github.com

# Capture the tenant's true API host:
gh api /copilot_internal/v2/token --hostname enterprise.github.com \
  --header 'Accept: application/json' | jq '.endpoints.api'
# Expected output: https://api.<tenant>.githubcopilot.com or https://api.<tenant>.ghe.com

# For VS Code: if available, check the extension settings for the debug endpoints
# (Settings > @ext:github.copilot advanced, look for debug.overrideCAPIUrl)
```

Document this as the **ground truth** — every proxied request is compared against it.

### 1.3 Proxy Setup
Single machine or container with:
- `headroom proxy` running on `localhost:8787`
- **Zero** Copilot/OpenAI URL or token env vars (the whole point)
- Debug logging: `RUST_LOG=debug` or `HEADROOM_LOG_LEVEL=debug`
- Flags enabled: `GITHUB_COPILOT_USE_TOKEN_EXCHANGE=true`, `GITHUB_COPILOT_INFER_TENANT_HOST=true`
- `OPENAI_TARGET_API_URL` explicitly set to the tenant host (as a fallback, not for inference to lean on)

---

## Phase 2 — Client Interposition Matrix

| Client | Proxy Hook | How to Verify Token Reaches Proxy | Token Type (hypothesis) |
|---|---|---|---|
| Copilot CLI | `COPILOT_PROVIDER_API_URL=http://localhost:8787` | `headroom proxy` debug log shows `Authorization: Bearer gho_…` or session token | OAuth (`gho_`/`ghu_`) OR session token — **must capture first** |
| VS Code Copilot | `settings.json`: `"github.copilot.advanced": {"debug.overrideCAPIUrl": "http://localhost:8787", "debug.overrideProxyUrl": "http://localhost:8787"}` (verify current setting names) | Debug log shows inbound request | Exchanged session token (`tid=…`) |
| Claude Code | `ANTHROPIC_BASE_URL=http://localhost:8787` | Debug log shows `Authorization: Bearer sk-ant-oat…` | OAuth bearer (Anthropic) |

**First action per client:** Send one request and classify the inbound `Authorization` header shape from proxy debug output (prefix and format, **never the value**). The Copilot CLI row is genuinely uncertain: with a provider URL, it runs BYOK transport and may expect a configured key rather than sending its own subscription token; if so, that's a documented CLI limitation, and the plan captures it as a finding.

---

## Phase 3 — Per-Request Validation

For each combination of client × {chat completions, responses API, streaming, model listing}:

### 3.1 Routing Assertion
**Expected:** resolved upstream host == ground truth from Phase 1.2.  
**Check:** proxy debug log line `"Resolved Copilot tenant host: …"` matches ground truth.  
**Failure mode:** routes to `api.openai.com` (default) or `api.individual.githubcopilot.com` (old segmented host).

### 3.2 Auth Passthrough
**Expected:** request succeeds with *zero* token configured on proxy.  
**Check:** client prints completion/response successfully; proxy logs show `Resolved Copilot tenant host: <tenant>` (not "no token available" error).  
**Kill switch test:** restart proxy without `GITHUB_COPILOT_INFER_TENANT_HOST=true` → request fails (ground truth for what "no inference" looks like).

### 3.3 Compression Applied
**Expected:** headroom compression metrics move; `x-headroom-*` response headers present.  
**Check:** `GET /stats` on proxy before and after request; `tokens_saved` > 0.  
**Failure mode:** `x-headroom-compression-failed` header or no stats delta.

### 3.4 The #610 Regression Check (Critical)
**Expected:** newer models on the responses API actually serve from the inferred tenant host (not the individual segmented host).  
Upstream removed auto-detection because the *individual* host (`api.individual.githubcopilot.com`) broke newer models. Whether *enterprise* hosts have the same defect is the single most important unknown.

**Test:** Request the newest available model via responses API (e.g., Claude 4.1 if it's available through Copilot). If the model list is empty or the request fails after routing to the inferred host, capture the error — this is the blocker for upstream acceptance.

**Check:** proxy logs + client success/failure. If the responses API fails but chat completions work, that's data (segmented host defect confirmed for this tenant too).

### 3.5 Cross-Contamination Negatives
**Expected:** no credential confusion across providers.  
**Assertions:**
- Claude Code traffic routes to `api.anthropic.com` with its own bearer untouched
- Anthropic bearer never appears on a GitHub-bound request
- GitHub Copilot token never appears on an Anthropic request
- Plain OpenAI-key request (if tested) still routes to `api.openai.com`

**Check:** grep proxy debug logs for each token prefix used in the session (capture them in Phase 2). Zero false positives.

### 3.6 Token Hygiene
**Expected:** no tokens in logs or responses.  
**Check:** Full debug log capture → grep for every token prefix observed (e.g., `gho_`, `sk-ant-`, `tid=`, etc.). Zero hits required.

---

## Exit Criteria & Deliverables

### Success (Green Path)
1. Confirmed that `endpoints.api` from token exchange (or session token metadata) reliably identifies the tenant host.
2. Responses API serves the full model set from the inferred host (no #610 regression for this tenant).
3. All three clients (Copilot CLI, VS Code, Claude Code) route correctly with auth passthrough, no env vars needed.
4. Phase 0 code merged (flag-gated, behind `GITHUB_COPILOT_INFER_TENANT_HOST`).
5. **Deliverable:** Upstream PR with inference enabled by default + `TESTING-copilot-subscription.md` section "GHE auto-detection" (or new doc).

### Findings Report (Regardless of Success)
Submit to upstream in the style of `TESTING-copilot-subscription.md`'s "what to report" section:
- Token shapes per client (redacted)
- Exchange response fields observed (redacted)
- Host resolution per request type
- Model availability from inferred host
- Any failures, with full error traces

### Failure (Red Path)
If `endpoints.api` doesn't match reality, or responses API fails from the inferred host:
1. Document exact failure mode (e.g., "responses API returns 404 for model X from `api.<tenant>.githubcopilot.com`").
2. Upstream issue linking to findings report.
3. Auto-detection stays off; policy remains: "operators must set `GITHUB_COPILOT_API_URL` explicitly" (or `OPENAI_TARGET_API_URL` for bare proxy).

---

## Known Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| VS Code debug overrides don't exist in current extension | Can't test VS Code leg of the matrix | Check extension source / release notes before Phase 1; scope reduction if needed, doesn't invalidate the OAuth-path testing |
| Copilot CLI refuses to send subscription token to custom provider URL | Can't test CLI leg | Document as CLI limitation; OAuth exchange can still be validated via other clients or curl if needed |
| Session token format undocumented / `proxy-ep` field missing | Can't infer from session token | Hypothesis becomes a finding: report the actual token format for upstream to confirm; fall back to OAuth-only inference |
| `is_copilot_api_url()` substring check fails on GHE host | Auth passthrough disengages silently | Phase 0 unit test: ensure `is_copilot_api_url("api.acme.ghe.com")` returns False (it will; update the check to handle GHE patterns or use explicit endpoint list) |
| Token exchange endpoint different on GHE | Exchange fails | Pre-flight: test exchange URL with the test account before full interposition |

---

## Implementation Checklist (Phase 0)

- [ ] Add `_classify_as_copilot_request(headers: dict) -> bool` in copilot_auth.py
- [ ] Add session token parser in copilot_auth.py: `_parse_session_token(token: str) -> dict | None`
- [ ] Add per-token exchange cache: `_exchange_cache: dict[str, (str, float)]` (host, expires_at)
- [ ] Modify `apply_copilot_api_auth()` to check for Copilot-shaped inbound token when local resolution fails
- [ ] Add `GITHUB_COPILOT_INFER_TENANT_HOST` flag (default False)
- [ ] Unit tests: exchange response parsing, caching, precedence, malformed tokens
- [ ] Lab tests using fake exchange URL override (conftest.py fixture)
- [ ] Integration test: Copilot classification vs. Anthropic (no cross-contamination)
- [ ] Update copilot_auth.py docstrings
- [ ] Update CHANGELOG.md with feature flag note

---

## Next Steps

1. **Immediate:** Phase 0 implementation on this branch (`claude/copilot-bearer-passthrough-uju33s`), gated behind the new flag.
2. **GHE tenant coordination:** Identify and onboard a real tenant (separate from code work; may take time).
3. **Phase 1 rehearsal:** Smoke test Phase 0 code in a staging environment with synthetic tenant (fake exchange endpoint).
4. **Real-tenant Phase 2/3:** Run the full matrix once tenant access confirmed.
5. **Upstream submission:** PR with findings + decision (inference on/off/conditional).

---

## References

- Upstream issue #610: https://github.com/chopratejas/headroom/issues/610
- Upstream discussion: token exchange endpoint as auto-detection source (see issue or PR comments)
- Session token format: Copilot CLI source or VS Code Copilot extension source
- This validation plan: committed to branch `claude/copilot-bearer-passthrough-uju33s`
