# headroom-prod: Headroom's own resource group (step 1: Key Vault + identities)

Decided by Serge on 2026-11-16: subscription Powell Software DevTest (`a2672c72-…`, the only one where he can
create resources besides his personal MSDN, and where W.A.L.T.E.R. lives), resource group `headroom-prod-rg`
in francecentral, tags `{application: headroom, environment: prod, managed-by: bicep}`.

| Resource | Purpose |
|---|---|
| `headroom-prod-kv` | Single home of the shared Headroom proxy token (secret `headroom-proxy-token`). RBAC mode, purge protection, soft delete 90 days. |
| `headroom-proxy-identity` | User-assigned identity for the `headroom` container app (reads the token it enforces). |
| `headroom-gateway-identity` | User-assigned identity for the `headroom-dashboard` container app (the Entra gateway, injects the token). |

The container apps and their environment stay in RG-SAR for now. Moving them is a separate plan: an Azure Container
Apps environment can't be moved, it is recreated.

## Deploy

`./deploy.sh` (creates the RG if missing, then deploys `main.bicep`). Re-runnable.

## Access (not in Bicep)

Serge is Contributor on the subscription, so he can create the vault but not grant data-plane roles on it. One
ask to Fabien Camier: "Role Based Access Control Administrator" for Serge on `headroom-prod-rg` (as on
`walter-job-rg`). Then, with az:

- Serge: `Key Vault Secrets Officer` on the vault (to set and rotate the secret).
- `headroom-proxy-identity`, `headroom-gateway-identity`: `Key Vault Secrets User` on the secret
  `headroom-proxy-token` only.
- W.A.L.T.E.R.'s reader identity (`walter-container-apps-identity`, and the job identity after GA 4c):
  `Key Vault Secrets User` on that secret only.

Then the container apps switch their `headroom-proxy-token` secret to a Key Vault reference (identity attached),
W.A.L.T.E.R.'s App Configuration key points to the same secret, and the hand copies (keyvault-SAR,
`sync-headroom-token.ps1`, `walter-prod-kv`) are retired. A rotation is then one secret update plus restarts.
