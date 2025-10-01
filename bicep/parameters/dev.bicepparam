// ============================================================================
// Development Environment Parameters
// ============================================================================

using '../templates/basic-web-app.bicep'

// Metadata
param appName = 'sample-app'
param environmentName = 'dev'
param teamName = 'platform-team'
param location = 'eastus'

// Container Configuration
param containerImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param cpu = '0.25'
param memory = '0.5Gi'
param minReplicas = 0
param maxReplicas = 5
param targetPort = 80
param externalIngress = true

// Networking
param enableVnetIntegration = false
param vnetAddressPrefix = '10.0.0.0/16'
param containerAppsSubnetPrefix = '10.0.0.0/23'

// Scaling
param httpScalingConcurrentRequests = '10'

// Environment Variables
param environmentVariables = [
  {
    name: 'ENVIRONMENT'
    value: 'development'
  }
  {
    name: 'LOG_LEVEL'
    value: 'debug'
  }
]
