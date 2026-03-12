# Handover — K8s Event Triage Pipeline

**Date:** 2026-03-12
**Cluster:** aks-event-triage-dev (AKS, UK South, K8s 1.32.11)
**Agent:** Noah (redeployment + validation)
**Previous Agent:** Original deployer (see `eventhub-otlp-pipeline/HANDOVER.md`)

---

## What Was Done

### Cleanup
- Deleted Fluent Bit deployment (wrong collector — not part of this stack)
- Deleted Ollama deployment + PVC (LLM triage not needed for proof of concept)
- Fixed stuck EventBus delete (removed `eventbus-controller` finalizer after deleting connected EventSource)
- Deleted old EventSource, Sensor, WorkflowTemplate from previous agent

### Deployment
- Deployed Grafana Alloy v1.12.2 (monitoring namespace) — watches `default` namespace for K8s events
- Alloy sends events to Event Hub via OTLP/Kafka (otelcol.exporter.kafka)
- Deployed fresh EventBus (JetStream 2.10.10, 1 replica)
- Deployed EventSource (Kafka consumer, consumer group `argo-events-consumer-v4`)
- Deployed Sensor (rate limited 5/min)
- Deployed simple WorkflowTemplate (parse event + log, no LLM or GitLab)
- Applied RBAC (argo-events-sa, sensor-workflow-creator, workflow-executor roles)

### Testing
- Created test pod with bad image (`nginx:does-not-exist-12345`) in `default` namespace
- **Result:** 8 workflows fired, all `Succeeded`
- Confirmed no feedback loop (workflow pods in argo-events don't trigger more events)
- Confirmed events stop when test pod is deleted

---

## Lessons Learned (for agent skills)

### 1. Pin Argo Events version — never use `stable` floating tag
- **Wrong:** `https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml`
- **Right:** `https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml`
- **Why:** `stable` resolves to latest release which may have breaking changes or panics

### 2. Secret key names must match EventSource spec exactly
- EventSource `sasl.userSecret.key: username` requires the K8s secret to have a key literally named `username`
- The previous agent had `sasl-username` as the key name — this fails silently at first, then errors in EventSource logs
- **Fix:** Always verify secret key names match the EventSource YAML exactly

### 3. TLS CA cert IS required — Argo Events v1.9.x validates it
- `tls: {}` fails validation in v1.9.10: "invalid tls config, please configure caCertSecret"
- You MUST provide a CA cert secret even though Event Hub uses a public CA (DigiCert)
- Secret key must be `ca.pem` (not `ca.crt`) — must match EventSource YAML
- Generate once per Event Hub namespace: `openssl s_client -showcerts -connect <ns>.servicebus.windows.net:9093`

### 4. EventBus finalizer gets stuck when EventSource is still connected
- Deleting an EventBus while an EventSource references it causes the controller to loop with "can not delete an EventBus with 1 EventSources connected"
- **Fix:** Delete EventSource first, then if EventBus is still stuck, patch out the finalizer:
  ```bash
  kubectl patch eventbus default -n argo-events --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```

### 5. Use fresh consumer group to avoid backlog storms
- When reconnecting to Event Hub, a consumer group may have old offsets that cause the EventSource to consume the entire backlog at once, creating hundreds of workflows
- **Fix:** Use a new consumer group name (e.g., increment `v3` -> `v4`) or delete/recreate the Event Hub topic

### 6. Alloy namespace filtering prevents feedback loops
- Alloy's `loki.source.kubernetes_events` takes a `namespaces` list
- NEVER include `argo`, `argo-events`, `monitoring`, or `kube-system` — workflow pods generate K8s events that would feed back into the pipeline
- Only watch application namespaces (e.g., `default`, `my-app`)

### 7. Alloy "no involved object for event" errors are harmless
- Some K8s events (especially from Karpenter/node lifecycle) lack `involvedObject`
- Alloy logs these as errors but continues processing normally

### 8. Container images used (verified working)
| Component | Image | Notes |
|-----------|-------|-------|
| Alloy | `grafana/alloy:v1.12.2` | Event collector |
| EventBus | JetStream `2.10.10` (managed by Argo Events) | NATS streaming |
| EventSource | `quay.io/argoproj/argo-events:v1.9.10` | Kafka consumer |
| Sensor | `quay.io/argoproj/argo-events:v1.9.10` | Event router |
| Workflow step | `badouralix/curl-jq:alpine` | Parse + log events |

### 9. Don't deploy Ollama or Fluent Bit
- Ollama is for LLM triage (production enhancement, not needed for proof of concept)
- Fluent Bit was deployed by mistake — the standard is Grafana Alloy

### 10. Event Hub must be Standard or Premium tier
- Basic tier does NOT support Kafka protocol
- The EventSource uses Kafka consumer group protocol which requires Standard+

---

## Current State

**All Running:**
- Alloy (monitoring namespace) — watching `default` namespace
- EventBus JetStream (argo-events namespace) — 3/3 containers
- EventSource (argo-events namespace) — connected to Event Hub
- Sensor (argo-events namespace) — subscribed and triggering workflows
- Argo Events controller (argo-events namespace)
- Argo Workflows controller + server (argo namespace)

**To scale down (stop processing):**
```bash
kubectl scale deploy -l eventsource-name=eventhub-k8s-events -n argo-events --replicas=0
kubectl scale deploy -l sensor-name=k8s-event-triage -n argo-events --replicas=0
```

**To scale back up:**
```bash
kubectl scale deploy -l eventsource-name=eventhub-k8s-events -n argo-events --replicas=1
kubectl scale deploy -l sensor-name=k8s-event-triage -n argo-events --replicas=1
```

---

## Files

All working manifests are in `working-config/`:

| File | Purpose | Placeholders |
|------|---------|-------------|
| `01-namespaces.yaml` | Namespaces | None |
| `02-secrets.yaml` | Secret templates | `REPLACE_WITH_EVENTHUB_CONNECTION_STRING` |
| `03-alloy.yaml` | Alloy (collector) | `REPLACE_CLUSTER_NAME`, `REPLACE_ENVIRONMENT`, `REPLACE_AZURE_REGION`, `REPLACE_EVENTHUB_NAMESPACE`, `REPLACE_EVENTHUB_NAME` |
| `04-eventbus.yaml` | JetStream EventBus | None |
| `05-eventsource.yaml` | Kafka EventSource | `REPLACE_EVENTHUB_NAMESPACE`, `REPLACE_EVENTHUB_NAME`, `REPLACE_CONSUMER_GROUP` |
| `06-rbac.yaml` | Service accounts + roles | None |
| `07-workflow-template.yaml` | Parse + log workflow | None |
| `08-sensor.yaml` | Event -> Workflow trigger | None |
