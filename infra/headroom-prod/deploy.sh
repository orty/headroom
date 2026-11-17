#!/usr/bin/env bash
# Creates or updates headroom-prod-rg and its resources (main.bicep). Safe to re-run.
# Needs: az, Contributor on the subscription. No secret is set here and no role is assigned (README.md).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"

SUB=a2672c72-a1eb-4c84-aec5-0b01fc14696f   # Powell Software DevTest (decided 2026-11-16)
RG=headroom-prod-rg
LOCATION=francecentral

az account set --subscription "$SUB"
if [ "$(az group exists -n "$RG" | tr -d '\r')" != "true" ]; then
  az group create -n "$RG" -l "$LOCATION" \
    --tags application=headroom environment=prod managed-by=bicep -o none
  echo "created resource group $RG"
fi
az deployment group create -g "$RG" -n "headroom-prod-$(date +%Y%m%d-%H%M%S)" \
  --template-file main.bicep --query "properties.outputs" -o json
