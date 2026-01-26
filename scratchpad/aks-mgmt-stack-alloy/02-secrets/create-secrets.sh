#!/bin/bash
# Create secrets for AKS Management Stack
# This script creates secrets from environment variables or prompts

set -e

echo "Creating secrets for AKS Management Stack..."
echo ""

# Event Hub Secret
echo "=== Event Hub Secret ==="
if [ -z "$EVENTHUB_SAS_KEY_NAME" ]; then
  read -p "Event Hub SAS Key Name (default: RootManageSharedAccessKey): " EVENTHUB_SAS_KEY_NAME
  EVENTHUB_SAS_KEY_NAME=${EVENTHUB_SAS_KEY_NAME:-RootManageSharedAccessKey}
fi

if [ -z "$EVENTHUB_SAS_KEY" ]; then
  read -sp "Event Hub SAS Key: " EVENTHUB_SAS_KEY
  echo ""
fi

kubectl create secret generic eventhub-listener-secret \
  --namespace argo-events \
  --from-literal=sharedAccessKeyName="$EVENTHUB_SAS_KEY_NAME" \
  --from-literal=sharedAccessKey="$EVENTHUB_SAS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created eventhub-listener-secret"
echo ""

# Holmes Secrets
echo "=== Holmes API Secrets ==="
if [ -z "$ANTHROPIC_API_KEY" ]; then
  read -sp "Anthropic API Key: " ANTHROPIC_API_KEY
  echo ""
fi

kubectl create secret generic holmes-secrets \
  --namespace holmesgpt \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created holmes-secrets"
echo ""

# GitLab Secret
echo "=== GitLab PAT Secret ==="
if [ -z "$GITLAB_PAT" ]; then
  read -sp "GitLab Personal Access Token: " GITLAB_PAT
  echo ""
fi

kubectl create secret generic gitlab-mcp-secret \
  --namespace argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="$GITLAB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created gitlab-mcp-secret"
echo ""

# PostgreSQL Secret for Mattermost
echo "=== PostgreSQL Secret ==="
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 24)}"

kubectl create secret generic postgresql-secret \
  --namespace mattermost \
  --from-literal=POSTGRES_USER="mattermost" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="mattermost" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created postgresql-secret"
echo ""

echo "All secrets created successfully!"
