#!/bin/bash
set -euo pipefail

# Deploy ONLY UAG agents to a worker cluster, connecting to a remote OMS.
#
# Usage:
#   ./deploy-remote-agents.sh <context> <oms-address> [replicas] [agent-prefix]
#
# Examples:
#   ./deploy-remote-agents.sh aks-worker1 10.0.1.100            # 2 agents, default names
#   ./deploy-remote-agents.sh aks-worker1 oms.mgmt.internal 3   # 3 agents
#   ./deploy-remote-agents.sh aks-worker2 10.0.1.100 2 WORKER2  # Custom prefix

CONTEXT="${1:?Usage: $0 <kube-context> <oms-address> [replicas] [agent-prefix]}"
OMS_ADDRESS="${2:?Usage: $0 <kube-context> <oms-address> [replicas] [agent-prefix]}"
REPLICAS="${3:-2}"
AGENT_PREFIX="${4:-UAG}"
NAMESPACE="stonebranch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Remote UAG Agents to context: ${CONTEXT} ==="
echo "    OMS address: ${OMS_ADDRESS}:7878"
echo "    Replicas: ${REPLICAS}"
echo "    Agent prefix: ${AGENT_PREFIX}"
echo ""

# Verify OMS is reachable (basic TCP check from a test pod)
echo "[0/4] Testing connectivity to OMS at ${OMS_ADDRESS}:7878..."
if kubectl --context "${CONTEXT}" run oms-connectivity-test \
    --image=busybox:1.36 --rm -it --restart=Never \
    --command -- timeout 5 nc -zv "${OMS_ADDRESS}" 7878 2>&1 | grep -q "open\|succeeded"; then
  echo "      OMS reachable!"
else
  echo "      WARNING: Could not confirm OMS connectivity."
  echo "      This may be OK if DNS isn't set up yet or if network policies block test pods."
  echo "      Proceeding with deployment..."
fi

# Create namespace
echo "[1/4] Creating namespace..."
kubectl --context "${CONTEXT}" apply -f "${SCRIPT_DIR}/00-namespace.yaml"

# Generate and apply agent deployment with custom OMS address
echo "[2/4] Generating agent deployment..."
cat <<EOF | kubectl --context "${CONTEXT}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uag-agent
  namespace: ${NAMESPACE}
  labels:
    app: uag-agent
    component: agent
    oms-target: "${OMS_ADDRESS}"
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: uag-agent
  template:
    metadata:
      labels:
        app: uag-agent
        component: agent
    spec:
      initContainers:
      - name: patch-agent-config
        image: stonebranch/universal-agent:8.0.0.0-debian
        command: ["sh", "-c"]
        args:
        - |
          # Copy default configs to writable volume
          cp -a /etc/universal/* /config/
          # Patch OMS server address to remote OMS
          sed -i 's|^oms_servers.*|oms_servers 7878@${OMS_ADDRESS}|' /config/uags.conf
          # Set unique agent name: PREFIX-<last 5 chars of pod hostname>
          sed -i "s|^netname.*|netname ${AGENT_PREFIX}-\$(hostname | tail -c 6)|" /config/uags.conf
          echo "=== Patched uags.conf ==="
          grep -E "^oms_servers|^netname" /config/uags.conf
        volumeMounts:
        - name: universal-config
          mountPath: /config
      containers:
      - name: uag
        image: stonebranch/universal-agent:8.0.0.0-debian
        volumeMounts:
        - name: universal-config
          mountPath: /etc/universal
        ports:
        - name: broker
          containerPort: 7887
          protocol: TCP
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          tcpSocket:
            port: 7887
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 7887
          initialDelaySeconds: 15
          periodSeconds: 5
      volumes:
      - name: universal-config
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: uag-agent
  namespace: ${NAMESPACE}
  labels:
    app: uag-agent
spec:
  type: ClusterIP
  ports:
  - name: broker
    port: 7887
    targetPort: 7887
    protocol: TCP
  selector:
    app: uag-agent
EOF

# Apply network policies (allow egress to OMS)
echo "[3/4] Applying network policies..."
kubectl --context "${CONTEXT}" apply -f "${SCRIPT_DIR}/04-networkpolicy.yaml"

# Wait for agents
echo "[4/4] Waiting for agents to be ready..."
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status deployment/uag-agent --timeout=180s

echo ""
echo "=== Remote agent deployment complete ==="
echo ""
echo "Pods:"
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pods -o wide
echo ""
echo "Verify connection to OMS:"
echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/uag-agent -c uag | grep 'Transport connected'"
echo ""
echo "View init container output (config patches):"
echo "  kubectl --context ${CONTEXT} -n ${NAMESPACE} logs deploy/uag-agent -c patch-agent-config"
echo ""
echo "Teardown:"
echo "  ./teardown.sh ${CONTEXT}"
