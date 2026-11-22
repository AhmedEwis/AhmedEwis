// Fils backend infrastructure (one resource group per environment).
// Deploy in two passes (see deploy.sh):
//   1) deployApps=false  -> network, identity, Key Vault, ACR, Postgres, storage, monitoring
//   2) set Key Vault secrets + push images, then deployApps=true -> Container Apps env, API, worker, migrate job
targetScope = 'resourceGroup'

@allowed(['staging', 'production'])
param env string
param location string = resourceGroup().location
@description('Short lowercase prefix, e.g. "fils".')
@minLength(3)
@maxLength(10)
param prefix string = 'fils'

@description('Deploy Container Apps (second pass, after secrets and images exist).')
param deployApps bool = false
@description('Image tag in ACR, e.g. "fils-api:1a2b3c4".')
param apiImage string = 'fils-api:latest'

// Postgres
param pgSkuName string = env == 'production' ? 'Standard_B2s' : 'Standard_B1ms'
param pgTier string = 'Burstable'
param pgStorageGb int = env == 'production' ? 64 : 32
param pgVersion string = '16'
param pgHaEnabled bool = false
param pgGeoRedundantBackup bool = env == 'production'
param pgBackupRetentionDays int = env == 'production' ? 35 : 7
param pgAdminLogin string = 'filsadmin'
@secure()
@description('Postgres admin password. Only used at server creation; store it in Key Vault as well.')
param pgAdminPassword string

// Apps
param apiMinReplicas int = env == 'production' ? 2 : 1
param apiMaxReplicas int = env == 'production' ? 6 : 2
@description('Non-secret app settings (FILS_* env vars).')
param appSettings object = {}

var suffix = uniqueString(resourceGroup().id)
var name = '${prefix}-${env}'
var tags = {
  app: 'fils'
  env: env
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: { name: name, location: location, tags: tags }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: { name: name, location: location, tags: tags, retentionDays: env == 'production' ? 90 : 30 }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: { name: name, location: location, tags: tags }
}

module kv 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: take('kv-${prefix}-${env}-${suffix}', 24)
    location: location
    tags: tags
    principalId: identity.outputs.principalId
    purgeProtection: env == 'production'
  }
}

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: take('acr${prefix}${env}${suffix}', 50)
    location: location
    tags: tags
    principalId: identity.outputs.principalId
    sku: env == 'production' ? 'Standard' : 'Basic'
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    name: take('st${prefix}${env}${suffix}', 24)
    location: location
    tags: tags
    principalId: identity.outputs.principalId
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    name: '${name}-pg-${suffix}'
    location: location
    tags: tags
    skuName: pgSkuName
    tier: pgTier
    storageGb: pgStorageGb
    version: pgVersion
    haEnabled: pgHaEnabled
    geoRedundantBackup: pgGeoRedundantBackup
    backupRetentionDays: pgBackupRetentionDays
    adminLogin: pgAdminLogin
    adminPassword: pgAdminPassword
    delegatedSubnetId: network.outputs.pgSubnetId
    privateDnsZoneId: network.outputs.pgDnsZoneId
  }
}

module apps 'modules/containerapps.bicep' = if (deployApps) {
  name: 'containerapps'
  params: {
    name: name
    location: location
    tags: tags
    env: env
    infrastructureSubnetId: network.outputs.acaSubnetId
    logAnalyticsCustomerId: monitoring.outputs.customerId
    logAnalyticsWorkspaceName: monitoring.outputs.workspaceName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    identityId: identity.outputs.id
    acrLoginServer: acr.outputs.loginServer
    keyVaultUri: kv.outputs.uri
    image: '${acr.outputs.loginServer}/${apiImage}'
    apiMinReplicas: apiMinReplicas
    apiMaxReplicas: apiMaxReplicas
    appSettings: appSettings
  }
}

output keyVaultName string = kv.outputs.name
output acrLoginServer string = acr.outputs.loginServer
output postgresFqdn string = postgres.outputs.fqdn
output apiFqdn string = deployApps ? apps.outputs.apiFqdn : ''
output identityClientId string = identity.outputs.clientId
