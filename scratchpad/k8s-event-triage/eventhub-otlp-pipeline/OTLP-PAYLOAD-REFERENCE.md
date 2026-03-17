# OTLP Payload Reference - Event Hub K8s Events

## Overview

Alloy on the workload cluster sends K8s events to Azure Event Hub using:
- `loki.source.kubernetes_events` → `loki.process.enrich` → `otelcol.receiver.loki` → `otelcol.exporter.kafka`
- Kafka encoding: `otlp_json`

This means every Kafka message body on Event Hub is an **OTLP JSON log envelope**, not raw K8s event JSON.

## OTLP JSON Structure (What Event Hub Receives)

```json
{
  "resourceLogs": [
    {
      "resource": {
        "attributes": [
          {
            "key": "service.name",
            "value": { "stringValue": "loki" }
          }
        ]
      },
      "scopeLogs": [
        {
          "scope": {},
          "logRecords": [
            {
              "timeUnixNano": "1708432800000000000",
              "observedTimeUnixNano": "1708432800123000000",
              "body": {
                "stringValue": "{\"type\":\"Warning\",\"reason\":\"BackOff\",\"message\":\"Back-off restarting failed container\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"my-app-abc123\",\"namespace\":\"production\",\"uid\":\"abc-123\"},\"count\":1,\"firstTimestamp\":\"2025-02-20T10:00:00Z\",\"lastTimestamp\":\"2025-02-20T10:00:00Z\",\"source\":{\"component\":\"kubelet\",\"host\":\"node-1\"}}"
              },
              "attributes": [
                { "key": "cluster", "value": { "stringValue": "aks-prod-01" } },
                { "key": "environment", "value": { "stringValue": "production" } },
                { "key": "region", "value": { "stringValue": "australiaeast" } },
                { "key": "source", "value": { "stringValue": "alloy" } },
                { "key": "event_type", "value": { "stringValue": "Warning" } },
                { "key": "event_reason", "value": { "stringValue": "BackOff" } },
                { "key": "obj_kind", "value": { "stringValue": "Pod" } },
                { "key": "obj_namespace", "value": { "stringValue": "production" } }
              ],
              "severityNumber": 0,
              "severityText": ""
            }
          ]
        }
      ]
    }
  ]
}
```

## Field Mapping

### Where Do Fields Come From?

| Workflow Field | OTLP Location | Alloy Source |
|---|---|---|
| `cluster` | `logRecords[].attributes[key=cluster]` | `stage.static_labels` |
| `environment` | `logRecords[].attributes[key=environment]` | `stage.static_labels` |
| `event_type` | `logRecords[].attributes[key=event_type]` | `stage.labels` (promoted from JSON parse) |
| `event_reason` | `logRecords[].attributes[key=event_reason]` | `stage.labels` (promoted from JSON parse) |
| `obj_kind` | `logRecords[].attributes[key=obj_kind]` | `stage.labels` (promoted from JSON parse) |
| `obj_namespace` | `logRecords[].attributes[key=obj_namespace]` | `stage.labels` (promoted from JSON parse) |
| `event_message` | `logRecords[].body.stringValue` → parsed JSON `.message` | Original K8s event |
| `object_name` | `logRecords[].body.stringValue` → parsed JSON `.involvedObject.name` | Original K8s event |
| `event_time` | `logRecords[].body.stringValue` → parsed JSON `.lastTimestamp` | Original K8s event |
| `event_count` | `logRecords[].body.stringValue` → parsed JSON `.count` | Original K8s event |

### Why Two Sources?

Alloy's `loki.process.enrich` stage:
1. **Promotes** some K8s event fields to Loki labels (`event_type`, `event_reason`, `obj_kind`, `obj_namespace`) via `stage.json` + `stage.labels`
2. **Adds** static cluster metadata (`cluster`, `environment`, `region`) via `stage.static_labels`
3. These labels become **OTLP attributes** when bridged through `otelcol.receiver.loki`
4. The **original K8s event JSON** stays in `body.stringValue`

The workflow's `parse-otlp` step prefers OTLP attributes (already extracted by Alloy) and falls back to parsing `body.stringValue` for fields not promoted to labels.

## Alloy Pipeline (Workload Cluster)

```
loki.source.kubernetes_events "cluster_events"
    │ Raw K8s event JSON
    ▼
loki.process "enrich"
    │ Adds labels: cluster, environment, event_type, event_reason, ...
    │ Dedup: drops events with count > 1
    │ Rate limit: 10/sec, burst 25
    ▼
otelcol.receiver.loki "bridge"
    │ Converts Loki → OTLP log format
    │ Labels → attributes, log line → body.stringValue
    ▼
otelcol.processor.batch "default"
    │ Batches: 100 records or 2s timeout
    ▼
otelcol.exporter.kafka "eventhub"
    │ Encoding: otlp_json
    │ Protocol: Kafka (SASL PLAIN, TLS)
    ▼
Azure Event Hub
```

## Management Cluster Consumer

```
Event Hub (Kafka consumer)
    │ OTLP JSON message
    ▼
EventSource (eventhub-k8s-events, jsonBody: true)
    │ Parsed JSON object
    ▼
Sensor (k8s-event-triage)
    │ No field-level filters (OTLP paths don't match)
    │ Rate limit: 5 workflows/min
    │ Passes full body as otlp-payload parameter
    ▼
Workflow: k8s-event-triage
    │
    ├─ parse-otlp (badouralix/curl-jq:alpine)
    │   - jq walks resourceLogs[].scopeLogs[].logRecords[]
    │   - Extracts attributes + parses body.stringValue (fromjson)
    │   - Filters: Warning events only (tier-specific)
    │   - Output: JSON array of normalized events
    │
    └─ analyze-and-alert (withParam fan-out)
        - Per event: KAgent A2A analysis + Mattermost alert
        - Image: badouralix/curl-jq:alpine
```

## Batching Behavior

One OTLP message from Event Hub may contain **multiple K8s events** because Alloy batches with `otelcol.processor.batch` (up to 100 records per batch, or 2-second timeout).

This is why the workflow uses `withParam` fan-out — a single OTLP payload can yield 1 to ~100 individual K8s events.

## Testing with a Sample Payload

Save as `sample-otlp.json`:

```json
{
  "resourceLogs": [{
    "resource": {
      "attributes": [{"key": "service.name", "value": {"stringValue": "loki"}}]
    },
    "scopeLogs": [{
      "scope": {},
      "logRecords": [{
        "timeUnixNano": "1708432800000000000",
        "body": {
          "stringValue": "{\"type\":\"Warning\",\"reason\":\"BackOff\",\"message\":\"Back-off restarting failed container\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"test-pod\",\"namespace\":\"default\"},\"count\":1,\"lastTimestamp\":\"2025-02-20T10:00:00Z\"}"
        },
        "attributes": [
          {"key": "cluster", "value": {"stringValue": "test-cluster"}},
          {"key": "environment", "value": {"stringValue": "dev"}},
          {"key": "event_type", "value": {"stringValue": "Warning"}},
          {"key": "event_reason", "value": {"stringValue": "BackOff"}},
          {"key": "obj_kind", "value": {"stringValue": "Pod"}},
          {"key": "obj_namespace", "value": {"stringValue": "default"}}
        ]
      }]
    }]
  }]
}
```

Submit:

```bash
argo submit -n argo-events \
  --from workflowtemplate/k8s-event-triage \
  -p "otlp-payload=$(cat sample-otlp.json)" \
  --watch
```
