#!/bin/bash
#
# Enhanced Test Script for Prometheus Alerting Triage Pipeline
#
# Features:
# - Direct webhook testing (no port-forward required)
# - Comprehensive test scenarios
# - Load testing
# - Automated verification
# - Detailed reporting

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test configuration
TEST_NAMESPACE="default"
TEST_LABEL="prometheus-alerting-test=true"
VERBOSE=false
QUIET=false
TIMEOUT=120
CLEANUP_ON_EXIT=true

# Results tracking
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    [ "$QUIET" = false ] && echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    [ "$QUIET" = false ] && echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    [ "$VERBOSE" = true ] && echo -e "${BLUE}[DEBUG]${NC} $1"
}

log_section() {
    [ "$QUIET" = false ] && echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" && echo -e "${CYAN}$1${NC}"
}

# Usage
usage() {
    cat <<EOF
Prometheus Alerting Test Script v${VERSION}

Usage: $0 [MODE] [OPTIONS]

Modes:
    webhook         Send direct webhook test to EventSource
    webhook-local   Send test via localhost port-forward
    pod-oom         Create OOMKill test pod
    pod-crash       Create CrashLoopBackOff test pod
    pod-image       Create ImagePullBackOff test pod
    pod-pending     Create pod that stays pending
    load            Run load test with multiple alerts
    verify          Verify workflows were created
    logs            Show workflow logs
    cleanup         Remove all test resources
    all             Run full test suite

Options:
    -n, --namespace NS    Test namespace (default: default)
    -t, --timeout SEC     Timeout for verification (default: 120)
    -v, --verbose         Enable verbose output
    -q, --quiet           Minimal output
    --no-cleanup          Don't cleanup on exit
    -h, --help            Show this help

Examples:
    $0 webhook            # Send direct webhook test
    $0 webhook-local      # Test via port-forward
    $0 pod-oom            # Create OOM test pod
    $0 all                # Run full test suite
    $0 all --no-cleanup   # Run tests without cleanup

EOF
}

# Parse arguments
parse_args() {
    MODE=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            webhook|webhook-local|pod-oom|pod-crash|pod-image|pod-pending|load|verify|logs|cleanup|all)
                MODE="$1"
                shift
                ;;
            -n|--namespace)
                TEST_NAMESPACE="$2"
                shift 2
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --no-cleanup)
                CLEANUP_ON_EXIT=false
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$MODE" ]; then
        log_error "No test mode specified"
        usage
        exit 1
    fi
}

# Cleanup function
cleanup() {
    if [ "$CLEANUP_ON_EXIT" = false ]; then
        log_info "Skipping cleanup (--no-cleanup)"
        return 0
    fi
    
    log_info "Cleaning up test resources..."
    
    # Delete test pods
    kubectl delete pods -n "$TEST_NAMESPACE" -l "$TEST_LABEL" --ignore-not-found 2>/dev/null || true
    
    # Delete test workflows
    kubectl delete workflows -n argo-events -l event-type=prometheus-alert --ignore-not-found 2>/dev/null || true
    
    log_info "Cleanup complete"
}

# Send webhook directly to EventSource service
webhook_test() {
    log_section "WEBHOOK TEST (Direct)"
    
    # Build test payload
    local payload
    payload=$(cat <<'EOF'
{
  "version": "4",
  "groupKey": "{alertname=\"TestAlert\"}",
  "truncatedAlerts": 0,
  "status": "firing",
  "receiver": "argo-events-webhook",
  "groupLabels": {"alertname": "TestAlert"},
  "commonLabels": {
    "alertname": "TestAlert",
    "severity": "warning",
    "namespace": "default"
  },
  "commonAnnotations": {
    "summary": "Test alert from test script"
  },
  "externalURL": "http://alertmanager:9093",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "TestAlert",
        "severity": "warning",
        "namespace": "default",
        "pod": "test-pod-123"
      },
      "annotations": {
        "summary": "Test alert from enhanced test script",
        "description": "This is a test alert to verify the triage pipeline is working correctly"
      },
      "startsAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://prometheus:9090/graph"
    }
  ]
}
EOF
)
    
    # Get EventSource service URL
    local service_url
    service_url="http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts"
    
    log_info "Sending webhook to: $service_url"
    log_debug "Payload: $payload"
    
    # Send request using kubectl run
    local response
    if response=$(kubectl run webhook-test --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST "$service_url" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1); then
        
        http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            log_info "✓ Webhook accepted (HTTP $http_code)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            log_error "✗ Webhook returned HTTP $http_code"
            log_debug "Response: $response"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    else
        log_error "✗ Failed to send webhook"
        log_debug "Response: $response"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Send webhook via localhost port-forward
webhook_local_test() {
    log_section "WEBHOOK TEST (Local Port-Forward)"
    
    log_warn "This test requires port-forward to be running in another terminal:"
    echo "  kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000"
    echo ""
    read -r -p "Press Enter when port-forward is ready..."
    
    local payload
    payload='{
        "version": "4",
        "status": "firing",
        "receiver": "argo-events-webhook",
        "alerts": [{
            "status": "firing",
            "labels": {
                "alertname": "TestAlert",
                "severity": "warning",
                "namespace": "default"
            },
            "annotations": {
                "summary": "Local test alert"
            },
            "startsAt": "2024-01-01T00:00:00Z"
        }]
    }'
    
    log_info "Sending webhook to localhost:12000..."
    
    if response=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
        -X POST http://localhost:12000/alerts \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1); then
        
        http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)
        
        if [ "$http_code" = "200" ]; then
            log_info "✓ Local webhook test passed (HTTP $http_code)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            return 0
        else
            log_error "✗ Local webhook returned HTTP $http_code"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        fi
    else
        log_error "✗ Failed to connect to localhost:12000"
        log_error "Is the port-forward running?"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Create OOMKill test pod
create_oom_pod() {
    log_section "OOMKILL TEST POD"
    
    log_info "Creating OOMKill test pod..."
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-oomkill
  namespace: $TEST_NAMESPACE
  labels:
    prometheus-alerting-test: "true"
    test-type: oomkill
spec:
  restartPolicy: Never
  containers:
    - name: oom-trigger
      image: polinux/stress:latest
      command: ["stress"]
      args: ["--vm", "1", "--vm-bytes", "256M", "--vm-hang", "0", "--timeout", "30s"]
      resources:
        limits:
          memory: "16Mi"
          cpu: "100m"
EOF
    
    log_info "✓ OOMKill test pod created"
    log_info "Pod will be killed within 30 seconds due to memory limit"
    
    # Wait briefly for pod to start
    sleep 5
    
    # Show pod status
    kubectl get pod test-oomkill -n "$TEST_NAMESPACE" 2>/dev/null || true
}

# Create CrashLoopBackOff test pod
create_crashloop_pod() {
    log_section "CRASHLOOP TEST POD"
    
    log_info "Creating CrashLoopBackOff test pod..."
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-crashloop
  namespace: $TEST_NAMESPACE
  labels:
    prometheus-alerting-test: "true"
    test-type: crashloop
spec:
  restartPolicy: Always
  containers:
    - name: crash
      image: busybox:latest
      command: ["sh", "-c", "echo 'Starting...'; sleep 3; exit 1"]
EOF
    
    log_info "✓ CrashLoop test pod created"
    log_info "Pod will start crash-looping after ~3 seconds"
    
    sleep 5
    kubectl get pod test-crashloop -n "$TEST_NAMESPACE" 2>/dev/null || true
}

# Create ImagePullBackOff test pod
create_imagepull_pod() {
    log_section "IMAGEPULL TEST POD"
    
    log_info "Creating ImagePullBackOff test pod..."
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-imagepull
  namespace: $TEST_NAMESPACE
  labels:
    prometheus-alerting-test: "true"
    test-type: imagepull
spec:
  restartPolicy: Never
  containers:
    - name: bad-image
      image: registry.invalid.example.com/nonexistent-image:tag
EOF
    
    log_info "✓ ImagePull test pod created"
    log_info "Pod will fail to pull the image"
    
    sleep 5
    kubectl get pod test-imagepull -n "$TEST_NAMESPACE" 2>/dev/null || true
}

# Create pending pod (resource constraints)
create_pending_pod() {
    log_section "PENDING POD TEST"
    
    log_info "Creating unschedulable test pod..."
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pending
  namespace: $TEST_NAMESPACE
  labels:
    prometheus-alerting-test: "true"
    test-type: pending
spec:
  containers:
    - name: huge
      image: busybox:latest
      command: ["sleep", "3600"]
      resources:
        requests:
          memory: "1000Ti"
          cpu: "1000000"
EOF
    
    log_info "✓ Pending test pod created"
    log_info "Pod cannot be scheduled due to impossible resource requirements"
}

# Load test
load_test() {
    log_section "LOAD TEST"
    
    local count=${1:-10}
    log_info "Sending $count concurrent alerts..."
    
    local service_url="http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts"
    
    for i in $(seq 1 $count); do
        local payload
        payload=$(cat <<EOF
{
  "version": "4",
  "status": "firing",
  "receiver": "argo-events-webhook",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "LoadTestAlert${i}",
      "severity": "warning",
      "namespace": "default",
      "test_id": "${i}"
    },
    "annotations": {
      "summary": "Load test alert $i"
    },
    "startsAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }]
}
EOF
)
        
        kubectl run "load-test-$i" --rm -i --restart=Never --image=curlimages/curl:latest \
            -- curl -s -X POST "$service_url" -H "Content-Type: application/json" -d "$payload" > /dev/null 2>&1 &
    done
    
    wait
    log_info "✓ Load test complete - sent $count alerts"
}

# Verify workflows were created
verify_workflows() {
    log_section "VERIFICATION"
    
    log_info "Checking for triggered workflows..."
    
    local retries=0
    local max_retries=$((TIMEOUT / 5))
    
    while [ $retries -lt $max_retries ]; do
        local workflows
        workflows=$(kubectl get workflows -n argo-events -l event-type=prometheus-alert --no-headers 2>/dev/null || true)
        
        if [ -n "$workflows" ]; then
            log_info "✓ Found triage workflows:"
            echo "$workflows"
            
            # Count successful workflows
            local succeeded
            succeeded=$(echo "$workflows" | grep -c "Succeeded" || true)
            log_info "Succeeded: $succeeded"
            
            if [ "$succeeded" -gt 0 ]; then
                TESTS_PASSED=$((TESTS_PASSED + 1))
                return 0
            fi
        fi
        
        retries=$((retries + 1))
        echo "  Waiting for workflows... ($retries/$max_retries)"
        sleep 5
    done
    
    log_warn "No workflows found yet. Alerts may take a few minutes to fire."
    log_info "Run '$0 verify' to check again later."
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 1
}

# Show workflow logs
show_logs() {
    log_section "WORKFLOW LOGS"
    
    local workflows
    workflows=$(kubectl get workflows -n argo-events -l event-type=prometheus-alert -o name 2>/dev/null || true)
    
    if [ -z "$workflows" ]; then
        log_warn "No workflows found"
        return 1
    fi
    
    for workflow in $workflows; do
        log_info "Logs for $workflow:"
        kubectl logs -n argo-events "$workflow" --all-containers 2>/dev/null | tail -30 || true
        echo ""
    done
}

# Run all tests
run_all_tests() {
    log_section "FULL TEST SUITE"
    
    # Test 1: Webhook direct
    webhook_test || true
    echo ""
    
    # Test 2: Create test pods
    create_oom_pod || true
    create_crashloop_pod || true
    create_imagepull_pod || true
    echo ""
    
    # Wait for alerts to fire and workflows to trigger
    log_info "Waiting 60 seconds for alerts to fire..."
    sleep 60
    
    # Test 3: Verify workflows
    verify_workflows || true
    
    # Show logs
    show_logs || true
}

# Print test summary
print_summary() {
    log_section "TEST SUMMARY"
    
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        log_info "All tests passed! ✓"
        return 0
    else
        log_warn "Some tests failed. Check the logs above."
        return 1
    fi
}

# Main function
main() {
    parse_args "$@"
    
    log_section "PROMETHEUS ALERTING TEST v${VERSION}"
    
    # Set trap for cleanup
    if [ "$CLEANUP_ON_EXIT" = true ]; then
        trap cleanup EXIT
    fi
    
    # Run selected mode
    case "$MODE" in
        webhook)
            webhook_test
            ;;
        webhook-local)
            webhook_local_test
            ;;
        pod-oom)
            create_oom_pod
            ;;
        pod-crash)
            create_crashloop_pod
            ;;
        pod-image)
            create_imagepull_pod
            ;;
        pod-pending)
            create_pending_pod
            ;;
        load)
            load_test "${2:-10}"
            ;;
        verify)
            verify_workflows
            ;;
        logs)
            show_logs
            ;;
        cleanup)
            cleanup
            exit 0
            ;;
        all)
            run_all_tests
            print_summary
            ;;
        *)
            log_error "Unknown mode: $MODE"
            usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
