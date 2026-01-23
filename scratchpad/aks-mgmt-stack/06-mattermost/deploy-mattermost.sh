#!/bin/bash
# Deploy Mattermost stack

set -e

echo "Deploying Mattermost stack..."
echo ""

# Ensure namespace exists
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

# Check if PostgreSQL secret exists
if ! kubectl get secret postgresql-secret -n mattermost &>/dev/null; then
  echo "Creating PostgreSQL secret..."
  kubectl create secret generic postgresql-secret \
    --namespace mattermost \
    --from-literal=POSTGRES_USER="mattermost" \
    --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24)" \
    --from-literal=POSTGRES_DB="mattermost"
fi

# Deploy PostgreSQL
echo "Deploying PostgreSQL..."
kubectl apply -f 01-postgresql.yaml
echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgresql -n mattermost --timeout=120s

# Deploy Mattermost
echo "Deploying Mattermost..."
kubectl apply -f 02-mattermost.yaml
echo "Waiting for Mattermost to be ready..."
kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=180s

echo ""
echo "Mattermost deployed successfully!"
echo ""
echo "=== Next Steps ==="
echo ""
echo "1. Access Mattermost:"
echo "   kubectl port-forward -n mattermost svc/mattermost 8065:8065"
echo "   Open: http://localhost:8065"
echo ""
echo "2. Create an admin account and team"
echo ""
echo "3. Create an Incoming Webhook:"
echo "   - Go to: Menu > Integrations > Incoming Webhooks > Add"
echo "   - Select a channel (e.g., Town Square)"
echo "   - Click 'Save'"
echo "   - Copy the webhook URL"
echo ""
echo "4. Update the webhook ConfigMap:"
echo "   kubectl edit configmap mattermost-webhook-config -n argo-events"
echo "   # Replace WEBHOOK_URL with your actual webhook URL"
echo ""
echo "5. Apply the webhook config:"
echo "   kubectl apply -f 03-mattermost-webhook-config.yaml"
