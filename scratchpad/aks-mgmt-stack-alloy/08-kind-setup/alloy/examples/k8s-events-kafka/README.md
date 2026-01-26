# Kubernetes Events Collector with Deduplication & Rate Limiting

This example demonstrates how to collect Kubernetes Warning events from a specific namespace and forward them to Kafka or Azure Event Hub with deduplication and rate limiting.

## Features

- **Namespace filtering**: Only collects events from `dg-demo` namespace
- **Severity filtering**: Only `Warning` events (drops `Normal` events)
- **Deduplication**: Tracks events by UID to prevent sending duplicates
- **Rate limiting**: Maximum 5 events per minute to prevent alert storms
- **Multiple outputs**: Kafka, Azure Event Hub, or HTTP webhook

## Configuration Files

| File | Output Target | Use Case |
|------|---------------|----------|
| `alloy-events-kafka.yaml` | Apache Kafka | Standard Kafka cluster |
| `alloy-events-eventhub.yaml` | Azure Event Hub | Azure cloud with Kafka-compatible API |
| `alloy-events-collector.yaml` | HTTP endpoint | Webhooks, Loki, or custom APIs |

## How Deduplication Works

Kubernetes events have a unique `metadata.uid` field. The configuration:

1. Extracts the event UID using `stage.json`
2. Uses `stage.limit` with `by_label_name = "event_uid"` to track events by UID
3. Events with the same UID within the rate window are deduplicated

Additionally, Kubernetes itself deduplicates events - repeated identical events increment a `count` field rather than creating new event objects.

## How Rate Limiting Works

The `stage.limit` component provides token-bucket rate limiting:

```river
stage.limit {
  rate  = 5        // 5 events per minute
  burst = 5        // Allow burst of 5 events
}
```

This means:
- Steady state: ~5 events per minute pass through
- Bursts: Up to 5 events can pass immediately, then rate-limited
- Excess events are dropped (not queued)

## Prerequisites

1. **Alloy Operator installed**:
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm install alloy-operator grafana/alloy-operator -n monitoring --create-namespace
   ```

2. **Target namespace exists**:
   ```bash
   kubectl create namespace dg-demo
   ```

## Quick Start

### Option 1: Kafka

```bash
# Edit the broker addresses in the file first
kubectl apply -f alloy-events-kafka.yaml
```

### Option 2: Azure Event Hub

```bash
# Create the secret with your Event Hub credentials
kubectl create secret generic eventhub-credentials \
  --namespace=monitoring \
  --from-literal=EVENTHUB_NAMESPACE="your-namespace" \
  --from-literal=EVENTHUB_NAME="k8s-warning-events" \
  --from-literal=EVENTHUB_CONNECTION_STRING="Endpoint=sb://..."

# Apply the configuration
kubectl apply -f alloy-events-eventhub.yaml
```

### Option 3: HTTP Webhook

```bash
# Edit the endpoint URL in the file first
kubectl apply -f alloy-events-collector.yaml
```

## Verify It's Working

1. **Check the Alloy pod is running**:
   ```bash
   kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy
   ```

2. **View Alloy logs**:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=alloy -f
   ```

3. **Generate a test Warning event**:
   ```bash
   # Create a pod that will fail (generates Warning events)
   kubectl run test-warning --image=invalid-image:v999 -n dg-demo

   # Clean up
   kubectl delete pod test-warning -n dg-demo
   ```

4. **Check the Alloy UI** (port-forward to see metrics):
   ```bash
   kubectl port-forward -n monitoring svc/k8s-events-kafka 12345:12345
   # Open http://localhost:12345 in browser
   ```

## Customization

### Change the target namespace

Edit the `namespaces` array in the config:

```river
loki.source.kubernetes_events "events" {
  namespaces = ["dg-demo", "production", "staging"]  // Multiple namespaces
  // OR
  namespaces = []  // All namespaces (not recommended for production)
}
```

### Adjust rate limiting

```river
stage.limit {
  rate  = 10       // Increase to 10 events/minute
  burst = 20       // Allow larger bursts
}
```

### Add additional filtering

Filter by event reason (e.g., only `FailedScheduling`, `Unhealthy`, etc.):

```river
stage.match {
  selector = "{reason!~\"FailedScheduling|Unhealthy|BackOff\"}"
  action   = "drop"
}
```

### Switch to Loki + Alertmanager

Replace the Kafka exporter with:

```river
loki.write "loki" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

Then create alerting rules in Loki/Grafana to send to your preferred notification channel.

## Architecture

```
┌─────────────────────┐
│  Kubernetes API     │
│  (Event Watch)      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ loki.source.        │
│ kubernetes_events   │
│ (namespace: dg-demo)│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ loki.process        │
│ - Filter: Warning   │
│ - Dedupe by UID     │
│ - Rate: 5/min       │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ otelcol.processor.  │
│ batch               │
│ (batch before send) │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ otelcol.exporter.   │
│ kafka               │
│ (Kafka/Event Hub)   │
└─────────────────────┘
```

## Troubleshooting

### Events not appearing

1. Check RBAC - Alloy needs permission to watch events:
   ```bash
   kubectl auth can-i watch events --as=system:serviceaccount:monitoring:k8s-events-kafka
   ```

2. Verify events exist in the namespace:
   ```bash
   kubectl get events -n dg-demo --field-selector type=Warning
   ```

### Rate limiting dropping too many events

Increase the rate/burst values or add more specific filtering to reduce noise before rate limiting.

### Kafka connection issues

Check the Alloy logs for connection errors and verify:
- Broker addresses are correct
- Network policies allow egress to Kafka
- Authentication credentials are valid
