#!/bin/bash
# Kyverno Policy Test Script
# Usage: ./test-policy.sh <policies-dir> [test-resources-dir]

set -euo pipefail

POLICIES_DIR="${1:-}"
RESOURCES_DIR="${2:-}"

if [[ -z "$POLICIES_DIR" ]]; then
    echo "Usage: $0 <policies-dir> [test-resources-dir]"
    echo ""
    echo "Examples:"
    echo "  $0 ./policies                    # Validate all policies"
    echo "  $0 ./policies ./test-resources   # Test policies against resources"
    exit 1
fi

echo "============================================"
echo "Kyverno Policy Testing"
echo "Policies: $POLICIES_DIR"
echo "============================================"
echo ""

# Check if kyverno CLI is installed
if ! command -v kyverno &> /dev/null; then
    echo "ERROR: kyverno CLI not found"
    echo "Install with: kubectl krew install kyverno"
    exit 1
fi

# Validate policies
echo "## Policy Validation"
echo "----------------------------------------"
POLICY_FILES=$(find "$POLICIES_DIR" -name "*.yaml" -o -name "*.yml")
VALIDATION_ERRORS=0

for policy in $POLICY_FILES; do
    echo -n "Validating: $(basename "$policy")... "
    if kyverno validate "$policy" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    fi
done

echo ""
echo "Validation complete: $VALIDATION_ERRORS errors"
echo ""

# Test against resources if provided
if [[ -n "$RESOURCES_DIR" && -d "$RESOURCES_DIR" ]]; then
    echo "## Policy Testing"
    echo "----------------------------------------"

    for policy in $POLICY_FILES; do
        POLICY_NAME=$(basename "$policy" .yaml)
        echo ""
        echo "Testing policy: $POLICY_NAME"
        echo "---"

        # Find matching test resources
        for resource in "$RESOURCES_DIR"/*.yaml "$RESOURCES_DIR"/*.yml; do
            if [[ -f "$resource" ]]; then
                RESOURCE_NAME=$(basename "$resource")
                echo -n "  $RESOURCE_NAME: "
                RESULT=$(kyverno apply "$policy" --resource "$resource" 2>&1)
                if echo "$RESULT" | grep -q "pass"; then
                    echo "PASS"
                elif echo "$RESULT" | grep -q "fail"; then
                    echo "FAIL"
                else
                    echo "SKIP"
                fi
            fi
        done
    done
fi

# Run kyverno test if test files exist
TEST_FILES=$(find "$POLICIES_DIR" -name "*test*.yaml" -o -name "*test*.yml" 2>/dev/null)
if [[ -n "$TEST_FILES" ]]; then
    echo ""
    echo "## Running Kyverno Tests"
    echo "----------------------------------------"
    kyverno test "$POLICIES_DIR" || echo "Some tests failed"
fi

echo ""
echo "============================================"
echo "Policy testing complete"
echo "============================================"
