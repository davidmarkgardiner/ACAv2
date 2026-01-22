# End-to-End Deployment Guide: Fluent Bit → Event Hub → HolmesGPT

Complete guide for deploying the Kubernetes event pipeline from scratch.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           WORKER CLUSTER (AKS)                              │
│                                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐ │
│  │ External     │───►│ K8s Secret   │───►│ Fluent Bit   │───►│ Event Hub │ │
│  │ Secrets Op   │    │ (SAS Token)  │    │ (Kafka Out)  │    │           │ │
│  └──────┬───────┘    └──────────────┘    └──────────────┘    └─────┬─────┘ │
│         │                                                          │       │
└─────────│──────────────────────────────────────────────────────────│───────┘
          │                                                          │
          ▼                                                          │
   ┌─────────────┐                                                   │
   │ Azure Key   │                                                   │
   │ Vault       │                                                   │
   └─────────────┘                                                   │
                                                                     │
┌────────────────────────────────────────────────────────────────────│───────┐
│                        MANAGEMENT CLUSTER                          │       │
│                                                                    ▼       │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────┐ │
│  │ Argo Events  │◄───│ EventSource  │◄───│ Event Hub    │◄───┤          │ │
│  │ Sensor       │    │              │    │ Consumer     │    │          │ │
│  └──────┬───────┘    └──────────────┘    └──────────────┘    └──────────┘ │
│         │                                                                  │
│         ▼                                                                  │
│  ┌──────────────┐    ┌──────────────┐                                     │
│  │ HolmesGPT    │───►│ GitLab Issue │                                     │
│  │ Workflow     │    │ Created      │                                     │
│  └──────────────┘    └──────────────┘                                     │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Required Access
- [ ] Azure subscription with Key Vault and Event Hub permissions
- [ ] AKS cluster admin access (both worker and management clusters)
- [ ] External Secrets Operator installed on worker cluster
- [ ] Argo Workflows + Argo Events installed on management cluster

### Tools Required
```bash
# Verify tools are installed
az --version          # Azure CLI
kubectl version       # Kubernetes CLI
```

---

## Phase 1: Azure Infrastructure Setup

### Step 1.1: Create Event Hub Namespace and Hub

```bash
# Set variables
export RESOURCE_GROUP="rg-holmesgpt"
export LOCATION="westeurope"
export EVENTHUB_NAMESPACE="k8s-events-$(openssl rand -hex 4)"
export EVENTHUB_NAME="kube-events"

# Create resource group (if needed)
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create Event Hub Namespace
az eventhubs namespace create \
  --name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard

# Create Event Hub (topic)
az eventhubs eventhub create \
  --name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP \
  --partition-count 2 \
  --message-retention 1

# Create consumer group for Argo Events
az eventhubs eventhub consumer-group create \
  --name argo-events \
  --eventhub-name $EVENTHUB_NAME \
  --namespace-name $EVENTHUB_NAMESPACE \
  --resource-group $RESOURCE_GROUP

echo "Event Hub FQDN: ${EVENTHUB_NAMESPACE}.servicebus.windows.net"
```

### Step 1.2: Get Connection String and Store in Key Vault

```bash
# Set Key Vault name (use existing or create new)
export KEY_VAULT_NAME="kv-holmesgpt"

# Get Event Hub connection string
EVENTHUB_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString \
  --output tsv)

# Store in Key Vault
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name eventhub-connection-string \
  --value "$EVENTHUB_CONNECTION_STRING"

# Verify
az keyvault secret show \
  --vault-name $KEY_VAULT_NAME \
  --name eventhub-connection-string \
  --query "name" -o tsv
```

### Step 1.3: Verify External Secrets Can Access Key Vault

```bash
# Check if ClusterSecretStore exists
kubectl get clustersecretstore

# If using Azure Workload Identity, verify the identity has access
# The ClusterSecretStore's identity needs "Key Vault Secrets User" role
```

---

## Phase 2: Worker Cluster Setup (Fluent Bit)

### Step 2.1: Create Namespace

```bash
# Switch to worker cluster context
kubectl config use-context <your-worker-cluster>

# Create monitoring namespace
kubectl create namespace monitoring
```

### Step 2.2: Configure External Secret

Edit `00-external-secret.yaml` to match your ClusterSecretStore:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: eventhub-sas-secret
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault          # <-- UPDATE: Your ClusterSecretStore name
    kind: ClusterSecretStore
  target:
    name: eventhub-sas-secret
    creationPolicy: Owner
  data:
    - secretKey: connectionString
      remoteRef:
        key: eventhub-connection-string
```

Apply:
```bash
kubectl apply -f 00-external-secret.yaml

# Verify secret was synced
kubectl get externalsecret -n monitoring
# STATUS should be "SecretSynced"

kubectl get secret eventhub-sas-secret -n monitoring
# Should exist
```

### Step 2.3: Configure Fluent Bit

Edit `02-fluent-bit-deployment.yaml` ConfigMap with your Event Hub details:

```yaml
data:
  EVENTHUB_NAMESPACE: "k8s-events-XXXX"                    # <-- UPDATE
  EVENTHUB_NAME: "kube-events"
  EVENTHUB_FQDN: "k8s-events-XXXX.servicebus.windows.net"  # <-- UPDATE
```

Edit the Deployment env var:
```yaml
env:
  - name: CLUSTER_NAME
    value: "your-aks-cluster-name"  # <-- UPDATE: Unique identifier
```

Apply:
```bash
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml

# Check deployment
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit -f
```

### Step 2.4: Verify Fluent Bit is Working

```bash
# Check logs for successful Kafka connection
kubectl logs -n monitoring -l app=fluent-bit | grep -i kafka

# Should see:
# [info] [output:kafka:kafka.0] brokers=*.servicebus.windows.net:9093

# Generate a test warning event
kubectl run test-warning --image=invalid:v999 --restart=Never -n default

# Check if Fluent Bit picked it up
kubectl logs -n monitoring -l app=fluent-bit | grep -i warning

# Clean up test pod
kubectl delete pod test-warning -n default --ignore-not-found
```

---

## Phase 3: Management Cluster Setup (Argo Events)

### Step 3.1: Prerequisites Check

```bash
# Switch to management cluster
kubectl config use-context <your-management-cluster>

# Verify Argo Events is installed
kubectl get pods -n argo-events

# Verify EventBus exists
kubectl get eventbus -n argo-events
```

### Step 3.2: Create Event Hub Secret for Argo Events

Argo Events needs its own secret to consume from Event Hub:

```bash
# Get the connection string again
EVENTHUB_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString \
  --output tsv)

# Create secret in argo-events namespace
kubectl create secret generic eventhub-connection \
  --namespace argo-events \
  --from-literal=connection-string="$EVENTHUB_CONNECTION_STRING"
```

### Step 3.3: Configure EventSource

Edit `03-eventsource-workload-identity.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: eventhub-k8s-events
  namespace: argo-events
spec:
  azureEventsHub:
    k8s-warnings:
      fqdn: "k8s-events-XXXX.servicebus.windows.net"  # <-- UPDATE
      hubName: "kube-events"
      sharedAccessKeyName:
        name: eventhub-connection
        key: connection-string
      sharedAccessKey:
        name: eventhub-connection
        key: connection-string
      consumerGroup: argo-events
```

Apply:
```bash
kubectl apply -f 03-eventsource-workload-identity.yaml

# Check status
kubectl get eventsource -n argo-events
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events
```

### Step 3.4: Configure Sensor and Workflow

Edit `04-sensor-production.yaml` if needed (GitLab project path, etc.)

Apply:
```bash
kubectl apply -f 04-sensor-production.yaml

# Check status
kubectl get sensor -n argo-events
kubectl describe sensor k8s-warnings-sensor -n argo-events
```

---

## Phase 4: End-to-End Test

### Step 4.1: Generate Test Event on Worker Cluster

```bash
# Switch to worker cluster
kubectl config use-context <your-worker-cluster>

# Create a pod that will generate a Warning event
kubectl run e2e-test --image=nonexistent-image:v1 --restart=Never

# Wait a moment, then check Fluent Bit logs
kubectl logs -n monitoring -l app=fluent-bit | tail -20

# Clean up
kubectl delete pod e2e-test --ignore-not-found
```

### Step 4.2: Verify Event Reached Management Cluster

```bash
# Switch to management cluster
kubectl config use-context <your-management-cluster>

# Check EventSource logs for incoming messages
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events | tail -20

# Watch for workflow execution
kubectl get workflows -n argo-events -w

# Check if sensor received the event
kubectl logs -n argo-events -l sensor-name=k8s-warnings-sensor | tail -20
```

### Step 4.3: Verify GitLab Issue (if configured)

Check your GitLab project for a new issue created by HolmesGPT.

---

## Troubleshooting

### External Secret Not Syncing

```bash
# Check ExternalSecret status
kubectl describe externalsecret eventhub-sas-secret -n monitoring

# Common issues:
# - ClusterSecretStore name mismatch
# - Key Vault secret name mismatch
# - Identity doesn't have Key Vault access
```

### Fluent Bit Not Connecting to Event Hub

```bash
# Check logs for auth errors
kubectl logs -n monitoring -l app=fluent-bit | grep -i error

# Verify secret has the connection string
kubectl get secret eventhub-sas-secret -n monitoring -o jsonpath='{.data.connectionString}' | base64 -d

# Common issues:
# - Connection string format incorrect
# - Event Hub namespace/name mismatch
# - Network policy blocking outbound traffic
```

### EventSource Not Receiving Events

```bash
# Check EventSource logs
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events

# Common issues:
# - Consumer group doesn't exist
# - Connection string missing sharedAccessKey
# - FQDN incorrect
```

### Sensor Not Triggering Workflows

```bash
# Check sensor status
kubectl describe sensor k8s-warnings-sensor -n argo-events

# Check if EventBus is healthy
kubectl get eventbus -n argo-events

# Common issues:
# - EventBus not running
# - Dependency name mismatch between EventSource and Sensor
```

---

## Configuration Reference

### Environment Variables Summary

| Variable | Location | Description |
|----------|----------|-------------|
| `CLUSTER_NAME` | Fluent Bit Deployment | Unique identifier for source cluster |
| `EVENTHUB_NAMESPACE` | ConfigMap | Event Hub namespace name |
| `EVENTHUB_NAME` | ConfigMap | Event Hub (topic) name |
| `EVENTHUB_FQDN` | ConfigMap | Full FQDN (namespace.servicebus.windows.net) |
| `EVENTHUB_CONNECTION_STRING` | Secret | SAS connection string (from Key Vault) |

### Files in This Directory

| File | Purpose | Apply To |
|------|---------|----------|
| `00-external-secret.yaml` | Syncs SAS token from Key Vault | Worker Cluster |
| `01-fluent-bit-config.yaml` | Fluent Bit ConfigMap (Kafka output) | Worker Cluster |
| `02-fluent-bit-deployment.yaml` | Fluent Bit Deployment + RBAC | Worker Cluster |
| `03-eventsource-workload-identity.yaml` | Argo EventSource | Management Cluster |
| `04-sensor-production.yaml` | Argo Sensor | Management Cluster |

---

## Quick Reference Commands

```bash
# === WORKER CLUSTER ===
kubectl config use-context <worker>
kubectl get externalsecret -n monitoring
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit -f

# === MANAGEMENT CLUSTER ===
kubectl config use-context <management>
kubectl get eventsource -n argo-events
kubectl get sensor -n argo-events
kubectl get workflows -n argo-events -w
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events -f
```

---

## Next Steps

- [ ] Add additional worker clusters (repeat Phase 2 for each)
- [ ] Configure HolmesGPT integration (API keys, LiteLLM)
- [ ] Set up GitLab token for issue creation
- [ ] Add Prometheus monitoring for Fluent Bit
- [ ] Configure secret rotation alerts
