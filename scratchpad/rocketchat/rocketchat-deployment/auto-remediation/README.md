# Auto-Remediation Pipeline

Automated Kubernetes event triage using Fluent Bit, Azure Event Hub, and Argo Workflows.

## Architecture

```
+------------------+     +-----------------+     +------------------+
| Kubernetes       |     | Azure           |     | Argo Events      |
| Events API       |     | Event Hub       |     | EventSource      |
+--------+---------+     +--------+--------+     +--------+---------+
         |                        |                       |
         v                        v                       v
+------------------+     +-----------------+     +------------------+
| Fluent Bit       |---->| Kafka Protocol  |---->| Sensor           |
| (kubernetes_     |     | (SASL_PLAIN)    |     | (rate limited)   |
|  events input)   |     |                 |     |                  |
+------------------+     +-----------------+     +--------+---------+
                                                          |
                                                          v
                                                +------------------+
                                                | multi-cluster-   |
                                                | triage Workflow  |
                                                +--------+---------+
                                                          |
                                      +-------------------+-------------------+
                                      v                   v                   v
                              +-------------+     +-------------+     +-------------+
                              | Holmes      |     | GitLab      |     | RocketChat  |
                              | Investigation|    | Issue       |     | Notification|
                              +-------------+     +-------------+     +-------------+
```

## Authentication

Since Fluent Bit's Kafka output doesn't support Workload Identity (OAUTHBEARER), we use:

| Component | Auth Method | Secret Source |
|-----------|-------------|---------------|
| Fluent Bit → Event Hub | SASL_PLAIN (connection string) | Key Vault |
| EventSource → Event Hub | Shared Access Key | Key Vault |

**Connection string format:**
```
Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<key-name>;SharedAccessKey=<key-value>
```

## Files

| File | Purpose |
|------|---------|
| `01-fluent-bit-config.yaml` | ConfigMap with kubernetes_events input + Kafka output |
| `02-fluent-bit-deployment.yaml` | Deployment (not DaemonSet), RBAC, Service |
| `03-eventhub-config.yaml` | ConfigMaps + Secrets for Event Hub (TEMPLATE) |
| `04-eventsource-eventhub.yaml` | Argo Events EventSource for Event Hub |
| `05-sensor-auto-triage.yaml` | Sensor with rate limiting + ResourceQuota |
| `06-keyvault-integration.yaml` | Options for syncing secrets from Key Vault |

## Prerequisites

### 1. Azure Event Hub

```bash
# Create Event Hub namespace
az eventhubs namespace create \
  --name k8s-events-hub \
  --resource-group YOUR_RG \
  --location westeurope \
  --sku Standard

# Create Event Hub (topic)
az eventhubs eventhub create \
  --name kube-events \
  --namespace-name k8s-events-hub \
  --resource-group YOUR_RG \
  --partition-count 2

# Create consumer group for Argo Events
az eventhubs eventhub consumer-group create \
  --name argo-events \
  --eventhub-name kube-events \
  --namespace-name k8s-events-hub \
  --resource-group YOUR_RG
```

### 2. Store Connection String in Key Vault

```bash
# Get connection string
CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
  --resource-group YOUR_RG \
  --namespace-name k8s-events-hub \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)

# Store in Key Vault
az keyvault secret set \
  --vault-name YOUR_KEYVAULT \
  --name eventhub-connection-string \
  --value "$CONNECTION_STRING"

# Also store the key name and value separately (for Argo Events)
az keyvault secret set \
  --vault-name YOUR_KEYVAULT \
  --name eventhub-key-name \
  --value "RootManageSharedAccessKey"

KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \
  --resource-group YOUR_RG \
  --namespace-name k8s-events-hub \
  --name RootManageSharedAccessKey \
  --query primaryKey -o tsv)

az keyvault secret set \
  --vault-name YOUR_KEYVAULT \
  --name eventhub-key-value \
  --value "$KEY_VALUE"
```

### 3. Argo Events + EventBus

```bash
# Install Argo Events
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml

# Install EventBus
kubectl apply -n argo-events \
  -f https://raw.githubusercontent.com/argoproj/argo-events/stable/examples/eventbus/native.yaml
```

## Deployment

### Step 1: Update Configuration

Edit `03-eventhub-config.yaml`:
- Set `EVENTHUB_NAMESPACE`, `EVENTHUB_NAME`, `EVENTHUB_FQDN`
- Set `CLUSTER_NAME` to identify this cluster

Edit `04-eventsource-eventhub.yaml`:
- Set `fqdn` to your Event Hub FQDN

Edit `05-sensor-auto-triage.yaml`:
- Set `gitlab-project` to your repository

### Step 2: Deploy Key Vault Integration

Choose one option from `06-keyvault-integration.yaml`:

**Option A: External Secrets Operator (Recommended)**
```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Apply ClusterSecretStore and ExternalSecrets
kubectl apply -f 06-keyvault-integration.yaml
```

**Option B: CSI Driver (AKS built-in)**
```bash
# Enable on AKS
az aks enable-addons --addons azure-keyvault-secrets-provider \
  -g YOUR_RG -n YOUR_CLUSTER

# Apply SecretProviderClass
kubectl apply -f 06-keyvault-integration.yaml
```

**Option C: Manual (Testing only)**
```bash
# Get from Key Vault
CONNECTION_STRING=$(az keyvault secret show \
  --vault-name YOUR_KEYVAULT \
  --name eventhub-connection-string \
  --query value -o tsv)

# Create secrets
kubectl create secret generic eventhub-kafka-secret \
  -n monitoring \
  --from-literal=connection-string="$CONNECTION_STRING"

kubectl create secret generic eventhub-credentials \
  -n argo-events \
  --from-literal=key-name="RootManageSharedAccessKey" \
  --from-literal=key-value="$KEY_VALUE"
```

### Step 3: Deploy Pipeline

```bash
# Create namespaces
kubectl create namespace monitoring
kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -

# Deploy Fluent Bit
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml
kubectl apply -f 03-eventhub-config.yaml

# Deploy Argo Events components
kubectl apply -f 04-eventsource-eventhub.yaml
kubectl apply -f 05-sensor-auto-triage.yaml

# Deploy the triage workflow template (from parent folder)
kubectl apply -f ../workflows/workflow-multi-cluster-triage.yaml
```

## Verification

```bash
# Check Fluent Bit
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit --tail=30

# Check EventSource
kubectl get eventsource -n argo-events
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20

# Check Sensor
kubectl get sensor -n argo-events
kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -5

# Generate test event
kubectl run test-event -n default --image=nonexistent:test --restart=Never
kubectl delete pod test-event -n default --ignore-not-found
```

## Rate Limiting

The sensor is configured with rate limiting to prevent workflow floods:

```yaml
rateLimit:
  requestsPerUnit: 3
  unit: Minute
```

A single pod failure can generate multiple events (BackOff, ImagePullBackOff, Failed). Without rate limiting, this can create hundreds of workflows.

**Safety nets:**
- Sensor rate limit: 3 workflows/minute
- ResourceQuota: max 100 pods, 50 workflows
- Workflow TTL: auto-delete after 5 minutes

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Fluent Bit not sending | Connection string wrong | Check logs, verify secret |
| EventSource not receiving | Consumer group doesn't exist | Create consumer group in Azure |
| Too many workflows | Rate limiting insufficient | Reduce `requestsPerUnit` |
| Workflow fails with secret error | Key Vault sync failed | Check ExternalSecret status |
| Base64 decode error | Event Hub payload format | Use `b64dec` in dataTemplate |

### Debug Commands

```bash
# Fluent Bit logs
kubectl logs -n monitoring deployment/fluent-bit-events -f

# EventSource logs
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events -f

# Sensor logs
kubectl logs -n argo-events -l sensor-name=auto-triage-sensor -f

# Check ExternalSecret sync
kubectl get externalsecret -A
kubectl describe externalsecret eventhub-kafka-secret -n monitoring
```
