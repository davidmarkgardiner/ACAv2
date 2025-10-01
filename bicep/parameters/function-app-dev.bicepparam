using '../templates/function-app-deployment.bicep'

// ============================================================================
// Development Environment Parameters
// ============================================================================

param namePrefix = 'funcapp'
param environment = 'dev'
param location = 'eastus'

// Container image - UPDATE THIS after building and pushing your image
// Format: <registry>.azurecr.io/<repository>:<tag>
// Example: 'myregistry.azurecr.io/function-app:latest'
param containerImage = '<YOUR_REGISTRY>.azurecr.io/function-app:latest'

// Scale-to-zero configuration
param minReplicas = 0  // Scale to zero when no requests
param maxReplicas = 10  // Maximum scale out

// Resource allocation
param cpu = '0.25'      // 0.25 CPU cores
param memory = '0.5Gi'  // 512 MB RAM

param tags = {
  environment: 'dev'
  application: 'function-app'
  managedBy: 'bicep'
  costCenter: 'engineering'
}
