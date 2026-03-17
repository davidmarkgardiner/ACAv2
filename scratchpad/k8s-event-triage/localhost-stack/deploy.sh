#!/bin/bash
# Deploy the full K8s Event Triage + AI Remediation stack on localhost
# Usage: ./deploy.sh [--skip-ai] [--skip-holmes] [--context <name>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKIP_AI=false
SKIP_HOLMES=true  # Holmes is optional by default
KUBE_CONTEXT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

kubectl_cmd() {
    if [ -n "$KUBE_CONTEXT" ]; then
        kubectl --context "$KUBE_CONTEXT" "$@"
    else
        kubectl "$@"
    fi
}

helm_cmd() {
    if [ -n "$KUBE_CONTEXT" ]; then
        helm --kube-context "$KUBE_CONTEXT" "$@"
    else
        helm "$@"
    fi
}

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-ai)      SKIP_AI=true; shift ;;
        --with-holmes)   SKIP_HOLMES=false; shift ;;
        --context)       KUBE_CONTEXT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--skip-ai] [--with-holmes] [--context <name>]"
            echo ""
            echo "  --skip-ai      Skip AI platform (KubeAI, LiteLLM, KAgent)"
            echo "  --with-holmes   Include HolmesGPT (optional, for comparison)"
            echo "  --context       Kubernetes context to use"
            exit 0 ;;
        *) log_error "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---- Prerequisites ----
log_phase "Phase 0: Prerequisites"

for cmd in kubectl helm; do
    if ! command -v $cmd &>/dev/null; then
        log_error "$cmd is not installed"
        exit 1
    fi
done
log_info "kubectl and helm found"

if ! kubectl_cmd get namespace monitoring &>/dev/null; then
    log_error "Namespace 'monitoring' not found. Deploy kube-prometheus-stack first."
    exit 1
fi
log_info "monitoring namespace exists"

# ---- Phase 1: Argo Workflows ----
log_phase "Phase 1: Argo Workflows"

if kubectl_cmd get namespace argo &>/dev/null; then
    log_info "argo namespace already exists, checking deployment..."
    if kubectl_cmd get deployment workflow-controller -n argo &>/dev/null; then
        log_info "Argo Workflows already deployed, skipping."
    else
        kubectl_cmd apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml
        kubectl_cmd wait --for=condition=available --timeout=120s deployment/workflow-controller -n argo
    fi
else
    kubectl_cmd create namespace argo
    kubectl_cmd apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml
    kubectl_cmd wait --for=condition=available --timeout=120s deployment/workflow-controller -n argo
    kubectl_cmd wait --for=condition=available --timeout=120s deployment/argo-server -n argo
fi
log_info "Argo Workflows ready"

# ---- Phase 2: Argo Events + Alerting Pipeline ----
log_phase "Phase 2: Argo Events + Prometheus Alerting"

if kubectl_cmd get namespace argo-events &>/dev/null; then
    log_info "argo-events namespace exists"
else
    kubectl_cmd create namespace argo-events
fi

# Install Argo Events controller if not present
if ! kubectl_cmd get deployment controller-manager -n argo-events &>/dev/null; then
    kubectl_cmd apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml
    kubectl_cmd wait --for=condition=available --timeout=120s deployment/controller-manager -n argo-events
else
    log_info "Argo Events controller already deployed"
fi

# EventBus
if ! kubectl_cmd get eventbus default -n argo-events &>/dev/null; then
    log_info "Deploying NATS EventBus..."
    kubectl_cmd apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      auth: token
EOF
    kubectl_cmd wait --for=condition=ready pod -l eventbus-name=default -n argo-events --timeout=120s
else
    log_info "EventBus already exists"
fi

# Prometheus alerting pipeline
ALERTING_DIR="$SCRIPT_DIR/../prometheus-alerting"
if [ -f "$ALERTING_DIR/deploy.sh" ]; then
    log_info "Deploying Prometheus alerting pipeline..."
    chmod +x "$ALERTING_DIR/deploy.sh"
    if [ -n "$KUBE_CONTEXT" ]; then
        "$ALERTING_DIR/deploy.sh" --context "$KUBE_CONTEXT"
    else
        "$ALERTING_DIR/deploy.sh"
    fi
else
    log_warn "Prometheus alerting deploy.sh not found at $ALERTING_DIR/deploy.sh, skipping"
fi

log_info "Argo Events + Alerting pipeline ready"

# ---- Phase 3: AI Platform ----
if [ "$SKIP_AI" = true ]; then
    log_phase "Phase 3: AI Platform (SKIPPED)"
else
    log_phase "Phase 3: AI Platform (KubeAI + LiteLLM)"

    # Helm repos
    helm repo add kubeai https://www.kubeai.org 2>/dev/null || true
    helm repo add litellm https://litellm.github.io/litellm-helm 2>/dev/null || true
    helm repo update

    # KubeAI
    AI_CONFIG="$REPO_ROOT/ai-platform/config"
    if helm_cmd status kubeai -n kubeai &>/dev/null; then
        log_info "KubeAI already deployed"
    else
        helm_cmd upgrade --install kubeai kubeai/kubeai \
            --namespace kubeai --create-namespace \
            -f "$AI_CONFIG/kubeai/kubeai-values.yaml" --wait
    fi

    # Qwen 14B model
    kubectl_cmd apply -f "$AI_CONFIG/kubeai/qwen-14b-model.yaml"
    log_info "Waiting for Qwen 14B model to load (may take several minutes on first deploy)..."
    kubectl_cmd wait --for=condition=ready pod -l model=qwen2.5-14b -n kubeai --timeout=600s || \
        log_warn "Model pod not ready after 10min — check GPU availability"

    # LiteLLM
    if helm_cmd status litellm -n litellm &>/dev/null; then
        log_info "LiteLLM already deployed"
    else
        helm_cmd upgrade --install litellm litellm/litellm \
            --namespace litellm --create-namespace \
            -f "$AI_CONFIG/litellm/litellm-values.yaml" --wait
    fi

    log_info "AI Platform ready"

    # ---- Phase 4: KAgent + AKS-MCP ----
    log_phase "Phase 4: KAgent + AKS-MCP"

    # AKS-MCP
    kubectl_cmd apply -f "$REPO_ROOT/aks-mgmt-stack/holmes-argoworkflows/aks-mcp/aks-mcp-local-admin.yaml"
    kubectl_cmd wait --for=condition=available --timeout=120s deployment/aks-mcp -n aks-mcp

    # KAgent
    helm repo add kagent https://kagent-dev.github.io/kagent 2>/dev/null || true
    helm repo update

    if ! kubectl_cmd get namespace kagent &>/dev/null; then
        kubectl_cmd create namespace kagent
    fi

    # KAgent API key secret
    if ! kubectl_cmd get secret kagent-openai -n kagent &>/dev/null; then
        kubectl_cmd create secret generic kagent-openai -n kagent \
            --from-literal=OPENAI_API_KEY=sk-poc-homelab-1234
    fi

    if helm_cmd status kagent -n kagent &>/dev/null; then
        log_info "KAgent already deployed"
    else
        helm_cmd upgrade --install kagent kagent/kagent \
            --namespace kagent \
            -f "$AI_CONFIG/kagent/kagent-values.yaml" --wait
    fi

    # ModelConfig for 14B model
    kubectl_cmd apply -f "$AI_CONFIG/kagent/kagent-modelconfig-14b.yaml"

    log_info "KAgent + AKS-MCP ready"

    # Workflow templates
    log_info "Deploying workflow templates..."
    HOLMES_DIR="$REPO_ROOT/aks-mgmt-stack/holmes-argoworkflows"
    kubectl_cmd apply -f "$HOLMES_DIR/kagent-sre-workflow.yaml"
    kubectl_cmd apply -f "$HOLMES_DIR/local-llm-analysis-only.yaml"
    log_info "Workflow templates deployed"

    # ---- Phase 5: Holmes (optional) ----
    if [ "$SKIP_HOLMES" = true ]; then
        log_phase "Phase 5: HolmesGPT (SKIPPED — use --with-holmes to include)"
    else
        log_phase "Phase 5: HolmesGPT"

        helm repo add robusta https://robusta-dev.github.io/robusta-charts 2>/dev/null || true
        helm repo update

        helm_cmd upgrade --install holmes robusta/holmes \
            --namespace holmesgpt --create-namespace \
            -f "$HOLMES_DIR/helm-values-proxmox.yaml" --wait

        kubectl_cmd apply -f "$HOLMES_DIR/holmes-remediation.yaml"
        log_info "HolmesGPT ready"
    fi
fi

# ---- Summary ----
log_phase "Deployment Complete"

echo ""
log_info "Namespaces:"
kubectl_cmd get namespaces | grep -E "^(argo|argo-events|monitoring|kubeai|litellm|kagent|aks-mcp|holmesgpt) "

echo ""
log_info "Workflow templates:"
kubectl_cmd get workflowtemplate -n argo 2>/dev/null || true
kubectl_cmd get workflowtemplate -n argo-events 2>/dev/null || true

echo ""
log_info "Argo Events pipeline:"
kubectl_cmd get eventbus,eventsource,sensor -n argo-events

echo ""
log_info "Next steps:"
echo "  1. Create secrets (see README.md Phase 6):"
echo "     kubectl create secret generic gitlab-token -n argo --from-literal=GITLAB_TOKEN='glpat-...'"
echo "     kubectl create secret generic mattermost-webhook -n argo --from-literal=url='https://...'"
echo "  2. Run test scenario:"
echo "     kubectl run crash-test --image=nginx:does-not-exist -n default"
echo "     argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \\"
echo "       -p namespace=default -p resource_name=crash-test -p remediate=false --watch"
