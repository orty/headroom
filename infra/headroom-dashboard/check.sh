#!/usr/bin/env bash
# Unauthenticated checks for headroom-dashboard (see README.md "Checks").
# Usage: ./check.sh [host]   (default: the custom host)
set -u
env_file="$(dirname "$0")/.env.local"
[ -f "$env_file" ] || { echo ".env.local missing: copy .env.example to .env.local and fill it in" >&2; exit 1; }
. <(tr -d '\r' < "$env_file")
for v in SUB RG TENANT HOST PROXY_HOST; do
  [ -n "${!v:-}" ] || { echo "$v is empty in .env.local" >&2; exit 1; }
done
HOST=${1:-$HOST}
fail=0

# expect <method> <url> <allowed statuses, space-separated> [substring of the redirect target]
expect() {
  local out code loc
  # Easy Auth redirects browsers to sign-in and answers 401 to everything else,
  # deciding by User-Agent, so present as a browser.
  out=$(curl -s -o /dev/null -X "$1" -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130' \
    -w '%{http_code} %{redirect_url}' --max-time 60 "$2")
  code=${out%% *}; loc=${out#* }
  if [[ " $3 " == *" $code "* && ( -z "${4:-}" || "$loc" == *"$4"* ) ]]; then
    echo "PASS $1 $2 -> $code"
  else
    echo "FAIL $1 $2 -> $code $loc (want $3${4:+ to *$4*})"; fail=1
  fi
}

# Every path on the dashboard host is behind Entra sign-in.
expect GET  "https://$HOST/"                     "302" "login.microsoftonline.com/$TENANT/"
for p in /dashboard /stats /health /v1/models /settings/schema; do
  expect GET "https://$HOST$p" "302 401"
done
expect POST "https://$HOST/v1/messages"          "302 401"
# Plain HTTP is redirected to HTTPS, never served.
expect GET  "http://$HOST/"                      "301 307 308" "https://"
# The headroom app is unchanged.
expect GET  "https://$PROXY_HOST/health"    "200"
expect GET  "https://$PROXY_HOST/dashboard" "401"

# Easy Auth config, read-only (needs az login). PENDING means deploy.sh has not
# been re-run since it dropped the client secret; any other difference is a regression.
want="true|RedirectToLoginPage|azureactivedirectory|true|https://login.microsoftonline.com/$TENANT/v2.0|true|null"
have=$(az containerapp auth show -n headroom-dashboard -g "$RG" --subscription "$SUB" \
  --query "join('|', [to_string(platform.enabled), to_string(globalValidation.unauthenticatedClientAction), to_string(globalValidation.redirectToProvider), to_string(httpSettings.requireHttps), to_string(identityProviders.azureActiveDirectory.registration.openIdIssuer), to_string(contains(identityProviders.azureActiveDirectory.validation.allowedAudiences, identityProviders.azureActiveDirectory.registration.clientId)), to_string(identityProviders.azureActiveDirectory.registration.clientSecretSettingName)])" \
  -o tsv 2>/dev/null | tr -d '\r')
case "$have" in
  "$want") echo "PASS Easy Auth config (no client secret)" ;;
  "${want%|null}|microsoft-provider-authentication-secret") echo "PENDING Easy Auth still uses a client secret: deploy.sh not re-run yet" ;;
  *) echo "FAIL Easy Auth config: ${have:-unreadable}"; fail=1 ;;
esac

exit $fail
