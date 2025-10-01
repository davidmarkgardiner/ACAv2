// ============================================================================
// Security Module - Key Vault for Secrets Management
// ============================================================================
// Creates Azure Key Vault for storing Container App secrets with
// proper access policies and managed identity integration.
// ============================================================================

@description('Name of the Key Vault')
param keyVaultName string

@description('Location for the Key Vault')
param location string = resourceGroup().location

@description('SKU for Key Vault (standard or premium)')
@allowed(['standard', 'premium'])
param sku string = 'standard'

@description('Enable RBAC authorization (recommended)')
param enableRbacAuthorization bool = true

@description('Enable soft delete')
param enableSoftDelete bool = true

@description('Soft delete retention period in days')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Enable purge protection')
param enablePurgeProtection bool = true

@description('Object IDs to grant access (managed identities, service principals)')
param accessPolicyObjectIds array = []

@description('Tenant ID')
param tenantId string = tenant().tenantId

@description('Tags to apply to resources')
param tags object = {}

// ============================================================================
// Key Vault
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: sku
    }
    enableRbacAuthorization: enableRbacAuthorization
    enableSoftDelete: enableSoftDelete
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection
    accessPolicies: !enableRbacAuthorization ? [
      for objectId in accessPolicyObjectIds: {
        tenantId: tenantId
        objectId: objectId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ] : []
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Key Vault')
output keyVaultId string = keyVault.id

@description('Name of the Key Vault')
output keyVaultName string = keyVault.name

@description('URI of the Key Vault')
output keyVaultUri string = keyVault.properties.vaultUri
