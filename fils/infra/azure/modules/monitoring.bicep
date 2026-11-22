param name string
param location string
param tags object
param retentionDays int = 30

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    workspaceCapping: { dailyQuotaGb: 2 } // cost guardrail; raise deliberately
  }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: '${name}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    DisableIpMasking: false
    IngestionMode: 'LogAnalytics'
  }
}

output customerId string = law.properties.customerId
output workspaceName string = law.name
output appInsightsConnectionString string = ai.properties.ConnectionString
