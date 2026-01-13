#!/bin/bash
# Pod Diagnostics Script
# Usage: ./pod-diagnostics.sh <namespace> <pod-name>

set -euo pipefail

NAMESPACE="${1:-}"
POD_NAME="${2:-}"

if [[ -z "$NAMESPACE" || -z "$POD_NAME" ]]; then
    echo "Usage: $0 <namespace> <pod-name>"
    exit 1
fi

echo "============================================"
echo "Pod Diagnostics: $POD_NAME"
echo "Namespace: $NAMESPACE"
echo "============================================"
echo ""

# Pod Status
echo "## Pod Status"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o wide
echo ""

# Pod Phase and Conditions
echo "## Pod Phase and Conditions"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='Phase: {.status.phase}{"\n"}'
echo "Conditions:"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'
echo ""

# Container Statuses
echo "## Container Statuses"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .status.containerStatuses[*]}Container: {.name}{"\n"}  Ready: {.ready}{"\n"}  Restart Count: {.restartCount}{"\n"}  State: {.state}{"\n"}{end}'
echo ""

# Last Termination (if any)
echo "## Last Termination Info"
echo "----------------------------------------"
TERM_REASON=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}' 2>/dev/null)
if [[ -n "$TERM_REASON" ]]; then
    echo "Reason: $TERM_REASON"
    kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='Exit Code: {.status.containerStatuses[*].lastState.terminated.exitCode}{"\n"}'
    kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='Message: {.status.containerStatuses[*].lastState.terminated.message}{"\n"}'
else
    echo "No previous termination"
fi
echo ""

# Resource Requests/Limits
echo "## Resource Configuration"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .spec.containers[*]}Container: {.name}{"\n"}  Requests: CPU={.resources.requests.cpu}, Memory={.resources.requests.memory}{"\n"}  Limits: CPU={.resources.limits.cpu}, Memory={.resources.limits.memory}{"\n"}{end}'
echo ""

# Current Resource Usage
echo "## Current Resource Usage"
echo "----------------------------------------"
kubectl top pod "$POD_NAME" -n "$NAMESPACE" --containers 2>/dev/null || echo "Metrics not available"
echo ""

# Environment Variables
echo "## Environment Variables"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .spec.containers[*].env[*]}{.name}={.value}{"\n"}{end}' | head -20
echo "(showing first 20)"
echo ""

# Volume Mounts
echo "## Volume Mounts"
echo "----------------------------------------"
kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{range .spec.containers[*].volumeMounts[*]}{.name} -> {.mountPath}{"\n"}{end}'
echo ""

# Events
echo "## Recent Events"
echo "----------------------------------------"
kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$POD_NAME" --sort-by='.lastTimestamp' | tail -10
echo ""

# Recent Logs
echo "## Recent Logs (last 50 lines)"
echo "----------------------------------------"
kubectl logs "$POD_NAME" -n "$NAMESPACE" --tail=50 2>/dev/null || echo "Could not retrieve logs"
echo ""

echo "============================================"
echo "Diagnostics complete for: $POD_NAME"
echo "============================================"
