// ============================================================================
// Luxury Auto MGA - core Azure infrastructure
// Implements: docs/decisions/0001-database-and-erp.md
//             docs/decisions/0002-cloud-provider-azure.md
//             docs/decisions/0008-azure-infra-provisioned.md
//
// Deploy into an existing resource group:
//   az deployment group create \
//     --resource-group luxauto-rg \
//     --template-file infra/bicep/main.bicep \
//     --parameters postgresAdminPassword='<generate one, do not commit it>'
//
// NOTE ON REGION: defaults to eastus2, not eastus. See ADR 0008 "Deviation 1" -
// eastus was found to be provisioning-restricted for PostgreSQL Flexible Server
// on the subscription this was built against. Re-check with:
//   az postgres flexible-server list-skus --location <region>
// before assuming eastus works for a different subscription.
// ============================================================================

@description('Region for the VNet, subnet, private DNS zone, and Postgres server. Must support PostgreSQL Flexible Server provisioning on this subscription - see ADR 0008.')
param location string = 'eastus2'

@description('Region for the storage account. Can differ from `location` (this project runs it in eastus) but colocating is recommended if starting fresh.')
param storageLocation string = 'eastus'

@description('Base name used to derive resource names. Keep short - storage account name derives from this and has a 24-char limit.')
param baseName string = 'luxauto'

@description('PostgreSQL administrator login name.')
param postgresAdminUsername string = 'luxautoadmin'

@secure()
@description('PostgreSQL administrator password. Pass at deploy time - never commit a real value. Generate with e.g. `openssl rand -base64 24`.')
param postgresAdminPassword string

@description('PostgreSQL server SKU. Standard_B1ms is Burstable/dev-test per ADR 0008; move to a General Purpose tier before production load.')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL server tier.')
param postgresTier string = 'Burstable'

@description('PostgreSQL version.')
param postgresVersion string = '16'

@description('PostgreSQL storage size in GB.')
param postgresStorageGb int = 32

@description('Extensions to allow-list on the server. Must include everything schemas/db/postgresql_schema.sql requires via CREATE EXTENSION - see ADR 0008 Deviation 2. Comma-separated, no spaces.')
param postgresAllowedExtensions string = 'UUID-OSSP,BTREE_GIST'

var vnetName = '${baseName}-vnet-${location}'
var pgSubnetName = '${baseName}-pg-subnet'
var privateDnsZoneName = '${baseName}-${location}.postgres.database.azure.com'
var postgresServerName = '${baseName}-pg'
// Storage account names must be globally unique, lowercase, alphanumeric, <=24 chars.
// uniqueString() keeps this deterministic per resource group rather than random per deploy.
var storageAccountName = toLower('${baseName}sa${uniqueString(resourceGroup().id)}')
var keyVaultName = toLower('${baseName}-kv-${uniqueString(resourceGroup().id)}')
var documentsContainerName = 'documents'

// ============================================================================
// NETWORKING - VNet + delegated subnet for Postgres Flexible Server
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: pgSubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          delegations: [
            {
              name: 'postgresFlexibleServerDelegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${baseName}-pg-dns-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ============================================================================
// POSTGRESQL FLEXIBLE SERVER - private, VNet-injected (ADR 0001/0002)
// ============================================================================

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: postgresServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: postgresTier
  }
  properties: {
    version: postgresVersion
    administratorLogin: postgresAdminUsername
    administratorLoginPassword: postgresAdminPassword
    storage: {
      storageSizeGB: postgresStorageGb
    }
    network: {
      delegatedSubnetResourceId: vnet.properties.subnets[0].id
      privateDnsZoneArmResourceId: privateDnsZone.id
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
  dependsOn: [
    privateDnsZoneLink
  ]
}

// Allow-list required extensions - see ADR 0008 Deviation 2. Without this,
// CREATE EXTENSION in schemas/db/postgresql_schema.sql fails and cascades
// into every uuid_generate_v4() default and the btree_gist exclusion
// constraint on state_rating_table_versions.
resource postgresExtensionsConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-06-01-preview' = {
  parent: postgresServer
  name: 'azure.extensions'
  properties: {
    value: postgresAllowedExtensions
    source: 'user-override'
  }
}

// ============================================================================
// STORAGE ACCOUNT + BLOB CONTAINER - documents (ADR 0002/0003)
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: storageLocation
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource documentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: documentsContainerName
  properties: {
    publicAccess: 'None'
  }
}

// ============================================================================
// KEY VAULT - RBAC-authorized, secrets populated out of band (never in IaC)
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output postgresFqdn string = postgresServer.properties.fullyQualifiedDomainName
output postgresServerName string = postgresServer.name
output vnetName string = vnet.name
output pgSubnetId string = vnet.properties.subnets[0].id
output storageAccountName string = storageAccount.name
output documentsContainerName string = documentsContainer.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri

// NOT deployed here, deliberately - see ADR 0008 "Consequences / not yet done":
//   - Key Vault secret VALUES (populate out of band, e.g. via Cloud Shell -
//     see ADR 0008; never put secret values in a template or parameters file)
//   - Any compute (Odoo hosting - VM vs. App Service is still an open decision)
//   - Role assignments granting a compute identity access to the Key Vault
//     (nothing to grant access to yet, since no compute is deployed)
