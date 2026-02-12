#!/bin/bash

# Test the Prometheus Alerting -> Argo Events triage pipeline
# Supports webhook tests, synthetic failure pods, verification, and cleanup.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

TEST_LABEL="prometheus-alerting-test=true"
TEST_NAMESPACE="default"

# --- Webhook test ---

webhook_test() {
    log_info "Sending mock AlertManager payload to EventSource webhook..."
    echo ""
    log_warn "Ensure port-forward is running first:"
    echo "  kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000"
    echo ""

    PAYLOAD='{
  "version": "4",
  "groupKey": "{}:{alertname=\"TestAlert\"}",
  "status": "firing",
  "receiver": "argo-events-webhook",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning",
      "namespace": "default",
      "pod": "test-pod-123"
    },
    "annotations": {
      "summary": "Test alert from test-alerts.sh",
      "description": "This is a pipeline validation test alert"
    },
    "startsAt": "2024-01-01T00:00:00.000Z",
    "endsAt": "0001-01-01T00:00:00Z",
    "generatorURL": "http://prometheus:9090/graph"
  }],
  "commonLabels": {"alertname": "TestAlert", "severity": "warning"},
  "commonAnnotations": {"summary": "Test alert from test-alerts.sh"},
  "externalURL": "http://alertmanager:9093"
}'

    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST http://localhost:12000/alerts \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>/dev/null) || true

    if [ "$RESPONSE" = "200" ]; then
        log_info "Webhook returned HTTP 200 - alert accepted."
    elif [ -z "$RESPONSE" ] || [ "$RESPONSE" = "000" ]; then
        log_error "Could not connect to localhost:12000. Is the port-forward running?"
        echo "  kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000"
        return 1
    else
        log_warn "Webhook returned HTTP $RESPONSE"
    fi
}

# --- Create failing test pods ---

create_oom_pod() {
    log_info "Creating OOMKill test pod in namespace '$TEST_NAMESPACE'..."
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-oomkill
  namespace: default
  labels:
    prometheus-alerting-test: "true"
    test-type: oomkill
spec:
  restartPolicy: Never
  containers:
    - name: oom-trigger
      image: polinux/stress
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "256M", "--vm-hang", "0"]
      resources:
        limits:
          memory: "10Mi"
EOF
    log_info "OOMKill test pod created. It will be killed shortly due to memory limit."
}

create_crashloop_pod() {
    log_info "Creating CrashLoopBackOff test pod in namespace '$TEST_NAMESPACE'..."
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-crashloop
  namespace: default
  labels:
    prometheus-alerting-test: "true"
    test-type: crashloop
spec:
  restartPolicy: Always
  containers:
    - name: crash
      image: busybox:latest
      command: ["sh", "-c", "echo 'Starting...'; sleep 2; exit 1"]
EOF
    log_info "CrashLoop test pod created. It will start crash-looping after ~2s."
}

create_imagepull_pod() {
    log_info "Creating ImagePullBackOff test pod in namespace '$TEST_NAMESPACE'..."
    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-imagepull
  namespace: default
  labels:
    prometheus-alerting-test: "true"
    test-type: imagepull
spec:
  restartPolicy: Never
  containers:
    - name: bad-image
      image: registry.invalid/does-not-exist:latest
EOF
    log_info "ImagePull test pod created. It will fail to pull the image."
}

# --- Verify triage workflows ---

verify() {
    log_info "Checking for triage workflows triggered by alerts..."
    echo ""

    WORKFLOWS=$(kubectl get workflows -n argo-events -l event-type=prometheus-alert --no-headers 2>/dev/null)
    if [ -n "$WORKFLOWS" ]; then
        log_info "Found triage workflows:"
        kubectl get workflows -n argo-events -l event-type=prometheus-alert
    else
        log_warn "No triage workflows found yet."
        echo "  Alerts may take a few minutes to fire and trigger workflows."
        echo "  Re-run with: $0 --verify"
    fi
    echo ""

    log_info "Test pods status:"
    kubectl get pods -n "$TEST_NAMESPACE" -l "$TEST_LABEL" 2>/dev/null || log_warn "No test pods found."
}

# --- Cleanup ---

cleanup() {
    log_info "Cleaning up test resources..."

    log_info "Deleting test pods..."
    kubectl delete pods -n "$TEST_NAMESPACE" -l "$TEST_LABEL" --ignore-not-found
    log_info "Test pods deleted."

    log_info "Deleting test triage workflows..."
    kubectl delete workflows -n argo-events -l event-type=prometheus-alert --ignore-not-found
    log_info "Test workflows deleted."

    log_info "Cleanup complete."
}

# --- Full test sequence ---

run_all() {
    log_info "=== Running full test sequence ==="
    echo ""

    webhook_test
    echo ""

    create_oom_pod
    create_crashloop_pod
    create_imagepull_pod
    echo ""

    log_info "Waiting 60s for alerts to fire and workflows to trigger..."
    sleep 60

    verify
}

# --- Usage ---

usage() {
    echo "Usage: $0 <mode>"
    echo ""
    echo "Test modes:"
    echo "  --webhook-test      Send a mock AlertManager payload to the EventSource webhook"
    echo "  --create-oom        Create a pod that will be OOMKilled"
    echo "  --create-crashloop  Create a pod that will CrashLoopBackOff"
    echo "  --create-imagepull  Create a pod with an invalid image (ImagePullBackOff)"
    echo "  --verify            Check for triggered triage workflows"
    echo "  --cleanup           Remove test pods and workflows"
    echo "  --all               Run full test sequence (webhook + failing pods + wait + verify)"
    echo ""
    echo "Port-forward helper (run in a separate terminal):"
    echo "  kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000"
}

# --- Main ---

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

case "$1" in
    --webhook-test)  webhook_test ;;
    --create-oom)    create_oom_pod ;;
    --create-crashloop) create_crashloop_pod ;;
    --create-imagepull) create_imagepull_pod ;;
    --verify)        verify ;;
    --cleanup)       cleanup ;;
    --all)           run_all ;;
    *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
esac
