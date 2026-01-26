#!/bin/bash
# Configure ASO Controller with Service Principal credentials
# Usage: ./02-configure-aso-credentials.sh <CLIENT_ID> <CLIENT_SECRET> <TENANT_ID>

set -e

# Configuration
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-133d5755-4074-4d6e-ad38-eb2a6ad12903}"
TENANT_ID="${3:-550cfcda-8a2d-452c-ba71-d6bc6bf5bb31}"
CLIENT_ID="${1}"
CLIENT_SECRET="${2}"

if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "Usage: $0 <CLIENT_ID> <CLIENT_SECRET> [TENANT_ID]"
  echo ""
  echo "Example: $0 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 'your-secret-here'"
  exit 1
fi

echo "Configuring ASO Controller credentials..."
echo "Subscription: $SUBSCRIPTION_ID"
echo "Tenant: $TENANT_ID"
echo "Client ID: $CLIENT_ID"
echo ""

# Check if ASO namespace exists
if ! kubectl get namespace azureserviceoperator-system &>/dev/null; then
  echo "ERROR: ASO namespace not found. Is ASO installed?"
  exit 1
fi

# Patch the ASO controller settings secret
kubectl patch secret aso-controller-settings \
  -n azureserviceoperator-system \
  --type merge \
  -p "{
    \"stringData\": {
      \"AZURE_SUBSCRIPTION_ID\": \"$SUBSCRIPTION_ID\",
      \"AZURE_TENANT_ID\": \"$TENANT_ID\",
      \"AZURE_CLIENT_ID\": \"$CLIENT_ID\",
      \"AZURE_CLIENT_SECRET\": \"$CLIENT_SECRET\"
    }
  }"

echo "Secret patched successfully."
echo ""

# Restart ASO controller to pick up new credentials
echo "Restarting ASO controller..."
kubectl rollout restart deployment -n azureserviceoperator-system azureserviceoperator-controller-manager

echo "Waiting for ASO controller to be ready..."
kubectl rollout status deployment -n azureserviceoperator-system azureserviceoperator-controller-manager --timeout=120s

echo ""
echo "ASO credentials configured successfully!"
echo ""
echo "Next steps:"
echo "1. Run: kubectl apply -f 03-resource-group.yaml"
echo "2. Verify: kubectl get resourcegroup -A"
