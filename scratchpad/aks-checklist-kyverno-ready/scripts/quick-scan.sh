#!/bin/bash
# AKS Checklist Quick Scan Script
# Usage: ./quick-scan.sh [namespace] [category]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"
OUTPUT_DIR="${SCRIPT_DIR}/../reports"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
NAMESPACE="${1:-all}"
CATEGORY="${2:-all}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}       AKS Checklist Compliance Scanner - Quick Scan${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Namespace: ${YELLOW}${NAMESPACE}${NC}"
echo -e "Category:  ${YELLOW}${CATEGORY}${NC}"
echo -e "Timestamp: ${TIMESTAMP}"
echo ""

# Check if kyverno CLI is installed
if ! command -v kyverno &> /dev/null; then
    echo -e "${RED}Error: kyverno CLI not found${NC}"
    echo "Install with: brew install kyverno/tap/kyverno-cli"
    echo "Or download from: https://github.com/kyverno/kyverno/releases"
    exit 1
fi

# Check if kubectl can access cluster
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo -e "Cluster:   ${YELLOW}${CLUSTER_NAME}${NC}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Build namespace flag
NS_FLAG=""
if [ "${NAMESPACE}" != "all" ]; then
    NS_FLAG="-n ${NAMESPACE}"
fi

# Build policy path
if [ "${CATEGORY}" == "all" ]; then
    POLICY_PATH="${POLICIES_DIR}"
else
    POLICY_PATH="${POLICIES_DIR}/${CATEGORY}"
    if [ ! -d "${POLICY_PATH}" ]; then
        echo -e "${RED}Error: Category '${CATEGORY}' not found${NC}"
        echo "Available categories:"
        ls -1 "${POLICIES_DIR}"
        exit 1
    fi
fi

echo -e "${BLUE}Starting compliance scan...${NC}"
echo ""

# Run the scan
REPORT_FILE="${OUTPUT_DIR}/scan-${TIMESTAMP}.json"
SUMMARY_FILE="${OUTPUT_DIR}/scan-${TIMESTAMP}-summary.txt"

kyverno apply "${POLICY_PATH}" \
    --cluster \
    ${NS_FLAG} \
    --policy-report \
    -o json > "${REPORT_FILE}" 2>&1 || true

# Parse and display results
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                        SCAN RESULTS${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Count results
PASS_COUNT=$(jq '[.results[] | select(.result == "pass")] | length' "${REPORT_FILE}" 2>/dev/null || echo "0")
FAIL_COUNT=$(jq '[.results[] | select(.result == "fail")] | length' "${REPORT_FILE}" 2>/dev/null || echo "0")
WARN_COUNT=$(jq '[.results[] | select(.result == "warn")] | length' "${REPORT_FILE}" 2>/dev/null || echo "0")
SKIP_COUNT=$(jq '[.results[] | select(.result == "skip")] | length' "${REPORT_FILE}" 2>/dev/null || echo "0")
ERROR_COUNT=$(jq '[.results[] | select(.result == "error")] | length' "${REPORT_FILE}" 2>/dev/null || echo "0")

TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [ ${TOTAL} -gt 0 ]; then
    COMPLIANCE=$(echo "scale=1; (${PASS_COUNT} * 100) / ${TOTAL}" | bc)
else
    COMPLIANCE="N/A"
fi

echo -e "  ${GREEN}✓ Pass:${NC}    ${PASS_COUNT}"
echo -e "  ${RED}✗ Fail:${NC}    ${FAIL_COUNT}"
echo -e "  ${YELLOW}⚠ Warn:${NC}    ${WARN_COUNT}"
echo -e "  ○ Skip:    ${SKIP_COUNT}"
echo -e "  ⊘ Error:   ${ERROR_COUNT}"
echo ""
echo -e "  ${BLUE}Compliance Score: ${COMPLIANCE}%${NC}"
echo ""

# Show failures
if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                        FAILURES${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    jq -r '.results[] | select(.result == "fail") | "  Policy: \(.policy)\n  Rule: \(.rule)\n  Resource: \(.resource.namespace)/\(.resource.kind)/\(.resource.name)\n  Message: \(.message)\n"' "${REPORT_FILE}" 2>/dev/null | head -100
    
    if [ "${FAIL_COUNT}" -gt 20 ]; then
        echo ""
        echo -e "${YELLOW}  ... and $((FAIL_COUNT - 20)) more failures. See full report: ${REPORT_FILE}${NC}"
    fi
fi

# Generate summary file
cat > "${SUMMARY_FILE}" << EOF
AKS Checklist Compliance Scan Summary
=====================================
Cluster:    ${CLUSTER_NAME}
Namespace:  ${NAMESPACE}
Category:   ${CATEGORY}
Timestamp:  ${TIMESTAMP}

Results:
- Pass:       ${PASS_COUNT}
- Fail:       ${FAIL_COUNT}
- Warn:       ${WARN_COUNT}
- Skip:       ${SKIP_COUNT}
- Error:      ${ERROR_COUNT}
- Compliance: ${COMPLIANCE}%

Full report: ${REPORT_FILE}
EOF

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "Reports saved to:"
echo -e "  JSON:    ${REPORT_FILE}"
echo -e "  Summary: ${SUMMARY_FILE}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Exit with appropriate code
if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
else
    exit 0
fi
