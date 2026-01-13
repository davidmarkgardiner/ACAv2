#!/bin/bash
# Service Connectivity Test Script
# Usage: ./service-connectivity-test.sh <namespace> <service-name> [port]

set -euo pipefail

NAMESPACE="${1:-}"
SERVICE_NAME="${2:-}"
PORT="${3:-}"

if [[ -z "$NAMESPACE" || -z "$SERVICE_NAME" ]]; then
    echo "Usage: $0 <namespace> <service-name> [port]"
    exit 1
fi

echo "============================================"
echo "Service Connectivity Test"
echo "Service: $SERVICE_NAME"
echo "Namespace: $NAMESPACE"
echo "============================================"
echo ""

# Check service exists
echo "## Service Configuration"
echo "----------------------------------------"
SVC_OUTPUT=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o wide 2>/dev/null)
if [[ -z "$SVC_OUTPUT" ]]; then
    echo "ERROR: Service '$SERVICE_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi
echo "$SVC_OUTPUT"
echo ""

# Get service details
SVC_TYPE=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
SVC_CLUSTER_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
SVC_PORTS=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[*].port}')

echo "Type: $SVC_TYPE"
echo "Cluster IP: $SVC_CLUSTER_IP"
echo "Ports: $SVC_PORTS"
echo ""

# Check endpoints
echo "## Endpoints"
echo "----------------------------------------"
ENDPOINTS=$(kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
if [[ -z "$ENDPOINTS" ]]; then
    echo "WARNING: No endpoints found for service"
    echo ""
    echo "Checking selector..."
    SELECTOR=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector}')
    echo "Service selector: $SELECTOR"

    echo ""
    echo "Pods matching selector:"
    kubectl get pods -n "$NAMESPACE" -l "$(echo "$SELECTOR" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')" 2>/dev/null || echo "Could not find matching pods"
else
    echo "Endpoints: $ENDPOINTS"
fi
echo ""

# Test connectivity from within cluster
echo "## Connectivity Test"
echo "----------------------------------------"
if [[ -z "$PORT" ]]; then
    PORT=$(echo "$SVC_PORTS" | awk '{print $1}')
fi

echo "Testing connection to $SERVICE_NAME:$PORT..."
kubectl run conn-test-$$ --image=curlimages/curl --rm -it --restart=Never -n "$NAMESPACE" \
    -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
    "http://$SERVICE_NAME.$NAMESPACE.svc.cluster.local:$PORT" --connect-timeout 5 2>/dev/null || echo "Connection test failed"
echo ""

# DNS Resolution
echo "## DNS Resolution"
echo "----------------------------------------"
kubectl run dns-test-$$ --image=busybox --rm -it --restart=Never -n "$NAMESPACE" \
    -- nslookup "$SERVICE_NAME.$NAMESPACE.svc.cluster.local" 2>/dev/null || echo "DNS resolution failed"
echo ""

echo "============================================"
echo "Service connectivity test complete"
echo "============================================"
