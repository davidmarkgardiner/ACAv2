#!/bin/bash

# Deploy Prometheus Alerting -> Argo Events triage pipeline
# This script configures AlertManager to forward alerts to an Argo Events
# webhook, which triggers triage workflows automatically.

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

# --- Prerequisite checks ---

check_prerequisites() {
    log_info "Checking prerequisites..."

    # kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    # helm
    if ! command -v helm &>/dev/null; then
        log_error "helm is not installed or not in PATH"
        exit 1
    fi

    # monitoring namespace
    if ! kubectl get namespace monitoring &>/dev/null; then
        log_error "Namespace 'monitoring' does not exist. Deploy kube-prometheus-stack first."
        exit 1
    fi

    # argo-events namespace
    if ! kubectl get namespace argo-events &>/dev/null; then
        log_error "Namespace 'argo-events' does not exist. Deploy Argo Events first."
        exit 1
    fi

    # kube-prometheus-stack helm release
    # Check for common kube-prometheus-stack release names
    HELM_RELEASE=""
    for name in kube-prom prometheus-stack prom-stack; do
        if helm status "$name" -n monitoring &>/dev/null; then
            HELM_RELEASE="$name"
            break
        fi
    done
    if [ -z "$HELM_RELEASE" ]; then
        log_error "No kube-prometheus-stack Helm release found in namespace 'monitoring'."
        log_error "Deploy kube-prometheus-stack first."
        exit 1
    fi
    log_info "Found Helm release: $HELM_RELEASE"

    log_info "All prerequisites met."
}

# --- Deployment steps ---

deploy() {
    # Step 1: Upgrade AlertManager with webhook receiver
    log_info "Step 1/8: Upgrading AlertManager with Argo Events webhook receiver..."
    if helm upgrade "$HELM_RELEASE" prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --reuse-values \
        -f "$SCRIPT_DIR/01-alertmanager-values.yaml" \
        --wait; then
        log_info "AlertManager upgraded successfully."
    else
        log_error "Failed to upgrade AlertManager."
        exit 1
    fi

    # Step 2: Apply custom PrometheusRule
    log_info "Step 2/8: Applying custom alerting rules (PrometheusRule)..."
    if kubectl apply -f "$SCRIPT_DIR/02-custom-alerting-rules.yaml"; then
        log_info "PrometheusRule applied successfully."
    else
        log_error "Failed to apply PrometheusRule."
        exit 1
    fi

    # Step 3: Deploy EventSource
    log_info "Step 3/8: Deploying AlertManager EventSource..."
    if kubectl apply -f "$SCRIPT_DIR/03-eventsource-alertmanager.yaml"; then
        log_info "EventSource applied successfully."
    else
        log_error "Failed to deploy EventSource."
        exit 1
    fi

    # Step 4: Wait for EventSource pod
    log_info "Step 4/8: Waiting for EventSource pod to be ready..."
    if kubectl wait --for=condition=ready pod -l eventsource-name=alertmanager -n argo-events --timeout=120s; then
        log_info "EventSource pod is ready."
    else
        log_error "EventSource pod did not become ready within 120s."
        exit 1
    fi

    # Step 5: Deploy WorkflowTemplate
    log_info "Step 5/8: Deploying triage WorkflowTemplate..."
    if kubectl apply -f "$SCRIPT_DIR/04-workflow-template.yaml"; then
        log_info "WorkflowTemplate applied successfully."
    else
        log_error "Failed to deploy WorkflowTemplate."
        exit 1
    fi

    # Step 6: Deploy Sensor
    log_info "Step 6/8: Deploying AlertManager triage Sensor..."
    if kubectl apply -f "$SCRIPT_DIR/05-sensor.yaml"; then
        log_info "Sensor applied successfully."
    else
        log_error "Failed to deploy Sensor."
        exit 1
    fi

    # Step 7: Wait for Sensor pod
    log_info "Step 7/8: Waiting for Sensor pod to be ready..."
    if kubectl wait --for=condition=ready pod -l sensor-name=alertmanager-triage-sensor -n argo-events --timeout=120s; then
        log_info "Sensor pod is ready."
    else
        log_error "Sensor pod did not become ready within 120s."
        exit 1
    fi

    # Step 8: Import Grafana dashboard (optional)
    log_info "Step 8/8: Importing Grafana dashboard..."
    kubectl apply -f "$SCRIPT_DIR/07-grafana-dashboard-configmap.yaml" 2>/dev/null \
        && log_info "Grafana dashboard ConfigMap applied." \
        || log_warn "Dashboard ConfigMap not found, skipping."
}

# --- Verification ---

verify() {
    log_info "=== Deployment Verification ==="
    echo ""

    log_info "EventSource:"
    kubectl get eventsource -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || log_warn "No EventSources found."
    echo ""

    log_info "Sensor:"
    kubectl get sensor -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || log_warn "No Sensors found."
    echo ""

    log_info "PrometheusRule:"
    kubectl get prometheusrule k8s-triage-alerting-rules -n monitoring 2>/dev/null || log_warn "PrometheusRule not found."
    echo ""

    log_info "Running pods in argo-events:"
    kubectl get pods -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || log_warn "No pods found."
    echo ""
}

# --- Main ---

main() {
    log_info "Starting Prometheus Alerting -> Argo Events triage pipeline deployment..."
    echo ""

    check_prerequisites
    deploy
    echo ""
    verify

    log_info "Deployment completed successfully!"
}

main "$@"
