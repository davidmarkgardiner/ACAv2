#!/bin/bash
# Deploy the kagent triage webhook Logic App
# Usage: ./deploy-logic-app.sh [resource-group] [location]

RG="${1:-dev-rg}"
LOCATION="${2:-uksouth}"
NAME="kagent-triage-webhook"

echo "Deploying Logic App: $NAME in $RG ($LOCATION)"

# Create the Logic App
az logic workflow create \
  --resource-group "$RG" \
  --name "$NAME" \
  --location "$LOCATION" \
  --definition "$(dirname "$0")/logic-app-definition.json"

# Get the webhook URL
WEBHOOK_URL=$(az rest --method POST \
  --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RG}/providers/Microsoft.Logic/workflows/${NAME}/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv)

echo ""
echo "=== Logic App Deployed ==="
echo "Webhook URL: $WEBHOOK_URL"
echo ""
echo "Create the K8s secret with:"
echo "  kubectl create secret generic logic-app-webhook-secret --from-literal=url=\"$WEBHOOK_URL\" -n argo-events"
