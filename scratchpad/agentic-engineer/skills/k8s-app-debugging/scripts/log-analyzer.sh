#!/bin/bash
# Log Analyzer Script - Search for common error patterns
# Usage: ./log-analyzer.sh <namespace> <pod-name> [container]

set -euo pipefail

NAMESPACE="${1:-}"
POD_NAME="${2:-}"
CONTAINER="${3:-}"

if [[ -z "$NAMESPACE" || -z "$POD_NAME" ]]; then
    echo "Usage: $0 <namespace> <pod-name> [container]"
    exit 1
fi

CONTAINER_ARG=""
if [[ -n "$CONTAINER" ]]; then
    CONTAINER_ARG="-c $CONTAINER"
fi

echo "============================================"
echo "Log Analysis: $POD_NAME"
echo "Namespace: $NAMESPACE"
echo "============================================"
echo ""

# Get logs
LOGS=$(kubectl logs "$POD_NAME" -n "$NAMESPACE" $CONTAINER_ARG --tail=1000 2>/dev/null)

if [[ -z "$LOGS" ]]; then
    echo "No logs available or pod not running"
    exit 1
fi

# Error patterns
echo "## Error Pattern Analysis"
echo "----------------------------------------"

patterns=(
    "error|Error|ERROR"
    "exception|Exception|EXCEPTION"
    "failed|Failed|FAILED|failure|Failure"
    "timeout|Timeout|TIMEOUT"
    "refused|Refused|REFUSED"
    "denied|Denied|DENIED"
    "OOM|OutOfMemory|out of memory"
    "crash|Crash|CRASH"
    "panic|Panic|PANIC"
    "fatal|Fatal|FATAL"
    "connection reset|connection refused"
    "permission denied"
    "no such file|not found"
)

for pattern in "${patterns[@]}"; do
    COUNT=$(echo "$LOGS" | grep -ciE "$pattern" 2>/dev/null || echo "0")
    if [[ "$COUNT" -gt 0 ]]; then
        echo "Pattern '$pattern': $COUNT occurrences"
    fi
done
echo ""

# Show actual errors
echo "## Recent Errors (last 20)"
echo "----------------------------------------"
echo "$LOGS" | grep -iE "error|exception|failed|timeout|refused|denied|crash|panic|fatal" | tail -20 || echo "No errors found"
echo ""

# HTTP Status Codes
echo "## HTTP Error Codes"
echo "----------------------------------------"
echo "$LOGS" | grep -oE "(4[0-9]{2}|5[0-9]{2})" | sort | uniq -c | sort -rn | head -10 || echo "No HTTP error codes found"
echo ""

# Stack traces
echo "## Stack Traces Detected"
echo "----------------------------------------"
STACK_COUNT=$(echo "$LOGS" | grep -cE "at .+\(.+:[0-9]+\)|Traceback|stacktrace" 2>/dev/null || echo "0")
echo "Stack trace indicators found: $STACK_COUNT"
echo ""

# Log levels distribution
echo "## Log Level Distribution"
echo "----------------------------------------"
echo "DEBUG: $(echo "$LOGS" | grep -ciE '\bdebug\b' || echo "0")"
echo "INFO:  $(echo "$LOGS" | grep -ciE '\binfo\b' || echo "0")"
echo "WARN:  $(echo "$LOGS" | grep -ciE '\bwarn\b|\bwarning\b' || echo "0")"
echo "ERROR: $(echo "$LOGS" | grep -ciE '\berror\b' || echo "0")"
echo ""

echo "============================================"
echo "Log analysis complete"
echo "============================================"
