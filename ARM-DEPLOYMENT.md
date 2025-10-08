# ARM Template Deployment Guide

Complete guide for deploying the Azure Function App on Container Apps using ARM templates and parameters.

## Table of Contents

1. [Quick Start](#quick-start)
2. [ARM Template Structure](#arm-template-structure)
3. [Parameter Files](#parameter-files)
4. [Deployment Methods](#deployment-methods)
5. [Examples](#examples)
6. [Validation & Troubleshooting](#validation--troubleshooting)

---

## Quick Start

### Convert Bicep to ARM Template

```bash
# Convert main template
az bicep build \
  --file bicep/templates/function-app-deployment.bicep \
  --outfile bicep/arm-templates/function-app-deployment.json

# Convert modules (optional)
az bicep build \
  --file bicep/modules/environment.bicep \
  --outfile bicep/arm-templates/environment.json

az bicep build \
  --file bicep/modules/container-app.bicep \
  --outfile bicep/arm-templates/container-app.json
```

### Deploy with ARM Template

```bash
# Using parameter file
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json

# Using inline parameters
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters \
    namePrefix=funcapp \
    environment=dev \
    containerImage=myregistry.azurecr.io/function-app:latest
```

---

## ARM Template Structure

The deployment consists of three main resources:

```
function-app-deployment.json
├── Log Analytics Workspace
│   └── For centralized logging
├── Container App Environment
│   └── Managed environment for Container Apps
└── Container App (Function App)
    ├── Azure Functions Runtime
    ├── Scale-to-zero configuration
    ├── HTTP ingress
    └── Managed identity
```

### Key Resources

| Resource Type | Purpose | API Version |
|--------------|---------|-------------|
| `Microsoft.OperationalInsights/workspaces` | Log Analytics | 2022-10-01 |
| `Microsoft.App/managedEnvironments` | Container App Environment | 2023-05-01 |
| `Microsoft.App/containerApps` | Function App Container | 2023-05-01 |

---

## Parameter Files

### Create Parameter File: `parameters-dev.json`

```bash
cat > bicep/arm-templates/parameters-dev.json << 'EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "namePrefix": {
      "value": "funcapp"
    },
    "environment": {
      "value": "dev"
    },
    "location": {
      "value": "eastus"
    },
    "containerImage": {
      "value": "YOUR_REGISTRY.azurecr.io/function-app:latest"
    },
    "minReplicas": {
      "value": 0
    },
    "maxReplicas": {
      "value": 10
    },
    "cpu": {
      "value": "0.25"
    },
    "memory": {
      "value": "0.5Gi"
    },
    "tags": {
      "value": {
        "environment": "dev",
        "application": "function-app",
        "managedBy": "arm-template",
        "costCenter": "engineering"
      }
    }
  }
}
EOF
```

### Parameter Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `namePrefix` | string | `funcapp` | Prefix for all resource names |
| `environment` | string | `dev` | Environment (dev/staging/prod) |
| `location` | string | Resource Group location | Azure region |
| `containerImage` | string | **Required** | Full container image path |
| `registryServer` | string | Auto-detected | ACR server (e.g., myregistry.azurecr.io) |
| `targetPort` | int | `80` | Container port for Azure Functions |
| `minReplicas` | int | `0` | Minimum replicas (0 = scale-to-zero) |
| `maxReplicas` | int | `10` | Maximum replicas (1-30) |
| `cpu` | string | `0.25` | CPU cores (0.25, 0.5, 1.0, 2.0) |
| `memory` | string | `0.5Gi` | Memory allocation |
| `tags` | object | `{}` | Resource tags |

---

## Deployment Methods

### Method 1: Azure CLI with Parameter File

```bash
# Create resource group
az group create \
  --name rg-funcapp-dev \
  --location eastus

# Deploy using parameter file
az deployment group create \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M%S) \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json

# Show deployment outputs
az deployment group show \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M%S) \
  --resource-group rg-funcapp-dev \
  --query properties.outputs
```

### Method 2: Azure CLI with Inline Parameters

```bash
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters \
    namePrefix=funcapp \
    environment=dev \
    location=eastus \
    containerImage=myregistry.azurecr.io/function-app:v1.0.0 \
    minReplicas=0 \
    maxReplicas=10 \
    cpu=0.25 \
    memory=0.5Gi
```

### Method 3: Azure PowerShell

```powershell
# Create resource group
New-AzResourceGroup `
  -Name rg-funcapp-dev `
  -Location eastus

# Deploy with parameter file
New-AzResourceGroupDeployment `
  -Name funcapp-deployment `
  -ResourceGroupName rg-funcapp-dev `
  -TemplateFile bicep/arm-templates/function-app-deployment.json `
  -TemplateParameterFile bicep/arm-templates/parameters-dev.json

# Deploy with inline parameters
New-AzResourceGroupDeployment `
  -Name funcapp-deployment `
  -ResourceGroupName rg-funcapp-dev `
  -TemplateFile bicep/arm-templates/function-app-deployment.json `
  -namePrefix funcapp `
  -environment dev `
  -containerImage "myregistry.azurecr.io/function-app:latest" `
  -minReplicas 0 `
  -maxReplicas 10
```

### Method 4: Azure Portal

1. Navigate to: **Azure Portal** → **Create a resource** → **Template deployment (deploy using custom templates)**
2. Select **Build your own template in the editor**
3. Copy/paste the ARM template JSON
4. Click **Save**
5. Fill in parameters:
   - **Resource group**: `rg-funcapp-dev`
   - **Name Prefix**: `funcapp`
   - **Environment**: `dev`
   - **Container Image**: `myregistry.azurecr.io/function-app:latest`
6. Click **Review + create** → **Create**

---

## Examples

### Example 1: Basic Deployment (Scale-to-Zero)

```bash
#!/bin/bash
# deploy-basic.sh - Minimal scale-to-zero deployment

RESOURCE_GROUP="rg-funcapp-dev"
LOCATION="eastus"
REGISTRY="myregistry"
IMAGE_TAG="latest"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Deploy with minimal parameters
az deployment group create \
  --name funcapp-basic-deployment \
  --resource-group $RESOURCE_GROUP \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters \
    namePrefix=funcapp \
    environment=dev \
    containerImage=$REGISTRY.azurecr.io/function-app:$IMAGE_TAG \
    minReplicas=0 \
    maxReplicas=5

# Get function URL
FUNCTION_URL=$(az deployment group show \
  --name funcapp-basic-deployment \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.functionAppUrl.value' \
  -o tsv)

echo "Function App URL: $FUNCTION_URL"
echo "Health Check: $FUNCTION_URL/api/health"
```

### Example 2: Production Deployment (No Scale-to-Zero)

```bash
#!/bin/bash
# deploy-prod.sh - Production deployment with minimum replicas

RESOURCE_GROUP="rg-funcapp-prod"
LOCATION="eastus"

az deployment group create \
  --name funcapp-prod-deployment \
  --resource-group $RESOURCE_GROUP \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters \
    namePrefix=funcapp \
    environment=prod \
    location=$LOCATION \
    containerImage=myregistry.azurecr.io/function-app:v1.0.0 \
    minReplicas=2 \
    maxReplicas=20 \
    cpu=0.5 \
    memory=1Gi \
    tags='{"environment":"prod","criticality":"high","costCenter":"operations"}'
```

### Example 3: Multi-Environment Deployment

```bash
#!/bin/bash
# deploy-all-envs.sh - Deploy to dev, staging, and prod

REGISTRY="myregistry.azurecr.io"
IMAGE="function-app"
VERSION="v1.2.3"

for ENV in dev staging prod; do
  echo "Deploying to $ENV..."

  # Set environment-specific values
  case $ENV in
    dev)
      MIN_REPLICAS=0
      MAX_REPLICAS=5
      CPU="0.25"
      MEMORY="0.5Gi"
      ;;
    staging)
      MIN_REPLICAS=1
      MAX_REPLICAS=10
      CPU="0.5"
      MEMORY="1Gi"
      ;;
    prod)
      MIN_REPLICAS=2
      MAX_REPLICAS=20
      CPU="1.0"
      MEMORY="2Gi"
      ;;
  esac

  az deployment group create \
    --name funcapp-$ENV-deployment \
    --resource-group rg-funcapp-$ENV \
    --template-file bicep/arm-templates/function-app-deployment.json \
    --parameters \
      namePrefix=funcapp \
      environment=$ENV \
      containerImage=$REGISTRY/$IMAGE:$VERSION \
      minReplicas=$MIN_REPLICAS \
      maxReplicas=$MAX_REPLICAS \
      cpu=$CPU \
      memory=$MEMORY

  echo "$ENV deployment complete!"
done
```

### Example 4: Deployment with What-If Analysis

```bash
#!/bin/bash
# deploy-with-validation.sh - Validate before deployment

RESOURCE_GROUP="rg-funcapp-dev"
TEMPLATE="bicep/arm-templates/function-app-deployment.json"
PARAMS="@bicep/arm-templates/parameters-dev.json"

echo "Step 1: Validating template..."
az deployment group validate \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters $PARAMS

if [ $? -ne 0 ]; then
  echo "Validation failed!"
  exit 1
fi

echo ""
echo "Step 2: Running What-If analysis..."
az deployment group what-if \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters $PARAMS

echo ""
read -p "Proceed with deployment? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Step 3: Deploying..."
  az deployment group create \
    --name funcapp-deployment-$(date +%Y%m%d-%H%M%S) \
    --resource-group $RESOURCE_GROUP \
    --template-file $TEMPLATE \
    --parameters $PARAMS
fi
```

### Example 5: Update Existing Deployment (Scale Settings)

```bash
#!/bin/bash
# update-scaling.sh - Update scaling configuration

RESOURCE_GROUP="rg-funcapp-dev"
DEPLOYMENT_NAME="funcapp-deployment"

# Get current deployment outputs
CURRENT_IMAGE=$(az containerapp show \
  --name funcapp-ca-dev \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.template.containers[0].image' \
  -o tsv)

# Update with new scaling parameters
az deployment group create \
  --name $DEPLOYMENT_NAME-update \
  --resource-group $RESOURCE_GROUP \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters \
    namePrefix=funcapp \
    environment=dev \
    containerImage=$CURRENT_IMAGE \
    minReplicas=1 \
    maxReplicas=15 \
    cpu=0.5 \
    memory=1Gi

echo "Scaling configuration updated!"
```

### Example 6: CI/CD Pipeline (GitHub Actions)

```yaml
# .github/workflows/deploy-function-app.yml
name: Deploy Function App

on:
  push:
    branches: [main]
    paths:
      - 'function-app/**'
      - 'bicep/**'

env:
  AZURE_RESOURCE_GROUP: rg-funcapp-dev
  ACR_NAME: myregistry
  IMAGE_NAME: function-app

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v3

      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Build and Push Image
        run: |
          az acr login --name ${{ env.ACR_NAME }}
          docker build -t ${{ env.ACR_NAME }}.azurecr.io/${{ env.IMAGE_NAME }}:${{ github.sha }} ./function-app
          docker push ${{ env.ACR_NAME }}.azurecr.io/${{ env.IMAGE_NAME }}:${{ github.sha }}

      - name: Deploy ARM Template
        run: |
          az deployment group create \
            --name funcapp-deployment-${{ github.run_number }} \
            --resource-group ${{ env.AZURE_RESOURCE_GROUP }} \
            --template-file bicep/arm-templates/function-app-deployment.json \
            --parameters \
              namePrefix=funcapp \
              environment=dev \
              containerImage=${{ env.ACR_NAME }}.azurecr.io/${{ env.IMAGE_NAME }}:${{ github.sha }}

      - name: Get Function URL
        id: get_url
        run: |
          FUNCTION_URL=$(az deployment group show \
            --name funcapp-deployment-${{ github.run_number }} \
            --resource-group ${{ env.AZURE_RESOURCE_GROUP }} \
            --query 'properties.outputs.functionAppUrl.value' \
            -o tsv)
          echo "url=$FUNCTION_URL" >> $GITHUB_OUTPUT

      - name: Test Deployment
        run: |
          curl -f ${{ steps.get_url.outputs.url }}/api/health || exit 1
```

---

## Validation & Troubleshooting

### Pre-Deployment Validation

```bash
# Validate template syntax
az deployment group validate \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json

# Preview changes (What-If)
az deployment group what-if \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json
```

### Check Deployment Status

```bash
# List recent deployments
az deployment group list \
  --resource-group rg-funcapp-dev \
  --query "[].{name:name, state:properties.provisioningState, timestamp:properties.timestamp}" \
  -o table

# Show deployment details
az deployment group show \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev

# Show deployment operations
az deployment operation group list \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  -o table
```

### Common Issues

#### Issue 1: Container Image Pull Failed

**Error**: "Failed to pull image from registry"

**Solution**:
```bash
# Grant Container App managed identity ACR pull access
CONTAINER_APP_PRINCIPAL=$(az containerapp show \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --query identity.principalId \
  -o tsv)

ACR_ID=$(az acr show --name myregistry --query id -o tsv)

az role assignment create \
  --assignee $CONTAINER_APP_PRINCIPAL \
  --role AcrPull \
  --scope $ACR_ID
```

#### Issue 2: Deployment Validation Failed

**Error**: "Template validation failed"

**Solution**:
```bash
# Check template syntax
az deployment group validate \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json

# Review error details
az deployment group show \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --query 'properties.error'
```

#### Issue 3: Resource Already Exists

**Error**: "Resource already exists"

**Solution**:
```bash
# Use incremental mode (default) to update existing resources
# Or use complete mode to replace all resources
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file bicep/arm-templates/function-app-deployment.json \
  --parameters @bicep/arm-templates/parameters-dev.json \
  --mode Incremental  # or Complete
```

### Verify Deployed Resources

```bash
#!/bin/bash
# verify-deployment.sh

RESOURCE_GROUP="rg-funcapp-dev"

echo "Checking deployed resources..."
echo "=============================="

# Check Log Analytics
echo ""
echo "Log Analytics Workspace:"
az monitor log-analytics workspace list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{name:name, location:location, sku:sku.name}" \
  -o table

# Check Container App Environment
echo ""
echo "Container App Environment:"
az containerapp env list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{name:name, location:location, provisioningState:properties.provisioningState}" \
  -o table

# Check Container App
echo ""
echo "Container App:"
az containerapp list \
  --resource-group $RESOURCE_GROUP \
  --query "[].{name:name, fqdn:properties.configuration.ingress.fqdn, replicas:properties.runningStatus}" \
  -o table

# Test endpoints
echo ""
echo "Testing endpoints..."
FUNCTION_URL=$(az containerapp show \
  --name funcapp-ca-dev \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.configuration.ingress.fqdn' \
  -o tsv)

echo "Health Check:"
curl -s https://$FUNCTION_URL/api/health | jq .

echo ""
echo "Hello Endpoint:"
curl -s "https://$FUNCTION_URL/api/hello?name=Deployment" | jq .
```

---

## Complete Deployment Workflow

```bash
#!/bin/bash
# complete-deployment.sh - Full deployment workflow

set -e  # Exit on error

# Configuration
RESOURCE_GROUP="rg-funcapp-dev"
LOCATION="eastus"
ACR_NAME="myregistry"
IMAGE_NAME="function-app"
IMAGE_TAG="latest"
TEMPLATE="bicep/arm-templates/function-app-deployment.json"

echo "===================================="
echo "Function App Deployment Workflow"
echo "===================================="

# Step 1: Login to Azure
echo ""
echo "Step 1: Logging in to Azure..."
az login

# Step 2: Create Resource Group
echo ""
echo "Step 2: Creating resource group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Step 3: Build and push container image
echo ""
echo "Step 3: Building container image..."
cd function-app
az acr login --name $ACR_NAME
docker build -t $ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG .
docker push $ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG
cd ..

# Step 4: Convert Bicep to ARM (if needed)
echo ""
echo "Step 4: Converting Bicep to ARM template..."
az bicep build \
  --file bicep/templates/function-app-deployment.bicep \
  --outfile $TEMPLATE

# Step 5: Validate template
echo ""
echo "Step 5: Validating ARM template..."
az deployment group validate \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters \
    containerImage=$ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG

# Step 6: Deploy
echo ""
echo "Step 6: Deploying infrastructure..."
az deployment group create \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M%S) \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters \
    namePrefix=funcapp \
    environment=dev \
    location=$LOCATION \
    containerImage=$ACR_NAME.azurecr.io/$IMAGE_NAME:$IMAGE_TAG

# Step 7: Get outputs
echo ""
echo "Step 7: Retrieving deployment outputs..."
FUNCTION_URL=$(az deployment group show \
  --name funcapp-deployment-$(date +%Y%m%d-%H%M%S) \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.functionAppUrl.value' \
  -o tsv)

echo ""
echo "===================================="
echo "Deployment Complete!"
echo "===================================="
echo "Function App URL: $FUNCTION_URL"
echo "Health Check: $FUNCTION_URL/api/health"
echo "Hello Endpoint: $FUNCTION_URL/api/hello"
echo ""
echo "Test with:"
echo "curl $FUNCTION_URL/api/health"
```

---

## Additional Resources

- [ARM Template Reference](https://learn.microsoft.com/azure/templates/)
- [Container Apps ARM API](https://learn.microsoft.com/azure/templates/microsoft.app/containerapps)
- [Bicep to ARM Conversion](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-cli)
- [Deployment Best Practices](https://learn.microsoft.com/azure/azure-resource-manager/templates/best-practices)
