// ============================================================================
// Basic Web App Template
// ============================================================================
// Complete template for deploying a basic web application with Container Apps
// including environment, networking, monitoring, and the container app itself.
// ============================================================================

targetScope = 'resourceGroup'

// ============================================================================
// Parameters - Metadata
// ============================================================================

@description('Application name (used for resource naming)')
param appName string

@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environmentName string

@description('Team name')
param teamName string

@description('Location for all resources')
param location string = resourceGroup().location

// ============================================================================
// Parameters - Container Configuration
// ============================================================================

@description('Container image (registry/repository:tag)')
param containerImage string

@description('CPU allocation')
@allowed(['0.25', '0.5', '0.75', '1.0', '1.25', '1.5', '1.75', '2.0'])
param cpu string = '0.25'

@description('Memory allocation')
@allowed(['0.5Gi', '1Gi', '1.5Gi', '2Gi', '3Gi', '4Gi'])
param memory string = '0.5Gi'

@description('Minimum replicas')
@minValue(0)
@maxValue(30)
param minReplicas int = 0

@description('Maximum replicas')
@minValue(1)
@maxValue(30)
param maxReplicas int = 10

@description('Target port for the application')
param targetPort int = 80

@description('Enable external ingress')
param externalIngress bool = true

// ============================================================================
// Parameters - Networking
// ============================================================================

@description('Enable VNet integration')
param enableVnetIntegration bool = false

@description('VNet address prefix')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Container Apps subnet prefix')
param containerAppsSubnetPrefix string = '10.0.0.0/23'

// ============================================================================
// Parameters - Scaling
// ============================================================================

@description('HTTP concurrent requests threshold for scaling')
param httpScalingConcurrentRequests string = '10'

// ============================================================================
// Parameters - Environment Variables
// ============================================================================

@description('Environment variables for the container')
param environmentVariables array = []

// ============================================================================
// Variables
// ============================================================================

var resourcePrefix = '${appName}-${environmentName}'
var logAnalyticsName = 'logs-${resourcePrefix}'
var containerAppEnvName = 'cae-${resourcePrefix}'
var containerAppName = 'ca-${resourcePrefix}'
var vnetName = 'vnet-${resourcePrefix}'
var nsgName = 'nsg-${resourcePrefix}'

var commonTags = {
  environment: environmentName
  team: teamName
  application: appName
  managedBy: 'aca-platform'
}

var scalingRules = [
  {
    name: 'http-scaling'
    http: {
      metadata: {
        concurrentRequests: httpScalingConcurrentRequests
      }
    }
  }
]

// ============================================================================
// Module: Log Analytics Workspace
// ============================================================================

module monitoring '../modules/monitoring.bicep' = {
  name: 'deploy-monitoring-${resourcePrefix}'
  params: {
    workspaceName: logAnalyticsName
    location: location
    retentionInDays: 30
    tags: commonTags
  }
}

// ============================================================================
// Module: Networking (if VNet integration enabled)
// ============================================================================

module networking '../modules/networking.bicep' = if (enableVnetIntegration) {
  name: 'deploy-networking-${resourcePrefix}'
  params: {
    vnetName: vnetName
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    containerAppsSubnetName: 'aca-subnet'
    containerAppsSubnetPrefix: containerAppsSubnetPrefix
    nsgName: nsgName
    tags: commonTags
  }
}

// ============================================================================
// Module: Container App Environment
// ============================================================================

module environment '../modules/environment.bicep' = {
  name: 'deploy-environment-${resourcePrefix}'
  params: {
    environmentName: containerAppEnvName
    location: location
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    vnetIntegrationEnabled: enableVnetIntegration
    subnetId: enableVnetIntegration ? networking.outputs.subnetId : ''
    internalLoadBalancerEnabled: false
    tags: commonTags
  }
  dependsOn: [
    monitoring
    networking
  ]
}

// ============================================================================
// Module: Container App
// ============================================================================

module containerApp '../modules/container-app.bicep' = {
  name: 'deploy-containerapp-${resourcePrefix}'
  params: {
    appName: containerAppName
    location: location
    environmentId: environment.outputs.environmentId
    containerImage: containerImage
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    ingressEnabled: true
    ingressExternal: externalIngress
    targetPort: targetPort
    transport: 'http'
    allowInsecure: false
    environmentVariables: environmentVariables
    scalingRules: scalingRules
    managedIdentityEnabled: true
    revisionMode: 'Single'
    tags: commonTags
  }
  dependsOn: [
    environment
  ]
}

// ============================================================================
// Outputs
// ============================================================================

@description('Container App FQDN')
output applicationUrl string = containerApp.outputs.applicationUrl

@description('Container App name')
output containerAppName string = containerApp.outputs.containerAppName

@description('Environment name')
output environmentName string = environment.outputs.environmentName

@description('Managed Identity Principal ID')
output principalId string = containerApp.outputs.principalId

@description('Log Analytics Workspace ID')
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
