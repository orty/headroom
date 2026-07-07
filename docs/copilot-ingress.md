# Server-side GitHub Copilot ingress

Route GitHub Copilot traffic through a Headroom proxy so Copilot requests reach
GitHub's Copilot API (with context compression) instead of the default OpenAI
host. Covers both Copilot environments:

- **Copilot Chat (VS Code)** — point the extension at the proxy via
  `github.copilot.advanced.debug.overrideCapiUrl`.
- **Copilot CLI (subscription seat)** — routed through the proxy (e.g. via
  `headroom wrap copilot --subscription`); the CLI sends no editor headers but
  carries a GitHub Copilot session token.

This is distinct from `headroom wrap copilot`'s local token-exchange flow: here
the client already presents a valid Copilot bearer, so the proxy forwards it
(and the Copilot headers) verbatim — **no token exchange**.

## Detection

A request is treated as Copilot (see `headroom/providers/copilot/ingress.py`)
when any of:

1. `copilot-integration-id` header present (Copilot Chat — definitive), or
2. `editor-version` **and** `x-github-api-version` headers present, or
3. the `Authorization` bearer is a Copilot **session token** — a plaintext
   `key=value;…` string starting `tid=` and containing `;sku=` (the header-less
   Copilot CLI subscription path).

The token is HMAC-signed but not encrypted; the proxy reads only non-secret
routing/classification fields and never uses them for a security decision. The
token id, signature and privacy-sensitive fields (`ip`, `asn`) are never logged.

## Routing

Copilot requests forward to the Copilot API base:

- default `https://api.githubcopilot.com` (the generic public host that serves
  the full model set);
- override with `GITHUB_COPILOT_API_URL` (or `COPILOT_TARGET_API_URL`) for
  GitHub Enterprise Cloud data-residency / egress-proxy tenants.

CAPI uses non-`/v1` paths; `build_copilot_upstream_url` strips the `/v1` prefix
for Copilot hosts. Path handling by surface:

| Surface | Route | Compression |
| --- | --- | --- |
| `/chat/completions`, `/responses` (and `/v1/...`) | OpenAI chat/responses handlers | yes |
| `/v1/messages` (Claude models — Copilot Chat sends the Anthropic Messages shape) | Anthropic handler → Copilot upstream | yes |
| `/models`, `/models/session`, `/agents/*`, other | catch-all passthrough | no (control plane) |

Copilot Chat selects the wire per model: OpenAI models use `/chat/completions`
(no `/v1`), Claude models use `/v1/messages` (**with** `/v1` — GitHub's Copilot
API serves it verbatim, so the usual `/v1` stripping is skipped for this path).
Without this, selecting a Claude model routed to `api.anthropic.com` and 401'd
the Copilot token.

Non-Copilot callers are unaffected: the new no-`/v1` routes fall back to the
existing catch-all passthrough, and the OpenAI handlers only divert to the
Copilot upstream when no explicit `x-headroom-base-url` is set **and** the
request is detected as Copilot.

## Ingress mode (dedicated Copilot proxy)

Per-request detection is enough for a shared proxy, but Copilot Chat's
connectivity ping (`GET /_ping`) and some `/agents/*` control calls carry **no**
Copilot markers — so on their own they fall through to OpenAI and 404 the ping,
which makes Chat report "network could not be re-established".

For a proxy **dedicated** to Copilot (the `overrideCapiUrl` target), set
`HEADROOM_COPILOT_INGRESS=1`. Marker-less/unclassified traffic then defaults to
the Copilot upstream instead of OpenAI. Anthropic (Claude Code) and Gemini
traffic are still classified before this fallback, so they route correctly even
with ingress mode on. Leave it unset on shared multi-provider proxies.

## Seat classification

`copilot_seat_class()` maps the token's `sku` to `enterprise` / `business` /
`individual` (e.g. `copilot_for_business_seat_quota` → `business`). Available for
telemetry/dashboard use.

## Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `GITHUB_COPILOT_API_URL` | Copilot upstream base (GHE/data-residency) | `https://api.githubcopilot.com` |
| `COPILOT_TARGET_API_URL` | Legacy alias for the above | — |
| `HEADROOM_COPILOT_INGRESS` | Treat unclassified traffic as Copilot (dedicated ingress) | off |
