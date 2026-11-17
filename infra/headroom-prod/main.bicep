// Headroom production resources that live outside RG-SAR (step 1: secrets and identities only).
// Deployed into resource group headroom-prod-rg (DevTest subscription, francecentral) by deploy.sh.
// The container apps stay in RG-SAR for now; moving them is a separate plan (an ACA environment is
// recreated, not moved). No secret value and no role assignment here: see README.md.

@description('Azure region; W.A.L.T.E.R. and the Headroom container apps environment are in francecentral.')
param location string = resourceGroup().location

@description('Tags on every resource, same pattern as the subscription\'s other app RGs.')
param tags object = {
  application: 'headroom'
  environment: 'prod'
  'managed-by': 'bicep'
}

// The shared Headroom proxy token's single home (replaces the hand copies in keyvault-SAR, the container apps'
// secrets and walter-prod-kv). RBAC mode, so access is granted per identity and per secret.
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'headroom-prod-kv'
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Identity of the `headroom` container app (reads the proxy token it enforces).
resource proxyIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'headroom-proxy-identity'
  location: location
  tags: tags
}

// Identity of the `headroom-dashboard` container app, the Entra gateway (reads the token it injects).
resource gatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'headroom-gateway-identity'
  location: location
  tags: tags
}

output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
output keyVaultId string = kv.id
output proxyIdentityId string = proxyIdentity.id
output proxyIdentityPrincipalId string = proxyIdentity.properties.principalId
output gatewayIdentityId string = gatewayIdentity.id
output gatewayIdentityPrincipalId string = gatewayIdentity.properties.principalId
