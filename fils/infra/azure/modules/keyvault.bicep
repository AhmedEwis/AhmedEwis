// RBAC-mode Key Vault. The app identity gets only "Key Vault Secrets User" (read secret values).
// Secrets are written by an operator (deploy.sh), never by this template, so their values
// never appear in deployment history.
param name string
param location string
param tags object
param principalId string
param purgeProtection bool = true

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: purgeProtection ? true : null
    publicNetworkAccess: 'Enabled' // Container Apps fetch secrets over the Azure backbone; tighten with private endpoint if required
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

var secretsUserRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, principalId, secretsUserRole)
  properties: { roleDefinitionId: secretsUserRole, principalId: principalId, principalType: 'ServicePrincipal' }
}

output name string = kv.name
output uri string = kv.properties.vaultUri
