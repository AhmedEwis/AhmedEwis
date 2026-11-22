// One user-assigned identity for the API, worker and migration job.
param name string
param location string
param tags object

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${name}-id'
  location: location
  tags: tags
}

output id string = uai.id
output principalId string = uai.properties.principalId
output clientId string = uai.properties.clientId
