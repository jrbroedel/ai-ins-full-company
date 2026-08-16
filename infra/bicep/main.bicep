// ============================================================================
// Luxury Auto MGA - data-layer infrastructure, for a PARALLEL environment
//
// WHAT THIS IS
//   A deployable template that stands up a fresh, self-contained copy of this
//   project's data layer: VNet + two subnets, private DNS zone, PostgreSQL
//   Flexible Server, storage account + documents container, and Key Vault.
//   Its purpose is the follow-up docs/runbooks/vm-rebuild.md names as still
//   outstanding - standing up a parallel environment and running that runbook
//   against it end to end, rather than trusting a reconstruction nobody has
//   executed.
//
// WHAT THIS IS NOT - read this before deploying anything
//   *** This template does NOT describe the running production environment,
//   *** and running it can never adopt, import or update those resources.
//   The live resources were created by hand and their names do not match what
//   this template generates - see ADR 0008's addendum for the full list. The
//   two most important:
//     - `luxautosa91a2e1` and `luxauto-kv-90a311` have DIFFERENT random
//       suffixes, but every name here derives from ONE uniqueString() call,
//       which by definition produces the same suffix for both. They therefore
//       cannot have come from this template, and no parameter value makes it
//       reproduce them.
//     - The live private DNS zone is `luxauto-eus2.postgres...` (abbreviated
//       region); an earlier version of this file interpolated the raw location
//       and would have produced `luxauto-eastus2.postgres...`.
//   Until 2026-08-16 this file's header told you to deploy it into
//   `luxauto-rg` with default parameters. Doing so would have SUCCEEDED and
//   silently created a second, disconnected set of resources beside the real
//   ones. `baseName` now has no default specifically so that command cannot be
//   run without a deliberate choice.
//
// DELIBERATELY OUT OF SCOPE - unchanged from the original, and not an omission
//   No compute (the VM), no NSG rules, no managed identity, no role
//   assignments, and no Key Vault secret VALUES. ADR 0008 excluded these
//   because VM-vs-App-Service was still open; ADR 0009 later resolved that,
//   but the VM layer has still never been expressed as IaC in any form. Do not
//   read this file as covering it. docs/runbooks/vm-rebuild.md step 2 is the
//   only description of the VM, and it is prose, not a template.
//
// STATUS: never deployed. Compiles clean (`bicep build`), but no deployment or
//   what-if has been run against any subscription - see ADR 0008's addendum.
//
// DEPLOY - into a NEW, EMPTY resource group, never luxauto-rg:
//   az group create --name luxauto-test-rg --location eastus2
//   az deployment group create \
//     --resource-group luxauto-test-rg \
//     --template-file infra/bicep/main.bicep \
//     --parameters baseName='luxauto-test' \
//                  postgresAdminPassword='<generate one, do not commit it>'
//
//   A new resource group matters for more than tidiness: the storage account
//   and Key Vault names derive from uniqueString(resourceGroup().id), so a
//   distinct group is what keeps those globally-unique names from colliding.
//
// Implements the data-layer half of:
//   docs/decisions/0001-database-and-erp.md
//   docs/decisions/0002-cloud-provider-azure.md
//   docs/decisions/0008-azure-infra-provisioned.md (+ its 2026-08-16 addendum)
//
// NOTE ON REGION: defaults to eastus2, not eastus. See ADR 0008 "Deviation 1" -
// eastus was found to be provisioning-restricted for PostgreSQL Flexible Server
// on the subscription this was built against. Re-check with:
//   az postgres flexible-server list-skus --location <region>
// before assuming eastus works for a different subscription.
// ============================================================================

@description('Region for the VNet, subnets, private DNS zone, and Postgres server. Must support PostgreSQL Flexible Server provisioning on this subscription - see ADR 0008.')
param location string = 'eastus2'

@description('Abbreviated form of `location`, used in the VNet and private DNS zone names. MUST correspond to `location` - this is a separate parameter rather than a lookup because Azure publishes no canonical abbreviation list. The live environment uses eus2 for eastus2.')
param locationAbbreviation string = 'eus2'

@description('Region for the storage account. Can differ from `location` (the live environment runs it in eastus) but colocating is recommended if starting fresh.')
param storageLocation string = 'eastus'

@minLength(3)
@maxLength(12)
@description('REQUIRED, no default - deliberately. Base name for every resource. Use something unmistakably non-production such as `luxauto-test`; passing `luxauto` would generate names that read as production while being unrelated to it. Lowercase letters, digits and hyphens; must start with a letter. Capped at 12 characters so the derived storage account and Key Vault names stay inside Azure\'s 24-character limits.')
param baseName string

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

@description('Address space for the VNet.')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('Address prefix for the Postgres-delegated subnet. Matches the live environment.')
param pgSubnetPrefix string = '10.20.1.0/24'

@description('Address prefix for the application subnet - where a VM would attach. Matches the live environment, where luxauto-odoo sits at 10.20.3.4. No VM is created here; see the header.')
param appSubnetPrefix string = '10.20.3.0/24'

// Region abbreviation, not the raw location: the live environment's VNet and
// private DNS zone use the short form, and interpolating `location` here is the
// naming mismatch ADR 0008's addendum records.
var vnetName = '${baseName}-vnet-${locationAbbreviation}'
var pgSubnetName = '${baseName}-pg-subnet'
var appSubnetName = '${baseName}-app-subnet'
var privateDnsZoneName = '${baseName}-${locationAbbreviation}.postgres.database.azure.com'
var postgresServerName = '${baseName}-pg'
// Storage account names must be globally unique, lowercase, ALPHANUMERIC ONLY
// (no hyphens) and <=24 chars - hence the replace(). uniqueString() keeps this
// deterministic per resource group rather than random per deploy, which is also
// why deploying into a NEW group is what avoids collisions.
var storageAccountName = toLower('${replace(baseName, '-', '')}sa${take(uniqueString(resourceGroup().id), 8)}')
// Key Vault names allow hyphens but are also capped at 24 characters. The
// suffix is truncated so a 12-character baseName still fits.
var keyVaultName = toLower('${baseName}-kv-${take(uniqueString(resourceGroup().id), 6)}')
var documentsContainerName = 'documents'

// Referenced via resourceId() rather than vnet.properties.subnets[0].id so that
// adding or reordering subnets cannot silently repoint the Postgres delegation
// at the wrong one.
var pgSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, pgSubnetName)
var appSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, appSubnetName)

// ============================================================================
// NETWORKING - VNet + delegated subnet for Postgres, plus an app subnet
// ============================================================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: pgSubnetName
        properties: {
          addressPrefix: pgSubnetPrefix
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
      {
        // Where a parallel VM would attach. The live VNet has this subnet and
        // earlier versions of this template did not, so its VNet had nowhere
        // for compute to go. No delegation (a VM needs none) and no NSG - NSG
        // rules are out of scope for this file, and a parallel environment
        // would need its own reviewed against runbook step 4 before exposing
        // anything.
        name: appSubnetName
        properties: {
          addressPrefix: appSubnetPrefix
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
      delegatedSubnetResourceId: pgSubnetId
      privateDnsZoneArmResourceId: privateDnsZone.id
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
  dependsOn: [
    vnet
    privateDnsZoneLink
  ]
}

// Allow-list required extensions - see ADR 0008 Deviation 2. Without this,
// CREATE EXTENSION in schemas/db/postgresql_schema.sql fails and cascades
// into every uuid_generate_v4() default and the btree_gist exclusion
// constraint on state_rating_table_versions. Confirmed still correct against
// the live server on 2026-08-16: pg_extension lists uuid-ossp 1.1 and
// btree_gist 1.7.
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

// The live account also has an `infra-artifacts` container holding the pinned
// Odoo .deb (ADR 0009's Deviation 1 addendum). It is deliberately NOT created
// here: it exists to make the production host reproducible, and a parallel
// environment installing from that same vendored artifact should read it from
// the real account rather than get an empty container of its own.

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
output pgSubnetId string = pgSubnetId
output appSubnetId string = appSubnetId
output privateDnsZoneName string = privateDnsZone.name
output storageAccountName string = storageAccount.name
output documentsContainerName string = documentsContainer.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri

// NOT deployed here, deliberately - see the header and ADR 0008's
// "Consequences / not yet done":
//   - Key Vault secret VALUES (populate out of band, e.g. via Cloud Shell -
//     see ADR 0008; never put secret values in a template or parameters file)
//   - Any compute. ADR 0009 settled VM-over-App-Service, but no VM, NIC,
//     public IP or NSG has ever been expressed as IaC. The app subnet above is
//     somewhere for one to attach; it is not one.
//   - Role assignments granting a compute identity access to the Key Vault.
//     A parallel environment needs its own, per runbook step 3.
