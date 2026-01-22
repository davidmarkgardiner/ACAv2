#!/bin/bash
# Quick local test script for Argo Events Sensor
# Tests the pipeline WITHOUT Event Hub

set -e

NS=argo-events
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Local Sensor Test ==="
echo ""

# Check Argo Events controller is installed
echo "1. Checking prerequisites..."

if ! kubectl get deployment -n argo-events eventsource-controller &>/dev/null && \
   ! kubectl get deployment -n argo-events controller-manager &>/dev/null; then
    echo "ERROR: Argo Events controller not found!"
    echo "Install with: kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml"
    exit 1
fi
echo "   Argo Events controller: OK"

# Check if namespace exists
if ! kubectl get namespace $NS &>/dev/null; then
    echo "   Namespace $NS not found, creating..."
    kubectl apply -f "$SCRIPT_DIR/00-rbac.yaml"
    echo "   Waiting for EventBus to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l eventbus-name=default -n $NS --timeout=120s || true
fi

# Check EventBus
if ! kubectl get eventbus default -n $NS &>/dev/null; then
    echo "   EventBus not found, applying RBAC..."
    kubectl apply -f "$SCRIPT_DIR/00-rbac.yaml"
    echo "   Waiting for EventBus to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l eventbus-name=default -n $NS --timeout=120s || true
fi
echo "   EventBus: OK"

# Check RBAC
if ! kubectl auth can-i create workflows --as=system:serviceaccount:$NS:argo-events-sa -n $NS 2>/dev/null | grep -q "yes"; then
    echo "   RBAC not configured, applying..."
    kubectl apply -f "$SCRIPT_DIR/00-rbac.yaml"
fi
echo "   RBAC: OK"

# Deploy test resources
echo ""
echo "2. Deploying test EventSource and Sensor..."
kubectl apply -f "$SCRIPT_DIR/01-webhook-eventsource.yaml"
kubectl apply -f "$SCRIPT_DIR/02-test-sensor.yaml"

# Wait for pods
echo ""
echo "3. Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l eventsource-name=webhook-test -n $NS --timeout=60s
kubectl wait --for=condition=ready pod -l sensor-name=webhook-test-sensor -n $NS --timeout=60s
echo "   Pods ready!"

# Start port-forward in background
echo ""
echo "4. Starting port-forward..."
kubectl port-forward -n $NS svc/eventsource-webhook-svc 12000:12000 &
PF_PID=$!
sleep 3

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Send test event
echo ""
echo "5. Sending test event..."
RESPONSE=$(curl -s -X POST http://localhost:12000/test-k8s-event \
  -H "Content-Type: application/json" \
  -d @"$SCRIPT_DIR/test-payload.json")

echo "   Response: $RESPONSE"

# Wait for workflow
echo ""
echo "6. Waiting for workflow to complete..."
sleep 5

# Get workflow logs
echo ""
echo "7. Workflow output:"
echo "---"
WF=$(kubectl get workflows -n $NS -l purpose=local-testing --sort-by=.metadata.creationTimestamp -o name | tail -1)
if [ -n "$WF" ]; then
    kubectl logs -n $NS $WF --tail=50 2>/dev/null || echo "Waiting for logs..."

    # Check workflow status
    STATUS=$(kubectl get $WF -n $NS -o jsonpath='{.status.phase}')
    echo "---"
    echo ""
    echo "Workflow: $WF"
    echo "Status: $STATUS"

    if [ "$STATUS" == "Succeeded" ]; then
        echo ""
        echo "SUCCESS: Local pipeline test passed!"
    else
        echo ""
        echo "WARNING: Workflow status is $STATUS"
    fi
else
    echo "No workflow found yet. Check manually:"
    echo "  kubectl get workflows -n $NS"
fi

echo ""
echo "=== Test Complete ==="
