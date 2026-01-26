#!/bin/bash
# Deploy Grafana Alloy on Kind cluster to send events to Event Hub
#
# Replaces Fluent Bit for Kubernetes events collection
#
# Prerequisites:
# - Event Hub namespace and hub created
# - Connection string available
# - kubectl configured to target cluster
#
# Usage:
#   export EVENTHUB_CONNECTION_STRING='Endpoint=sb://...'
#   export CLUSTER_NAME='kind-local'
#   ./deploy-alloy.sh
#
# For test mode (use separate Event Hub topic):
#   export TEST_MODE=true
#   ./deploy-alloy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Grafana Alloy Deployment for Kind Cluster ==="
echo ""

# Configuration - can be overridden via environment variables
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-k8s-events-hub-4808}"
EVENTHUB_FQDN="${EVENTHUB_FQDN:-${EVENTHUB_NAMESPACE}.servicebus.windows.net}"
CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"
CLUSTER_REGION="${CLUSTER_REGION:-local}"
CLUSTER_ENVIRONMENT="${CLUSTER_ENVIRONMENT:-dev}"
WATCH_NAMESPACES="${WATCH_NAMESPACES:-dg-demo}"

# Use test topic if TEST_MODE is set
if [ "$TEST_MODE" = "true" ]; then
  EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events-alloy}"
  echo "TEST MODE: Using test Event Hub topic: $EVENTHUB_NAME"
else
  EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events}"
fi

echo "Configuration:"
echo "  Event Hub Namespace: $EVENTHUB_NAMESPACE"
echo "  Event Hub FQDN:      $EVENTHUB_FQDN"
echo "  Event Hub Topic:     $EVENTHUB_NAME"
echo "  Cluster Name:        $CLUSTER_NAME"
echo "  Cluster Region:      $CLUSTER_REGION"
echo "  Cluster Environment: $CLUSTER_ENVIRONMENT"
echo "  Watch Namespaces:    $WATCH_NAMESPACES"
echo ""

# Create namespace
echo "Creating monitoring namespace..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Check for connection string
if [ -z "$EVENTHUB_CONNECTION_STRING" ]; then
  echo ""
  echo "ERROR: EVENTHUB_CONNECTION_STRING environment variable not set"
  echo ""
  echo "Set it with:"
  echo "  export EVENTHUB_CONNECTION_STRING='Endpoint=sb://...'"
  echo ""
  echo "Or get it from Azure:"
  echo "  az eventhubs namespace authorization-rule keys list \\"
  echo "    --resource-group <RG> \\"
  echo "    --namespace-name ${EVENTHUB_NAMESPACE} \\"
  echo "    --name RootManageSharedAccessKey \\"
  echo "    --query primaryConnectionString -o tsv"
  exit 1
fi

# Create Event Hub secret (reuses same secret name as Fluent Bit for compatibility)
echo "Creating Event Hub secret..."
kubectl create secret generic eventhub-sas-secret \
  --namespace monitoring \
  --from-literal=connectionString="$EVENTHUB_CONNECTION_STRING" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create/Update Event Hub config
echo "Creating Event Hub config..."
kubectl create configmap alloy-eventhub-config \
  --namespace monitoring \
  --from-literal=EVENTHUB_NAMESPACE="$EVENTHUB_NAMESPACE" \
  --from-literal=EVENTHUB_NAME="$EVENTHUB_NAME" \
  --from-literal=EVENTHUB_FQDN="$EVENTHUB_FQDN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Convert comma-separated namespaces to River array format
# e.g., "dg-demo,production" -> ["dg-demo", "production"]
NAMESPACES_ARRAY=$(echo "$WATCH_NAMESPACES" | sed 's/,/", "/g' | sed 's/^/["/' | sed 's/$/"]/')
echo "Namespaces array: $NAMESPACES_ARRAY"

# Apply Alloy configuration with namespace substitution
echo "Applying Alloy configuration..."
cat "$SCRIPT_DIR/01-alloy-config.yaml" | \
  sed "s/namespaces = \[\"dg-demo\"\]/namespaces = $NAMESPACES_ARRAY/" | \
  kubectl apply -f -

# Apply deployment with variable substitution
echo "Deploying Alloy..."
cat "$SCRIPT_DIR/02-alloy-deployment.yaml" | \
  sed "s/value: \"kind-local\"/value: \"$CLUSTER_NAME\"/" | \
  sed "s/value: \"local\"/value: \"$CLUSTER_REGION\"/" | \
  sed "s/value: \"dev\"/value: \"$CLUSTER_ENVIRONMENT\"/" | \
  sed "s/value: \"dg-demo\"/value: \"$WATCH_NAMESPACES\"/" | \
  kubectl apply -f -

echo ""
echo "Waiting for Alloy to be ready..."
kubectl wait --for=condition=ready pod -l app=alloy-events -n monitoring --timeout=120s

echo ""
echo "=== Grafana Alloy Deployed Successfully ==="
echo ""
echo "Alloy is now watching namespaces: $WATCH_NAMESPACES"
echo "Events will be sent to Event Hub: $EVENTHUB_NAME"
echo ""
echo "To test, create a failing pod in a watched namespace:"
echo "  kubectl create namespace dg-demo --dry-run=client -o yaml | kubectl apply -f -"
echo "  kubectl run test-crash -n dg-demo --image=invalid-image-xyz --restart=Never"
echo ""
echo "Check Alloy logs:"
echo "  kubectl logs -n monitoring -l app=alloy-events -f"
echo ""
echo "Access Alloy UI (port-forward):"
echo "  kubectl port-forward -n monitoring svc/alloy-events 12345:12345"
echo "  Open: http://localhost:12345"
echo ""
echo "View component status:"
echo "  kubectl exec -n monitoring deploy/alloy-events -- wget -qO- http://localhost:12345/api/v0/web/components"
