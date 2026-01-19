#!/bin/bash
# AKS Checklist Kyverno Policies - Installation Script
# Usage: ./install.sh [--enforce] [--namespace <ns>] [--dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
MODE="audit"
DRY_RUN=""
NAMESPACE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --enforce)
            MODE="enforce"
            shift
            ;;
        --dry-run)
            DRY_RUN="--dry-run=client"
            shift
            ;;
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --enforce     Apply policies in Enforce mode (default: Audit)"
            echo "  --dry-run     Show what would be applied without making changes"
            echo "  --namespace   Apply to specific namespace only"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}       AKS Checklist Kyverno Policies - Installation${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi

CLUSTER_NAME=$(kubectl config current-context)
echo -e "  Cluster: ${GREEN}${CLUSTER_NAME}${NC}"

# Check if Kyverno is installed
if ! kubectl get deployment -n kyverno kyverno-admission-controller &> /dev/null; then
    echo -e "${YELLOW}Warning: Kyverno doesn't appear to be installed${NC}"
    echo ""
    read -p "Install Kyverno now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Installing Kyverno...${NC}"
        kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml
        echo -e "${GREEN}Kyverno installed. Waiting for pods to be ready...${NC}"
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=kyverno -n kyverno --timeout=120s
    else
        echo -e "${YELLOW}Skipping Kyverno installation. Policies may fail to apply.${NC}"
    fi
fi

echo ""
echo -e "${BLUE}Installation Settings:${NC}"
echo -e "  Mode:      ${YELLOW}${MODE}${NC}"
echo -e "  Dry Run:   ${YELLOW}${DRY_RUN:-No}${NC}"
echo -e "  Namespace: ${YELLOW}${NAMESPACE:-All}${NC}"
echo ""

# If enforce mode, update policies
if [ "${MODE}" == "enforce" ]; then
    echo -e "${YELLOW}Warning: Enforce mode will block non-compliant resources!${NC}"
    echo -e "${YELLOW}It's recommended to run in Audit mode first.${NC}"
    echo ""
    read -p "Continue with Enforce mode? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 0
    fi
fi

# Create temporary directory for modified policies
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

echo -e "${BLUE}Preparing policies...${NC}"

# Copy and modify policies based on mode
for category_dir in "${POLICIES_DIR}"/*; do
    if [ -d "${category_dir}" ]; then
        category=$(basename "${category_dir}")
        mkdir -p "${TEMP_DIR}/${category}"
        
        for policy_file in "${category_dir}"/*.yaml; do
            if [ -f "${policy_file}" ]; then
                filename=$(basename "${policy_file}")
                
                if [ "${MODE}" == "enforce" ]; then
                    # Change Audit to Enforce
                    sed 's/validationFailureAction: Audit/validationFailureAction: Enforce/g' \
                        "${policy_file}" > "${TEMP_DIR}/${category}/${filename}"
                else
                    cp "${policy_file}" "${TEMP_DIR}/${category}/${filename}"
                fi
            fi
        done
    fi
done

# Count policies
POLICY_COUNT=$(find "${TEMP_DIR}" -name "*.yaml" -exec grep -l "kind: ClusterPolicy" {} \; | wc -l | tr -d ' ')
echo -e "  Found ${GREEN}${POLICY_COUNT}${NC} policies to install"
echo ""

# Apply policies
echo -e "${BLUE}Applying policies...${NC}"
echo ""

APPLIED=0
FAILED=0

for category_dir in "${TEMP_DIR}"/*; do
    if [ -d "${category_dir}" ]; then
        category=$(basename "${category_dir}")
        echo -e "  ${BLUE}Category: ${category}${NC}"
        
        for policy_file in "${category_dir}"/*.yaml; do
            if [ -f "${policy_file}" ]; then
                filename=$(basename "${policy_file}")
                
                if kubectl apply -f "${policy_file}" ${DRY_RUN} 2>&1 | grep -q "error\|Error"; then
                    echo -e "    ${RED}✗${NC} ${filename}"
                    ((FAILED++)) || true
                else
                    echo -e "    ${GREEN}✓${NC} ${filename}"
                    ((APPLIED++)) || true
                fi
            fi
        done
        echo ""
    fi
done

# Summary
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                      Installation Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Applied:${NC} ${APPLIED} policies"
echo -e "  ${RED}Failed:${NC}  ${FAILED} policies"
echo ""

if [ -z "${DRY_RUN}" ]; then
    echo -e "${GREEN}Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Check policy reports: kubectl get policyreport -A"
    echo "  2. Run quick scan: ./scripts/quick-scan.sh"
    echo "  3. View cluster policy reports: kubectl get clusterpolicyreport"
else
    echo -e "${YELLOW}Dry run complete. No changes were made.${NC}"
    echo "Run without --dry-run to apply policies."
fi

echo ""
