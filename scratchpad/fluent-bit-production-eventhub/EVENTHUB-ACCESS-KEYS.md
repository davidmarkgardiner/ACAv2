# Azure Event Hub Access Keys - Least Privilege Setup

Configure separate Shared Access Policies for sender (Fluent Bit) and receiver (Argo Events EventSource).

## Access Policy Types

| Policy | Rights | Use Case |
|--------|--------|----------|
| **Manage** | Send, Listen, Manage | Admin only - creating topics, policies |
| **Send** | Send only | Fluent Bit (producer) |
| **Listen** | Listen only | EventSource (consumer) |

## Setup Commands

### Prerequisites

```bash
# Set variables
export RESOURCE_GROUP="your-rg"
export EVENTHUB_NAMESPACE="k8s-events-hub"
export EVENTHUB_NAME="kube-events"
export KEY_VAULT="your-keyvault"
```

### 1. Create Send Policy (for Fluent Bit)

```bash
az eventhubs eventhub authorization-rule create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "fluent-bit-sender" \
  --rights Send
```

### 2. Create Listen Policy (for EventSource)

```bash
az eventhubs eventhub authorization-rule create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events-listener" \
  --rights Listen
```

### 3. Verify Policies Created

```bash
az eventhubs eventhub authorization-rule list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --output table
```

---

## Configure Fluent Bit (Sender)

### Get Send Connection String

```bash
SEND_CONN_STRING=$(az eventhubs eventhub authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "fluent-bit-sender" \
  --query primaryConnectionString -o tsv)

echo "Connection string: $SEND_CONN_STRING"
```

### Store in Key Vault (for External Secrets)

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name eventhub-connection-string \
  --value "$SEND_CONN_STRING"
```

### Or Create K8s Secret Directly (Worker Cluster)

```bash
kubectl create secret generic eventhub-sas-secret \
  --namespace monitoring \
  --from-literal=connectionString="$SEND_CONN_STRING"
```

---

## Configure EventSource (Listener)

### Get Listen Key

```bash
LISTEN_KEY_NAME="argo-events-listener"

LISTEN_KEY=$(az eventhubs eventhub authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name $LISTEN_KEY_NAME \
  --query primaryKey -o tsv)

echo "Key name: $LISTEN_KEY_NAME"
echo "Key value: ${LISTEN_KEY:0:20}..." # Show first 20 chars only
```

### Store in Key Vault (for External Secrets)

```bash
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name eventhub-shared-access-key-name \
  --value "$LISTEN_KEY_NAME"

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name eventhub-shared-access-key \
  --value "$LISTEN_KEY"
```

### Or Create K8s Secret Directly (Management Cluster)

```bash
kubectl create secret generic eventhub-listener-secret \
  --namespace argo-events \
  --from-literal=sharedAccessKeyName="$LISTEN_KEY_NAME" \
  --from-literal=sharedAccessKey="$LISTEN_KEY"
```

---

## Summary

| Cluster | Component | Secret Name | Policy | Rights |
|---------|-----------|-------------|--------|--------|
| Worker | Fluent Bit | `eventhub-sas-secret` | `fluent-bit-sender` | Send |
| Management | EventSource | `eventhub-listener-secret` | `argo-events-listener` | Listen |

---

## Verify Secrets

### Worker Cluster (Fluent Bit)

```bash
# Check secret exists
kubectl get secret eventhub-sas-secret -n monitoring

# Verify connection string format (should contain 'fluent-bit-sender')
kubectl get secret eventhub-sas-secret -n monitoring \
  -o jsonpath='{.data.connectionString}' | base64 -d | grep -o 'SharedAccessKeyName=[^;]*'
```

### Management Cluster (EventSource)

```bash
# Check secret exists
kubectl get secret eventhub-listener-secret -n argo-events

# Verify key name
kubectl get secret eventhub-listener-secret -n argo-events \
  -o jsonpath='{.data.sharedAccessKeyName}' | base64 -d
# Should output: argo-events-listener
```

---

## Troubleshooting

### "Unauthorized" Error in Fluent Bit

```bash
# Check the policy has Send rights
az eventhubs eventhub authorization-rule show \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "fluent-bit-sender" \
  --query rights -o tsv
# Should show: Send
```

### "Unauthorized" Error in EventSource

```bash
# Check the policy has Listen rights
az eventhubs eventhub authorization-rule show \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events-listener" \
  --query rights -o tsv
# Should show: Listen
```

### Regenerate Keys (if compromised)

```bash
# Regenerate primary key for listener
az eventhubs eventhub authorization-rule keys renew \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events-listener" \
  --key PrimaryKey

# Then update the K8s secret or Key Vault
```

---

## Quick Setup Script

```bash
#!/bin/bash
set -e

RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:?Set EVENTHUB_NAMESPACE}"
EVENTHUB_NAME="${EVENTHUB_NAME:-kube-events}"

echo "Creating Send policy for Fluent Bit..."
az eventhubs eventhub authorization-rule create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "fluent-bit-sender" \
  --rights Send 2>/dev/null || echo "Already exists"

echo "Creating Listen policy for EventSource..."
az eventhubs eventhub authorization-rule create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events-listener" \
  --rights Listen 2>/dev/null || echo "Already exists"

echo ""
echo "=== Send Key (for Fluent Bit) ==="
az eventhubs eventhub authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "fluent-bit-sender" \
  --query '{keyName:keyName, primaryKey:primaryKey}' -o table

echo ""
echo "=== Listen Key (for EventSource) ==="
az eventhubs eventhub authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events-listener" \
  --query '{keyName:keyName, primaryKey:primaryKey}' -o table
```
