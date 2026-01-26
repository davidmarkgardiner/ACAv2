#!/bin/bash
# Create Service Principal for Azure Service Operator
# Run this script ONCE to create the SP credentials

set -e

# Configuration
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-133d5755-4074-4d6e-ad38-eb2a6ad12903}"
SP_NAME="aso-kind-cluster-sp"

echo "Creating Service Principal: $SP_NAME"
echo "Subscription: $SUBSCRIPTION_ID"
echo ""

# Create Service Principal with Contributor role
SP_OUTPUT=$(az ad sp create-for-rbac \
  --name "$SP_NAME" \
  --role Contributor \
  --scopes "/subscriptions/$SUBSCRIPTION_ID" \
  --output json)

echo "Service Principal created successfully!"
echo ""
echo "=== SAVE THESE VALUES ==="
echo ""
echo "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
echo "AZURE_TENANT_ID=$(echo $SP_OUTPUT | jq -r '.tenant')"
echo "AZURE_CLIENT_ID=$(echo $SP_OUTPUT | jq -r '.appId')"
echo "AZURE_CLIENT_SECRET=$(echo $SP_OUTPUT | jq -r '.password')"
echo ""
echo "=== END VALUES ==="
echo ""
echo "Next steps:"
echo "1. Save the values above securely"
echo "2. Run: ./02-configure-aso-credentials.sh <CLIENT_ID> <CLIENT_SECRET> <TENANT_ID>"
