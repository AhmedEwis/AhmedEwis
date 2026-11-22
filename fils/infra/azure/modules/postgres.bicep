// PostgreSQL Flexible Server with private (VNet) access only.
param name string
param location string
param tags object
param skuName string
param tier string
param storageGb int
param version string
param haEnabled bool
param geoRedundantBackup bool
param backupRetentionDays int
param adminLogin string
@secure()
param adminPassword string
param delegatedSubnetId string
param privateDnsZoneId string

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: skuName, tier: tier }
  properties: {
    version: version
    administratorLogin: adminLogin
    administratorLoginPassword: adminPassword
    storage: { storageSizeGB: storageGb }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: geoRedundantBackup ? 'Enabled' : 'Disabled'
    }
    highAvailability: { mode: haEnabled ? 'ZoneRedundant' : 'Disabled' }
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
    }
  }
}

resource db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = {
  parent: pg
  name: 'fils'
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
}

resource tls 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2022-12-01' = {
  parent: pg
  name: 'require_secure_transport'
  properties: { value: 'on', source: 'user-override' }
}

output fqdn string = pg.properties.fullyQualifiedDomainName
