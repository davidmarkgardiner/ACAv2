#!/bin/bash
# Network Connectivity Test Script
# Usage: ./network-connectivity-test.sh [namespace]

set -euo pipefail

NAMESPACE="${1:-default}"

echo "============================================"
echo "Network Connectivity Test"
echo "Namespace: $NAMESPACE"
echo "============================================"
echo ""

# DNS Test
echo "## DNS Resolution Test"
echo "----------------------------------------"
kubectl run dns-test-$$ --image=busybox --rm -it --restart=Never -n "$NAMESPACE" -- nslookup kubernetes.default 2>/dev/null || echo "DNS test failed"
echo ""

# CoreDNS Status
echo "## CoreDNS Status"
echo "----------------------------------------"
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
echo ""

# Network Policies
echo "## Network Policies in Namespace"
echo "----------------------------------------"
kubectl get networkpolicies -n "$NAMESPACE" 2>/dev/null || echo "No network policies found"
echo ""

# Services in Namespace
echo "## Services in Namespace"
echo "----------------------------------------"
kubectl get svc -n "$NAMESPACE" -o wide
echo ""

# Endpoints Check
echo "## Service Endpoints"
echo "----------------------------------------"
for svc in $(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
    ENDPOINTS=$(kubectl get endpoints "$svc" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [[ -z "$ENDPOINTS" ]]; then
        echo "$svc: NO ENDPOINTS"
    else
        echo "$svc: $ENDPOINTS"
    fi
done
echo ""

# Check for Azure CNI
echo "## Azure CNI Status"
echo "----------------------------------------"
kubectl get pods -n kube-system -l k8s-app=azure-cni-networkmonitor -o wide 2>/dev/null || echo "Azure CNI monitor not found (may be using overlay)"
echo ""

# Check kube-proxy
echo "## Kube-proxy Status"
echo "----------------------------------------"
kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide 2>/dev/null || echo "Kube-proxy pods not found"
echo ""

echo "============================================"
echo "Network connectivity test complete"
echo "============================================"
