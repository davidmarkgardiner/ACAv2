#!/bin/bash
# deploy.sh - Deploy Function App using ARM template
# Usage: ./deploy.sh [dev|staging|prod]

set -e

# Get environment from argument or default to dev
ENVIRONMENT=${1:-dev}

# Configuration
RESOURCE_GROUP="rg-funcapp-${ENVIRONMENT}"
LOCATION="eastus"
TEMPLATE="function-app-deployment.json"
PARAMS="parameters-${ENVIRONMENT}.json"
DEPLOYMENT_NAME="funcapp-deployment-$(date +%Y%m%d-%H%M%S)"

echo "===================================="
echo "Function App ARM Template Deployment"
echo "===================================="
echo "Environment: $ENVIRONMENT"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "===================================="

# Check if logged in to Azure
echo ""
echo "Checking Azure login status..."
if ! az account show &> /dev/null; then
    echo "Not logged in. Please login to Azure:"
    az login
fi

# Display current subscription
SUBSCRIPTION=$(az account show --query name -o tsv)
echo "Using subscription: $SUBSCRIPTION"

# Create resource group if it doesn't exist
echo ""
echo "Ensuring resource group exists..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output none

echo "Resource group: $RESOURCE_GROUP (ready)"

# Validate template
echo ""
echo "Validating ARM template..."
VALIDATION_RESULT=$(az deployment group validate \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters @$PARAMS 2>&1)

if [ $? -ne 0 ]; then
    echo "❌ Template validation failed:"
    echo "$VALIDATION_RESULT"
    exit 1
fi

echo "✅ Template validation passed"

# Preview changes (What-If)
echo ""
read -p "Run What-If analysis? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Running What-If analysis..."
    az deployment group what-if \
      --resource-group $RESOURCE_GROUP \
      --template-file $TEMPLATE \
      --parameters @$PARAMS

    echo ""
    read -p "Proceed with deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled."
        exit 0
    fi
fi

# Deploy
echo ""
echo "Deploying ARM template..."
echo "Deployment name: $DEPLOYMENT_NAME"

az deployment group create \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --template-file $TEMPLATE \
  --parameters @$PARAMS \
  --output json > deployment-output.json

if [ $? -ne 0 ]; then
    echo "❌ Deployment failed!"
    exit 1
fi

echo "✅ Deployment completed successfully!"

# Get outputs
echo ""
echo "Retrieving deployment outputs..."

FUNCTION_URL=$(az deployment group show \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.functionAppUrl.value' \
  -o tsv)

HEALTH_URL=$(az deployment group show \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.healthCheckUrl.value' \
  -o tsv)

HELLO_URL=$(az deployment group show \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.helloWorldUrl.value' \
  -o tsv)

CONTAINER_APP=$(az deployment group show \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.outputs.containerAppName.value' \
  -o tsv)

# Display results
echo ""
echo "===================================="
echo "✅ Deployment Summary"
echo "===================================="
echo "Environment: $ENVIRONMENT"
echo "Resource Group: $RESOURCE_GROUP"
echo "Container App: $CONTAINER_APP"
echo ""
echo "📡 Endpoints:"
echo "  Base URL: $FUNCTION_URL"
echo "  Health: $HEALTH_URL"
echo "  Hello: $HELLO_URL"
echo ""
echo "🧪 Test Commands:"
echo "  curl $HEALTH_URL"
echo "  curl \"${HELLO_URL}?name=Test\""
echo ""
echo "📊 Monitor:"
echo "  az containerapp logs show --name $CONTAINER_APP --resource-group $RESOURCE_GROUP --follow"
echo ""
echo "🗑️  Cleanup:"
echo "  az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo "===================================="

# Test health endpoint
echo ""
read -p "Test health endpoint? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Testing health endpoint..."
    curl -s $HEALTH_URL | jq . || curl -s $HEALTH_URL
fi

# Save deployment info
cat > deployment-info-${ENVIRONMENT}.txt << EOF
Deployment Information
======================
Date: $(date)
Environment: $ENVIRONMENT
Resource Group: $RESOURCE_GROUP
Deployment Name: $DEPLOYMENT_NAME
Container App: $CONTAINER_APP

Endpoints
=========
Base URL: $FUNCTION_URL
Health Check: $HEALTH_URL
Hello World: $HELLO_URL

Test Commands
=============
curl $HEALTH_URL
curl "${HELLO_URL}?name=Test"
curl -w "%{time_total}\n" "${HELLO_URL}?name=Performance"

Monitor Logs
============
az containerapp logs show --name $CONTAINER_APP --resource-group $RESOURCE_GROUP --follow

Check Replicas
==============
az containerapp show --name $CONTAINER_APP --resource-group $RESOURCE_GROUP --query 'properties.runningStatus'

Cleanup
=======
az group delete --name $RESOURCE_GROUP --yes --no-wait
EOF

echo ""
echo "Deployment info saved to: deployment-info-${ENVIRONMENT}.txt"
