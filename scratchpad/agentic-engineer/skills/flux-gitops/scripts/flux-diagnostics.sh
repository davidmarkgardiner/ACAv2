#!/bin/bash
# Flux GitOps Diagnostics Script
# Usage: ./flux-diagnostics.sh

set -euo pipefail

echo "============================================"
echo "Flux GitOps Diagnostics"
echo "============================================"
echo ""

# Check Flux installation
echo "## Flux Installation Check"
echo "----------------------------------------"
flux check 2>/dev/null || echo "Flux check failed - may not be installed"
echo ""

# Get all Flux resources
echo "## Flux Resources Summary"
echo "----------------------------------------"
flux get all -A 2>/dev/null || echo "Could not get Flux resources"
echo ""

# Source status
echo "## Git Sources Status"
echo "----------------------------------------"
kubectl get gitrepositories -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
READY:.status.conditions[-1].status,\
MESSAGE:.status.conditions[-1].message 2>/dev/null || echo "No GitRepositories found"
echo ""

echo "## Helm Repositories Status"
echo "----------------------------------------"
kubectl get helmrepositories -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
READY:.status.conditions[-1].status 2>/dev/null || echo "No HelmRepositories found"
echo ""

# Kustomizations
echo "## Kustomizations Status"
echo "----------------------------------------"
kubectl get kustomizations -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
READY:.status.conditions[-1].status,\
MESSAGE:.status.conditions[-1].message 2>/dev/null || echo "No Kustomizations found"
echo ""

# HelmReleases
echo "## HelmReleases Status"
echo "----------------------------------------"
kubectl get helmreleases -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
READY:.status.conditions[-1].status,\
REVISION:.status.lastAppliedRevision 2>/dev/null || echo "No HelmReleases found"
echo ""

# Failed resources
echo "## Failed/Unhealthy Resources"
echo "----------------------------------------"
echo "Kustomizations with issues:"
kubectl get kustomizations -A -o json 2>/dev/null | jq -r '
    .items[] |
    select(.status.conditions[-1].status != "True") |
    "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[-1].message)"
' || echo "None"

echo ""
echo "HelmReleases with issues:"
kubectl get helmreleases -A -o json 2>/dev/null | jq -r '
    .items[] |
    select(.status.conditions[-1].status != "True") |
    "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[-1].message)"
' || echo "None"
echo ""

# Recent events
echo "## Recent Flux Events"
echo "----------------------------------------"
kubectl get events -n flux-system --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || echo "No events found"
echo ""

# Controller logs errors
echo "## Recent Controller Errors"
echo "----------------------------------------"
echo "Source Controller:"
kubectl logs -n flux-system -l app=source-controller --tail=20 2>/dev/null | grep -iE "error|fail" | tail -5 || echo "No errors"

echo ""
echo "Kustomize Controller:"
kubectl logs -n flux-system -l app=kustomize-controller --tail=20 2>/dev/null | grep -iE "error|fail" | tail -5 || echo "No errors"

echo ""
echo "Helm Controller:"
kubectl logs -n flux-system -l app=helm-controller --tail=20 2>/dev/null | grep -iE "error|fail" | tail -5 || echo "No errors"
echo ""

# Suspended resources
echo "## Suspended Resources"
echo "----------------------------------------"
echo "Kustomizations:"
kubectl get kustomizations -A -o json 2>/dev/null | jq -r '
    .items[] |
    select(.spec.suspend == true) |
    "\(.metadata.namespace)/\(.metadata.name)"
' || echo "None"

echo ""
echo "HelmReleases:"
kubectl get helmreleases -A -o json 2>/dev/null | jq -r '
    .items[] |
    select(.spec.suspend == true) |
    "\(.metadata.namespace)/\(.metadata.name)"
' || echo "None"
echo ""

echo "============================================"
echo "Flux diagnostics complete"
echo "============================================"
