// ============================================================================
// Azure Container App Environment Module
// ============================================================================
// Creates a Container Apps managed environment with optional VNet integration,
// Log Analytics workspace connection, and monitoring configuration.
// ============================================================================

@description('Name of the Container App Environment')
param environmentName string

@description('Location for the environment')
param location string = resourceGroup().location

@description('Log Analytics Workspace ID for monitoring')
param logAnalyticsWorkspaceId string

@description('Enable VNet integration')
param vnetIntegrationEnabled bool = false

@description('Subnet ID for VNet integration (required if vnetIntegrationEnabled is true)')
param subnetId string = ''

@description('Enable Dapr')
param daprEnabled bool = false

@description('Internal load balancer enabled')
param internalLoadBalancerEnabled bool = false

@description('Tags to apply to resources')
param tags object = {}

// ============================================================================
// Container App Environment
// ============================================================================

resource environment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: reference(logAnalyticsWorkspaceId, '2022-10-01').customerId
        sharedKey: listKeys(logAnalyticsWorkspaceId, '2022-10-01').primarySharedKey
      }
    }
    vnetConfiguration: vnetIntegrationEnabled ? {
      infrastructureSubnetId: subnetId
      internal: internalLoadBalancerEnabled
    } : null
    daprAIInstrumentationKey: daprEnabled ? null : null
    zoneRedundant: false
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Container App Environment')
output environmentId string = environment.id

@description('Name of the Container App Environment')
output environmentName string = environment.name

@description('Default domain of the environment')
output defaultDomain string = environment.properties.defaultDomain

@description('Static IP address (if VNet integration is enabled)')
output staticIp string = vnetIntegrationEnabled ? environment.properties.staticIp : ''
