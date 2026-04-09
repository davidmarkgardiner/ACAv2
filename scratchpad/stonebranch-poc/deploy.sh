#!/bin/bash
set -euo pipefail

CONTEXT="${1:-proxmox-k8s}"
NAMESPACE="stonebranch"

echo "=== Deploying Stonebranch UAG POC to context: ${CONTEXT} ==="
echo ""

# Create namespace
echo "[1/5] Creating namespace..."
kubectl --context "${CONTEXT}" apply -f 00-namespace.yaml

# Deploy ConfigMap (reference only — init containers do the real config)
echo "[2/5] Applying configuration reference..."
kubectl --context "${CONTEXT}" apply -f 01-configmap.yaml

# Deploy OMS server (includes init container to enable OMS auto_start)
echo "[3/5] Deploying OMS server..."
kubectl --context "${CONTEXT}" apply -f 02-oms-server.yaml

# Wait for OMS — image is ~600MB on first pull, allow 3 minutes
echo "      Waiting for OMS to be ready (first deploy pulls ~600MB image)..."
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/oms-server --timeout=180s

# Deploy UAG agents (includes init container to patch OMS address)
echo "[4/5] Deploying UAG agents..."
kubectl --context "${CONTEXT}" apply -f 03-uag-agent.yaml

# Deploy network policies
echo "[5/5] Applying network policies..."
kubectl --context "${CONTEXT}" apply -f 04-networkpolicy.yaml

# Wait for agents
echo "      Waiting for agents to be ready..."
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/uag-agent --timeout=180s

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Pods:"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods -o wide
echo ""
echo "Services:"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get svc
echo ""
echo "Verify agent connection:"
echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/uag-agent -c uag | grep 'Transport connected'"
echo ""
echo "View logs:"
echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l app=oms-server -c oms -f"
echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} logs -l app=uag-agent -c uag -f"
echo ""
echo "Teardown:"
echo "  ./teardown.sh ${CONTEXT}"
