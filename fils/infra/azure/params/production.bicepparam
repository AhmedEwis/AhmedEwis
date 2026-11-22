using '../main.bicep'

param env = 'production'
param prefix = 'fils'
param deployApps = false
param apiImage = 'fils-api:latest'
param pgSkuName = 'Standard_B2s'
param pgHaEnabled = false // set true (and a General Purpose SKU) when an SLA requires it
param pgGeoRedundantBackup = true
param pgBackupRetentionDays = 35
param apiMinReplicas = 2
param apiMaxReplicas = 6
param pgAdminPassword = readEnvironmentVariable('FILS_PG_ADMIN_PASSWORD')
param appSettings = {
  FILS_LOG_LEVEL: 'INFO'
  FILS_APPLE_CLIENT_IDS: '["kw.fils.fils"]'
  FILS_APPLE_ALLOW_SANDBOX: 'false'
  FILS_LLM_PROVIDER: 'disabled'
  FILS_SPEECH_PROVIDER: 'disabled'
}
