#!/bin/bash
# Kyverno Policy Report Summary Script
# Usage: ./policy-report-summary.sh [namespace]

set -euo pipefail

NAMESPACE="${1:-}"

echo "============================================"
echo "Kyverno Policy Report Summary"
if [[ -n "$NAMESPACE" ]]; then
    echo "Namespace: $NAMESPACE"
fi
echo "============================================"
echo ""

# Check if Kyverno is installed
if ! kubectl get crd policyreports.wgpolicyk8s.io &>/dev/null; then
    echo "ERROR: Kyverno PolicyReport CRD not found"
    echo "Is Kyverno installed?"
    exit 1
fi

# Cluster-wide summary
echo "## Cluster Policy Reports"
echo "----------------------------------------"
kubectl get clusterpolicyreport -o custom-columns=\
NAME:.metadata.name,\
PASS:.summary.pass,\
FAIL:.summary.fail,\
WARN:.summary.warn,\
ERROR:.summary.error,\
SKIP:.summary.skip 2>/dev/null || echo "No cluster policy reports found"
echo ""

# Namespace reports
echo "## Namespace Policy Reports"
echo "----------------------------------------"
if [[ -n "$NAMESPACE" ]]; then
    kubectl get policyreport -n "$NAMESPACE" -o custom-columns=\
NAME:.metadata.name,\
PASS:.summary.pass,\
FAIL:.summary.fail,\
WARN:.summary.warn,\
ERROR:.summary.error,\
SKIP:.summary.skip 2>/dev/null || echo "No policy reports found"
else
    kubectl get policyreport -A -o custom-columns=\
NAMESPACE:.metadata.namespace,\
NAME:.metadata.name,\
PASS:.summary.pass,\
FAIL:.summary.fail,\
WARN:.summary.warn 2>/dev/null || echo "No policy reports found"
fi
echo ""

# Violations by policy
echo "## Violations by Policy"
echo "----------------------------------------"
if [[ -n "$NAMESPACE" ]]; then
    REPORTS=$(kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null)
else
    REPORTS=$(kubectl get policyreport -A -o json 2>/dev/null)
fi

if [[ -n "$REPORTS" ]]; then
    echo "$REPORTS" | jq -r '
        .items[].results[]? |
        select(.result == "fail") |
        .policy
    ' | sort | uniq -c | sort -rn | head -20
else
    echo "No violations found"
fi
echo ""

# Recent violations
echo "## Recent Violations (last 10)"
echo "----------------------------------------"
if [[ -n "$NAMESPACE" ]]; then
    kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
        .items[].results[]? |
        select(.result == "fail") |
        "\(.policy) | \(.rule) | \(.resources[0].name // "N/A")"
    ' | head -10
else
    kubectl get policyreport -A -o json 2>/dev/null | jq -r '
        .items[] |
        .metadata.namespace as $ns |
        .results[]? |
        select(.result == "fail") |
        "\($ns) | \(.policy) | \(.rule)"
    ' | head -10
fi
echo ""

# Policies with most violations
echo "## Top Violating Resources"
echo "----------------------------------------"
if [[ -n "$NAMESPACE" ]]; then
    kubectl get policyreport -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
        .items[].results[]? |
        select(.result == "fail") |
        .resources[0].name // "unknown"
    ' | sort | uniq -c | sort -rn | head -10
else
    kubectl get policyreport -A -o json 2>/dev/null | jq -r '
        .items[].results[]? |
        select(.result == "fail") |
        .resources[0].name // "unknown"
    ' | sort | uniq -c | sort -rn | head -10
fi
echo ""

echo "============================================"
echo "Policy report summary complete"
echo "============================================"
