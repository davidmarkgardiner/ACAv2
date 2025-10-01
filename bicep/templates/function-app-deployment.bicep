// ============================================================================
// Function App Container App Deployment
// ============================================================================
// Complete deployment template for Azure Functions in Container Apps
// Includes: Log Analytics, Environment, and Container App with scale-to-zero
// ============================================================================

@description('Name prefix for all resources')
param namePrefix string = 'funcapp'

@description('Environment (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Container image for the function app')
param containerImage string

@description('Container registry server')
param registryServer string = split(containerImage, '/')[0]

@description('Target port (Azure Functions uses 80)')
param targetPort int = 80

@description('Minimum replicas (0 for scale-to-zero)')
@minValue(0)
param minReplicas int = 0

@description('Maximum replicas')
@minValue(1)
@maxValue(30)
param maxReplicas int = 10

@description('CPU cores')
param cpu string = '0.25'

@description('Memory size')
param memory string = '0.5Gi'

@description('Tags to apply to all resources')
param tags object = {
  environment: environment
  application: 'function-app'
  managedBy: 'bicep'
}

// ============================================================================
// Variables
// ============================================================================

var resourceNames = {
  logAnalytics: '${namePrefix}-logs-${environment}'
  environment: '${namePrefix}-env-${environment}'
  containerApp: '${namePrefix}-ca-${environment}'
}

// ============================================================================
// Log Analytics Workspace
// ============================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: resourceNames.logAnalytics
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ============================================================================
// Container Apps Environment
// ============================================================================

module containerEnvironment '../modules/environment.bicep' = {
  name: 'deploy-environment'
  params: {
    environmentName: resourceNames.environment
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.id
  }
}

// ============================================================================
// Function App Container
// ============================================================================

module functionApp '../modules/container-app.bicep' = {
  name: 'deploy-function-app'
  params: {
    appName: resourceNames.containerApp
    location: location
    environmentId: containerEnvironment.outputs.environmentId
    containerImage: containerImage
    registryServer: registryServer
    cpu: cpu
    memory: memory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    ingressEnabled: true
    ingressExternal: true
    targetPort: targetPort
    transport: 'http'
    allowInsecure: false
    managedIdentityEnabled: true
    tags: tags
    scalingRules: [
      {
        name: 'http-scaling-rule'
        http: {
          metadata: {
            concurrentRequests: '10'
          }
        }
      }
    ]
    environmentVariables: [
      {
        name: 'FUNCTIONS_WORKER_RUNTIME'
        value: 'python'
      }
      {
        name: 'AzureWebJobsScriptRoot'
        value: '/home/site/wwwroot'
      }
      {
        name: 'AzureFunctionsJobHost__Logging__Console__IsEnabled'
        value: 'true'
      }
    ]
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Function App URL')
output functionAppUrl string = functionApp.outputs.applicationUrl

@description('Function App FQDN')
output fqdn string = functionApp.outputs.fqdn

@description('Container App Name')
output containerAppName string = functionApp.outputs.containerAppName

@description('Environment Name')
output environmentName string = containerEnvironment.outputs.environmentName

@description('Health Check Endpoint')
output healthCheckUrl string = '${functionApp.outputs.applicationUrl}/api/health'

@description('Hello World Endpoint')
output helloWorldUrl string = '${functionApp.outputs.applicationUrl}/api/hello'
