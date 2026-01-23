#!/bin/bash
# AKS Management Stack - Quick Deployment Script
# Usage: ./deploy-stack.sh

set -e

echo "=========================================="
echo "AKS Management Stack Deployment"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check prerequisites
check_prereqs() {
    echo -e "\n${YELLOW}Checking prerequisites...${NC}"

    command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl not found${NC}"; exit 1; }
    command -v helm >/dev/null 2>&1 || { echo -e "${RED}helm not found${NC}"; exit 1; }

    echo -e "${GREEN}Prerequisites OK${NC}"
}

# Get user input for secrets
get_secrets() {
    echo -e "\n${YELLOW}Enter required secrets:${NC}"

    read -p "Event Hub SAS Key: " EVENTHUB_SAS_KEY
    read -p "Gemini API Key: " GEMINI_API_KEY
    read -p "GitLab Personal Access Token: " GITLAB_PAT
    read -p "GitLab Project (e.g., myorg/myrepo): " GITLAB_PROJECT
    read -p "GitLab Username (for assignee): " GITLAB_USERNAME
    read -p "Event Hub FQDN (e.g., myhub.servicebus.windows.net): " EVENTHUB_FQDN
}

# Create namespaces
create_namespaces() {
    echo -e "\n${YELLOW}Creating namespaces...${NC}"

    kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace holmesgpt --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}Namespaces created${NC}"
}

# Deploy Argo Workflows
deploy_argo_workflows() {
    echo -e "\n${YELLOW}Deploying Argo Workflows...${NC}"

    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update

    helm upgrade --install argo-workflows argo/argo-workflows -n argo \
        --set server.serviceType=ClusterIP \
        --set workflow.serviceAccount.create=true \
        --wait

    echo -e "${GREEN}Argo Workflows deployed${NC}"
}

# Deploy Argo Events
deploy_argo_events() {
    echo -e "\n${YELLOW}Deploying Argo Events...${NC}"

    helm upgrade --install argo-events argo/argo-events -n argo-events --wait

    # Create EventBus
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  native:
    replicas: 3
    auth: token
EOF

    echo -e "${GREEN}Argo Events deployed${NC}"
}

# Create secrets
create_secrets() {
    echo -e "\n${YELLOW}Creating secrets...${NC}"

    # Event Hub secret
    kubectl create secret generic eventhub-listener-secret -n argo-events \
        --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \
        --from-literal=sharedAccessKey="$EVENTHUB_SAS_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Holmes secrets
    kubectl create secret generic holmes-secrets -n holmesgpt \
        --from-literal=GOOGLE_API_KEY="$GEMINI_API_KEY" \
        --from-literal=ANTHROPIC_API_KEY="" \
        --from-literal=OPENAI_API_KEY="" \
        --dry-run=client -o yaml | kubectl apply -f -

    # GitLab secret
    kubectl create secret generic gitlab-mcp-secret -n argo-events \
        --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="$GITLAB_PAT" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}Secrets created${NC}"
}

# Deploy HolmesGPT
deploy_holmesgpt() {
    echo -e "\n${YELLOW}Deploying HolmesGPT...${NC}"

    kubectl apply -f 04-holmesgpt/
    kubectl wait --for=condition=available deployment/holmes -n holmesgpt --timeout=120s

    echo -e "${GREEN}HolmesGPT deployed${NC}"
}

# Deploy Mattermost
deploy_mattermost() {
    echo -e "\n${YELLOW}Deploying Mattermost...${NC}"

    kubectl apply -f 06-mattermost/

    echo "Waiting for PostgreSQL..."
    kubectl wait --for=condition=ready pod -l app=postgresql -n mattermost --timeout=120s

    echo "Waiting for Mattermost..."
    kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=180s

    echo -e "${GREEN}Mattermost deployed${NC}"
    echo -e "${YELLOW}NOTE: Configure webhook manually via port-forward${NC}"
    echo "  kubectl port-forward -n mattermost svc/mattermost 8065:8065"
}

# Deploy workflow template
deploy_workflow() {
    echo -e "\n${YELLOW}Deploying workflow template...${NC}"

    # Get GitLab user ID
    GITLAB_USER_ID=$(curl -s "https://gitlab.com/api/v4/users?username=$GITLAB_USERNAME" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -n "$GITLAB_USER_ID" ]; then
        echo "Found GitLab user ID: $GITLAB_USER_ID"
        # Update assignee ID in workflow template
        sed -i.bak "s/ASSIGNEE_ID=\"[0-9]*\"/ASSIGNEE_ID=\"$GITLAB_USER_ID\"/" 05-workflow/workflow-multi-cluster-triage-optimized.yaml
    fi

    # Update GitLab project in workflow template
    sed -i.bak "s|xxxmarkgardiner/mcp-test-repo|$GITLAB_PROJECT|g" 05-workflow/workflow-multi-cluster-triage-optimized.yaml

    kubectl apply -f 05-workflow/
    kubectl apply -f 06-rbac/ 2>/dev/null || true

    echo -e "${GREEN}Workflow template deployed${NC}"
}

# Deploy event flow
deploy_event_flow() {
    echo -e "\n${YELLOW}Deploying event flow...${NC}"

    # Update Event Hub FQDN
    sed -i.bak "s|xxx|$EVENTHUB_FQDN|g" 07-event-flow/01-eventsource-eventhub.yaml

    kubectl apply -f 07-event-flow/

    echo -e "${GREEN}Event flow deployed${NC}"
}

# Main deployment
main() {
    check_prereqs
    get_secrets
    create_namespaces
    deploy_argo_workflows
    deploy_argo_events
    create_secrets
    deploy_holmesgpt
    deploy_mattermost
    deploy_workflow
    deploy_event_flow

    echo -e "\n${GREEN}=========================================="
    echo "Deployment Complete!"
    echo "==========================================${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Configure Mattermost webhook:"
    echo "   kubectl port-forward -n mattermost svc/mattermost 8065:8065"
    echo "   Open http://localhost:8065, create webhook, update ConfigMap"
    echo ""
    echo "2. Deploy Fluent Bit on source cluster (see 08-kind-setup/)"
    echo ""
    echo "3. Test with manual workflow:"
    echo "   See README.md for test commands"
}

# Run
cd "$(dirname "$0")"
main
