#!/bin/bash
# Deploy Fluent Bit on Kind cluster to send events to Event Hub
#
# Prerequisites:
# - Event Hub namespace and hub created
# - Connection string available

set -e

echo "=== Fluent Bit Deployment for Kind Cluster ==="
echo ""

# Configuration - UPDATE THESE
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-YOUR-EVENTHUB-NAMESPACE}"
EVENTHUB_FQDN="${EVENTHUB_FQDN:-${EVENTHUB_NAMESPACE}.servicebus.windows.net}"
CLUSTER_NAME="${CLUSTER_NAME:-kind-local}"

echo "Event Hub Namespace: $EVENTHUB_NAMESPACE"
echo "Event Hub FQDN: $EVENTHUB_FQDN"
echo "Cluster Name: $CLUSTER_NAME"
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

# Create Event Hub secret
echo "Creating Event Hub secret..."
kubectl create secret generic eventhub-sas-secret \
  --namespace monitoring \
  --from-literal=connectionString="$EVENTHUB_CONNECTION_STRING" \
  --dry-run=client -o yaml | kubectl apply -f -

# Update ConfigMap with Event Hub details
echo "Updating Event Hub config..."
kubectl create configmap eventhub-config \
  --namespace monitoring \
  --from-literal=EVENTHUB_NAMESPACE="$EVENTHUB_NAMESPACE" \
  --from-literal=EVENTHUB_NAME="kube-events" \
  --from-literal=EVENTHUB_FQDN="$EVENTHUB_FQDN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply Fluent Bit config
echo "Applying Fluent Bit configuration..."
kubectl apply -f 01-fluent-bit-config.yaml

# Update deployment with cluster name
echo "Deploying Fluent Bit..."
cat 02-fluent-bit-deployment.yaml | \
  sed "s/value: \"kind-local\"/value: \"$CLUSTER_NAME\"/" | \
  kubectl apply -f -

echo ""
echo "Waiting for Fluent Bit to be ready..."
kubectl wait --for=condition=ready pod -l app=fluent-bit -n monitoring --timeout=60s

echo ""
echo "=== Fluent Bit Deployed Successfully ==="
echo ""
echo "To test, create a failing pod:"
echo "  kubectl run test-crash --image=invalid-image-xyz --restart=Never"
echo ""
echo "Check Fluent Bit logs:"
echo "  kubectl logs -n monitoring -l app=fluent-bit -f"
