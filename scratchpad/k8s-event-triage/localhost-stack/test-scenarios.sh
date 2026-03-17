#!/bin/bash
# Test scenarios for the K8s Event Triage + AI Remediation stack
# Usage: ./test-scenarios.sh [1|2|3|4|5|clean]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_phase() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

usage() {
    echo "Usage: $0 <scenario>"
    echo ""
    echo "Scenarios:"
    echo "  1   KAgent triage (readonly analysis of a failing pod)"
    echo "  2   KAgent remediation (auto-fix a broken deployment)"
    echo "  3   Local LLM analysis (direct model call, no KAgent)"
    echo "  4   Holmes investigation (optional, for comparison)"
    echo "  5   End-to-end Prometheus alert -> automated triage"
    echo "  clean  Remove all test resources"
    echo ""
    echo "Examples:"
    echo "  $0 1        # Quick triage test"
    echo "  $0 2        # Remediation test"
    echo "  $0 clean    # Clean up test pods"
}

scenario_1() {
    log_phase "Scenario 1: KAgent Triage (readonly)"

    log_info "Creating broken pod..."
    kubectl run crash-test --image=nginx:does-not-exist --restart=Never -n default 2>/dev/null || true
    sleep 10

    log_info "Submitting triage workflow..."
    argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
        -p query="Investigate why this pod is failing to start" \
        -p event_type="ImagePullBackOff" \
        -p namespace="default" \
        -p resource_kind="Pod" \
        -p resource_name="crash-test" \
        -p severity="high" \
        -p error_message="Failed to pull image nginx:does-not-exist" \
        -p remediate="false" \
        --watch

    log_info "Check full output:"
    echo "  argo logs -n argo @latest"
}

scenario_2() {
    log_phase "Scenario 2: KAgent Remediation (auto-fix)"

    log_info "Creating deployment with wrong image..."
    kubectl create deployment fix-me --image=nginx:wrong-tag -n default 2>/dev/null || true
    sleep 15

    log_info "Submitting remediation workflow..."
    argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
        -p query="Fix this deployment - the image tag is wrong, use nginx:latest instead" \
        -p event_type="ImagePullBackOff" \
        -p namespace="default" \
        -p resource_kind="Deployment" \
        -p resource_name="fix-me" \
        -p severity="high" \
        -p error_message="Failed to pull image nginx:wrong-tag" \
        -p remediate="true" \
        --watch

    log_info "Checking if agent fixed the deployment..."
    kubectl get pods -n default -l app=fix-me
}

scenario_3() {
    log_phase "Scenario 3: Local LLM Analysis (direct model call)"

    # Reuse existing broken pod or create one
    kubectl run llm-test --image=busybox --restart=Always -n default -- /bin/sh -c "exit 1" 2>/dev/null || true
    sleep 10

    log_info "Submitting local LLM analysis workflow..."
    argo submit -n argo --from=workflowtemplate/local-llm-analysis \
        -p query="Why is this pod crash looping? What would you recommend?" \
        -p event_type="CrashLoopBackOff" \
        -p namespace="default" \
        -p resource_kind="Pod" \
        -p resource_name="llm-test" \
        -p severity="high" \
        --watch
}

scenario_4() {
    log_phase "Scenario 4: Holmes Investigation"

    if ! kubectl get workflowtemplate holmes-remediation -n argo &>/dev/null; then
        echo -e "${RED}Holmes workflow template not found. Deploy with: ./deploy.sh --with-holmes${NC}"
        exit 1
    fi

    kubectl run holmes-test --image=nginx:nonexistent --restart=Never -n default 2>/dev/null || true
    sleep 10

    log_info "Submitting Holmes investigation workflow..."
    argo submit -n argo --from=workflowtemplate/holmes-remediation \
        -p query="Investigate pod failure" \
        -p event_type="ImagePullBackOff" \
        -p namespace="default" \
        -p resource_kind="Pod" \
        -p resource_name="holmes-test" \
        -p severity="high" \
        -p remediate="false" \
        --watch
}

scenario_5() {
    log_phase "Scenario 5: End-to-End Prometheus Alert"

    log_info "Creating a CrashLoopBackOff pod to trigger Prometheus alerts..."
    kubectl run crashloop-e2e --image=busybox --restart=Always -n default -- /bin/sh -c "exit 1" 2>/dev/null || true

    log_info "Waiting for Prometheus to detect the issue (2-5 minutes)..."
    log_info "Monitor alerts at: kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093"
    log_info "Then visit: http://localhost:9093/#/alerts"
    echo ""
    log_info "Watch for automated workflows:"
    echo "  watch kubectl get workflows -n argo-events"
    echo ""
    log_info "When a workflow appears, check output:"
    echo "  argo logs -n argo-events @latest"
}

clean() {
    log_phase "Cleaning up test resources"

    for pod in crash-test llm-test holmes-test crashloop-e2e; do
        kubectl delete pod $pod -n default --ignore-not-found 2>/dev/null && \
            log_info "Deleted pod/$pod" || true
    done

    kubectl delete deployment fix-me -n default --ignore-not-found 2>/dev/null && \
        log_info "Deleted deployment/fix-me" || true

    # Clean up completed workflows
    ARGO_WF=$(kubectl get workflows -n argo -o name 2>/dev/null | wc -l | tr -d ' ')
    EVENTS_WF=$(kubectl get workflows -n argo-events -o name 2>/dev/null | wc -l | tr -d ' ')

    if [ "$ARGO_WF" -gt 0 ]; then
        log_info "Found $ARGO_WF workflows in argo namespace. Delete? (y/N)"
        read -r answer
        if [ "$answer" = "y" ]; then
            kubectl delete workflows --all -n argo
            log_info "Deleted workflows in argo"
        fi
    fi

    if [ "$EVENTS_WF" -gt 0 ]; then
        log_info "Found $EVENTS_WF workflows in argo-events namespace. Delete? (y/N)"
        read -r answer
        if [ "$answer" = "y" ]; then
            kubectl delete workflows --all -n argo-events
            log_info "Deleted workflows in argo-events"
        fi
    fi

    log_info "Cleanup complete"
}

# Main
case "${1:-}" in
    1) scenario_1 ;;
    2) scenario_2 ;;
    3) scenario_3 ;;
    4) scenario_4 ;;
    5) scenario_5 ;;
    clean) clean ;;
    *) usage ;;
esac
