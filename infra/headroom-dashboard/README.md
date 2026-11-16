# headroom-dashboard: Entra gateway for the Headroom dashboard and proxy

Status: dashboard deployed 2026-10-09 at `https://$HOST/` (Caddy). Gateway version (Envoy,
Entra tokens on the API) written 2026-11-16, not deployed yet.

Environment values (`$SUB`, `$RG`, `$TENANT`, `$HOST`, ...) live in `.env.local`, which is
git-ignored. `.env.example` lists them. Deployment-specific notes stay in local `*.local.md` files
(git-ignored).

## Why

`HEADROOM_PROXY_TOKEN` is enforced on the `headroom` container app since 2026-10-08. Two problems:

- A browser cannot attach `x-headroom-proxy-token`, so the dashboard needs a front that signs the
  user in and adds the token (done 2026-10-09 with Easy Auth + Caddy).
- Every client of the proxy holds the same shared token (in `~/.claude/settings.json`, in the
  Toolkit extension's package). The gateway replaces it with each caller's own Entra token, so the
  shared token only lives in Key Vault and in the services that need it.

## Decisions

| Question | Decision |
|---|---|
| Container app | Keep `headroom-dashboard` (ACA apps cannot be renamed); add a new hostname `$GATEWAY_HOST`. |
| Entra registration | The existing, shared one (`$APP_ID`). It also signs in W.A.L.T.E.R.'s dashboard and serves its connector, OBO and app roles, so changes to it are additive only (`entra-gateway-api.py`) and coordinated with W.A.L.T.E.R. |
| Engine | Official Envoy image: `jwt_authn` reads a custom header, checks signature/issuer/audience/expiry with Entra's JWKS, turns claims into headers. No custom image. |
| Browser routes | As before: Easy Auth signs in, GET-only allowlist, token added, `Cookie`/`Authorization` stripped. |
| API routes | `/v1/*`, `/api/*`: excluded from Easy Auth; Envoy requires an Entra token in `x-headroom-gateway-token`. `Authorization` keeps the caller's Anthropic credential. |
| Who may call the API | Tokens for this registration with delegated scope `access_as_user` (people) or app role `Headroom.Proxy` (services). A token that only signs in to W.A.L.T.E.R. is refused (403). |
| Cutover | Parallel run: `https://$PROXY_HOST` keeps accepting the shared token until no client uses it. W.A.L.T.E.R. moves last. |

Rejected: Easy Auth on the `headroom` app itself (it would see the Anthropic bearer, and
`excludedPaths` cannot cover the catch-all relay); Azure Front Door (cannot validate a JWT); a
custom Caddy build (needs an image pipeline outside the fork's overlay paths).

## Architecture

```
Browser ─┐
Laptop shim (MSAL, Windows broker) ─┤     headroom-dashboard  (container app, env $ENV)
Services (managed identity) ────────┘       ├─ Easy Auth sidecar: browser routes need a session;
                                            │  /v1/*, /api/* excluded
                                            └─ Envoy (port 8080)
   GET /                                   → /dashboard           ┐
   GET /dashboard[/], /dashboard/static/*,                        │ + x-headroom-proxy-token
       /stats, /stats-history, /stats-lifetime, /health           │ - Cookie, Authorization
   any /v1/*, /api/*  + Entra token in x-headroom-gateway-token   │ + x-headroom-proxy-token
       (HEAD/GET /api/hello: no token, Claude Code preconnect)    │ - x-headroom-gateway-token
                                                                  │ + x-headroom-user/-principal/-app
                                                                  ┘ → http://headroom (internal)
   anything else                           → 404
```

### Envoy rules (`envoy.yaml.tpl`, rendered by `render-envoy.sh`)

- **Spoofing.** Callers' `x-headroom-proxy-token`, `x-headroom-user`, `x-headroom-principal` and
  `x-headroom-app` are removed before authentication; the identity headers are then set from the
  token's claims (`preferred_username`/`upn`, `oid`, `azp`/`appid`). Headroom records `x-headroom-*`
  headers as request tags, which gives per-caller attribution in its request log and exports.
- **Token formats.** v2 (`login.microsoftonline.com/$TENANT/v2.0`, audience = client id) and v1
  (`sts.windows.net/$TENANT/`, audience = App ID URI) are both accepted, so the shared
  registration's token version never has to change.
- **Errors.** Missing, malformed, expired, wrong-tenant or badly signed token: 401. Wrong audience:
  403 (Envoy's choice). Valid token without the scope or role: 403.
- **Streaming.** No buffering, no route timeout, 900 s idle timeout, no retries (POST bodies are never
  replayed).
- **Token handling.** The proxy token is read from the env at request time
  (`%ENVIRONMENT(HEADROOM_PROXY_TOKEN)%`), never rendered into the config. No admin listener. The
  access log (JSON on stdout) has method, path, status, timings and the caller tags, never a token.
- **GET only on browser routes, HEAD excluded**: FastAPI registers no HEAD for its GET routes, so a
  HEAD would reach Headroom's passthrough relay.
- **Upstream `Host` is `headroom`**: ACA routes internal calls by Host.

## Entra ID (`entra-gateway-api.py`)

Dry run by default; `--apply` sends one Graph PATCH. Additive only:

- App ID URI `api://$APP_ID` only if the registration has none (otherwise the existing one is the
  audience).
- Delegated scope `access_as_user` (admin consent type).
- App role `Headroom.Proxy` (Application members) for managed identities.
- Public-client redirect URIs `ms-appx-web://microsoft.aad.brokerplugin/$APP_ID` and
  `http://localhost`, for MSAL on laptops. `isFallbackPublicClient` stays off: no device code or
  password flows.
- `https://$GATEWAY_HOST/.auth/login/aad/callback` as a web redirect URI.
- Its own scope in `requiredResourceAccess`, then one admin consent (the tenant allows no user
  consent).
- Display name, only if `NEW_DISPLAY_NAME` is set. `deploy.sh` no longer depends on the name once
  `APP_ID` is pinned in `.env.local`.

Never touched: secrets, token version, existing scopes/roles/URIs, the service principal. If
W.A.L.T.E.R. sets "Assignment required" on the service principal, every Headroom user must be
assigned too, or Entra refuses their token.

## Container app

| Setting | Value |
|---|---|
| Image | `docker.io/envoyproxy/envoy:v1.32.3` |
| Command | `envoy -c /etc/gateway/envoy.yaml --log-level warn` |
| Ingress | external, target port 8080, `allowInsecure: false` |
| Scale | 1 to 1 replica, 0.5 vCPU / 1 Gi |
| Secrets | `headroom-proxy-token` (copy of the `headroom` app's), `envoy-yaml` (rendered config). Written through az's `@file` expansion. The Caddy-era `caddyfile` secret stays for rollback; remove it by hand later. |
| Env | `HEADROOM_PROXY_TOKEN=secretref:headroom-proxy-token` |
| Volume | Secret volume with `envoy-yaml` at `/etc/gateway/envoy.yaml` |
| Easy Auth | `RedirectToLoginPage`, `excludedPaths: ["/v1/*", "/api/*"]`, no client secret, no token store |

On an existing app, `deploy.sh` switches the template from Caddy to Envoy with a PATCH of
`properties.template` (secrets and ingress are not in the body).

## DNS (zone managed outside Azure)

For each of `$HOST` and `$GATEWAY_HOST`: CNAME to `headroom-dashboard.$ENV_DOMAIN`, and TXT
`asuid.<name>` = the environment's custom domain verification id. `deploy.sh` binds a free managed
certificate once the CNAME resolves.

## Deployment order

0. Throwaway test app in `$ENV` (same script with another `APP`) to check on real ACA: Easy Auth
   `excludedPaths` wildcards leave `/v1/*` with an Anthropic `Authorization: Bearer` untouched; the
   PATCH keeps secrets; SSE through two ingress hops.
1. `python3 entra-gateway-api.py` (dry run), review with W.A.L.T.E.R., then `--apply`; admin consent.
2. `deploy.sh`.
3. `check.sh`, then a real call with a token:
   `az account get-access-token --scope api://$APP_ID/access_as_user` (needs Azure CLI
   pre-authorized or consented) or the laptop shim.
4. Clients one by one: Serge's laptop shim, Powell devs' shim (Toolkit), W.A.L.T.E.R. last (needs a
   token-refreshing local proxy in each container, plus the `Headroom.Proxy` role on its managed
   identities).
5. When no client sends the shared token any more: rotate it, drop it from the Toolkit package.

## Checks

- `test-envoy.py` (local, no Azure): renders the real template against a mock Entra JWKS and a mock
  Headroom, runs Envoy (`ENVOY=/path/to/envoy`, same version as the image) and checks every route,
  the token rules (401/403 cases, v1/v2, scope/role, spoofing), SSE streaming and the access log.
- `check.sh` (no sign-in): browser routes redirect to sign-in, API routes answer 401 without a
  token, `$PROXY_HOST` unchanged.
- `check.js` (signed in, browser console): dashboard routes return 200.
- `test-deploy.sh` (static): no secret on a command line, no `.env.local` value in tracked files.

## Operations

- **Proxy token.** Re-run `deploy.sh` whenever the `headroom` app's `headroom-proxy-token` changes.
- **Entra keys.** Envoy caches Entra's JWKS for an hour and refetches on an unknown `kid`.
- **Rollback.** Before switching an existing app to Envoy, `deploy.sh` saves its Caddy template to
  `rollback-template.local.json` (git-ignored) and leaves the `caddyfile` secret in place. To roll
  back: `az rest --method patch --body @rollback-template.local.json --url <app id>?api-version=2024-03-01`,
  then put Easy Auth's `excludedPaths` back to none. The Entra additions are harmless left in place.
