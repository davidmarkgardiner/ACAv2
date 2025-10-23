#!/bin/bash

# Deploy Azure Function App to Azure Container Apps using ZIP artifact
# Based on official Azure documentation for artifact deployment

set -e  # Exit on error

# Configuration variables
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-functionapp-aca}"
LOCATION="${LOCATION:-canadacentral}"
ENVIRONMENT="${ENVIRONMENT:-env-functionapp-aca}"
APP_NAME="${APP_NAME:-functionapp-api}"
ARTIFACT_PATH="./function-app.zip"
SUBSCRIPTION="${SUBSCRIPTION:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Azure Container Apps - Function App Artifact Deployment ===${NC}"
echo ""

# Validate artifact exists
if [ ! -f "$ARTIFACT_PATH" ]; then
    echo -e "${RED}Error: Artifact file not found at $ARTIFACT_PATH${NC}"
    echo "Run the build script first: ./build-artifact.sh"
    exit 1
fi

echo -e "${GREEN}✓ Found artifact:${NC} $ARTIFACT_PATH ($(ls -lh $ARTIFACT_PATH | awk '{print $5}'))"
echo ""

# Check if subscription is set
if [ -z "$SUBSCRIPTION" ]; then
    echo -e "${YELLOW}Warning: SUBSCRIPTION not set. Using default subscription.${NC}"
    echo "To set subscription, export SUBSCRIPTION=<your-subscription-id>"
    echo ""
fi

# Display configuration
echo -e "${GREEN}Deployment Configuration:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  Environment: $ENVIRONMENT"
echo "  App Name: $APP_NAME"
echo "  Artifact: $ARTIFACT_PATH"
[ -n "$SUBSCRIPTION" ] && echo "  Subscription: $SUBSCRIPTION"
echo ""

# Prompt for confirmation
read -p "Continue with deployment? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# Build deployment command
DEPLOY_CMD="az containerapp up \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --environment $ENVIRONMENT \
  --artifact $ARTIFACT_PATH \
  --ingress external \
  --target-port 80"

# Add subscription if provided
if [ -n "$SUBSCRIPTION" ]; then
    DEPLOY_CMD="$DEPLOY_CMD \
  --subscription $SUBSCRIPTION"
fi

echo -e "${GREEN}Executing deployment command...${NC}"
echo ""

# Execute deployment
eval $DEPLOY_CMD

# Check deployment status
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== Deployment Successful! ===${NC}"
    echo ""
    echo -e "${GREEN}Retrieving FQDN...${NC}"

    # Get FQDN
    FQDN_CMD="az containerapp show \
      --name $APP_NAME \
      --resource-group $RESOURCE_GROUP \
      --query properties.configuration.ingress.fqdn \
      --output tsv"

    [ -n "$SUBSCRIPTION" ] && FQDN_CMD="$FQDN_CMD --subscription $SUBSCRIPTION"

    FQDN=$(eval $FQDN_CMD)

    echo ""
    echo -e "${GREEN}Application Endpoints:${NC}"
    echo "  Health Check: https://$FQDN/api/health"
    echo "  Hello World:  https://$FQDN/api/hello"
    echo ""
    echo -e "${GREEN}Test with:${NC}"
    echo "  curl https://$FQDN/api/health"
    echo "  curl https://$FQDN/api/hello?name=YourName"
    echo ""
else
    echo ""
    echo -e "${RED}Deployment failed. Check the error messages above.${NC}"
    exit 1
fi
