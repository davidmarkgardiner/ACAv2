#!/bin/bash
# Verify ASO is working correctly

set -e

echo "=== ASO Controller Status ==="
kubectl get pods -n azureserviceoperator-system
echo ""

echo "=== ASO Controller Settings (keys only) ==="
kubectl get secret aso-controller-settings -n azureserviceoperator-system -o jsonpath='{.data}' | jq -r 'keys[]'
echo ""

echo "=== ResourceGroups ==="
kubectl get resourcegroup -A 2>/dev/null || echo "No ResourceGroups found"
echo ""

echo "=== ManagedClusters ==="
kubectl get managedcluster -A 2>/dev/null || echo "No ManagedClusters found"
echo ""

# Check if we can verify in Azure
echo "=== Azure Resource Group Check ==="
az group show --name at39473-weu-dev-public --query "{name:name, location:location, state:properties.provisioningState}" -o table 2>/dev/null || echo "ResourceGroup not found in Azure (may not be created yet)"
