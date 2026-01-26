# Grafana Alloy Deployment Guide for AKS

**Consolidated guide for deploying Alloy to collect Kubernetes events and send to Azure Event Hub.**

This guide combines best practices from multiple implementations in this repo.

## Quick Reference

| Source | Location | Best For |
|--------|----------|----------|
| Weekend Agent | `08-kind-setup/alloy/` | Alloy Operator CRD, deduplication examples |
| PR #7 | `k8s-event-triage/workload-cluster/` | Production AKS with External Secrets |
| PR #6 | `../local-triage-stack/aks-deploy/` | Full stack with Argo Events integration |

---

## Architecture

```
┌──────────────────────┐     ┌─────────────────────┐     ┌────────────────────────┐
│  AKS Workload Cluster │     │   Azure Event Hub   │     │  Management Cluster    │
│                      │     │   (Kafka Protocol)  │     │                        │
│  ┌────────────────┐  │     │                     │     │  ┌──────────────────┐  │
│  │ K8s Events API │  │     │                     │     │  │ Argo EventSource │  │
│  └───────┬────────┘  │     │                     │     │  └────────┬─────────┘  │
│          │           │     │                     │     │           │            │
│          ▼           │     │                     │     │           ▼            │
│  ┌────────────────┐  │     │  ┌───────────────┐  │     │  ┌──────────────────┐  │
│  │ Grafana Alloy  │──┼─────┼─►│  kube-events  │──┼─────┼─►│  Sensor          │  │
│  │ - Filter       │  │     │  │  topic        │  │     │  │  - Triage        │  │
│  │ - Dedupe       │  │     │  └───────────────┘  │     │  │  - Alert         │  │
│  │ - Rate Limit   │  │     │                     │     │  └──────────────────┘  │
│  └────────────────┘  │     │                     │     │                        │
└──────────────────────┘     └─────────────────────┘     └────────────────────────┘
```

---

## Prerequisites

### 1. Azure Event Hub

```bash
# Create Event Hub namespace (if not exists)
az eventhubs namespace create \
  --name k8s-events-hub \
  --resource-group <YOUR_RG> \
  --location <REGION> \
  --sku Standard

# Create Event Hub (topic)
az eventhubs eventhub create \
  --name kube-events \
  --namespace-name k8s-events-hub \
  --resource-group <YOUR_RG> \
  --partition-count 4 \
  --message-retention 1

# Get connection string
az eventhubs namespace authorization-rule keys list \
  --resource-group <YOUR_RG> \
  --namespace-name k8s-events-hub \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv
```

### 2. Create Namespace

```bash
kubectl create namespace monitoring
```

---

## Option A: Quick Deploy (Script-based)

Use the deploy script from `08-kind-setup/alloy/`:

```bash
# Set required variables
export EVENTHUB_CONNECTION_STRING='Endpoint=sb://k8s-events-hub.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...'
export EVENTHUB_NAMESPACE='k8s-events-hub'
export EVENTHUB_NAME='kube-events'
export CLUSTER_NAME='aks-prod-westeurope'
export CLUSTER_REGION='westeurope'
export CLUSTER_ENVIRONMENT='production'
export WATCH_NAMESPACES='default,kube-system,app-ns'

# Deploy
cd aks-mgmt-stack/08-kind-setup/alloy
./deploy-alloy.sh
```

### Test Mode (Safe Rollout)

```bash
# Use separate Event Hub topic for testing
export TEST_MODE=true
./deploy-alloy.sh
```

---

## Option B: Production Deploy (Manifests)

### Step 1: Create Secret

**Option B1: Direct Secret (dev/test)**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: eventhub-sas-secret
  namespace: monitoring
type: Opaque
stringData:
  connectionString: "Endpoint=sb://k8s-events-hub.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=..."
```

**Option B2: External Secrets (production - recommended)**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: eventhub-sas-secret
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: eventhub-sas-secret
  data:
    - secretKey: connectionString
      remoteRef:
        key: eventhub-connection-string
```

### Step 2: Apply Alloy Config

Use `k8s-event-triage/workload-cluster/02-alloy-config.yaml` as base:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-events-config
  namespace: monitoring
data:
  config.alloy: |
    // =============================================================================
    // Grafana Alloy - K8s Events to Azure Event Hub
    // =============================================================================

    // Stage 1: Collect K8s Events
    loki.source.kubernetes_events "k8s_events" {
      namespaces = ["default", "kube-system", "app-ns"]  // UPDATE: your namespaces
      job_name   = "kubernetes-events"
      log_format = "json"
      forward_to = [loki.process.filter_and_enrich.receiver]
    }

    // Stage 2: Filter + Enrich + Rate Limit
    loki.process "filter_and_enrich" {
      // Only Warning events
      stage.match {
        selector = "{type!=\"Warning\"}"
        action   = "drop"
      }

      // Parse event fields
      stage.json {
        expressions = {
          event_type      = "type",
          event_reason    = "reason",
          event_message   = "message",
          obj_kind        = "involvedObject.kind",
          obj_name        = "involvedObject.name",
          obj_namespace   = "involvedObject.namespace",
          event_uid       = "metadata.uid",
        }
      }

      // Add cluster metadata
      stage.static_labels {
        values = {
          cluster             = env("CLUSTER_NAME"),
          cluster_region      = env("CLUSTER_REGION"),
          cluster_environment = env("CLUSTER_ENVIRONMENT"),
        }
      }

      // Rate limit: 10 events/min (prevents alert storms)
      stage.limit {
        rate  = 10
        burst = 10
        by_label_name = "event_uid"  // Dedupe by event UID
      }

      forward_to = [otelcol.receiver.loki.bridge.receiver]
    }

    // Stage 3: Bridge to OTEL
    otelcol.receiver.loki "bridge" {
      output {
        logs = [otelcol.processor.batch.events.input]
      }
    }

    // Stage 4: Batch before sending
    otelcol.processor.batch "events" {
      timeout             = "10s"
      send_batch_size     = 10
      send_batch_max_size = 20

      output {
        logs = [otelcol.exporter.kafka.eventhub.input]
      }
    }

    // Stage 5: Export to Event Hub
    otelcol.exporter.kafka "eventhub" {
      protocol_version = "2.0.0"
      brokers = [env("EVENTHUB_FQDN") + ":9093"]
      topic   = env("EVENTHUB_NAME")
      encoding = "json"

      auth {
        sasl {
          mechanism = "PLAIN"
          username  = "$ConnectionString"
          password  = env("EVENTHUB_CONNECTION_STRING")
        }
        tls {
          insecure = false
        }
      }

      retry_on_failure {
        enabled          = true
        initial_interval = "500ms"
        max_interval     = "30s"
        max_elapsed_time = "5m"
      }
    }

    // Health endpoints
    logging {
      level  = "info"
      format = "logfmt"
    }
```

### Step 3: Apply Deployment

Use `k8s-event-triage/workload-cluster/03-alloy-deployment.yaml`:

```bash
kubectl apply -f k8s-event-triage/workload-cluster/02-alloy-config.yaml
kubectl apply -f k8s-event-triage/workload-cluster/03-alloy-deployment.yaml
```

---

## Option C: Alloy Operator (GitOps-friendly)

If you have the Alloy Operator installed, use the CRD format from `08-kind-setup/alloy/examples/`:

```bash
# Install Alloy Operator
helm repo add grafana https://grafana.github.io/helm-charts
helm install alloy-operator grafana/alloy-operator -n monitoring

# Create secret first
kubectl create secret generic eventhub-credentials \
  --namespace=monitoring \
  --from-literal=EVENTHUB_NAMESPACE="k8s-events-hub" \
  --from-literal=EVENTHUB_NAME="kube-events" \
  --from-literal=EVENTHUB_CONNECTION_STRING="Endpoint=sb://..."

# Apply Alloy CRD
kubectl apply -f 08-kind-setup/alloy/examples/k8s-events-kafka/alloy-events-eventhub.yaml
```

---

## Verification

### 1. Check Alloy Pod

```bash
kubectl get pods -n monitoring -l app=alloy-events
kubectl logs -n monitoring -l app=alloy-events -f
```

### 2. Access Alloy UI

```bash
kubectl port-forward -n monitoring svc/alloy-events 12345:12345
# Open http://localhost:12345
```

### 3. Generate Test Events

```bash
# Create test namespace (if not watching default)
kubectl create namespace dg-demo

# Create failing pod (generates Warning events)
kubectl run test-crash -n dg-demo --image=invalid-image-xyz --restart=Never

# Check events exist
kubectl get events -n dg-demo --field-selector type=Warning

# Cleanup
kubectl delete pod test-crash -n dg-demo
```

### 4. Verify in Event Hub

```bash
# Check Event Hub metrics
az eventhubs eventhub show \
  --namespace-name k8s-events-hub \
  --name kube-events \
  --resource-group <YOUR_RG> \
  --query "messageRetentionInDays"

# Or use Azure Portal > Event Hub > Process Data > Explore
```

---

## Configuration Reference

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `EVENTHUB_CONNECTION_STRING` | Yes | - | SAS connection string |
| `EVENTHUB_FQDN` | Yes | - | `<namespace>.servicebus.windows.net` |
| `EVENTHUB_NAME` | Yes | - | Event Hub (topic) name |
| `CLUSTER_NAME` | No | `unknown` | Cluster identifier |
| `CLUSTER_REGION` | No | `unknown` | Azure region |
| `CLUSTER_ENVIRONMENT` | No | `unknown` | Environment (dev/prod) |

### Namespaces to Watch

Edit the `namespaces` array in the config:

```river
loki.source.kubernetes_events "k8s_events" {
  namespaces = ["default", "kube-system", "production"]  // Specific namespaces
  // OR
  namespaces = []  // All namespaces (not recommended)
}
```

### Rate Limiting

Adjust to prevent alert storms:

```river
stage.limit {
  rate  = 10       // events per minute
  burst = 20       // max burst
  by_label_name = "event_uid"  // dedupe key
}
```

---

## Troubleshooting

### Alloy Pod Not Starting

```bash
kubectl describe pod -n monitoring -l app=alloy-events
kubectl logs -n monitoring -l app=alloy-events --previous
```

### No Events in Event Hub

1. **Check namespace has events:**
   ```bash
   kubectl get events -n <namespace> --field-selector type=Warning
   ```

2. **Check Alloy logs:**
   ```bash
   kubectl logs -n monitoring -l app=alloy-events | grep -i "event\|error"
   ```

3. **Check connectivity:**
   ```bash
   kubectl exec -n monitoring deploy/alloy-events -- \
     wget -qO- --timeout=5 https://k8s-events-hub.servicebus.windows.net || echo "Failed"
   ```

4. **Verify secret:**
   ```bash
   kubectl get secret -n monitoring eventhub-sas-secret -o jsonpath='{.data.connectionString}' | base64 -d
   ```

### Events Not Triggering Argo Workflows

Check sensor logs:
```bash
kubectl logs -n argo-events -l sensor-name=<your-sensor>
```

---

## Migration from Fluent Bit

See `08-kind-setup/README.md` for detailed migration steps:

1. Deploy Alloy in test mode (separate topic)
2. Validate JSON format matches expected structure
3. Switch Alloy to production topic
4. Scale down Fluent Bit
5. Cleanup after validation

---

## Related Files

| Purpose | Location |
|---------|----------|
| Script-based deploy | `08-kind-setup/alloy/deploy-alloy.sh` |
| Alloy Operator examples | `08-kind-setup/alloy/examples/k8s-events-kafka/` |
| Production workload cluster | `k8s-event-triage/workload-cluster/` |
| Management cluster (Argo Events) | `k8s-event-triage/management-cluster/` |
| Local dev stack | `../local-triage-stack/` |
| AKS-ready full stack | `../local-triage-stack/aks-deploy/` |
