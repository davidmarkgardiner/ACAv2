#!/bin/bash
#
# Enhanced Deployment Script for Prometheus Alerting -> Argo Events Triage Pipeline
#
# Features:
# - Comprehensive prerequisite checks
# - Dry-run mode
# - Rollback capability
# - Detailed status reporting
# - Configuration validation
# - Interactive setup wizard

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="2.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
DRY_RUN=false
VERBOSE=false
SKIP_CHECKS=false
INTERACTIVE=false
ROLLBACK=false
COMPONENTS="all"
HELM_RELEASE=""

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    [ "$VERBOSE" = true ] && echo "  [$(date '+%Y-%m-%d %H:%M:%S')]"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    [ "$VERBOSE" = true ] && echo -e "${BLUE}[DEBUG]${NC} $1"
}

log_section() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Usage information
usage() {
    cat <<EOF
Prometheus Alerting Triage Pipeline Deployment Script v${VERSION}

Usage: $0 [OPTIONS]

Options:
    -d, --dry-run          Show what would be deployed without making changes
    -v, --verbose          Enable verbose output
    -s, --skip-checks      Skip prerequisite checks
    -i, --interactive      Interactive setup wizard
    -r, --rollback         Rollback to previous configuration
    -c, --components LIST  Deploy specific components (comma-separated)
                           Available: alertmanager,rules,eventsource,workflows,sensor,policies,config
    -h, --help             Show this help message

Examples:
    $0                                    # Deploy all components
    $0 --dry-run                          # Preview deployment
    $0 --components eventsource,sensor    # Deploy only EventSource and Sensor
    $0 --interactive                      # Run setup wizard

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--skip-checks)
                SKIP_CHECKS=true
                shift
                ;;
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -r|--rollback)
                ROLLBACK=true
                shift
                ;;
            -c|--components)
                COMPONENTS="$2"
                shift 2
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
}

# Check if a command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "$1 is not installed or not in PATH"
        return 1
    fi
    log_debug "$1 found: $(command -v "$1")"
    return 0
}

# Check kubectl cluster connection
check_cluster() {
    log_info "Checking Kubernetes cluster connection..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_error "Check your kubectl configuration: kubectl config current-context"
        return 1
    fi
    local context
    context=$(kubectl config current-context)
    log_info "Connected to cluster: $context"
    return 0
}

# Check namespace exists
check_namespace() {
    local ns="$1"
    if ! kubectl get namespace "$ns" &>/dev/null; then
        log_error "Namespace '$ns' does not exist"
        return 1
    fi
    log_debug "Namespace '$ns' exists"
    return 0
}

# Find kube-prometheus-stack helm release
find_helm_release() {
    log_info "Looking for kube-prometheus-stack Helm release..."
    
    for name in monitoring-kube-prometheus kube-prom prometheus-stack prom-stack prometheus; do
        if helm status "$name" -n monitoring &>/dev/null 2>&1; then
            HELM_RELEASE="$name"
            log_info "Found Helm release: $HELM_RELEASE"
            return 0
        fi
    done
    
    # List all releases in monitoring namespace
    log_warn "Standard release names not found. Checking all releases in monitoring namespace..."
    local releases
    releases=$(helm list -n monitoring -q 2>/dev/null || true)
    
    if [ -n "$releases" ]; then
        log_info "Available releases: $releases"
        # Try to find prometheus-related release
        HELM_RELEASE=$(echo "$releases" | grep -i prometheus | head -1 || true)
        if [ -n "$HELM_RELEASE" ]; then
            log_info "Selected release: $HELM_RELEASE"
            return 0
        fi
    fi
    
    log_error "No kube-prometheus-stack Helm release found in namespace 'monitoring'"
    return 1
}

# Check EventBus exists
check_eventbus() {
    log_info "Checking EventBus..."
    if ! kubectl get eventbus default -n argo-events &>/dev/null; then
        log_error "EventBus 'default' not found in argo-events namespace"
        log_error "Deploy Argo Events first: kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml"
        return 1
    fi
    log_info "EventBus 'default' found"
    return 0
}

# Check ServiceAccount exists
check_serviceaccount() {
    log_info "Checking ServiceAccount..."
    if ! kubectl get serviceaccount argo-events-sa -n argo-events &>/dev/null; then
        log_warn "ServiceAccount 'argo-events-sa' not found, will use default"
        # Create it if needed
        if [ "$DRY_RUN" = false ]; then
            log_info "Creating ServiceAccount argo-events-sa..."
            kubectl create serviceaccount argo-events-sa -n argo-events 2>/dev/null || true
        fi
    fi
    return 0
}

# Run all prerequisite checks
run_prerequisites() {
    log_section "PREREQUISITE CHECKS"
    
    if [ "$SKIP_CHECKS" = true ]; then
        log_warn "Skipping prerequisite checks (--skip-checks)"
        return 0
    fi
    
    # Check required commands
    check_command kubectl || return 1
    check_command helm || return 1
    
    # Check cluster connection
    check_cluster || return 1
    
    # Check required namespaces
    check_namespace monitoring || return 1
    check_namespace argo-events || return 1
    
    # Find Helm release
    find_helm_release || return 1
    
    # Check Argo Events
    check_eventbus || return 1
    
    # Check ServiceAccount
    check_serviceaccount || return 1
    
    log_info "All prerequisites met!"
    echo ""
    return 0
}

# Interactive setup wizard
run_wizard() {
    log_section "SETUP WIZARD"
    
    echo "This wizard will help you configure the alerting pipeline."
    echo ""
    
    # Ask about notification channels
    echo "Select notification channels (comma-separated):"
    echo "  1) Mattermost"
    echo "  2) Slack"
    echo "  3) Generic webhook"
    echo "  4) Skip notifications"
    read -r -p "Choice [1]: " channels
    channels=${channels:-1}
    
    # Configure Mattermost
    if echo "$channels" | grep -q "1"; then
        echo ""
        read -r -p "Mattermost webhook URL (without token): " mm_url
        read -r -p "Mattermost webhook token: " mm_token
        
        if [ "$DRY_RUN" = false ] && [ -n "$mm_url" ]; then
            kubectl create configmap notification-config \
                --namespace argo-events \
                --from-literal=MATTERMOST_WEBHOOK_URL="$mm_url" \
                --dry-run=client -o yaml | kubectl apply -f -
            
            if [ -n "$mm_token" ]; then
                kubectl create secret generic mattermost-webhook-secret \
                    --namespace argo-events \
                    --from-literal=WEBHOOK_TOKEN="$mm_token" \
                    --dry-run=client -o yaml | kubectl apply -f -
            fi
        fi
    fi
    
    # Configure GitLab
    echo ""
    read -r -p "Enable GitLab issue creation? (y/N): " enable_gitlab
    if [[ "$enable_gitlab" =~ ^[Yy]$ ]]; then
        read -r -p "GitLab project (format: group/project): " gitlab_project
        read -r -p "GitLab personal access token: " gitlab_token
        
        if [ "$DRY_RUN" = false ] && [ -n "$gitlab_token" ]; then
            kubectl create secret generic gitlab-mcp-secret \
                --namespace argo-events \
                --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="$gitlab_token" \
                --dry-run=client -o yaml | kubectl apply -f -
        fi
        
        # Update workflow template with project
        if [ -n "$gitlab_project" ]; then
            sed -i.bak "s|value: \"\"|value: \"$gitlab_project\"|" "$SCRIPT_DIR/04-workflow-template.yaml"
        fi
    fi
    
    echo ""
    log_info "Configuration complete!"
}

# Deploy component
deploy_component() {
    local component="$1"
    local file="$2"
    local namespace="${3:-argo-events}"
    
    log_info "Deploying $component..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would apply: $file"
        if [ -f "$SCRIPT_DIR/$file" ]; then
            kubectl apply -f "$SCRIPT_DIR/$file" --dry-run=client -n "$namespace" 2>&1 | head -20 || true
        fi
        return 0
    fi
    
    if [ ! -f "$SCRIPT_DIR/$file" ]; then
        log_error "File not found: $SCRIPT_DIR/$file"
        return 1
    fi
    
    if kubectl apply -f "$SCRIPT_DIR/$file" -n "$namespace"; then
        log_info "$component deployed successfully"
        return 0
    else
        log_error "Failed to deploy $component"
        return 1
    fi
}

# Upgrade AlertManager
upgrade_alertmanager() {
    log_info "Upgrading AlertManager with webhook configuration..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would run: helm upgrade $HELM_RELEASE prometheus-community/kube-prometheus-stack"
        return 0
    fi
    
    if helm upgrade "$HELM_RELEASE" prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --reuse-values \
        -f "$SCRIPT_DIR/01-alertmanager-values.yaml" \
        --wait --timeout 5m; then
        log_info "AlertManager upgraded successfully"
        return 0
    else
        log_error "Failed to upgrade AlertManager"
        return 1
    fi
}

# Wait for EventSource pod
wait_for_eventsource() {
    log_info "Waiting for EventSource pod to be ready..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would wait for EventSource pod"
        return 0
    fi
    
    local retries=0
    local max_retries=30
    
    while [ $retries -lt $max_retries ]; do
        if kubectl wait --for=condition=ready pod \
            -l eventsource-name=alertmanager \
            -n argo-events --timeout=10s 2>/dev/null; then
            log_info "EventSource pod is ready"
            return 0
        fi
        
        retries=$((retries + 1))
        echo "  Waiting... ($retries/$max_retries)"
        sleep 5
    done
    
    log_error "EventSource pod did not become ready within timeout"
    return 1
}

# Wait for Sensor pod
wait_for_sensor() {
    log_info "Waiting for Sensor pod to be ready..."
    
    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would wait for Sensor pod"
        return 0
    fi
    
    local retries=0
    local max_retries=30
    
    while [ $retries -lt $max_retries ]; do
        if kubectl wait --for=condition=ready pod \
            -l sensor-name=alertmanager-triage-sensor \
            -n argo-events --timeout=10s 2>/dev/null; then
            log_info "Sensor pod is ready"
            return 0
        fi
        
        retries=$((retries + 1))
        echo "  Waiting... ($retries/$max_retries)"
        sleep 5
    done
    
    log_error "Sensor pod did not become ready within timeout"
    return 1
}

# Main deployment
run_deployment() {
    log_section "DEPLOYMENT"
    
    local deploy_order=(
        "config:07-notification-config.yaml"
        "alertmanager:01-alertmanager-values.yaml:helm"
        "rules:02-custom-alerting-rules.yaml:monitoring"
        "eventsource:03-eventsource-alertmanager.yaml"
        "workflows:04-workflow-template.yaml"
        "sensor:05-sensor.yaml"
        "policies:06-network-policies.yaml"
    )
    
    for item in "${deploy_order[@]}"; do
        IFS=':' read -r name file extra <<< "$item"
        
        # Check if this component should be deployed
        if [ "$COMPONENTS" != "all" ] && ! echo "$COMPONENTS" | grep -qw "$name"; then
            log_debug "Skipping $name (not in component list)"
            continue
        fi
        
        case "$name" in
            alertmanager)
                upgrade_alertmanager || return 1
                ;;
            rules)
                deploy_component "PrometheusRules" "$file" "monitoring" || return 1
                ;;
            eventsource)
                deploy_component "EventSource" "$file" || return 1
                wait_for_eventsource || return 1
                ;;
            sensor)
                deploy_component "Sensor" "$file" || return 1
                wait_for_sensor || return 1
                ;;
            *)
                deploy_component "$name" "$file" || return 1
                ;;
        esac
        
        echo ""
    done
    
    log_info "Deployment complete!"
}

# Verify deployment
verify_deployment() {
    log_section "VERIFICATION"
    
    log_info "Checking deployed resources..."
    
    echo ""
    echo "EventSources:"
    kubectl get eventsource -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || echo "  None found"
    
    echo ""
    echo "Sensors:"
    kubectl get sensor -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || echo "  None found"
    
    echo ""
    echo "WorkflowTemplates:"
    kubectl get workflowtemplate -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || echo "  None found"
    
    echo ""
    echo "PrometheusRules:"
    kubectl get prometheusrule -n monitoring k8s-triage-alerting-rules 2>/dev/null || echo "  None found"
    
    echo ""
    echo "Running pods:"
    kubectl get pods -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting 2>/dev/null || echo "  None found"
    
    echo ""
    log_info "Verification complete!"
}

# Print next steps
print_next_steps() {
    log_section "NEXT STEPS"
    
    cat <<EOF
1. Test the webhook endpoint:
   kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000
   curl -X POST http://localhost:12000/alerts -H "Content-Type: application/json" \
     -d '{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Test","severity":"warning"}}]}'

2. Check AlertManager configuration:
   kubectl port-forward -n monitoring svc/${HELM_RELEASE}-alertmanager 9093:9093
   # Open http://localhost:9093 to verify webhook receiver

3. Run test alerts:
   ./test-alerts.sh --all

4. View workflow logs:
   kubectl logs -n argo-events -l event-type=prometheus-alert --tail=50

5. Check Grafana dashboard (if configured):
   kubectl port-forward -n monitoring svc/${HELM_RELEASE}-grafana 3000:80
   # Default credentials: admin/prom-operator
EOF
}

# Main function
main() {
    parse_args "$@"
    
    log_section "PROMETHEUS ALERTING TRIAGE PIPELINE v${VERSION}"
    
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN MODE: No changes will be made"
        echo ""
    fi
    
    # Run wizard if requested
    if [ "$INTERACTIVE" = true ]; then
        run_wizard
    fi
    
    # Run prerequisites
    run_prerequisites || exit 1
    
    # Run deployment
    run_deployment || exit 1
    
    # Verify
    verify_deployment
    
    # Print next steps
    echo ""
    print_next_steps
    
    log_section "DONE!"
}

# Run main function
main "$@"
