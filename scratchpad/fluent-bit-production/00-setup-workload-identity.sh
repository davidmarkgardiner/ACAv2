#!/bin/bash
# Setup Workload Identity and Event Hub for Fluent Bit Production
# Automates:
# 1. Azure Event Hub creation
# 2. Managed Identity creation (Sender & Receiver)
# 3. Workload Identity federation
# 4. Kubernetes Secrets & ConfigMaps creation

set -e

# ============================================
# CONFIGURATION
# ============================================
RESOURCE_GROUP="${RESOURCE_GROUP:-aks-prod-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-prod-cluster}"
LOCATION="${LOCATION:-uksouth}"
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-k8s-events-hub-fb}"
EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events}"

# Identity names
SENDER_IDENTITY="fluent-bit-events-sender"
RECEIVER_IDENTITY="eventhub-receiver-identity" # For Argo

# Kubernetes details
MONITORING_NAMESPACE="monitoring"
ARGO_EVENTS_NAMESPACE="argo-events"
FLUENT_BIT_SA="fluent-bit-events"
EVENTSOURCE_SA="eventhub-eventsource-sa"

# ============================================
# PRE-FLIGHT CHECKS
# ============================================
echo "=== Verifying prerequisites ==="

# Get Tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)
if [ -z "$TENANT_ID" ]; then
    echo "ERROR: Could not get Azure Tenant ID. Please login with 'az login'."
    exit 1
fi

# Check AKS OIDC issuer
OIDC_ISSUER=$(az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null)
if [ -z "$OIDC_ISSUER" ]; then
    echo "ERROR: OIDC Issuer not enabled on AKS cluster $CLUSTER_NAME"
    exit 1
fi

# Check Workload Identity
WI_ENABLED=$(az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query securityProfile.workloadIdentity.enabled -o tsv 2>/dev/null)
if [ "$WI_ENABLED" != "true" ]; then
    echo "ERROR: Workload Identity not enabled on AKS cluster"
    exit 1
fi

# ============================================
# 1. SETUP AZURE EVENT HUB
# ============================================
echo ""
echo "=== Setting up Azure Event Hub ==="

if ! az eventhubs namespace show -g $RESOURCE_GROUP -n $EVENTHUB_NAMESPACE &>/dev/null; then
    az eventhubs namespace create -g $RESOURCE_GROUP -n $EVENTHUB_NAMESPACE -l $LOCATION --sku Standard --enable-auto-inflate
fi

if ! az eventhubs eventhub show -g $RESOURCE_GROUP --namespace-name $EVENTHUB_NAMESPACE -n $EVENTHUB_NAME &>/dev/null; then
    az eventhubs eventhub create -g $RESOURCE_GROUP --namespace-name $EVENTHUB_NAMESPACE -n $EVENTHUB_NAME --partition-count 4 --cleanup-policy Delete --retention-time 24
fi

if ! az eventhubs eventhub consumer-group show -g $RESOURCE_GROUP --namespace-name $EVENTHUB_NAMESPACE --eventhub-name $EVENTHUB_NAME -n argo-events &>/dev/null; then
    az eventhubs eventhub consumer-group create -g $RESOURCE_GROUP --namespace-name $EVENTHUB_NAMESPACE --eventhub-name $EVENTHUB_NAME -n argo-events
fi

# ============================================
# 2. SETUP SENDER IDENTITY (FLUENT BIT)
# ============================================
echo ""
echo "=== Setting up Sender Identity (Workload Identity) ==="

if ! az identity show -g $RESOURCE_GROUP -n $SENDER_IDENTITY &>/dev/null; then
    az identity create -g $RESOURCE_GROUP -n $SENDER_IDENTITY -l $LOCATION
fi
SENDER_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n $SENDER_IDENTITY --query clientId -o tsv)
SENDER_PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n $SENDER_IDENTITY --query principalId -o tsv)

echo "Assigning 'Azure Event Hubs Data Sender' role..."
SCOPE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.EventHub/namespaces/$EVENTHUB_NAMESPACE/eventhubs/$EVENTHUB_NAME"

az role assignment create \
    --assignee-object-id $SENDER_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Event Hubs Data Sender" \
    --scope "$SCOPE_ID" \
    2>/dev/null || echo "Role assignment exists"

# ============================================
# 3. SETUP RECEIVER IDENTITY (ARGO)
# ============================================
echo ""
echo "=== Setting up Receiver Identity (Workload Identity) ==="

if ! az identity show -g $RESOURCE_GROUP -n $RECEIVER_IDENTITY &>/dev/null; then
    az identity create -g $RESOURCE_GROUP -n $RECEIVER_IDENTITY -l $LOCATION
fi
RECEIVER_CLIENT_ID=$(az identity show -g $RESOURCE_GROUP -n $RECEIVER_IDENTITY --query clientId -o tsv)
RECEIVER_PRINCIPAL_ID=$(az identity show -g $RESOURCE_GROUP -n $RECEIVER_IDENTITY --query principalId -o tsv)

echo "Assigning 'Azure Event Hubs Data Receiver' role..."
az role assignment create \
    --assignee-object-id $RECEIVER_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Event Hubs Data Receiver" \
    --scope "$SCOPE_ID" \
    2>/dev/null || echo "Role assignment exists"

# ============================================
# 4. CREATE K8S RESOURCES
# ============================================
echo ""
echo "=== Creating Kubernetes ConfigMaps & ServiceAccounts ==="

# Create Namespaces
kubectl create namespace $MONITORING_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $ARGO_EVENTS_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# 4a. Fluent Bit - ConfigMap
kubectl create configmap eventhub-config -n $MONITORING_NAMESPACE \
    --from-literal=EVENTHUB_FQDN="$EVENTHUB_NAMESPACE.servicebus.windows.net" \
    --from-literal=EVENTHUB_NAME="$EVENTHUB_NAME" \
    --dry-run=client -o yaml | kubectl apply -f -

# 4b. Fluent Bit - Service Account
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $FLUENT_BIT_SA
  namespace: $MONITORING_NAMESPACE
  annotations:
    azure.workload.identity/client-id: "$SENDER_CLIENT_ID"
  labels:
    azure.workload.identity/use: "true"
EOF

# 4c. Argo Events - ConfigMap (Tenant ID)
kubectl create configmap azure-eventhub-aad-config -n $ARGO_EVENTS_NAMESPACE \
    --from-literal=tenant-id="$TENANT_ID" \
    --dry-run=client -o yaml | kubectl apply -f -

# 4d. Argo Events - Service Account
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $EVENTSOURCE_SA
  namespace: $ARGO_EVENTS_NAMESPACE
  annotations:
    azure.workload.identity/client-id: "$RECEIVER_CLIENT_ID"
  labels:
    azure.workload.identity/use: "true"
EOF

# ============================================
# 5. FEDERATE IDENTITIES
# ============================================
echo ""
echo "=== Federating Identities ==="

# Sender (Fluent Bit)
if ! az identity federated-credential show -g $RESOURCE_GROUP --identity-name $SENDER_IDENTITY -n "fed-$FLUENT_BIT_SA" &>/dev/null; then
    az identity federated-credential create \
        --name "fed-$FLUENT_BIT_SA" \
        --identity-name $SENDER_IDENTITY \
        --resource-group $RESOURCE_GROUP \
        --issuer "$OIDC_ISSUER" \
        --subject "system:serviceaccount:$MONITORING_NAMESPACE:$FLUENT_BIT_SA" \
        --audiences api://AzureADTokenExchange
fi

# Receiver (Argo)
if ! az identity federated-credential show -g $RESOURCE_GROUP --identity-name $RECEIVER_IDENTITY -n "fed-$EVENTSOURCE_SA" &>/dev/null; then
    az identity federated-credential create \
        --name "fed-$EVENTSOURCE_SA" \
        --identity-name $RECEIVER_IDENTITY \
        --resource-group $RESOURCE_GROUP \
        --issuer "$OIDC_ISSUER" \
        --subject "system:serviceaccount:$ARGO_EVENTS_NAMESPACE:$EVENTSOURCE_SA" \
        --audiences api://AzureADTokenExchange
fi

# ============================================
# 6. OUTPUT SUMMARY
# ============================================
echo ""
echo "============================================"
echo "FLUENT BIT + EVENT HUB SETUP COMPLETE"
echo "============================================"
echo "AZURE_CLIENT_ID (Sender): $SENDER_CLIENT_ID"
echo "AZURE_TENANT_ID: $TENANT_ID"
echo ""
echo "Next Steps:"
echo "1. Update 02-fluent-bit-deployment.yaml env vars:"
echo "   - AZURE_CLIENT_ID: $SENDER_CLIENT_ID"
echo "   - AZURE_TENANT_ID: $TENANT_ID"
echo "2. kubectl apply -f 01-fluent-bit-config.yaml"
echo "3. kubectl apply -f 02-fluent-bit-deployment.yaml"
