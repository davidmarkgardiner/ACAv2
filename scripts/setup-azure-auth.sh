#!/bin/bash

# ============================================================================
# Azure Service Principal Setup Script for ACA Platform
# ============================================================================
# This script automates the creation of Azure Service Principal and
# Kubernetes secrets for Argo Workflows authentication.
#
# Usage:
#   ./scripts/setup-azure-auth.sh
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - kubectl configured to access Kubernetes cluster
#   - Appropriate Azure subscription permissions
# ============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SP_NAME="aca-platform-sp"
K8S_NAMESPACE="argo"
SECRET_NAME="azure-credentials"

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Please install: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi

    # Check Azure login
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Please run: az login"
        exit 1
    fi

    # Check kubectl access
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check kubectl config."
        exit 1
    fi

    log_success "All prerequisites met"
}

get_subscription_info() {
    log_info "Getting Azure subscription information..."

    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)

    echo ""
    echo "Subscription ID:   $SUBSCRIPTION_ID"
    echo "Subscription Name: $SUBSCRIPTION_NAME"
    echo "Tenant ID:         $TENANT_ID"
    echo ""

    read -p "Is this the correct subscription? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Please set the correct subscription with: az account set --subscription <SUBSCRIPTION_ID>"
        exit 1
    fi
}

create_service_principal() {
    log_info "Creating Azure Service Principal: $SP_NAME"

    # Check if SP already exists
    EXISTING_SP=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

    if [ -n "$EXISTING_SP" ]; then
        log_warning "Service Principal '$SP_NAME' already exists with client ID: $EXISTING_SP"
        read -p "Do you want to reset credentials? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Resetting Service Principal credentials..."
            SP_OUTPUT=$(az ad sp credential reset --id "$EXISTING_SP" --query "{clientId:appId, clientSecret:password, tenantId:tenant}" -o json)
        else
            log_error "Cannot proceed without valid credentials. Exiting."
            exit 1
        fi
    else
        log_info "Creating new Service Principal with Contributor role..."
        SP_OUTPUT=$(az ad sp create-for-rbac \
            --name "$SP_NAME" \
            --role Contributor \
            --scopes /subscriptions/$SUBSCRIPTION_ID \
            --query "{clientId:appId, clientSecret:password, tenantId:tenant}" \
            -o json)
    fi

    # Extract credentials
    CLIENT_ID=$(echo "$SP_OUTPUT" | jq -r '.clientId')
    CLIENT_SECRET=$(echo "$SP_OUTPUT" | jq -r '.clientSecret')

    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
        log_error "Failed to create or retrieve Service Principal credentials"
        exit 1
    fi

    log_success "Service Principal created/updated successfully"
    echo "Client ID: $CLIENT_ID"
    echo ""
}

test_service_principal() {
    log_info "Testing Service Principal authentication..."
    log_info "Note: Azure AD propagation may take 30-60 seconds..."

    MAX_RETRIES=6
    RETRY_DELAY=10

    for i in $(seq 1 $MAX_RETRIES); do
        if [ $i -gt 1 ]; then
            log_info "Retry $((i-1))/$((MAX_RETRIES-1)) - waiting ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi

        if az login --service-principal \
            -u "$CLIENT_ID" \
            -p "$CLIENT_SECRET" \
            --tenant "$TENANT_ID" \
            --output none 2>/dev/null; then
            log_success "Service Principal authentication successful"

            # Switch back to user account
            az login --output none 2>/dev/null || true
            return 0
        fi
    done

    log_error "Service Principal authentication failed after $MAX_RETRIES attempts"
    log_warning "The Service Principal was created but may need more time to propagate."
    log_warning "You can test manually with: az login --service-principal -u $CLIENT_ID -p <SECRET> --tenant $TENANT_ID"

    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
}

create_kubernetes_secret() {
    log_info "Creating Kubernetes secret in namespace: $K8S_NAMESPACE"

    # Create namespace if it doesn't exist
    if ! kubectl get namespace "$K8S_NAMESPACE" &> /dev/null; then
        log_info "Creating namespace: $K8S_NAMESPACE"
        kubectl create namespace "$K8S_NAMESPACE"
    fi

    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$K8S_NAMESPACE" &> /dev/null; then
        log_warning "Secret '$SECRET_NAME' already exists in namespace '$K8S_NAMESPACE'"
        read -p "Do you want to update it? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping secret creation"
            return
        fi
    fi

    # Create or update secret
    kubectl create secret generic "$SECRET_NAME" \
        --namespace="$K8S_NAMESPACE" \
        --from-literal=client-id="$CLIENT_ID" \
        --from-literal=client-secret="$CLIENT_SECRET" \
        --from-literal=tenant-id="$TENANT_ID" \
        --from-literal=subscription-id="$SUBSCRIPTION_ID" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "Kubernetes secret created/updated successfully"
}

verify_secret() {
    log_info "Verifying Kubernetes secret..."

    # Check if secret exists and has correct keys
    KEYS=$(kubectl get secret "$SECRET_NAME" -n "$K8S_NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || true)

    REQUIRED_KEYS=("client-id" "client-secret" "tenant-id" "subscription-id")
    MISSING_KEYS=()

    for key in "${REQUIRED_KEYS[@]}"; do
        if ! echo "$KEYS" | grep -q "^${key}$"; then
            MISSING_KEYS+=("$key")
        fi
    done

    if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
        log_error "Secret is missing required keys: ${MISSING_KEYS[*]}"
        exit 1
    fi

    log_success "Secret verification passed"
}

test_from_pod() {
    log_info "Testing authentication from Kubernetes pod..."

    POD_NAME="azure-auth-test-$(date +%s)"

    kubectl run "$POD_NAME" \
        --namespace="$K8S_NAMESPACE" \
        --image=mcr.microsoft.com/azure-cli:latest \
        --restart=Never \
        --rm -i \
        --env="AZURE_CLIENT_ID=$(kubectl get secret $SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.client-id}' | base64 -d)" \
        --env="AZURE_CLIENT_SECRET=$(kubectl get secret $SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.client-secret}' | base64 -d)" \
        --env="AZURE_TENANT_ID=$(kubectl get secret $SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.tenant-id}' | base64 -d)" \
        --env="AZURE_SUBSCRIPTION_ID=$(kubectl get secret $SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.subscription-id}' | base64 -d)" \
        -- bash -c "az login --service-principal -u \$AZURE_CLIENT_ID -p \$AZURE_CLIENT_SECRET --tenant \$AZURE_TENANT_ID > /dev/null 2>&1 && echo 'SUCCESS' || echo 'FAILED'" > /tmp/azure-test-result.txt 2>&1

    if grep -q "SUCCESS" /tmp/azure-test-result.txt; then
        log_success "Pod authentication test passed"
    else
        log_error "Pod authentication test failed"
        cat /tmp/azure-test-result.txt
        exit 1
    fi

    rm -f /tmp/azure-test-result.txt
}

save_credentials() {
    log_info "Saving credentials to .env.azure file..."

    cat > .env.azure << EOF
# Azure Service Principal Credentials
# Generated: $(date)
# IMPORTANT: Keep this file secure and do not commit to version control

AZURE_CLIENT_ID=$CLIENT_ID
AZURE_CLIENT_SECRET=$CLIENT_SECRET
AZURE_TENANT_ID=$TENANT_ID
AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID
EOF

    chmod 600 .env.azure

    log_success "Credentials saved to .env.azure (chmod 600)"
    log_warning "Keep this file secure and do not commit to version control"
}

print_summary() {
    echo ""
    echo "============================================================================"
    echo "                        Setup Complete!"
    echo "============================================================================"
    echo ""
    echo "Service Principal:"
    echo "  Name:            $SP_NAME"
    echo "  Client ID:       $CLIENT_ID"
    echo "  Tenant ID:       $TENANT_ID"
    echo "  Subscription ID: $SUBSCRIPTION_ID"
    echo ""
    echo "Kubernetes Secret:"
    echo "  Name:            $SECRET_NAME"
    echo "  Namespace:       $K8S_NAMESPACE"
    echo ""
    echo "Credentials saved to: .env.azure"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy Argo Workflows: kubectl apply -f argo/workflows/"
    echo "  2. Deploy Argo Events: kubectl apply -f argo/events/"
    echo "  3. Test with sample payload: curl -X POST http://localhost:3000/api/v1/container-apps ..."
    echo ""
    echo "Documentation: docs/azure-setup.md"
    echo "============================================================================"
}

# ============================================================================
# Main Script
# ============================================================================

main() {
    echo ""
    echo "============================================================================"
    echo "         Azure Service Principal Setup for ACA Platform"
    echo "============================================================================"
    echo ""

    check_prerequisites
    get_subscription_info
    create_service_principal
    test_service_principal
    create_kubernetes_secret
    verify_secret

    read -p "Do you want to test authentication from a Kubernetes pod? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        test_from_pod
    fi

    save_credentials
    print_summary
}

# Run main function
main
