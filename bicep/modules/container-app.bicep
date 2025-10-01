// ============================================================================
// Azure Container App Module
// ============================================================================
// Creates a Container App with specified configuration including image,
// resources, scaling rules, ingress, environment variables, and secrets.
// ============================================================================

@description('Name of the Container App')
param appName string

@description('Location for resources')
param location string = resourceGroup().location

@description('Container App Environment ID')
param environmentId string

@description('Container image (e.g., myregistry.azurecr.io/myapp:v1.0.0)')
param containerImage string

@description('Container registry server')
param registryServer string = split(containerImage, '/')[0]

@description('CPU cores (e.g., 0.25, 0.5, 1.0, 2.0)')
param cpu string = '0.25'

@description('Memory size (e.g., 0.5Gi, 1Gi, 2Gi)')
param memory string = '0.5Gi'

@description('Minimum number of replicas')
@minValue(0)
@maxValue(30)
param minReplicas int = 0

@description('Maximum number of replicas')
@minValue(1)
@maxValue(30)
param maxReplicas int = 10

@description('Enable external ingress')
param ingressEnabled bool = true

@description('Make ingress external (true) or internal (false)')
param ingressExternal bool = true

@description('Target port for ingress')
param targetPort int = 80

@description('Transport protocol (http, http2, tcp)')
@allowed(['http', 'http2', 'tcp'])
param transport string = 'http'

@description('Allow insecure connections')
param allowInsecure bool = false

@description('Environment variables')
param environmentVariables array = []

@description('Secrets for the Container App')
param secrets array = []

@description('Scaling rules')
param scalingRules array = []

@description('Tags to apply to resources')
param tags object = {}

@description('Enable managed identity')
param managedIdentityEnabled bool = true

@description('Container port (internal)')
param containerPort int = targetPort

@description('Revision mode (Single or Multiple)')
@allowed(['Single', 'Multiple'])
param revisionMode string = 'Single'

// ============================================================================
// Container App
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: appName
  location: location
  tags: tags
  identity: managedIdentityEnabled ? {
    type: 'SystemAssigned'
  } : null
  properties: {
    environmentId: environmentId
    configuration: {
      activeRevisionsMode: revisionMode
      ingress: ingressEnabled ? {
        external: ingressExternal
        targetPort: targetPort
        transport: transport
        allowInsecure: allowInsecure
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      } : null
      secrets: secrets
      registries: [
        {
          server: registryServer
          identity: managedIdentityEnabled ? 'system' : null
        }
      ]
    }
    template: {
      containers: [
        {
          name: appName
          image: containerImage
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: environmentVariables
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: scalingRules
      }
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the Container App')
output containerAppId string = containerApp.id

@description('Name of the Container App')
output containerAppName string = containerApp.name

@description('FQDN of the Container App')
output fqdn string = ingressEnabled ? containerApp.properties.configuration.ingress.fqdn : ''

@description('Latest revision name')
output latestRevisionName string = containerApp.properties.latestRevisionName

@description('Managed Identity Principal ID')
output principalId string = managedIdentityEnabled ? containerApp.identity.principalId : ''

@description('Application URL')
output applicationUrl string = ingressEnabled ? 'https://${containerApp.properties.configuration.ingress.fqdn}' : ''
