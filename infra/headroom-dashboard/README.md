# headroom-dashboard: the Headroom dashboard behind Entra ID

Status: deployed 2026-10-09 at `https://$HOST/` (managed certificate bound).

Environment values (`$SUB`, `$RG`, `$TENANT`, `$HOST`, ...) live in `.env.local`, which is
git-ignored. `.env.example` lists them. Deployment-specific notes, including the implementation
plan, stay in local `*.local.md` files (git-ignored): see the local ops notes.

## Why

Since `HEADROOM_PROXY_TOKEN` was enforced on the `headroom` container app (2026-10-08), the
proxy returns 401 to every non-loopback request that lacks `x-headroom-proxy-token`. A browser
cannot attach that header, so `/dashboard`, its static assets and its `/stats*` fetches are all
rejected.

This puts the dashboard on its own host, behind Microsoft Entra ID sign-in. The `headroom` app,
its data plane (`/v1/*`, WebSocket, MCP) and every client stay exactly as they are.

## Decisions

| Question | Decision |
|---|---|
| Who may open the dashboard | Accounts in the tenant `$TENANT`. Access policy details: see the local ops notes. |
| Where auth happens | ACA built-in auth (Easy Auth) on a separate container app. No code change in Headroom. |
| URL | `https://$HOST/`, with the dashboard served at the root. |
| What the dashboard host exposes | GET-only, read-only dashboard routes. Everything else returns 404. |

Rejected: Easy Auth on the `headroom` app itself. That would put the auth sidecar in front of all
LLM traffic, where it may reject non-Entra `Authorization: Bearer` values (Claude Code OAuth
tokens, the proxy token sent as a bearer), and `excludedPaths` cannot cover the catch-all
passthrough relay. Also rejected: OIDC inside Headroom (new dependency, upstream would not take it).

## Architecture

```
Browser ──► headroom-dashboard  (container app in environment $ENV, resource group $RG)
              ├─ Easy Auth sidecar   no session → 302 to Entra sign-in
              └─ Caddy  (docker.io/library/caddy:2-alpine, port 8080)
                   GET /                  → rewritten to /dashboard (no redirect)
                   GET /dashboard, /dashboard/, /dashboard/static/*,
                       /stats, /stats-history, /stats-lifetime, /health
                                          → http://headroom  (internal ingress)
                                            + x-headroom-proxy-token from env
                                            - Cookie, Authorization stripped
                   anything else          → 404
```

Headroom sees a non-loopback peer that carries a valid token, so the request passes the security
gate and `_authenticated_at_gate`. That is all `/stats*` requires.

Behaviour that stays as it is today:

- `/settings*` stays unreachable remotely. It is loopback or trusted-dashboard-client only, and
  Caddy does not route it.
- `/transformations/feed` (prompt bodies) stays loopback-only. Caddy does not route it either.
- `https://$PROXY_HOST/dashboard` keeps returning 401.

### Caddy routing rules

- **GET only, HEAD excluded.** FastAPI's `@app.get` does not register HEAD, so a HEAD on a
  dashboard path would fall through to Headroom's catch-all passthrough relay upstream.
- **`Cookie` and `Authorization` are stripped.** The Easy Auth session cookie never reaches
  Headroom.
- **Upstream `Host` is set to `headroom`.** ACA routes internal calls by the Host header. Without
  this, Caddy would forward `$HOST` and the request would loop back into the dashboard app.
- **Token read at request time.** It comes from `{env.HEADROOM_PROXY_TOKEN}`, so it is never
  written into the loaded config. The admin API is off.
- **Plain HTTP upstream.** Caddy calls `http://headroom` over the environment's internal network.
  Whether that hop needs changing depends on the `headroom` app's ingress settings: see the local
  ops notes.

## Entra ID

App registration `headroom-dashboard` (client ID `$APP_ID`):

- Single tenant (`AzureADMyOrg`), with a service principal created for it.
- ID token issuance enabled.
- Owner: the operator who runs `deploy.sh`.
- Redirect URIs:
  - `https://$HOST/.auth/login/aad/callback`
  - `https://headroom-dashboard.$ENV_DOMAIN/.auth/login/aad/callback`. This one allows testing
    before DNS exists. It is safe to keep because it is gated the same way.
- No client secret. Easy Auth then signs in with the ID token alone (OAuth 2.0 implicit grant,
  `response_mode=form_post`), which needs ID token issuance on the registration (enabled). The
  dashboard needs only the user's identity, never an access token. Nothing expires.
- Easy Auth answers 401 instead of redirecting when the User-Agent is not a browser's (curl, scripts).
- No "assignment required". `deploy.sh` declares Graph `openid profile email offline_access` on the
  registration. If the tenant does not allow user consent, an administrator grants them once.

Easy Auth (`az containerapp auth`):

| Setting | Value |
|---|---|
| Platform | enabled |
| Unauthenticated action | `RedirectToLoginPage`, provider `azureactivedirectory` |
| Require HTTPS | true |
| Issuer | `https://login.microsoftonline.com/$TENANT/v2.0` |
| Allowed audience | the app's client ID |
| Client secret | none (`clientSecretSettingName` unset) |
| Token store | off |
| Session | 8 h (default) |
| Forward proxy convention | default (`NoProxy`). Switch to `Standard` only if the sign-in redirect shows the `azurecontainerapps.io` host instead of the custom one. |

## Container app

| Setting | Value |
|---|---|
| Name / RG / environment | `headroom-dashboard` / `$RG` / `$ENV` |
| Image | `docker.io/library/caddy:2-alpine` |
| Command | `caddy run --config /etc/caddy/Caddyfile --adapter caddyfile` |
| Ingress | external, target port 8080, `allowInsecure: false` |
| Scale | 0 to 1 replicas, 0.25 vCPU / 0.5 Gi. The first open after idle takes about 5 to 10 s. |
| Secrets | `headroom-proxy-token`: a copy of the value on the `headroom` app. `caddyfile`: the Caddyfile. `deploy.sh` writes both through az's `@file` expansion, never on a command line, and removes the old `microsoft-provider-authentication-secret`. |
| Env | `HEADROOM_PROXY_TOKEN=secretref:headroom-proxy-token` |
| Volume | Secret volume mounting only `caddyfile`, at `/etc/caddy/Caddyfile` |

## DNS (zone of `$HOST`, managed outside Azure)

| Type | Name | Value |
|---|---|---|
| CNAME | `headroom-dashboard` | `headroom-dashboard.$ENV_DOMAIN` |
| TXT | `asuid.headroom-dashboard` | the environment's verification ID: `az containerapp env show -n $ENV -g $RG --query properties.customDomainConfiguration.customDomainVerificationId` |

After both records resolve: `az containerapp hostname add`, then `hostname bind` with a free
managed certificate (`--validation-method CNAME`).

## Deployment order

1. Create the app registration and service principal.
2. Create the container app: Caddy, secrets, secret volume, ingress.
3. Configure Easy Auth.
4. Run the checks below against `headroom-dashboard.$ENV_DOMAIN`.
5. Once the DNS records exist, add the hostname and bind the managed certificate.
6. Run the checks below against `https://$HOST/`.

`deploy.sh` runs every step except the checks, and is safe to re-run. It needs `.env.local`.
The container app first boots with the token set to `pending`. The script copies the real token
only after Easy Auth is enabled, so the dashboard is never reachable without sign-in.

## Checks

- `check.sh` (no sign-in): every path on the dashboard host redirects a browser to the tenant's
  sign-in, plain HTTP redirects to HTTPS, and `$PROXY_HOST` behaves as before. It also reads the
  live Easy Auth config: `PENDING` means it still differs from what `deploy.sh` sets only by a
  client secret, so re-run `deploy.sh`; any other difference fails.
- `check.js` (signed in, pasted into the browser console): the dashboard routes return 200;
  HEAD, `/v1/*`, `/settings*` and `/transformations/feed` return 404 from Caddy; POSTs return 403
  from the auth layer before reaching Caddy.
- `test-deploy.sh` (static, no Azure): `deploy.sh` keeps secret values off the command line, and no
  value from `.env.local` appears in a tracked file.

## Operations

- **Proxy token.** The `headroom-dashboard` app holds its own copy. Whenever the `headroom` app's
  `headroom-proxy-token` secret changes, re-run `deploy.sh`. Until then, Headroom rejects the stale
  token and the dashboard host shows `{"error":"unauthorized"}`.
- **Session expiry.** If the 8 h session lapses while the page is open, its `/stats` polls are
  redirected to sign-in and blocked by the browser, so the numbers freeze and the health badge turns
  unhealthy. Reloading the page signs in again silently while the Microsoft session is valid.
- **Rollback.** Delete the `headroom-dashboard` container app and the `headroom-dashboard` app
  registration, then ask for the two DNS records to be removed. The `headroom` app is never
  modified.

## Out of scope

- Narrowing who can sign in beyond the tenant (see the local ops notes).
- The `headroom` app's own ingress settings.
- Settings writes from the remote dashboard.
