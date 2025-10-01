# Azure Container Apps Bicep Templates

This directory contains modular Bicep templates for deploying Azure Container Apps infrastructure as part of the ACA-as-a-Service platform.

## Directory Structure

```
bicep/
├── modules/              # Reusable Bicep modules
│   ├── environment.bicep       # Container App Environment
│   ├── container-app.bicep     # Container App definition
│   ├── monitoring.bicep        # Log Analytics workspace
│   ├── networking.bicep        # VNet and subnet configuration
│   └── security.bicep          # Key Vault for secrets
├── templates/            # Complete deployment templates
│   └── basic-web-app.bicep    # Basic web app template
└── parameters/           # Parameter files for environments
    └── dev.bicepparam         # Development environment parameters
```

## Modules

### environment.bicep
Creates a Container Apps managed environment with:
- Log Analytics integration for monitoring
- Optional VNet integration
- Dapr support (configurable)
- Internal/external load balancer options

**Inputs:**
- `environmentName`: Name of the environment
- `location`: Azure region
- `logAnalyticsWorkspaceId`: Resource ID of Log Analytics workspace
- `vnetIntegrationEnabled`: Enable VNet integration (bool)
- `subnetId`: Subnet for VNet integration

**Outputs:**
- `environmentId`: Resource ID
- `environmentName`: Name
- `defaultDomain`: Default domain suffix
- `staticIp`: Static IP (if VNet enabled)

### container-app.bicep
Deploys a Container App with:
- Container image specification
- Resource allocation (CPU, memory)
- Scaling configuration (min/max replicas, scaling rules)
- Ingress configuration (external/internal, ports)
- Environment variables and secrets
- Managed identity support

**Inputs:**
- `appName`: Container App name
- `environmentId`: Container App Environment ID
- `containerImage`: Full image path
- `cpu`, `memory`: Resource allocation
- `minReplicas`, `maxReplicas`: Scaling bounds
- `ingressEnabled`, `targetPort`: Ingress settings
- `environmentVariables`: Array of env vars
- `scalingRules`: Array of scaling rules

**Outputs:**
- `containerAppId`: Resource ID
- `fqdn`: Application FQDN
- `applicationUrl`: Full HTTPS URL
- `principalId`: Managed identity ID

### monitoring.bicep
Creates Log Analytics workspace for:
- Container App logs
- Metrics collection
- Query and analysis

**Inputs:**
- `workspaceName`: Name
- `location`: Azure region
- `retentionInDays`: Log retention (30-730)

**Outputs:**
- `workspaceId`: Resource ID
- `customerId`: Workspace customer ID

### networking.bicep
Sets up networking infrastructure:
- Virtual Network
- Subnet with Container Apps delegation
- Network Security Group with basic rules

**Inputs:**
- `vnetName`: VNet name
- `vnetAddressPrefix`: VNet CIDR (e.g., 10.0.0.0/16)
- `containerAppsSubnetPrefix`: Subnet CIDR (requires /23 or larger)

**Outputs:**
- `vnetId`: VNet resource ID
- `subnetId`: Subnet resource ID
- `nsgId`: NSG resource ID

### security.bicep
Creates Key Vault for secrets management:
- RBAC or access policy authorization
- Soft delete and purge protection
- Integration with Container Apps managed identity

**Inputs:**
- `keyVaultName`: Key Vault name
- `enableRbacAuthorization`: Use RBAC (recommended)
- `accessPolicyObjectIds`: Object IDs for access policies

**Outputs:**
- `keyVaultId`: Resource ID
- `keyVaultUri`: Vault URI

## Templates

### basic-web-app.bicep
Complete deployment template that orchestrates:
1. Log Analytics workspace
2. Networking (optional)
3. Container App Environment
4. Container App

This template is designed to be called from Argo Workflows with parameters extracted from the platform payload.

## Usage

### Validate Bicep Templates

```bash
# Validate a module
az bicep build --file bicep/modules/container-app.bicep

# Validate a template
az bicep build --file bicep/templates/basic-web-app.bicep
```

### Deploy Using Azure CLI

```bash
# Create resource group
az group create --name rg-myapp-dev --location eastus

# Deploy using parameter file
az deployment group create \
  --resource-group rg-myapp-dev \
  --template-file bicep/templates/basic-web-app.bicep \
  --parameters bicep/parameters/dev.bicepparam

# Deploy with inline parameters
az deployment group create \
  --resource-group rg-myapp-dev \
  --template-file bicep/templates/basic-web-app.bicep \
  --parameters \
    appName=myapp \
    environmentName=dev \
    teamName=platform \
    containerImage=mcr.microsoft.com/azuredocs/containerapps-helloworld:latest
```

### Deploy from Argo Workflow

See `argo/workflows/containerapp-create.yaml` for the workflow that:
1. Parses the JSON payload
2. Extracts parameters
3. Executes `az deployment group create` with these Bicep templates
4. Returns the FQDN and resource IDs

## Naming Conventions

Resources follow this naming pattern:
- Resource prefix: `{appName}-{environmentName}`
- Log Analytics: `logs-{prefix}`
- Container App Environment: `cae-{prefix}`
- Container App: `ca-{prefix}`
- VNet: `vnet-{prefix}`
- NSG: `nsg-{prefix}`

## Tags

All resources are tagged with:
- `environment`: dev/staging/prod
- `team`: Team name
- `application`: App name
- `managedBy`: aca-platform

## Testing

1. **Syntax validation:**
   ```bash
   az bicep build --file bicep/modules/*.bicep
   ```

2. **What-if deployment:**
   ```bash
   az deployment group what-if \
     --resource-group rg-test \
     --template-file bicep/templates/basic-web-app.bicep \
     --parameters bicep/parameters/dev.bicepparam
   ```

3. **Test deployment:**
   ```bash
   # Deploy to test resource group
   az deployment group create \
     --resource-group rg-test-aca \
     --template-file bicep/templates/basic-web-app.bicep \
     --parameters bicep/parameters/dev.bicepparam

   # Verify Container App is running
   az containerapp show \
     --name ca-sample-app-dev \
     --resource-group rg-test-aca \
     --query "properties.configuration.ingress.fqdn"
   ```

## Integration with Platform

These Bicep templates are called from Argo Workflows in the following pattern:

1. **Payload received** via API → Argo Events webhook
2. **Sensor triggers** appropriate workflow (create/update/delete)
3. **Workflow step** executes Azure CLI in container:
   ```bash
   az deployment group create \
     --resource-group $RESOURCE_GROUP \
     --template-file /bicep/templates/basic-web-app.bicep \
     --parameters \
       appName=$APP_NAME \
       containerImage=$IMAGE \
       cpu=$CPU \
       memory=$MEMORY
   ```
4. **Outputs extracted** and returned to user

## Future Enhancements

- [ ] Add Application Insights module
- [ ] Create template for API services with authentication
- [ ] Add template for event-driven workloads
- [ ] Implement blue-green deployment template
- [ ] Add Dapr components configuration
- [ ] Support for custom domains and certificates
