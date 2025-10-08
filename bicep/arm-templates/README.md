# ARM Template Deployment - Quick Start

This directory contains ARM templates and deployment scripts for the Azure Function App on Container Apps.

## Files

```
arm-templates/
├── function-app-deployment.json    # Main ARM template (generated from Bicep)
├── parameters-dev.json             # Development environment parameters
├── parameters-prod.json            # Production environment parameters
├── deploy.sh                       # Automated deployment script
└── README.md                       # This file
```

## Quick Deployment

### Option 1: Use the Deployment Script (Easiest)

```bash
# Deploy to development
./deploy.sh dev

# Deploy to production
./deploy.sh prod
```

The script will:
1. Validate your Azure login
2. Create resource group
3. Validate ARM template
4. Show What-If preview (optional)
5. Deploy infrastructure
6. Display endpoints and test commands
7. Save deployment info

### Option 2: Manual Azure CLI Deployment

```bash
# 1. Update container image in parameters file
vi parameters-dev.json
# Change: "YOUR_REGISTRY.azurecr.io/function-app:latest"
# To: "myregistry.azurecr.io/function-app:latest"

# 2. Create resource group
az group create \
  --name rg-funcapp-dev \
  --location eastus

# 3. Deploy
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json

# 4. Get function URL
az deployment group show \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --query 'properties.outputs.functionAppUrl.value' \
  -o tsv
```

## Parameter Customization

### Edit Parameter File

```bash
# Development
vi parameters-dev.json

# Production
vi parameters-prod.json
```

### Key Parameters to Update

| Parameter | Description | Example |
|-----------|-------------|---------|
| `containerImage` | Full image path | `myregistry.azurecr.io/function-app:v1.0.0` |
| `minReplicas` | Min instances (0 = scale-to-zero) | `0` (dev), `2` (prod) |
| `maxReplicas` | Max instances | `10` (dev), `20` (prod) |
| `cpu` | CPU cores per instance | `0.25`, `0.5`, `1.0` |
| `memory` | Memory per instance | `0.5Gi`, `1Gi`, `2Gi` |

## Validation Before Deployment

```bash
# Validate template syntax
az deployment group validate \
  --resource-group rg-funcapp-dev \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json

# Preview changes (What-If)
az deployment group what-if \
  --resource-group rg-funcapp-dev \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json
```

## Complete Example

Here's a complete deployment example with your current function app:

```bash
#!/bin/bash

# Configuration
RESOURCE_GROUP="rg-funcapp-dev"
LOCATION="westeurope"  # Match your current deployment
ACR_REGISTRY="YOUR_REGISTRY"  # Update this
IMAGE_NAME="function-app"
IMAGE_TAG="latest"

# Step 1: Login
az login

# Step 2: Create resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Step 3: Update parameter file with your registry
cat > parameters-dev.json << EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "namePrefix": {"value": "funcapp"},
    "environment": {"value": "dev"},
    "location": {"value": "$LOCATION"},
    "containerImage": {"value": "$ACR_REGISTRY.azurecr.io/$IMAGE_NAME:$IMAGE_TAG"},
    "minReplicas": {"value": 0},
    "maxReplicas": {"value": 10},
    "cpu": {"value": "0.25"},
    "memory": {"value": "0.5Gi"}
  }
}
EOF

# Step 4: Deploy
az deployment group create \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M) \
  --resource-group $RESOURCE_GROUP \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json

# Step 5: Get URL and test
FUNCTION_URL=$(az deployment group show \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M) \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.functionAppUrl.value' \
  -o tsv)

echo "Function App URL: $FUNCTION_URL"

# Test health endpoint
curl "$FUNCTION_URL/api/health"

# Test hello endpoint with timing
curl -w "\nResponse time: %{time_total}s\n" \
  "$FUNCTION_URL/api/hello?name=Test"
```

## Deployment Outputs

After successful deployment, you'll get these outputs:

```json
{
  "functionAppUrl": "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io",
  "fqdn": "funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io",
  "containerAppName": "funcapp-ca-dev",
  "environmentName": "funcapp-env-dev",
  "healthCheckUrl": "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health",
  "helloWorldUrl": "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello"
}
```

## Testing Deployed Function

```bash
# Health check
curl https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health

# Hello endpoint
curl "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"

# With response time (your example)
curl -w "%{time_total}\n" \
  "https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test"
```

## Monitoring

```bash
# View container app status
az containerapp show \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --query '{name:name,status:properties.runningStatus,replicas:properties.runningStatus}'

# Stream logs
az containerapp logs show \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --follow

# Check replica count (scale-to-zero testing)
az containerapp revision list \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --query "[0].properties.replicas"
```

## Update Existing Deployment

```bash
# Update scaling parameters
az deployment group create \
  --name funcapp-update \
  --resource-group rg-funcapp-dev \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json \
  --parameters minReplicas=1 maxReplicas=15

# Update container image
az deployment group create \
  --name funcapp-update \
  --resource-group rg-funcapp-dev \
  --template-file function-app-deployment.json \
  --parameters @parameters-dev.json \
  --parameters containerImage=myregistry.azurecr.io/function-app:v2.0.0
```

## Cleanup

```bash
# Delete all resources
az group delete --name rg-funcapp-dev --yes --no-wait

# Or delete specific deployment
az deployment group delete \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev
```

## Troubleshooting

### Check Deployment Status

```bash
az deployment group list \
  --resource-group rg-funcapp-dev \
  --query "[].{name:name,state:properties.provisioningState}" \
  -o table
```

### View Deployment Errors

```bash
az deployment group show \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --query 'properties.error'
```

### Grant ACR Access (if image pull fails)

```bash
# Get container app managed identity
PRINCIPAL_ID=$(az containerapp show \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --query identity.principalId \
  -o tsv)

# Grant ACR pull access
ACR_ID=$(az acr show --name myregistry --query id -o tsv)

az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope $ACR_ID
```

## CI/CD Integration

See [../../ARM-DEPLOYMENT.md](../../ARM-DEPLOYMENT.md) for GitHub Actions and Azure DevOps pipeline examples.

## Additional Resources

- Full documentation: [../../ARM-DEPLOYMENT.md](../../ARM-DEPLOYMENT.md)
- Function app guide: [../../function-app/README.md](../../function-app/README.md)
- Testing guide: [../../TESTING.md](../../TESTING.md)
