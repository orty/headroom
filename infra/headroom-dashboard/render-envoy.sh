#!/usr/bin/env bash
# Renders envoy.yaml.tpl to stdout. Values come from the environment (deploy.sh
# sources .env.local first); the defaults are the production ones. No secret is
# rendered: the proxy token is read by Envoy from its env at request time.
set -euo pipefail
cd "$(dirname "$0")"
: "${TENANT:?TENANT is empty}"
: "${APP_ID:?APP_ID is empty (client id of the shared app registration)}"
APP_ID_URI=${APP_ID_URI:-api://$APP_ID}
SCOPE=${GATEWAY_SCOPE:-access_as_user}
APP_ROLE=${GATEWAY_APP_ROLE:-Headroom.Proxy}
UPSTREAM_HOST=${UPSTREAM_HOST:-headroom}
UPSTREAM_PORT=${UPSTREAM_PORT:-80}
JWKS_HOST=${JWKS_HOST:-login.microsoftonline.com}
JWKS_PORT=${JWKS_PORT:-443}
CA_FILE=${CA_FILE:-/etc/ssl/certs/ca-certificates.crt}

for v in TENANT APP_ID APP_ID_URI SCOPE APP_ROLE UPSTREAM_HOST UPSTREAM_PORT JWKS_HOST JWKS_PORT CA_FILE; do
  # Only plain id/host/uri characters: nothing here may change the YAML structure.
  [[ ${!v} =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "$v has unexpected characters" >&2; exit 1; }
done

tr -d '\r' < envoy.yaml.tpl | sed \
  -e "s|__TENANT__|$TENANT|g" -e "s|__CLIENT_ID__|$APP_ID|g" -e "s|__APP_ID_URI__|$APP_ID_URI|g" \
  -e "s|__SCOPE__|$SCOPE|g" -e "s|__APP_ROLE__|$APP_ROLE|g" \
  -e "s|__UPSTREAM_HOST__|$UPSTREAM_HOST|g" -e "s|__UPSTREAM_PORT__|$UPSTREAM_PORT|g" \
  -e "s|__JWKS_HOST__|$JWKS_HOST|g" -e "s|__JWKS_PORT__|$JWKS_PORT|g" -e "s|__CA_FILE__|$CA_FILE|g"
