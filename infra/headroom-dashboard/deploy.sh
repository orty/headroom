#!/usr/bin/env bash
# Deploys the headroom-dashboard gateway as designed in README.md. Safe to re-run.
# The shared Entra app registration is NOT changed here: see entra-gateway-api.sh.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

# Environment values live in the git-ignored .env.local (template: .env.example).
[ -f .env.local ] || { echo ".env.local missing: copy .env.example to .env.local and fill it in" >&2; exit 1; }
. <(tr -d '\r' < .env.local)
for v in SUB RG LOCATION ENV ENV_DOMAIN TENANT HOST; do
  [ -n "${!v:-}" ] || { echo "$v is empty in .env.local" >&2; exit 1; }
done
APP=${APP:-headroom-dashboard}   # APP=<name> for a throwaway test app (phase 0)
FQDN=$APP.$ENV_DOMAIN
ENVOY_IMAGE=docker.io/envoyproxy/envoy:v1.32.3
# Easy Auth leaves these to Envoy, which requires an Entra token on them.
EXCLUDED_PATHS='["/v1/*","/api/*"]'

# az prints CRLF in Git Bash; strip it from every captured value.
azv() { az "$@" | tr -d '\r'; }
# Temp files never outlive the script.
trap 'rm -f "${yaml:-}" "${tokfile:-}" "${envoyfile:-}" "${tplfile:-}"' EXIT

az account set --subscription "$SUB"

# 1. Entra app registration + service principal.
#    The registration is shared with W.A.L.T.E.R. (dashboard sign-in, connector,
#    OBO, app roles) and its display name may change, so pin APP_ID in .env.local.
#    The by-name lookup and the create branch only serve a brand-new deployment.
if [ -z "${APP_ID:-}" ]; then
  APP_ID=$(azv ad app list --display-name "${APP_DISPLAY_NAME:-$APP}" --query "[0].appId" -o tsv)
  if [ -z "$APP_ID" ]; then
    APP_ID=$(azv ad app create --display-name "${APP_DISPLAY_NAME:-$APP}" --sign-in-audience AzureADMyOrg \
      --web-redirect-uris "https://$HOST/.auth/login/aad/callback" "https://$FQDN/.auth/login/aad/callback" \
      --enable-id-token-issuance true --query appId -o tsv)
    az ad sp create --id "$APP_ID" -o none
    echo "created app registration $APP_ID"
  fi
  echo "APP_ID was empty: found/created $APP_ID. Pin it in .env.local (APP_ID=...)." >&2
fi
export TENANT APP_ID
# The gateway's token audience: the registration's App ID URI (entra-gateway-api.sh).
APP_ID_URI=${APP_ID_URI:-$(azv ad app show --id "$APP_ID" --query "identifierUris[0]" -o tsv)}
APP_ID_URI=${APP_ID_URI:-api://$APP_ID}
export APP_ID_URI
# The tenant allows no user consent, so declare Graph sign-in scopes for an
# admin's one-click "Grant admin consent": openid, profile, email, offline_access.
if [ "$(azv ad app show --id "$APP_ID" --query "length(requiredResourceAccess)" -o tsv)" = "0" ]; then
  az ad app permission add --id "$APP_ID" --api 00000003-0000-0000-c000-000000000000 --api-permissions \
    37f7f235-527c-4136-accd-4a02d197296e=Scope 14dad69e-099b-42c9-810b-d002981feec1=Scope \
    64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope 7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope -o none
  echo "declared Graph sign-in permissions; admin consent still needed"
fi

envoyfile=$(mktemp)
./render-envoy.sh > "$envoyfile"

# The container template (Envoy, its config from a secret volume), as JSON so the
# create branch (YAML accepts JSON) and the PATCH below share one definition.
# A new app boots with the token "pending", so nothing real is exposed before
# Easy Auth is on.
template_json() {
  cat <<EOF
{"containers": [{"name": "gateway", "image": "$ENVOY_IMAGE",
   "command": ["envoy", "-c", "/etc/gateway/envoy.yaml", "--log-level", "warn"],
   "resources": {"cpu": 0.5, "memory": "1Gi"},
   "env": [{"name": "HEADROOM_PROXY_TOKEN", "secretRef": "headroom-proxy-token"}],
   "volumeMounts": [{"volumeName": "gateway-config", "mountPath": "/etc/gateway"}]}],
 "scale": {"minReplicas": 1, "maxReplicas": 1},
 "volumes": [{"name": "gateway-config", "storageType": "Secret",
              "secrets": [{"secretRef": "envoy-yaml", "path": "envoy.yaml"}]}]}
EOF
}

# 2. Container app.
if ! az containerapp show -n "$APP" -g "$RG" -o none 2>/dev/null; then
  yaml=$(mktemp)
  cat > "$yaml" <<EOF
location: $LOCATION
properties:
  managedEnvironmentId: $(azv containerapp env show -n "$ENV" -g "$RG" --query id -o tsv)
  configuration:
    ingress:
      external: true
      targetPort: 8080
      allowInsecure: false
    secrets:
      - name: headroom-proxy-token
        value: pending
      - name: envoy-yaml
        value: |
$(sed 's/^/          /' "$envoyfile")
  template: $(template_json | tr -d '\n')
EOF
  az containerapp create -n "$APP" -g "$RG" --yaml "$yaml" -o none
  echo "created container app $APP"
fi

# 3. Easy Auth (Entra, single tenant, redirect to sign-in), with no client secret:
#    sign-in then uses the ID token alone (implicit grant). The API paths are
#    excluded: their callers are not browsers and carry the caller's Anthropic
#    credential in Authorization, which Easy Auth must never see as its own.
#    The PUT replaces the whole config, so drift in the compared fields is repaired.
auth_want="true|RedirectToLoginPage|azureactivedirectory|$(tr -d ' ' <<<"$EXCLUDED_PATHS")|true|$APP_ID|https://login.microsoftonline.com/$TENANT/v2.0|[\"$APP_ID\"]|null"
auth_have=$(azv containerapp auth show -n "$APP" -g "$RG" --query "join('|', [to_string(platform.enabled), \
to_string(globalValidation.unauthenticatedClientAction), to_string(globalValidation.redirectToProvider), \
to_string(globalValidation.excludedPaths), \
to_string(httpSettings.requireHttps), to_string(identityProviders.azureActiveDirectory.registration.clientId), \
to_string(identityProviders.azureActiveDirectory.registration.openIdIssuer), \
to_string(identityProviders.azureActiveDirectory.validation.allowedAudiences), \
to_string(identityProviders.azureActiveDirectory.registration.clientSecretSettingName)])" -o tsv)
if [ "$auth_have" != "$auth_want" ]; then
  body=$(cat <<EOF
{"properties": {
  "platform": {"enabled": true},
  "globalValidation": {"unauthenticatedClientAction": "RedirectToLoginPage", "redirectToProvider": "azureactivedirectory",
                       "excludedPaths": $EXCLUDED_PATHS},
  "httpSettings": {"requireHttps": true},
  "identityProviders": {"azureActiveDirectory": {
    "enabled": true,
    "registration": {"clientId": "$APP_ID", "openIdIssuer": "https://login.microsoftonline.com/$TENANT/v2.0"},
    "validation": {"allowedAudiences": ["$APP_ID"]}}}}}
EOF
)
  az rest --method put --body "$body" -o none \
    --url "https://management.azure.com$(azv containerapp show -n "$APP" -g "$RG" --query id -o tsv)/authConfigs/current?api-version=2024-03-01"
  echo "configured Easy Auth (no client secret, API paths excluded)"
fi
# Earlier versions of this script stored a client secret on the app; nothing reads it now.
if [ -n "$(azv containerapp secret list -n "$APP" -g "$RG" --query "[?name=='microsoft-provider-authentication-secret'].name" -o tsv)" ]; then
  az containerapp secret remove -n "$APP" -g "$RG" --secret-names microsoft-provider-authentication-secret -o none
  echo "removed the unused microsoft-provider-authentication-secret"
fi

# 5. Custom domains + free managed certificates, once DNS points here.
#    HOST is the dashboard hostname; GATEWAY_HOST (optional) the gateway's new one.
for h in "$HOST" ${GATEWAY_HOST:-}; do
  bound=$(azv containerapp hostname list -n "$APP" -g "$RG" --query "[?name=='$h'].bindingType" -o tsv)
  [ "$bound" = "SniEnabled" ] && continue
  if nslookup -type=CNAME "$h" 2>/dev/null | tr -d '\r' | grep -qi "$FQDN"; then
    # The managed certificate requires the hostname to be added to the app first.
    [ -n "$bound" ] || az containerapp hostname add -n "$APP" -g "$RG" --hostname "$h" -o none
    az containerapp hostname bind -n "$APP" -g "$RG" --hostname "$h" \
      --environment "$ENV" --validation-method CNAME -o none
    echo "bound $h"
  else
    echo "skipped $h: CNAME not in place yet"
  fi
done

# 4. Sync the proxy token and the Envoy config, then the container template.
#    Runs after step 3, so the real token never serves without Easy Auth.
want_token=$(azv containerapp secret show -n headroom -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)
: "${want_token:?could not read the proxy token of the headroom app}"
have_token=$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)
want_envoy=$(cat "$envoyfile")
have_envoy=$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name envoy-yaml --query value -o tsv 2>/dev/null || true)
changed=0
if [ "$want_token" != "$have_token" ] || [ "$want_envoy" != "$have_envoy" ]; then
  # Values go through az's @file expansion, never the command line.
  tokfile=$(mktemp)
  chmod 600 "$tokfile"
  printf '%s' "$want_token" > "$tokfile"
  az containerapp secret set -n "$APP" -g "$RG" \
    --secrets "headroom-proxy-token=@$tokfile" "envoy-yaml=@$envoyfile" -o none
  rm -f "$tokfile"
  # az stores the literal "@path" when it cannot read the file; refuse to go on.
  if [ "$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)" != "$want_token" ] ||
     [ "$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name envoy-yaml --query value -o tsv)" != "$want_envoy" ]; then
    echo "secret sync failed: stored values differ from the source" >&2
    exit 1
  fi
  changed=1
fi
unset want_token have_token

# The template: Envoy instead of the former Caddy container. A PATCH of
# properties.template replaces the template only; secrets and ingress stay.
have_image=$(azv containerapp show -n "$APP" -g "$RG" --query "properties.template.containers[0].image" -o tsv)
if [ "$have_image" != "$ENVOY_IMAGE" ]; then
  # Rollback: az rest --method patch --body @rollback-template.local.json --url <same url>
  [ -f rollback-template.local.json ] ||
    azv containerapp show -n "$APP" -g "$RG" --query "{properties: {template: properties.template}}" -o json \
      > rollback-template.local.json
  tplfile=$(mktemp)
  printf '{"properties": {"template": %s}}' "$(template_json)" > "$tplfile"
  az rest --method patch --body "@$tplfile" -o none \
    --url "https://management.azure.com$(azv containerapp show -n "$APP" -g "$RG" --query id -o tsv)?api-version=2024-03-01"
  echo "switched the container to $ENVOY_IMAGE (new revision)"
  changed=0
fi
if [ "$changed" = 1 ]; then
  az containerapp revision restart -n "$APP" -g "$RG" \
    --revision "$(azv containerapp show -n "$APP" -g "$RG" --query properties.latestRevisionName -o tsv)" -o none
  echo "synced token/Envoy config and restarted"
fi
# The Caddy-era `caddyfile` secret is left in place: with rollback-template.local.json
# it is the rollback. Remove it by hand once the gateway has run for a while.
