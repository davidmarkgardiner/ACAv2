#!/bin/bash
set -euo pipefail

# Deploy ONLY the OMS server to a central/management cluster.
# Remote agents on other clusters connect to this OMS.
#
# Usage:
#   ./deploy-central-oms.sh <context> [expose-method]
#
# Examples:
#   ./deploy-central-oms.sh proxmox-k8s              # ClusterIP only (same-cluster agents)
#   ./deploy-central-oms.sh aks-mgmt nodeport         # NodePort (dev/testing)
#   ./deploy-central-oms.sh aks-mgmt loadbalancer     # Internal LoadBalancer (production)

CONTEXT="${1:?Usage: $0 <kube-context> [expose-method: clusterip|nodeport|loadbalancer]}"
EXPOSE="${2:-clusterip}"
NAMESPACE="stonebranch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Central OMS to context: ${CONTEXT} ==="
echo "    Expose method: ${EXPOSE}"
echo ""

# Create namespace
echo "[1/3] Creating namespace..."
kubectl --context "${CONTEXT}" apply -f "${SCRIPT_DIR}/00-namespace.yaml"

# Deploy OMS server
echo "[2/3] Deploying OMS server..."
kubectl --context "${CONTEXT}" apply -f "${SCRIPT_DIR}/02-oms-server.yaml"

# Wait for OMS
echo "      Waiting for OMS to be ready (first deploy pulls ~600MB image)..."
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/oms-server --timeout=300s

# Expose OMS based on method
echo "[3/3] Exposing OMS (${EXPOSE})..."
case "${EXPOSE}" in
  clusterip)
    echo "      OMS available at: oms-server.${NAMESPACE}.svc.cluster.local:7878"
    echo "      (Only reachable from within this cluster)"
    ;;
  nodeport)
    # Create or patch service to NodePort
    kubectl --context "${CONTEXT}" -n "${NAMESPACE}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: oms-server-external
  namespace: stonebranch
  labels:
    app: oms-server
spec:
  type: NodePort
  ports:
  - name: oms
    port: 7878
    targetPort: 7878
    nodePort: 30878
    protocol: TCP
  - name: broker
    port: 7887
    targetPort: 7887
    nodePort: 30887
    protocol: TCP
  selector:
    app: oms-server
EOF
    NODE_IP=$(kubectl --context "${CONTEXT}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    echo ""
    echo "      OMS available at: ${NODE_IP}:30878"
    echo "      Remote agents should use: oms_servers 30878@${NODE_IP}"
    ;;
  loadbalancer)
    # Internal LoadBalancer (Azure annotation included, works on other clouds too)
    kubectl --context "${CONTEXT}" -n "${NAMESPACE}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: oms-server-external
  namespace: stonebranch
  labels:
    app: oms-server
  annotations:
    # Azure: internal LB
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    # AWS: internal NLB
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
    # GCP: internal LB
    networking.gke.io/load-balancer-type: "Internal"
EOF
    kubectl --context "${CONTEXT}" -n "${NAMESPACE}" patch svc oms-server-external \
      --type=merge -p '{
        "spec": {
          "type": "LoadBalancer",
          "ports": [
            {"name": "oms", "port": 7878, "targetPort": 7878, "protocol": "TCP"},
            {"name": "broker", "port": 7887, "targetPort": 7887, "protocol": "TCP"}
          ],
          "selector": {"app": "oms-server"}
        }
      }' 2>/dev/null || \
    kubectl --context "${CONTEXT}" -n "${NAMESPACE}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: oms-server-external
  namespace: stonebranch
  labels:
    app: oms-server
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
    networking.gke.io/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  ports:
  - name: oms
    port: 7878
    targetPort: 7878
    protocol: TCP
  - name: broker
    port: 7887
    targetPort: 7887
    protocol: TCP
  selector:
    app: oms-server
EOF
    echo ""
    echo "      Waiting for LoadBalancer IP..."
    for i in $(seq 1 30); do
      LB_IP=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get svc oms-server-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      if [ -n "${LB_IP}" ]; then
        echo "      OMS available at: ${LB_IP}:7878"
        echo "      Remote agents should use: oms_servers 7878@${LB_IP}"
        break
      fi
      sleep 5
    done
    if [ -z "${LB_IP:-}" ]; then
      echo "      LoadBalancer IP not yet assigned. Check:"
      echo "      kubectl --context ${CONTEXT} -n ${NAMESPACE} get svc oms-server-external"
    fi
    ;;
  *)
    echo "ERROR: Unknown expose method '${EXPOSE}'. Use: clusterip, nodeport, or loadbalancer"
    exit 1
    ;;
esac

echo ""
echo "=== Central OMS deployment complete ==="
echo ""
echo "Pods:"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods -o wide
echo ""
echo "Services:"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get svc
echo ""
echo "Next: Deploy remote agents on worker clusters:"
echo "  ./deploy-remote-agents.sh <worker-context> <oms-address>"
