#!/usr/bin/env bash
# Deploys headroom-dashboard as designed in README.md. Safe to re-run.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

# Environment values live in the git-ignored .env.local (template: .env.example).
[ -f .env.local ] || { echo ".env.local missing: copy .env.example to .env.local and fill it in" >&2; exit 1; }
. <(tr -d '\r' < .env.local)
for v in SUB RG LOCATION ENV ENV_DOMAIN TENANT HOST; do
  [ -n "${!v:-}" ] || { echo "$v is empty in .env.local" >&2; exit 1; }
done
APP=headroom-dashboard
FQDN=$APP.$ENV_DOMAIN

# az prints CRLF in Git Bash; strip it from every captured value.
azv() { az "$@" | tr -d '\r'; }
# Temp files (the step 2 YAML, the step 4 token file) never outlive the script.
trap 'rm -f "${yaml:-}" "${tokfile:-}"' EXIT

az account set --subscription "$SUB"

# 1. Entra app registration + service principal
APP_ID=${APP_ID:-$(azv ad app list --display-name "$APP" --query "[0].appId" -o tsv)}
if [ -z "$APP_ID" ]; then
  APP_ID=$(azv ad app create --display-name "$APP" --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "https://$HOST/.auth/login/aad/callback" "https://$FQDN/.auth/login/aad/callback" \
    --enable-id-token-issuance true --query appId -o tsv)
  az ad sp create --id "$APP_ID" -o none
  echo "created app registration $APP_ID"
fi
# The tenant allows no user consent for these, so declare them for an admin's
# one-click "Grant admin consent": Graph openid, profile, email, offline_access.
if [ "$(azv ad app show --id "$APP_ID" --query "length(requiredResourceAccess)" -o tsv)" = "0" ]; then
  az ad app permission add --id "$APP_ID" --api 00000003-0000-0000-c000-000000000000 --api-permissions \
    37f7f235-527c-4136-accd-4a02d197296e=Scope 14dad69e-099b-42c9-810b-d002981feec1=Scope \
    64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope 7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope -o none
  echo "declared Graph sign-in permissions; admin consent still needed"
fi

# 2. Container app. Boots with token "pending" so nothing real is exposed
#    before Easy Auth is on; step 4 loads the real token.
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
      - name: caddyfile
        value: |
$(tr -d '\r' < Caddyfile | sed 's/^/          /')
  template:
    containers:
      - name: caddy
        image: docker.io/library/caddy:2-alpine
        command: [caddy, run, --config, /etc/caddy/Caddyfile, --adapter, caddyfile]
        resources:
          cpu: 0.25
          memory: 0.5Gi
        env:
          - name: HEADROOM_PROXY_TOKEN
            secretRef: headroom-proxy-token
        volumeMounts:
          - volumeName: caddy-config
            mountPath: /etc/caddy
    scale:
      minReplicas: 0
      maxReplicas: 1
    volumes:
      - name: caddy-config
        storageType: Secret
        secrets:
          - secretRef: caddyfile
            path: Caddyfile
EOF
  az containerapp create -n "$APP" -g "$RG" --yaml "$yaml" -o none
  echo "created container app $APP"
fi

# 3. Easy Auth (Entra, single tenant, redirect to sign-in), with no client secret:
#    sign-in then uses the ID token alone (implicit grant), so there is no secret
#    to store, pass on a command line, or let expire. The PUT replaces the whole
#    config, so any drift in the compared fields is repaired on re-run.
auth_want="true|RedirectToLoginPage|azureactivedirectory|true|$APP_ID|https://login.microsoftonline.com/$TENANT/v2.0|[\"$APP_ID\"]|null"
auth_have=$(azv containerapp auth show -n "$APP" -g "$RG" --query "join('|', [to_string(platform.enabled), \
to_string(globalValidation.unauthenticatedClientAction), to_string(globalValidation.redirectToProvider), \
to_string(httpSettings.requireHttps), to_string(identityProviders.azureActiveDirectory.registration.clientId), \
to_string(identityProviders.azureActiveDirectory.registration.openIdIssuer), \
to_string(identityProviders.azureActiveDirectory.validation.allowedAudiences), \
to_string(identityProviders.azureActiveDirectory.registration.clientSecretSettingName)])" -o tsv)
if [ "$auth_have" != "$auth_want" ]; then
  body=$(cat <<EOF
{"properties": {
  "platform": {"enabled": true},
  "globalValidation": {"unauthenticatedClientAction": "RedirectToLoginPage", "redirectToProvider": "azureactivedirectory"},
  "httpSettings": {"requireHttps": true},
  "identityProviders": {"azureActiveDirectory": {
    "enabled": true,
    "registration": {"clientId": "$APP_ID", "openIdIssuer": "https://login.microsoftonline.com/$TENANT/v2.0"},
    "validation": {"allowedAudiences": ["$APP_ID"]}}}}}
EOF
)
  az rest --method put --body "$body" -o none \
    --url "https://management.azure.com$(azv containerapp show -n "$APP" -g "$RG" --query id -o tsv)/authConfigs/current?api-version=2024-03-01"
  echo "configured Easy Auth (no client secret)"
fi
# Earlier versions of this script stored a client secret on the app; nothing reads it now.
if [ -n "$(azv containerapp secret list -n "$APP" -g "$RG" --query "[?name=='microsoft-provider-authentication-secret'].name" -o tsv)" ]; then
  az containerapp secret remove -n "$APP" -g "$RG" --secret-names microsoft-provider-authentication-secret -o none
  echo "removed the unused microsoft-provider-authentication-secret"
fi

# 5. Custom domain + free managed certificate, once DNS points here.
bound=$(azv containerapp hostname list -n "$APP" -g "$RG" --query "[?name=='$HOST'].bindingType" -o tsv)
if [ "$bound" != "SniEnabled" ]; then
  if nslookup -type=CNAME "$HOST" 2>/dev/null | tr -d '\r' | grep -qi "$FQDN"; then
    # The managed certificate requires the hostname to be added to the app first.
    [ -n "$bound" ] || az containerapp hostname add -n "$APP" -g "$RG" --hostname "$HOST" -o none
    az containerapp hostname bind -n "$APP" -g "$RG" --hostname "$HOST" \
      --environment "$ENV" --validation-method CNAME -o none
    echo "bound $HOST"
  else
    echo "skipped $HOST: CNAME not in place yet"
  fi
fi

# 4. Sync the proxy token and Caddyfile; restart only when either changed.
#    Runs after step 3, so the real token never serves without Easy Auth.
want_token=$(azv containerapp secret show -n headroom -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)
: "${want_token:?could not read the proxy token of the headroom app}"
have_token=$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)
want_caddy=$(tr -d '\r' < Caddyfile)
have_caddy=$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name caddyfile --query value -o tsv)
if [ "$want_token" != "$have_token" ] || [ "$want_caddy" != "$have_caddy" ]; then
  # Values go through az's @file expansion, never the command line.
  tokfile=$(mktemp)
  chmod 600 "$tokfile"
  printf '%s' "$want_token" > "$tokfile"
  az containerapp secret set -n "$APP" -g "$RG" \
    --secrets "headroom-proxy-token=@$tokfile" "caddyfile=@Caddyfile" -o none
  rm -f "$tokfile"
  # az stores the literal "@path" when it cannot read the file; refuse to restart on that.
  if [ "$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name headroom-proxy-token --query value -o tsv)" != "$want_token" ] ||
     [ "$(azv containerapp secret show -n "$APP" -g "$RG" --secret-name caddyfile --query value -o tsv)" != "$want_caddy" ]; then
    echo "secret sync failed: stored values differ from the source" >&2
    exit 1
  fi
  az containerapp revision restart -n "$APP" -g "$RG" \
    --revision "$(azv containerapp show -n "$APP" -g "$RG" --query properties.latestRevisionName -o tsv)" -o none
  echo "synced token/Caddyfile and restarted"
fi
unset want_token have_token
