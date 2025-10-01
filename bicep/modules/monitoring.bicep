// ============================================================================
// Monitoring Module - Log Analytics Workspace
// ============================================================================
// Creates or references a Log Analytics workspace for Container Apps monitoring
// and logging. Required for Container App Environment configuration.
// ============================================================================

@description('Name of the Log Analytics Workspace')
param workspaceName string

@description('Location for the workspace')
param location string = resourceGroup().location

@description('SKU for Log Analytics (PerGB2018 or CapacityReservation)')
@allowed(['PerGB2018', 'CapacityReservation'])
param sku string = 'PerGB2018'

@description('Retention period in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Tags to apply to resources')
param tags object = {}

// ============================================================================
// Log Analytics Workspace
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Log Analytics Workspace')
output workspaceId string = logAnalyticsWorkspace.id

@description('Name of the Log Analytics Workspace')
output workspaceName string = logAnalyticsWorkspace.name

@description('Workspace Customer ID')
output customerId string = logAnalyticsWorkspace.properties.customerId
