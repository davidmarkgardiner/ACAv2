# Kind Cluster Event Collection Setup

This directory contains configurations for collecting Kubernetes events from a Kind cluster (or any source cluster) and forwarding them to Azure Event Hub for processing by Argo Events.

## Architecture

```
┌──────────────────┐     ┌─────────────────────┐     ┌──────────────────────┐
│  Source Cluster  │     │   Azure Event Hub   │     │  Management Cluster  │
│  (Kind/AKS)      │     │   (Kafka Protocol)  │     │  (AKS)               │
├──────────────────┤     ├─────────────────────┤     ├──────────────────────┤
│                  │     │                     │     │                      │
│  K8s Events API  │────►│  kube-events topic  │────►│  Argo Events Sensor  │
│        │         │     │                     │     │         │            │
│        ▼         │     │                     │     │         ▼            │
│  Grafana Alloy   │     │                     │     │  Triage Workflow     │
│  (event collector)│    │                     │     │  (HolmesGPT)         │
└──────────────────┘     └─────────────────────┘     └──────────────────────┘
```

## Current Implementation: Grafana Alloy

We use **Grafana Alloy** to collect Kubernetes events and forward them to Azure Event Hub.

### Why Alloy?

- **Unified telemetry stack**: Alloy is part of the Grafana observability stack
- **OpenTelemetry native**: Built-in support for OTEL protocols
- **Programmable pipelines**: River configuration language for flexible processing
- **Active development**: Grafana's strategic direction for telemetry collection

### Files

| File | Purpose |
|------|---------|
| `alloy/01-alloy-config.yaml` | ConfigMap with Alloy River configuration |
| `alloy/02-alloy-deployment.yaml` | Deployment, RBAC, and Service resources |
| `alloy/deploy-alloy.sh` | Installation script |

### Quick Start

```bash
# 1. Ensure kind cluster is running
kind get clusters

# 2. Set Event Hub connection string
export EVENTHUB_CONNECTION_STRING='Endpoint=sb://your-namespace.servicebus.windows.net/;SharedAccessKeyName=...'

# 3. Deploy Alloy
cd alloy
./deploy-alloy.sh

# 4. Create test namespace and generate events
kubectl create namespace dg-demo
kubectl run test-crash -n dg-demo --image=invalid-image-xyz --restart=Never

# 5. Check Alloy logs
kubectl logs -n monitoring -l app=alloy-events -f
```

### Configuration

#### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `EVENTHUB_CONNECTION_STRING` | Yes | - | Azure Event Hub SAS connection string |
| `EVENTHUB_NAMESPACE` | No | `k8s-events-hub-4808` | Event Hub namespace name |
| `EVENTHUB_FQDN` | No | `<namespace>.servicebus.windows.net` | Event Hub FQDN |
| `EVENTHUB_NAME` | No | `kube-events` | Event Hub topic name |
| `CLUSTER_NAME` | No | `kind-local` | Cluster identifier for metadata |
| `CLUSTER_REGION` | No | `local` | Cluster region for metadata |
| `CLUSTER_ENVIRONMENT` | No | `dev` | Environment (dev/staging/prod) |
| `WATCH_NAMESPACES` | No | `dg-demo` | Comma-separated list of namespaces to watch |

#### Watching Multiple Namespaces

```bash
export WATCH_NAMESPACES="dg-demo,production,staging"
./deploy-alloy.sh
```

### Testing Mode

To test without affecting production, use a separate Event Hub topic:

```bash
# 1. Create test Event Hub topic in Azure
az eventhubs eventhub create --name kube-events-alloy \
  --namespace-name k8s-events-hub-4808 \
  --resource-group <your-rg>

# 2. Deploy Alloy in test mode
export TEST_MODE=true
./deploy-alloy.sh

# 3. Generate test events
kubectl run test-crash -n dg-demo --image=invalid-image-xyz --restart=Never

# 4. Verify events in Azure Portal or via CLI
az eventhubs eventhub show \
  --namespace-name k8s-events-hub-4808 \
  --name kube-events-alloy \
  --query "messageRetentionInDays"
```

### Accessing Alloy UI

```bash
# Port forward to Alloy
kubectl port-forward -n monitoring svc/alloy-events 12345:12345

# Open browser
open http://localhost:12345
```

The Alloy UI shows:
- Component graph and status
- Live configuration
- Metrics and logs

---

## Migration from Fluent Bit

The previous implementation used Fluent Bit. Files are preserved in `deprecated/` for rollback capability.

### Migration Steps

1. **Parallel deployment (recommended)**:
   ```bash
   # Keep Fluent Bit running on kube-events topic
   # Deploy Alloy to test topic
   export TEST_MODE=true
   cd alloy && ./deploy-alloy.sh
   ```

2. **Validate JSON format**:
   - Check Event Hub for events from both collectors
   - Verify JSON structure matches expected format (see below)

3. **Cutover**:
   ```bash
   # Switch Alloy to production topic
   export TEST_MODE=false
   ./deploy-alloy.sh

   # Scale down Fluent Bit
   kubectl scale deploy fluent-bit-events -n monitoring --replicas=0
   ```

4. **Cleanup** (after validation):
   ```bash
   kubectl delete deploy fluent-bit-events -n monitoring
   ```

### Expected JSON Format

The Argo Events sensor expects this JSON structure in Event Hub messages:

```json
{
  "type": "Warning",
  "reason": "BackOff",
  "message": "Back-off pulling image...",
  "involvedObject": {
    "kind": "Pod",
    "name": "test-crash",
    "namespace": "dg-demo"
  },
  "cluster": "kind-local",
  "cluster_region": "local",
  "cluster_environment": "dev"
}
```

### Rollback Procedure

If issues occur after migration:

```bash
# 1. Scale down Alloy
kubectl scale deploy alloy-events -n monitoring --replicas=0

# 2. Restore Fluent Bit from deprecated files
kubectl apply -f deprecated/01-fluent-bit-config.yaml
kubectl apply -f deprecated/02-fluent-bit-deployment.yaml

# 3. Wait for Fluent Bit to be ready
kubectl wait --for=condition=ready pod -l app=fluent-bit -n monitoring --timeout=60s

# 4. Verify events flow
kubectl logs -n monitoring -l app=fluent-bit -f
```

---

## Deprecated: Fluent Bit

The `deprecated/` directory contains the original Fluent Bit configuration for reference and rollback capability.

| File | Purpose |
|------|---------|
| `deprecated/01-fluent-bit-config.yaml` | Fluent Bit ConfigMap |
| `deprecated/02-fluent-bit-deployment.yaml` | Fluent Bit Deployment and RBAC |
| `deprecated/deploy-fluent-bit.sh` | Fluent Bit installation script |

---

## Troubleshooting

### Alloy Pod Not Starting

```bash
# Check pod events
kubectl describe pod -n monitoring -l app=alloy-events

# Check configuration syntax
kubectl logs -n monitoring -l app=alloy-events --previous
```

### No Events in Event Hub

1. **Check namespace exists and has events**:
   ```bash
   kubectl get events -n dg-demo
   ```

2. **Verify Alloy is processing events**:
   ```bash
   kubectl logs -n monitoring -l app=alloy-events | grep -i event
   ```

3. **Check Event Hub connectivity**:
   ```bash
   # Verify FQDN is reachable
   kubectl exec -n monitoring deploy/alloy-events -- \
     wget -qO- --timeout=5 https://k8s-events-hub-4808.servicebus.windows.net || echo "Connection failed"
   ```

4. **Verify connection string**:
   ```bash
   kubectl get secret -n monitoring eventhub-sas-secret -o jsonpath='{.data.connectionString}' | base64 -d
   ```

### Events Not Triggering Workflows

1. **Check sensor is receiving events**:
   ```bash
   kubectl logs -n argo-events -l sensor-name=fluent-bit-multi-cluster-triage
   ```

2. **Verify JSON format**:
   - Use the debug sensor to log raw events
   - Compare against expected format above

### Known Issues

1. **OTEL Kafka encoding**: The `encoding = "raw"` setting may wrap logs differently than Fluent Bit. If the sensor fails to parse events, check the actual JSON structure in Event Hub.

2. **Namespace filtering**: Unlike Fluent Bit which filters in the pipeline, Alloy's `loki.source.kubernetes_events` filters at the source. This is more efficient but means you must specify namespaces upfront.
