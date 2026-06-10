# fix(copilot): forward inbound bearer token when no local Copilot token is configured

## Description

`headroom proxy` rejects GitHub Copilot requests that carry a valid
`Authorization: Bearer <token>` header unless a Copilot token is *also*
configured on the proxy side (`GITHUB_COPILOT_TOKEN` env var or OS secret
store). `apply_copilot_api_auth()` unconditionally strips the inbound
`Authorization` header and replaces it with a locally resolved token, raising
`RuntimeError` when local resolution finds nothing — even though the client
already sent a usable credential.

This is the same class of bug as #200 (Anthropic handler not honoring
`ANTHROPIC_AUTH_TOKEN` bearer tokens), and the fix brings the Copilot path in
line with how the Anthropic handler already treats inbound bearer credentials:
when the proxy has nothing configured locally, the client's token is forwarded
upstream unchanged.

The practical impact is the Docker dev-container model: inside a container,
`wrap --subscription` cannot reach the host keychain, so today the only option
is manually extracting the token and re-injecting it as a Docker env var on
every session. With this fix, pointing the Copilot CLI at the proxy via
`COPILOT_PROVIDER_API_URL` just works — the proxy reuses the bearer token the
CLI is already sending.

Fixes the Copilot analog of #200.

## Type of Change

- [x] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [x] Documentation update
- [ ] Performance improvement
- [ ] Code refactoring (no functional changes)

## Changes Made

All changes are confined to `headroom/copilot_auth.py` (shared by every Copilot
call site: chat, responses, websocket, streaming, passthrough) plus tests and
docs. No other handlers or proxy core are touched.

- `CopilotTokenUnavailableError(RuntimeError)`: raised by
  `CopilotTokenProvider.get_api_token()` when *discovery* finds no token.
  Subclassing `RuntimeError` keeps every existing catcher and test working.
  Other auth failures (e.g. a failed token exchange for a *configured* token)
  still raise plain `RuntimeError` and do **not** trigger the fallback —
  a misconfigured local token fails loudly instead of silently switching
  credentials.
- `apply_copilot_api_auth()` catches only `CopilotTokenUnavailableError`:
  - If the inbound request carries a non-empty `Authorization: Bearer` header,
    the headers are returned unchanged (single `logger.debug`, no token data).
  - Otherwise it re-raises with a message naming both remedies (set
    `GITHUB_COPILOT_TOKEN` / send a bearer header), preceded by a
    `logger.warning` so the failure is visible at every call site — including
    the passthrough paths that don't wrap this call in their own try/except.
- The inbound token is never extracted, stored, or logged — presence is
  detected and the header dict is passed through as-is.

**Precedence is unchanged.** A locally resolvable token (env vars, keychain,
credential files, `gh` CLI) always wins, exactly as today; the inbound header
is consulted only when local resolution finds nothing. `GITHUB_COPILOT_API_URL`
host overrides (enterprise / data-residency) compose with both token sources,
since URL resolution was already independent of token resolution.

**Behavior notes for existing paths (no surprises intended):**
- With any local token configured: byte-for-byte identical behavior.
- With nothing configured anywhere: the request still fails before reaching
  upstream, as today — only the error message changed (it now names both
  missing paths) and it now logs a `warning` at the failure point.

Docs: `TESTING-copilot-subscription.md` gains a "Containers & CI" section
documenting the no-`wrap` flow; CHANGELOG entry added under Unreleased.

## Testing

- [x] Unit tests pass (`pytest`)
- [x] Linting passes (`ruff check .`)
- [x] Type checking passes (`mypy headroom`)
- [x] New tests added for new functionality
- [ ] Manual testing performed

New tests in `tests/test_copilot_auth.py` (existing suite untouched):

1. inbound bearer forwarded unchanged when no local token resolves
2. `GITHUB_COPILOT_API_TOKEN` env var wins over an inbound bearer header
3. no token anywhere → error message names both `GITHUB_COPILOT_TOKEN` and the
   `Authorization` header
4. non-`Bearer` `Authorization` (e.g. `Basic`) does not satisfy the fallback
5. `GITHUB_COPILOT_API_URL` (GHE / data-residency host) composes with the
   inbound-token path, including `/v1` path normalization
6. the inbound token value never appears in log output (caplog at DEBUG)

## Test Output

```
$ pytest -q tests/test_copilot_auth.py tests/test_copilot_subscription_smoke.py \
    tests/test_proxy_copilot_auth_hooks.py tests/test_provider_copilot_wrap.py \
    tests/test_copilot_quota.py tests/test_cli/test_wrap_copilot.py
102 passed

$ ruff check headroom/copilot_auth.py tests/test_copilot_auth.py
All checks passed!

$ mypy headroom/copilot_auth.py
Success: no issues found in 1 source file
```

## Checklist

- [x] My code follows the project's style guidelines
- [x] I have performed a self-review of my code
- [x] I have commented my code, particularly in hard-to-understand areas
- [x] I have made corresponding changes to the documentation
- [x] My changes generate no new warnings
- [x] I have added tests that prove my fix is effective or that my feature works
- [x] New and existing unit tests pass locally with my changes
- [x] I have updated the CHANGELOG.md if applicable

## Additional Notes

The Anthropic handler needs no change here: it never strips the inbound
`Authorization` header (it forwards it upstream and only *additionally*
notifies the subscription tracker for OAuth-shaped tokens), so after #203 it
already exhibits the behavior this PR gives Copilot. The Copilot-specific
logic lives solely in `copilot_auth.py`, which all Copilot call sites share,
so there is no duplicated implementation to keep in sync.
