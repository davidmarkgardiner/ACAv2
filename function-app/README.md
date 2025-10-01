# Azure Functions on Container Apps - Scale-to-Zero

A simple HTTP-triggered Azure Function deployed to Azure Container Apps with automatic scale-to-zero capability.

## 📁 Project Structure

```
function-app/
├── function_app.py         # Azure Function code with HTTP triggers
├── requirements.txt        # Python dependencies
├── host.json              # Azure Functions host configuration
├── Dockerfile             # Container image definition
├── .dockerignore          # Docker build exclusions
├── deploy.sh              # Automated deployment script
└── README.md              # This file
```

## 🚀 Quick Start (Automated)

The easiest way to deploy:

```bash
cd function-app
./deploy.sh
```

The script will:
1. Build the Docker image
2. Push to Azure Container Registry
3. Deploy infrastructure via Bicep
4. Show you the function URLs

## 📋 Manual Deployment

### Prerequisites

- [Azure CLI](https://aka.ms/azure-cli) installed
- [Docker](https://www.docker.com/products/docker-desktop) installed
- Azure subscription
- Azure Container Registry (or create one)

### Step 1: Create Azure Resources

```bash
# Login to Azure
az login

# Set variables
RESOURCE_GROUP="rg-funcapp-dev"
LOCATION="eastus"
ACR_NAME="<your-registry-name>"  # Must be globally unique

# Create resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Create Azure Container Registry (if you don't have one)
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --location $LOCATION
```

### Step 2: Build and Push Container Image

```bash
# Navigate to function app directory
cd function-app

# Login to ACR
az acr login --name $ACR_NAME

# Build image
docker build -t $ACR_NAME.azurecr.io/function-app:latest .

# Push image to ACR
docker push $ACR_NAME.azurecr.io/function-app:latest

# Verify image
az acr repository list --name $ACR_NAME --output table
```

### Step 3: Deploy with Bicep

```bash
# Update the parameter file with your registry name
# Edit: ../bicep/parameters/function-app-dev.bicepparam
# Change: <YOUR_REGISTRY>.azurecr.io/function-app:latest
# To: youracr.azurecr.io/function-app:latest

# Deploy infrastructure
az deployment group create \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --template-file ../bicep/templates/function-app-deployment.bicep \
  --parameters ../bicep/parameters/function-app-dev.bicepparam \
  --parameters location=$LOCATION \
  --parameters containerImage=$ACR_NAME.azurecr.io/function-app:latest
```

### Step 4: Get Function URLs

```bash
# Get deployment outputs
FUNCTION_URL=$(az deployment group show \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --query properties.outputs.functionAppUrl.value \
  -o tsv)

echo "Function App URL: $FUNCTION_URL"
echo "Health Check: $FUNCTION_URL/api/health"
echo "Hello World: $FUNCTION_URL/api/hello"
```

## 🧪 Testing the Function

### Health Check Endpoint

```bash
curl https://<your-app>.azurecontainerapps.io/api/health
```

Expected response:
```json
{
  "status": "healthy",
  "timestamp": "2025-10-02T12:00:00.000000"
}
```

### Hello World Endpoint

Basic request:
```bash
curl https://<your-app>.azurecontainerapps.io/api/hello
```

With name parameter:
```bash
curl "https://<your-app>.azurecontainerapps.io/api/hello?name=Azure"
```

POST request with JSON:
```bash
curl -X POST https://<your-app>.azurecontainerapps.io/api/hello \
  -H "Content-Type: application/json" \
  -d '{"name":"Container Apps"}'
```

Expected response:
```json
{
  "message": "Hello, Azure! This function scaled from zero to serve your request.",
  "timestamp": "2025-10-02T12:00:00.000000",
  "scaled_from_zero": true
}
```

## 📊 Monitoring Scale-to-Zero

### View Container App Status

```bash
# Get container app name
CONTAINER_APP=$(az deployment group show \
  --name funcapp-deployment \
  --resource-group $RESOURCE_GROUP \
  --query properties.outputs.containerAppName.value \
  -o tsv)

# Check current replica count
az containerapp revision list \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query "[0].properties.replicas" \
  -o tsv
```

### View Logs

```bash
# Stream logs
az containerapp logs show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --follow

# Or view in Azure Portal
# Navigate to: Container Apps > Your App > Monitoring > Log stream
```

### Test Scale-to-Zero Behavior

1. Wait 2-3 minutes after last request
2. Check replica count (should be 0)
3. Send a new request
4. Check replica count again (should scale up to 1)

```bash
# Check replicas
watch -n 5 "az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query properties.runningStatus"
```

## 🏗️ Architecture

### Components

- **Azure Functions Runtime**: Python 3.11 with Azure Functions v4
- **Container Apps**: Serverless container platform
- **Scale-to-Zero**: Automatic scaling from 0 to 10 replicas
- **HTTP Scaling**: Triggers based on concurrent requests (10 per replica)
- **Log Analytics**: Centralized logging and monitoring

### Resource Specifications

- **CPU**: 0.25 cores
- **Memory**: 0.5 GB
- **Min Replicas**: 0 (scale-to-zero)
- **Max Replicas**: 10
- **Target Port**: 80 (Azure Functions default)

### Scaling Configuration

```yaml
Scaling Rule: HTTP Concurrent Requests
Trigger: 10 concurrent requests per replica
Scale Up: Provisions new replica when threshold exceeded
Scale Down: Removes replicas when requests drop
Scale to Zero: After ~2 minutes of no traffic
```

## 🔧 Customization

### Change Function Code

Edit `function_app.py` and add new routes:

```python
@app.route(route="myfunction")
def my_function(req: func.HttpRequest) -> func.HttpResponse:
    # Your code here
    return func.HttpResponse("Hello from my function!")
```

Then rebuild and redeploy:
```bash
./deploy.sh
```

### Adjust Scaling Parameters

Edit `../bicep/parameters/function-app-dev.bicepparam`:

```bicep
param minReplicas = 0      // Keep at 0 for scale-to-zero
param maxReplicas = 20     // Increase max scale
param cpu = '0.5'          // More CPU per instance
param memory = '1Gi'       // More memory per instance
```

### Change Scaling Rules

Edit `../bicep/templates/function-app-deployment.bicep`:

```bicep
scalingRules: [
  {
    name: 'http-scaling-rule'
    http: {
      metadata: {
        concurrentRequests: '5'  // Scale faster
      }
    }
  }
]
```

## 🛠️ Troubleshooting

### Image Pull Errors

Ensure Container App has access to ACR:

```bash
# Grant ACR pull access to Container App managed identity
CONTAINER_APP_PRINCIPAL=$(az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query identity.principalId \
  -o tsv)

ACR_ID=$(az acr show --name $ACR_NAME --query id -o tsv)

az role assignment create \
  --assignee $CONTAINER_APP_PRINCIPAL \
  --role AcrPull \
  --scope $ACR_ID
```

### Function Not Responding

Check logs for errors:

```bash
az containerapp logs show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --tail 50
```

### Slow Cold Start

First request after scale-to-zero takes ~10-30 seconds:
- This is expected behavior
- Consider using warmup requests for production
- Or set `minReplicas = 1` to keep one instance running

## 📚 Additional Resources

- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)
- [Azure Functions Documentation](https://learn.microsoft.com/azure/azure-functions/)
- [Scale-to-Zero Configuration](https://learn.microsoft.com/azure/container-apps/scale-app)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)

## 🧹 Cleanup

To delete all resources:

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

## 📝 Notes

- **Cost**: With scale-to-zero, you only pay when the function is running
- **Cold Start**: First request after scaling from zero takes longer (~10-30s)
- **Health Probes**: `/api/health` endpoint for Container Apps health checks
- **Logs**: Sent to Log Analytics workspace for 30-day retention
- **Security**: Uses managed identity for ACR authentication
