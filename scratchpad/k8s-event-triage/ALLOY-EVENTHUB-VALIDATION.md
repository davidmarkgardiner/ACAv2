# Alloy → Event Hub Validation Results

## Test Date: 2026-01-29

## Summary: PASS

Grafana Alloy successfully collects K8s events and delivers them to Azure Event Hub via Kafka protocol.

## Test Environment

| Component | Details |
|-----------|---------|
| Local K8s | kind (`kind-argo-workflow`) |
| Alloy version | **v1.12.2** (latest) |
| Event Hub namespace | `evhns-alloy-v12-test` (Standard tier) |
| Event Hub name | `k8s-events` |
| Region | UK South |

## Results

| Metric | Value |
|--------|-------|
| Log records sent | 123 |
| Send failures | 0 |
| Queue size (steady state) | 0 |
| All component health | Healthy |

## Issues Found & Fixed

### 1. `kafka.write` component does not exist in Alloy

**Original config used:** `kafka.write "eventhub" { ... }`

**Problem:** This component doesn't exist. Alloy has no native Loki-to-Kafka writer.

**Fix:** Bridge from Loki to OpenTelemetry pipeline:
```
loki.source.kubernetes_events → loki.process → otelcol.receiver.loki → otelcol.processor.batch → otelcol.exporter.kafka
```

### 2. Alloy v1.5.1 too old for `otelcol.exporter.kafka`

**Problem:** v1.5.1 doesn't recognize `tls` or `logs` blocks inside `otelcol.exporter.kafka`.

**Fix:** Upgraded to v1.8.1. The `tls` block must be nested under `authentication`, not at the top level:

```alloy
// WRONG (top-level tls)
otelcol.exporter.kafka "eventhub" {
  tls {}          // Error: unrecognized block name "tls"
  authentication { ... }
}

// CORRECT (tls under authentication)
otelcol.exporter.kafka "eventhub" {
  authentication {
    tls {
      insecure = false
    }
    sasl { ... }
  }
}
```

### 3. Event Hub Basic tier does not support Kafka

**Problem:** Basic tier returns EOF when Alloy tries to connect via Kafka protocol on port 9093.

**Fix:** Use Standard or Premium tier. The Kafka endpoint is only available on Standard+.

### 4. `env()` is deprecated, use `sys.env()`

**Problem:** `env("EVENTHUB_CONNECTION_STRING")` produces a deprecation warning.

**Fix:** Use `sys.env("EVENTHUB_CONNECTION_STRING")` instead.

### 5. `logs {}` block REQUIRED in v1.12.x (breaking change from v1.8.x)

**Problem:** In v1.8.x, the top-level `topic` argument worked. In v1.12.x, using only the top-level `topic` results in `"telemetry type is not supported"` errors and events silently fail to deliver.

**Fix:** Use the `logs {}` block with explicit `topic` and `encoding`:
```alloy
otelcol.exporter.kafka "eventhub" {
  // topic = "k8s-events"    // NOT sufficient in v1.12.x

  logs {
    topic    = "k8s-events"   // REQUIRED in v1.12.x
    encoding = "otlp_json"    // REQUIRED in v1.12.x
  }
}
```

## Working Pipeline

```
┌──────────────────────────────┐
│ loki.source.kubernetes_events│  Watches K8s API for events
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ loki.process "enrich"        │  Adds cluster labels, parses JSON
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ otelcol.receiver.loki        │  Converts Loki entries → OTLP logs
│ "bridge"                     │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ otelcol.processor.batch      │  Batches (100 records / 2s timeout)
│ "default"                    │
└──────────┬───────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ otelcol.exporter.kafka       │  SASL PLAIN + TLS → Event Hub:9093
│ "eventhub"                   │
└──────────────────────────────┘
```

## Cleanup

```bash
# Remove test Event Hub resources
az group delete --name rg-alloy-test --yes --no-wait

# Remove Alloy from kind cluster
kubectl delete -f workload-cluster/ 2>/dev/null
kubectl delete namespace monitoring 2>/dev/null
```

## Version Compatibility Matrix

| Alloy Version | Status | Notes |
|---------------|--------|-------|
| v1.5.1 | BROKEN | `otelcol.exporter.kafka` blocks not recognized |
| v1.8.x | WORKS | Use top-level `topic` argument |
| v1.9.x | BROKEN | `invalid topic` regression ([#3890](https://github.com/grafana/alloy/issues/3890)) |
| v1.10.x | UNCLEAR | Fix merged upstream, but one user reported silent failures |
| **v1.12.2** | **WORKS** | Must use `logs { topic = "..." encoding = "otlp_json" }` block |
