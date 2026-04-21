#!/usr/bin/env bash
# preflight-check.sh — check which CRDs are installed before deploying
#
# Run on both management and worker cluster contexts.
# Exits 0 if required CRDs are present, 1 if any are missing.
# Optional CRDs print a warning and install hint but don't fail.
#
# Usage:
#   ./preflight-check.sh                    # check current kubectl context
#   ./preflight-check.sh --context=<ctx>    # check specific context
#
set -uo pipefail

CONTEXT_ARG=""
if [[ "${1:-}" == --context=* ]]; then
  CONTEXT_ARG="$1"
fi

# ANSI colours
G='\033[0;32m'   # green
Y='\033[0;33m'   # yellow
R='\033[0;31m'   # red
B='\033[1;34m'   # blue
N='\033[0m'      # reset

check_crd() {
  local crd=$1
  local label=$2
  local role=$3   # required / optional-mgmt / optional-worker / worker / mgmt
  local install_hint=$4

  if kubectl $CONTEXT_ARG get crd "$crd" >/dev/null 2>&1; then
    printf "  ${G}✓${N}  %-45s  %s\n" "$crd" "$label"
    return 0
  else
    case "$role" in
      required)
        printf "  ${R}✗${N}  %-45s  %s ${R}[REQUIRED]${N}\n" "$crd" "$label"
        printf "     install: %s\n" "$install_hint"
        return 1
        ;;
      *)
        printf "  ${Y}○${N}  %-45s  %s ${Y}[${role}]${N}\n" "$crd" "$label"
        printf "     install: %s\n" "$install_hint"
        return 0
        ;;
    esac
  fi
}

current_ctx=$(kubectl $CONTEXT_ARG config current-context 2>/dev/null || echo "unknown")
echo ""
printf "${B}═══ Preflight check: %s ═══${N}\n" "$current_ctx"
echo ""

failed=0

# ── REQUIRED regardless of cluster role ─────────────────────────────────────
echo "Gateway API (required on mgmt cluster, optional on worker):"
check_crd "gateways.gateway.networking.k8s.io" \
  "Gateway API v1 core" \
  "optional-mgmt" \
  "helm upgrade -i gateway-api oci://registry.k8s.io/gateway-api/charts/gateway-api --version v1.5.0 -n gateway-system --create-namespace" \
  || failed=1

check_crd "httproutes.gateway.networking.k8s.io" \
  "Gateway API HTTPRoute" \
  "optional-mgmt" \
  "(installed with Gateway API standard bundle above)" \
  || failed=1

check_crd "referencegrants.gateway.networking.k8s.io" \
  "Gateway API ReferenceGrant" \
  "optional-mgmt" \
  "(installed with Gateway API standard bundle above)" \
  || failed=1

echo ""
echo "agentgateway (required on mgmt cluster):"
check_crd "agentgatewaybackends.agentgateway.dev" \
  "agentgateway Backend CRD" \
  "optional-mgmt" \
  "helm upgrade -i --create-namespace -n agentgateway-system --version v1.1.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds"

check_crd "agentgatewaypolicies.agentgateway.dev" \
  "agentgateway Policy CRD" \
  "optional-mgmt" \
  "(installed with agentgateway-crds chart above)"

echo ""
echo "kagent (required on worker cluster):"
check_crd "modelconfigs.kagent.dev" \
  "kagent ModelConfig" \
  "optional-worker" \
  "helm upgrade -i kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent -n kagent"

check_crd "agents.kagent.dev" \
  "kagent Agent" \
  "optional-worker" \
  "(installed with kagent helm chart above)"

# ── OPTIONAL (depends on what else you have) ────────────────────────────────
echo ""
echo "Istio (required on mgmt cluster for cross-cluster access):"
check_crd "virtualservices.networking.istio.io" \
  "Istio VirtualService" \
  "optional-mgmt" \
  "https://istio.io/latest/docs/setup/install/ (istioctl install --set profile=default)"

check_crd "authorizationpolicies.security.istio.io" \
  "Istio AuthorizationPolicy" \
  "optional-mgmt" \
  "(installed with Istio above)"

echo ""
echo "Prometheus Operator (optional — for monitoring.yaml):"
check_crd "podmonitors.monitoring.coreos.com" \
  "Prometheus Operator PodMonitor" \
  "optional" \
  "helm install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace"

check_crd "servicemonitors.monitoring.coreos.com" \
  "Prometheus Operator ServiceMonitor" \
  "optional" \
  "(installed with kube-prometheus-stack above)"

check_crd "prometheusrules.monitoring.coreos.com" \
  "Prometheus Operator PrometheusRule" \
  "optional" \
  "(installed with kube-prometheus-stack above)"

# ── Workload identity (required for UAMI on mgmt cluster) ───────────────────
echo ""
echo "Azure Workload Identity (required for UAMI to Azure OpenAI on mgmt cluster):"
if kubectl $CONTEXT_ARG get ns azure-workload-identity-system >/dev/null 2>&1 \
   || kubectl $CONTEXT_ARG get mutatingwebhookconfigurations \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
      | grep -q "azure-wi-webhook"; then
  printf "  ${G}✓${N}  azure-workload-identity webhook present\n"
else
  printf "  ${Y}○${N}  azure-workload-identity webhook ${Y}[optional-mgmt]${N}\n"
  printf "     install: https://azure.github.io/azure-workload-identity/docs/installation.html\n"
  printf "     or enable via AKS:  az aks update -n <aks> -g <rg> --enable-workload-identity --enable-oidc-issuer\n"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
printf "${B}═══ Summary ═══${N}\n"
printf "  ${G}✓${N}  = installed\n"
printf "  ${Y}○${N}  = missing (optional — install only if you need the feature)\n"
printf "  ${R}✗${N}  = missing (REQUIRED — must install)\n"
echo ""

if [[ "$failed" -ne 0 ]]; then
  printf "${R}One or more REQUIRED CRDs missing. Fix before deploying.${N}\n"
  exit 1
fi

cat <<'EOF'
What to install on each cluster:

  MANAGEMENT CLUSTER (runs agentgateway):
    REQUIRED:   Gateway API, agentgateway-crds, Istio (if cross-cluster)
    OPTIONAL:   Prometheus Operator (for monitoring.yaml)
    OPTIONAL:   Azure Workload Identity (if using UAMI to Azure OpenAI)

  WORKER CLUSTER (runs kagent):
    REQUIRED:   kagent CRDs
    OPTIONAL:   Prometheus Operator (for monitoring.yaml worker section)

Manifest → CRD mapping:
  gateway-resources.yaml       → Gateway API
  backend-*.yaml, ai-policy    → agentgateway CRDs
  istio-*.yaml                 → Istio CRDs
  monitoring.yaml              → Prometheus Operator CRDs (skip if not installed)
  modelconfig-*.yaml           → kagent CRDs
  networkpolicy.yaml           → built-in (always available)
EOF
