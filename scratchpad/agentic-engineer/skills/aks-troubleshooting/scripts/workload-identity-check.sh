#!/bin/bash
# Workload Identity Configuration Checker
# Usage: ./workload-identity-check.sh <namespace> <service-account>

set -euo pipefail

NAMESPACE="${1:-}"
SERVICE_ACCOUNT="${2:-}"

if [[ -z "$NAMESPACE" || -z "$SERVICE_ACCOUNT" ]]; then
    echo "Usage: $0 <namespace> <service-account>"
    exit 1
fi

echo "============================================"
echo "Workload Identity Check"
echo "Namespace: $NAMESPACE"
echo "Service Account: $SERVICE_ACCOUNT"
echo "============================================"
echo ""

# Check if service account exists
echo "## Service Account Configuration"
echo "----------------------------------------"
SA_OUTPUT=$(kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o yaml 2>/dev/null)
if [[ -z "$SA_OUTPUT" ]]; then
    echo "ERROR: Service account '$SERVICE_ACCOUNT' not found in namespace '$NAMESPACE'"
    exit 1
fi

echo "$SA_OUTPUT"
echo ""

# Check for required annotations
echo "## Workload Identity Annotations"
echo "----------------------------------------"
CLIENT_ID=$(kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null)
TENANT_ID=$(kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.azure\.workload\.identity/tenant-id}' 2>/dev/null)

if [[ -z "$CLIENT_ID" ]]; then
    echo "WARNING: Missing annotation 'azure.workload.identity/client-id'"
else
    echo "Client ID: $CLIENT_ID"
fi

if [[ -z "$TENANT_ID" ]]; then
    echo "INFO: Tenant ID annotation not set (using default)"
else
    echo "Tenant ID: $TENANT_ID"
fi
echo ""

# Check webhook pods
echo "## Azure Workload Identity Webhook Status"
echo "----------------------------------------"
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true -o wide 2>/dev/null || echo "Webhook pods not found"
echo ""

# Find pods using this service account
echo "## Pods Using This Service Account"
echo "----------------------------------------"
PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[?(@.spec.serviceAccountName=="'"$SERVICE_ACCOUNT"'")]}{.metadata.name}{"\n"}{end}')
if [[ -z "$PODS" ]]; then
    echo "No pods found using service account '$SERVICE_ACCOUNT'"
else
    echo "$PODS"
    echo ""

    # Check first pod for token projection
    FIRST_POD=$(echo "$PODS" | head -1)
    echo "## Token Projection Check (Pod: $FIRST_POD)"
    echo "----------------------------------------"

    # Check for projected token volume
    TOKEN_PATH=$(kubectl get pod "$FIRST_POD" -n "$NAMESPACE" -o jsonpath='{.spec.volumes[?(@.name=="azure-identity-token")]}' 2>/dev/null)
    if [[ -z "$TOKEN_PATH" ]]; then
        echo "WARNING: No 'azure-identity-token' volume found"
        echo "Pod may not have workload identity configured correctly"
    else
        echo "Token volume configured: YES"

        # Try to check if token exists
        kubectl exec "$FIRST_POD" -n "$NAMESPACE" -- ls -la /var/run/secrets/azure/tokens/ 2>/dev/null || echo "Could not check token path (pod may not be running)"
    fi

    # Check environment variables
    echo ""
    echo "## Environment Variables"
    echo "----------------------------------------"
    kubectl get pod "$FIRST_POD" -n "$NAMESPACE" -o jsonpath='{range .spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}' | grep -E "AZURE|IDENTITY" || echo "No Azure/Identity env vars found"
fi

echo ""
echo "============================================"
echo "Workload Identity check complete"
echo "============================================"
