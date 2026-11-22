using '../main.bicep'

param env = 'staging'
param prefix = 'fils'
param deployApps = false // flip to true on the second pass (deploy.sh does this)
param apiImage = 'fils-api:latest'
param pgHaEnabled = false
param pgGeoRedundantBackup = false
param pgBackupRetentionDays = 7
param pgAdminPassword = readEnvironmentVariable('FILS_PG_ADMIN_PASSWORD')
param appSettings = {
  FILS_LOG_LEVEL: 'INFO'
  FILS_APPLE_CLIENT_IDS: '["kw.fils.fils"]'
  FILS_LLM_PROVIDER: 'disabled'
  FILS_SPEECH_PROVIDER: 'disabled'
}
