#!/bin/bash
# AKS Node Diagnostics Script
# Usage: ./aks-node-diagnostics.sh <node-name>

set -euo pipefail

NODE_NAME="${1:-}"

if [[ -z "$NODE_NAME" ]]; then
    echo "Usage: $0 <node-name>"
    echo ""
    echo "Available nodes:"
    kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status
    exit 1
fi

echo "============================================"
echo "AKS Node Diagnostics: $NODE_NAME"
echo "============================================"
echo ""

echo "## Node Status"
echo "----------------------------------------"
kubectl get node "$NODE_NAME" -o wide
echo ""

echo "## Node Conditions"
echo "----------------------------------------"
kubectl get node "$NODE_NAME" -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}'
echo ""

echo "## Node Resources"
echo "----------------------------------------"
kubectl describe node "$NODE_NAME" | grep -A10 "Allocated resources:"
echo ""

echo "## Node Labels"
echo "----------------------------------------"
kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels}' | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' 2>/dev/null || kubectl get node "$NODE_NAME" --show-labels
echo ""

echo "## Node Taints"
echo "----------------------------------------"
kubectl get node "$NODE_NAME" -o jsonpath='{.spec.taints}' | jq '.' 2>/dev/null || echo "No taints"
echo ""

echo "## Pods on Node"
echo "----------------------------------------"
kubectl get pods -A --field-selector spec.nodeName="$NODE_NAME" -o wide
echo ""

echo "## Recent Node Events"
echo "----------------------------------------"
kubectl get events -A --field-selector involvedObject.name="$NODE_NAME" --sort-by='.lastTimestamp' | tail -20
echo ""

echo "## Node Capacity vs Allocatable"
echo "----------------------------------------"
echo "Capacity:"
kubectl get node "$NODE_NAME" -o jsonpath='{.status.capacity}' | jq '.'
echo ""
echo "Allocatable:"
kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable}' | jq '.'
echo ""

echo "## System Pods Status"
echo "----------------------------------------"
kubectl get pods -n kube-system --field-selector spec.nodeName="$NODE_NAME" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount

echo ""
echo "============================================"
echo "Diagnostics complete for: $NODE_NAME"
echo "============================================"
