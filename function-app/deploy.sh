#!/bin/bash
# ============================================================================
# Function App Deployment Script
# ============================================================================
# Builds, pushes, and deploys the function app to Azure Container Apps
# ============================================================================

set -e  # Exit on error

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v az >/dev/null 2>&1 || { log_error "Azure CLI is required but not installed. Install from https://aka.ms/azure-cli"; exit 1; }
    command -v docker >/dev/null 2>&1 || { log_error "Docker is required but not installed."; exit 1; }

    log_info "Prerequisites check passed"
}

get_user_input() {
    log_info "Gathering deployment configuration..."

    # Get Azure Container Registry name
    read -p "Enter your Azure Container Registry name (e.g., myregistry): " ACR_NAME

    # Strip .azurecr.io suffix if user included it
    ACR_NAME="${ACR_NAME%.azurecr.io}"

    # Set derived values
    REGISTRY_SERVER="${ACR_NAME}.azurecr.io"
    IMAGE_NAME="function-app"
    IMAGE_TAG="${IMAGE_TAG:-latest}"
    FULL_IMAGE="${REGISTRY_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

    # Get resource group
    read -p "Enter resource group name (will be created if doesn't exist): " RESOURCE_GROUP

    # Get location
    read -p "Enter Azure location (default: eastus): " LOCATION
    LOCATION="${LOCATION:-eastus}"

    # Get environment
    read -p "Enter environment (dev/staging/prod, default: dev): " ENVIRONMENT
    ENVIRONMENT="${ENVIRONMENT:-dev}"

    log_info "Configuration:"
    echo "  Registry: ${REGISTRY_SERVER}"
    echo "  Image: ${FULL_IMAGE}"
    echo "  Resource Group: ${RESOURCE_GROUP}"
    echo "  Location: ${LOCATION}"
    echo "  Environment: ${ENVIRONMENT}"
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Deployment cancelled"
        exit 1
    fi
}

login_azure() {
    log_info "Checking Azure login status..."

    if ! az account show &>/dev/null; then
        log_warn "Not logged in to Azure. Please log in..."
        az login
    fi

    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    log_info "Using subscription: ${SUBSCRIPTION_ID}"
}

create_resource_group() {
    log_info "Ensuring resource group exists..."

    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        log_info "Resource group '${RESOURCE_GROUP}' already exists"
    else
        log_info "Creating resource group '${RESOURCE_GROUP}'..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
    fi
}

build_and_push_image() {
    log_info "Building Docker image for linux/amd64 platform..."

    cd "$SCRIPT_DIR"
    docker build --platform linux/amd64 -t "${FULL_IMAGE}" .

    log_info "Logging in to Azure Container Registry..."
    az acr login --name "${ACR_NAME}"

    log_info "Pushing image to registry..."
    docker push "${FULL_IMAGE}"

    log_info "Image pushed successfully: ${FULL_IMAGE}"
}

deploy_infrastructure() {
    log_info "Deploying infrastructure..."

    TEMPLATE_FILE="${PROJECT_ROOT}/bicep/templates/function-app-deployment.bicep"

    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_error "Template file not found: ${TEMPLATE_FILE}"
        exit 1
    fi

    DEPLOYMENT_NAME="funcapp-deployment-$(date +%Y%m%d-%H%M%S)"

    log_info "Starting deployment: ${DEPLOYMENT_NAME}"
    log_info "  Template: ${TEMPLATE_FILE}"
    log_info "  Image: ${FULL_IMAGE}"
    log_info "  Location: ${LOCATION}"
    log_info "  Environment: ${ENVIRONMENT}"

    # Deploy with inline parameters (no .bicepparam file needed)
    az deployment group create \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$TEMPLATE_FILE" \
        --parameters \
            namePrefix=funcapp \
            environment="$ENVIRONMENT" \
            location="$LOCATION" \
            containerImage="$FULL_IMAGE"

    if [ $? -eq 0 ]; then
        log_info "Deployment completed successfully"
    else
        log_error "Deployment failed"
        exit 1
    fi
}

show_outputs() {
    log_info "Retrieving deployment outputs..."

    DEPLOYMENT_NAME=$(az deployment group list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(name, 'funcapp-deployment')].name | [0]" \
        -o tsv)

    if [ -z "$DEPLOYMENT_NAME" ]; then
        log_warn "Could not find deployment outputs"
        return
    fi

    FUNCTION_URL=$(az deployment group show \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query properties.outputs.functionAppUrl.value \
        -o tsv 2>/dev/null || echo "")

    HEALTH_URL=$(az deployment group show \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query properties.outputs.healthCheckUrl.value \
        -o tsv 2>/dev/null || echo "")

    HELLO_URL=$(az deployment group show \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query properties.outputs.helloWorldUrl.value \
        -o tsv 2>/dev/null || echo "")

    echo ""
    log_info "==================================================="
    log_info "Deployment Complete!"
    log_info "==================================================="
    echo ""
    echo "Function App URL: ${FUNCTION_URL}"
    echo "Health Check: ${HEALTH_URL}"
    echo "Hello World: ${HELLO_URL}"
    echo ""
    log_info "Test your function:"
    echo "  curl ${HELLO_URL}"
    echo "  curl \"${HELLO_URL}?name=YourName\""
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "Starting Function App deployment..."
    echo ""

    check_prerequisites
    get_user_input
    login_azure
    create_resource_group
    build_and_push_image
    deploy_infrastructure
    show_outputs

    log_info "All done! 🚀"
}

main "$@"
