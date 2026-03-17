#!/bin/bash

# Test the Prometheus Alerting -> Argo Events triage pipeline
# Supports webhook tests, synthetic failure pods, verification, and cleanup.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT=""
WEBHOOK_MODE="incluster"
MODE=""

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
ARGO_EVENTS_NAMESPACE="argo-events"

usage() {
    echo "Usage: $0 [--context <kube-context>] [--webhook-mode local|incluster] <mode>"
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
    echo "Examples:"
    echo "  $0 --context proxmox-k8s --webhook-test"
    echo "  $0 --context proxmox-k8s --webhook-mode local --webhook-test"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --context)
                if [ -z "${2:-}" ]; then
                    log_error "--context requires a value"
                    usage
                    exit 1
                fi
                KUBE_CONTEXT="$2"
                shift 2
                ;;
            --webhook-mode)
                if [ -z "${2:-}" ]; then
                    log_error "--webhook-mode requires a value: local|incluster"
                    usage
                    exit 1
                fi
                WEBHOOK_MODE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*)
                if [ -n "$MODE" ]; then
                    log_error "Only one mode can be provided"
                    usage
                    exit 1
                fi
                MODE="$1"
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ -z "$MODE" ]; then
        usage
        exit 1
    fi

    if [ "$WEBHOOK_MODE" != "local" ] && [ "$WEBHOOK_MODE" != "incluster" ]; then
        log_error "Invalid --webhook-mode '$WEBHOOK_MODE'. Use: local|incluster"
        exit 1
    fi
}

kubectl_cmd() {
    if [ -n "$KUBE_CONTEXT" ]; then
        kubectl --context "$KUBE_CONTEXT" "$@"
    else
        kubectl "$@"
    fi
}

send_webhook_local() {
    local payload="$1"
    local response

    log_warn "Ensure port-forward is running first:"
    echo "  kubectl port-forward -n ${ARGO_EVENTS_NAMESPACE} svc/alertmanager-eventsource-svc 12000:12000"
    echo ""

    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST http://localhost:12000/alerts \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null) || true

    if [ "$response" = "200" ]; then
        log_info "Webhook returned HTTP 200 - alert accepted."
        return 0
    fi

    if [ -z "$response" ] || [ "$response" = "000" ]; then
        log_error "Could not connect to localhost:12000. Is the port-forward running?"
    else
        log_warn "Webhook returned HTTP $response"
    fi
    return 1
}

send_webhook_incluster() {
    local payload="$1"
    local run_id pod_name cm_name http_code

    run_id="$(date +%s)-$RANDOM"
    pod_name="webhook-test-${run_id}"
    cm_name="webhook-payload-${run_id}"

    printf "%s\n" "$payload" > "/tmp/${cm_name}.json"
    kubectl_cmd create configmap "$cm_name" --from-file=payload.json="/tmp/${cm_name}.json" -n "$ARGO_EVENTS_NAMESPACE" >/dev/null

    kubectl_cmd run "$pod_name" -n "$ARGO_EVENTS_NAMESPACE" \
        --image=curlimages/curl:8.12.1 \
        --restart=Never \
        --overrides='{
          "spec":{
            "containers":[
              {
                "name":"'"$pod_name"'",
                "image":"curlimages/curl:8.12.1",
                "command":["sh","-c","code=$(curl -s -o /tmp/resp.txt -w \"%{http_code}\" -X POST http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts -H \"Content-Type: application/json\" --data-binary @/payload/payload.json); echo \"$code\""],
                "volumeMounts":[{"name":"payload","mountPath":"/payload"}]
              }
            ],
            "volumes":[{"name":"payload","configMap":{"name":"'"$cm_name"'"}}]
          }
        }' >/dev/null

    kubectl_cmd wait --for=condition=Ready "pod/${pod_name}" -n "$ARGO_EVENTS_NAMESPACE" --timeout=45s >/dev/null 2>&1 || true
    http_code="$(kubectl_cmd logs "pod/${pod_name}" -n "$ARGO_EVENTS_NAMESPACE" | tail -n1 | tr -d '\r' || true)"

    kubectl_cmd delete pod "$pod_name" -n "$ARGO_EVENTS_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    kubectl_cmd delete configmap "$cm_name" -n "$ARGO_EVENTS_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    rm -f "/tmp/${cm_name}.json"

    if [ "$http_code" = "200" ]; then
        log_info "In-cluster webhook returned HTTP 200 - alert accepted."
        return 0
    fi

    log_error "In-cluster webhook test failed (HTTP: ${http_code:-unknown})."
    return 1
}

# --- Webhook test ---

webhook_test() {
    log_info "Sending mock AlertManager payload to EventSource webhook..."

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

    if [ "$WEBHOOK_MODE" = "local" ]; then
        send_webhook_local "$PAYLOAD"
    else
        send_webhook_incluster "$PAYLOAD"
    fi
}

# --- Create failing test pods ---

create_oom_pod() {
    log_info "Creating OOMKill test pod in namespace '$TEST_NAMESPACE'..."
    kubectl_cmd apply -f - <<'EOF'
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
    kubectl_cmd apply -f - <<'EOF'
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
    kubectl_cmd apply -f - <<'EOF'
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

    WORKFLOWS=$(kubectl_cmd get workflows -n "$ARGO_EVENTS_NAMESPACE" -l event-type=prometheus-alert --no-headers 2>/dev/null)
    if [ -n "$WORKFLOWS" ]; then
        log_info "Found triage workflows:"
        kubectl_cmd get workflows -n "$ARGO_EVENTS_NAMESPACE" -l event-type=prometheus-alert
    else
        log_warn "No triage workflows found yet."
        echo "  Alerts may take a few minutes to fire and trigger workflows."
        echo "  Re-run with: $0 --verify"
    fi
    echo ""

    log_info "Test pods status:"
    kubectl_cmd get pods -n "$TEST_NAMESPACE" -l "$TEST_LABEL" 2>/dev/null || log_warn "No test pods found."
}

# --- Cleanup ---

cleanup() {
    log_info "Cleaning up test resources..."

    log_info "Deleting test pods..."
    kubectl_cmd delete pods -n "$TEST_NAMESPACE" -l "$TEST_LABEL" --ignore-not-found
    log_info "Test pods deleted."

    log_info "Deleting test triage workflows..."
    kubectl_cmd delete workflows -n "$ARGO_EVENTS_NAMESPACE" -l event-type=prometheus-alert --ignore-not-found
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

main() {
    parse_args "$@"
    if [ -n "$KUBE_CONTEXT" ]; then
        log_info "Using Kubernetes context: $KUBE_CONTEXT"
    fi
    log_info "Webhook test mode: $WEBHOOK_MODE"

    case "$MODE" in
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
}

main "$@"
