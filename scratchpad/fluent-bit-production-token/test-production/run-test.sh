#!/bin/bash
# Production Test Script
# Tests the full pipeline: Webhook -> Sensor -> Holmes -> GitLab
#
# Prerequisites:
#   - Argo Events controller installed
#   - GitLab PAT configured in 01-secrets.yaml
#

set -e

NS=argo-events
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "Production Pipeline Test"
echo "Webhook -> Sensor -> Holmes -> GitLab"
echo "=============================================="
echo ""

# Check Argo Events controller
echo "1. Checking prerequisites..."

if ! kubectl get deployment -n argo-events eventsource-controller &>/dev/null && \
   ! kubectl get deployment -n argo-events controller-manager &>/dev/null; then
    echo "   ERROR: Argo Events controller not found!"
    echo "   Install with: kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml"
    exit 1
fi
echo "   Argo Events controller: OK"

# Apply RBAC if needed
if ! kubectl get namespace $NS &>/dev/null; then
    echo "   Namespace $NS not found, creating..."
    kubectl apply -f "$SCRIPT_DIR/00-rbac.yaml"
    echo "   Waiting for EventBus to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l eventbus-name=default -n $NS --timeout=120s || true
fi

if ! kubectl get eventbus default -n $NS &>/dev/null; then
    echo "   EventBus not found, applying RBAC..."
    kubectl apply -f "$SCRIPT_DIR/00-rbac.yaml"
    echo "   Waiting for EventBus to be ready..."
    sleep 10
    kubectl wait --for=condition=ready pod -l eventbus-name=default -n $NS --timeout=120s || true
fi
echo "   EventBus: OK"

# Check/apply secrets
echo ""
echo "2. Checking secrets..."

if ! kubectl get secret gitlab-mcp-secret -n $NS &>/dev/null; then
    echo "   WARNING: GitLab secret not found!"
    echo "   Please edit 01-secrets.yaml with your GitLab PAT and apply:"
    echo "   kubectl apply -f 01-secrets.yaml"
    echo ""
    read -p "   Continue without GitLab integration? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    # Check if it's a placeholder
    TOKEN=$(kubectl get secret gitlab-mcp-secret -n $NS -o jsonpath='{.data.GITLAB_PERSONAL_ACCESS_TOKEN}' | base64 -d)
    if [ "$TOKEN" = "<YOUR_GITLAB_PAT>" ]; then
        echo "   WARNING: GitLab PAT is still placeholder!"
        echo "   Edit 01-secrets.yaml and apply to create real issues"
    else
        echo "   GitLab secret: OK"
    fi
fi

# Apply workflow template
echo ""
echo "3. Deploying workflow template..."
kubectl apply -f "$SCRIPT_DIR/02-workflow-template.yaml"
echo "   WorkflowTemplate: OK"

# Apply test resources
echo ""
echo "4. Deploying test EventSource and Sensor..."
kubectl apply -f "$SCRIPT_DIR/03-webhook-eventsource.yaml"
kubectl apply -f "$SCRIPT_DIR/04-sensor-production-test.yaml"

# Wait for pods
echo ""
echo "5. Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l eventsource-name=webhook-prod-test -n $NS --timeout=60s
kubectl wait --for=condition=ready pod -l sensor-name=prod-test-gitlab-issues -n $NS --timeout=60s
echo "   Pods ready!"

# Start port-forward in background
echo ""
echo "6. Starting port-forward..."
kubectl port-forward -n $NS svc/webhook-prod-test-svc 12000:12000 &
PF_PID=$!
sleep 3

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up port-forward..."
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Send test event
echo ""
echo "7. Sending test event (Event Hub format with base64 body)..."
echo "   Payload: test-payload-eventhub.json"
RESPONSE=$(curl -s -X POST http://localhost:12000/k8s-event \
  -H "Content-Type: application/json" \
  -d @"$SCRIPT_DIR/test-payload-eventhub.json")

echo "   Response: $RESPONSE"

# Wait for workflows
echo ""
echo "8. Waiting for workflows to start..."
sleep 5

# Show workflow status
echo ""
echo "9. Workflow status:"
echo "---"
kubectl get workflows -n $NS -l purpose=production-testing --sort-by=.metadata.creationTimestamp | tail -5

# Get the main triage workflow (not debug)
echo ""
echo "10. Checking triage workflow..."
TRIAGE_WF=$(kubectl get workflows -n $NS -l purpose=production-testing -o name 2>/dev/null | grep -v debug | tail -1)

if [ -n "$TRIAGE_WF" ]; then
    echo "    Workflow: $TRIAGE_WF"

    # Wait for completion (max 3 minutes for Holmes)
    echo "    Waiting for completion (this may take a few minutes if Holmes is processing)..."
    kubectl wait --for=condition=Completed $TRIAGE_WF -n $NS --timeout=300s 2>/dev/null || true

    STATUS=$(kubectl get $TRIAGE_WF -n $NS -o jsonpath='{.status.phase}')
    echo "    Status: $STATUS"

    if [ "$STATUS" = "Succeeded" ]; then
        echo ""
        echo "=============================================="
        echo "SUCCESS: Production pipeline test passed!"
        echo "=============================================="
        echo ""
        echo "Check your GitLab project for the new issue:"
        echo "  https://gitlab.com/markgardiner/mcp-test-repo/-/issues"
        echo ""
        echo "Workflow logs:"
        kubectl logs -n $NS $TRIAGE_WF --all-containers 2>/dev/null | tail -30
    else
        echo ""
        echo "Workflow did not succeed. Checking logs..."
        kubectl logs -n $NS $TRIAGE_WF --all-containers 2>/dev/null | tail -50
    fi
else
    echo "    No triage workflow found yet."
    echo "    Check manually: kubectl get workflows -n $NS"
fi

echo ""
echo "=============================================="
echo "Test Complete"
echo "=============================================="
