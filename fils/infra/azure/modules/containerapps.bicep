// Container Apps environment (VNet-integrated) with:
//  - api:     external HTTPS ingress, liveness /healthz, readiness /readyz, HTTP scale rule
//  - worker:  no ingress, min 1 replica (Postgres SKIP LOCKED queue makes >1 safe)
//  - migrate: manual job running `alembic upgrade head` before traffic is shifted
// Secrets are Key Vault references resolved with the user-assigned identity.
param name string
param location string
param tags object
param env string
param infrastructureSubnetId string
param logAnalyticsCustomerId string
param logAnalyticsWorkspaceName string
@secure()
param appInsightsConnectionString string
param identityId string
param acrLoginServer string
param keyVaultUri string
param image string
param apiMinReplicas int
param apiMaxReplicas int
@description('Non-secret FILS_* settings, e.g. {"FILS_APPLE_CLIENT_IDS": "[\\"kw.fils.fils\\"]"}')
param appSettings object = {}
@description('Optional Key Vault secrets: { ENV_VAR_NAME: "kv-secret-name" }. Only list secrets that exist.')
// Lint suppression is unnecessary: this maps ENV_VAR → Key Vault secret NAME (no secret values).
param keyVaultEnvMap object = {}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${name}-cae'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: { infrastructureSubnetId: infrastructureSubnetId, internal: false }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: { customerId: logAnalyticsCustomerId, sharedKey: law.listKeys().primarySharedKey }
    }
    workloadProfiles: [ { name: 'Consumption', workloadProfileType: 'Consumption' } ]
  }
}

var kv = endsWith(keyVaultUri, '/') ? keyVaultUri : '${keyVaultUri}/'
var requiredSecrets = [
  { name: 'jwt-secret', keyVaultUrl: '${kv}secrets/fils-jwt-secret', identity: identityId }
  { name: 'data-key', keyVaultUrl: '${kv}secrets/fils-data-key', identity: identityId }
  { name: 'database-url', keyVaultUrl: '${kv}secrets/fils-database-url', identity: identityId }
  { name: 'appi-conn', value: appInsightsConnectionString }
]
var keyVaultEnvDefs = [for item in items(keyVaultEnvMap): {
  name: toLower(replace(item.key, '_', '-'))
  keyVaultUrl: '${kv}secrets/${item.value}'
  identity: identityId
}]
var secrets = concat(requiredSecrets, keyVaultEnvDefs)

var baseEnv = [
  { name: 'FILS_ENV', value: env }
  { name: 'FILS_JWT_SECRET', secretRef: 'jwt-secret' }
  { name: 'FILS_DATA_KEY', secretRef: 'data-key' }
  { name: 'FILS_DATABASE_URL', secretRef: 'database-url' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appi-conn' }
]
var settingEnv = [for item in items(appSettings): { name: item.key, value: string(item.value) }]
var optionalEnv = [for item in items(keyVaultEnvMap): { name: item.key, secretRef: toLower(replace(item.key, '_', '-')) }]
var envVars = concat(baseEnv, settingEnv, optionalEnv)

var registries = [ { server: acrLoginServer, identity: identityId } ]
var uai = { type: 'UserAssigned', userAssignedIdentities: { '${identityId}': {} } }

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${name}-api'
  location: location
  tags: tags
  identity: uai
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Multiple' // enables blue/green traffic shift and instant rollback
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
        traffic: [ { latestRevision: true, weight: 100 } ]
      }
      registries: registries
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'api'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: envVars
          probes: [
            { type: 'Liveness', httpGet: { path: '/healthz', port: 8000 }, periodSeconds: 15, failureThreshold: 3 }
            { type: 'Readiness', httpGet: { path: '/readyz', port: 8000 }, periodSeconds: 10, failureThreshold: 3, initialDelaySeconds: 5 }
            { type: 'Startup', httpGet: { path: '/healthz', port: 8000 }, periodSeconds: 5, failureThreshold: 24 }
          ]
        }
      ]
      scale: {
        minReplicas: apiMinReplicas
        maxReplicas: apiMaxReplicas
        rules: [ { name: 'http', http: { metadata: { concurrentRequests: '50' } } } ]
      }
    }
  }
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${name}-worker'
  location: location
  tags: tags
  identity: uai
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: image
          command: ['python', '-m', 'fils_api.worker']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: envVars
        }
      ]
      scale: { minReplicas: 1, maxReplicas: env == 'production' ? 3 : 1 }
    }
  }
}

resource migrate 'Microsoft.App/jobs@2024-03-01' = {
  name: '${name}-migrate'
  location: location
  tags: tags
  identity: uai
  properties: {
    environmentId: cae.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 900
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: registries
      secrets: secrets
    }
    template: {
      containers: [
        {
          name: 'migrate'
          image: image
          command: ['alembic', 'upgrade', 'head']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: envVars
        }
      ]
    }
  }
}

output apiFqdn string = api.properties.configuration.ingress.fqdn
output environmentId string = cae.id
