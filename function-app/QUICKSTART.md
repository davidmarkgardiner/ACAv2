# Quick Start Guide - 5 Minutes to Deploy

## Prerequisites

✅ [Azure CLI](https://aka.ms/azure-cli) installed
✅ [Docker](https://www.docker.com/) installed
✅ Azure subscription

## One-Command Deploy

```bash
cd function-app && ./deploy.sh
```

## Manual Deploy (if you prefer)

### 1. Set Variables

```bash
ACR_NAME="myregistry"              # Your ACR name (must be unique)
RESOURCE_GROUP="rg-funcapp-dev"
LOCATION="eastus"
```

### 2. Create & Build

```bash
# Create resources
az group create --name $RESOURCE_GROUP --location $LOCATION
az acr create --name $ACR_NAME --resource-group $RESOURCE_GROUP --sku Basic

# Build & push
az acr login --name $ACR_NAME
docker build -t $ACR_NAME.azurecr.io/function-app:latest .
docker push $ACR_NAME.azurecr.io/function-app:latest
```

### 3. Deploy

```bash
# Update parameter file first:
# Edit ../bicep/parameters/function-app-dev.bicepparam
# Replace <YOUR_REGISTRY> with your ACR name

az deployment group create \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --template-file ../bicep/templates/function-app-deployment.bicep \
  --parameters ../bicep/parameters/function-app-dev.bicepparam \
  --parameters containerImage=$ACR_NAME.azurecr.io/function-app:latest
```

### 4. Test

```bash
# Get URL
URL=$(az deployment group show \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --query properties.outputs.functionAppUrl.value -o tsv)

# Test it
curl "$URL/api/hello?name=World"
```

## What You Get

- ✅ HTTP-triggered Azure Function
- ✅ Scales to zero when not in use
- ✅ Scales up automatically on requests
- ✅ Health check endpoint at `/api/health`
- ✅ Hello World endpoint at `/api/hello`

## Verify Scale-to-Zero

```bash
# Wait 2-3 minutes without requests
# Then check replica count
az containerapp revision list \
  --name funcapp-ca-dev \
  --resource-group $RESOURCE_GROUP \
  --query "[0].properties.replicas"

# Should return 0
```

## Cleanup

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

## Need Help?

See [README.md](./README.md) for detailed documentation.
