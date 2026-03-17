# Critical Tier — K8s Event Triage Workflow

Automated triage pipeline for critical Kubernetes events. Events flow from workload clusters through Azure Event Hub and are analysed by KAgent AI agents.

---

## How It Works

### Big Picture

```
Workload Cluster                        Management Cluster
────────────────                        ──────────────────
K8s event happens
  │
  ▼
Alloy picks it up
  │  wraps in OTLP JSON
  ▼
Azure Event Hub (Kafka)  ──────────►  EventSource (Kafka consumer)
                                        │  receives OTLP blob
                                        ▼
                                      Sensor
                                        │  triggers workflow, passes OTLP blob
                                        ▼
                                      Workflow: k8s-triage-critical
                                        │
                                        ├─ Step 1: validate-kagent
                                        ├─ Step 2: parse-otlp + route agents
                                        └─ Step 3: fan-out (one pod per event)
                                             ├─ KAgent A2A analysis
                                             ├─ GitLab issue creation
                                             └─ Mattermost notification
```

### Step 1 — Validate KAgent (~3s)

Checks that the KAgent controller is alive before processing anything.

- Curls `/api/agents` on the KAgent controller
- Lists available agents in the logs
- **If KAgent is down** → workflow fails immediately (no point spinning up fan-out pods that will all fail)
- **If KAGENT_URL is empty** → warns but continues (workflow degrades gracefully — skips AI analysis, still does GitLab + Mattermost)

### Step 2 — Parse OTLP + Route Agents (~3s)

The OTLP blob from Event Hub contains a batch of K8s events wrapped in an envelope. This step:

1. **Cracks open the OTLP envelope** — extracts individual events from `resourceLogs[].scopeLogs[].logRecords[]`
2. **Filters** — only keeps Warning events with critical reasons:
   - `CrashLoopBackOff`, `OOMKilled`, `OOMKilling`
   - `FailedScheduling`, `NodeNotReady`, `NodeNotSchedulable`
   - `FailedMount`, `FailedAttachVolume`
3. **Routes each event to an agent** — checks the `agent-routing` ConfigMap (see [Agent Routing](#agent-routing) below)
4. **Outputs a JSON array** — one object per qualifying event, each with a `target_agent` field

Normal events (Scheduled, Pulled, etc.) and non-critical warnings (BackOff, FailedCreate, etc.) are filtered out.

### Step 3 — Fan-Out: Investigate and Report (~3s per event, parallel)

Argo's `withParam` creates a **separate pod for each event**. Pods run in parallel. Each runs the full pipeline:

1. **KAgent A2A call** — sends the event to the routed agent (`target_agent`). The agent investigates using its k8s tools and returns an analysis.
2. **GitLab issue** — creates an issue with the AI analysis, event details, and quick `kubectl` commands. *Skipped if no GitLab token configured.*
3. **Mattermost notification** — posts a rich message with the analysis summary. *Skipped if no webhook configured.*

Each step is **best-effort** — if one fails, the others still run. For example, if GitLab is down, the Mattermost notification still goes out.

---

## Agent Routing

Events are routed to different KAgent agents based on their content. The routing table lives in the `agent-routing` ConfigMap — update it to add specialist agents without redeploying the workflow.

### Routing Priority (first match wins)

| Priority | Match On | Example |
|----------|----------|---------|
| 1 | **Namespace** | cert-manager events → `cert-manager-agent` |
| 2 | **Reason** | FailedMount events → `storage-specialist-agent` |
| 3 | **Default** | Everything else → `sre-triage-agent` or `sre-remediation-agent` |

### Override Chain

For agent selection, most specific wins:

| Priority | Source | Use Case |
|----------|--------|----------|
| 1 (highest) | Workflow param `kagent-agent` | Manual override for testing |
| 2 | Routing table (namespace → reason → default) | Normal operation |
| 3 (lowest) | ConfigMap defaults | Fallback |

### Current Configuration

Out of the box, all events go to:
- **Triage mode** (`remediate=false`): `sre-triage-agent` (read-only investigation)
- **Remediation mode** (`remediate=true`): `sre-remediation-agent` (read-write, can fix issues)

### Adding a Specialist Agent

To route cert-manager events to a dedicated cert-manager agent:

```bash
# 1. Create the agent CRD in kagent namespace
kubectl apply -f cert-manager-agent.yaml -n kagent

# 2. Update the routing ConfigMap
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"cert-manager\":\"cert-manager-agent\"}"}}'

# That's it. Next cert-manager event will go to cert-manager-agent.
```

To route specific event reasons:

```bash
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"reason-routes":"{\"FailedMount\":\"storage-specialist-agent\",\"FailedAttachVolume\":\"storage-specialist-agent\"}"}}'
```

---

## Files

| File | Purpose |
|------|---------|
| `workflow-template.yaml` | The WorkflowTemplate — all the logic |
| `agent-routing.yaml` | ConfigMap with agent routing table |
| `eventsource.yaml` | Kafka consumer connecting to Event Hub |
| `sensor.yaml` | Wires EventSource → Workflow (passes OTLP blob) |
| `QUICK-TEST.md` | How to test the workflow without Event Hub |

---

## Prerequisites

### ConfigMaps

```bash
# KAgent connection (required for AI analysis)
kubectl create configmap kagent-config -n argo-events \
  --from-literal=KAGENT_URL="http://kagent-a2a.kagent.svc.cluster.local" \
  --dry-run=client -o yaml | kubectl apply -f -

# Agent routing (required — controls which agent handles which event)
kubectl apply -f agent-routing.yaml

# Mattermost webhook (optional — skipped if empty)
kubectl create configmap mattermost-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="https://mattermost.example.com/hooks/YOUR_HOOK_ID" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Secrets

```bash
# GitLab token (optional — issue creation skipped if missing)
kubectl create secret generic gitlab-token -n argo-events \
  --from-literal=GITLAB_TOKEN="glpat-xxxx" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### RBAC

The service account `argo-events-sa` needs:
- Create Workflows
- Create/get `workflowtaskresults` (Argo Workflows requirement for step pods)

---

## Deploy

### Workflow only (for quick testing)

```bash
kubectl apply -f agent-routing.yaml
kubectl apply -f workflow-template.yaml
# Then follow QUICK-TEST.md
```

### Full pipeline (Event Hub end-to-end)

```bash
# 1. Secrets for Event Hub connection
kubectl create secret generic eventhub-credentials -n argo-events \
  --from-literal=username='$ConnectionString' \
  --from-literal=connection-string='Endpoint=sb://...'

# 2. TLS CA (if needed — Azure Event Hub uses public CAs)
# kubectl create secret generic eventhub-tls-ca -n argo-events --from-file=ca.pem=...

# 3. EventBus (if not already deployed)
# kubectl apply -f ../eventbus.yaml

# 4. All components
kubectl apply -f agent-routing.yaml
kubectl apply -f workflow-template.yaml
kubectl apply -f eventsource.yaml
kubectl apply -f sensor.yaml
```

---

## OTLP Payload Structure

Alloy sends K8s events as OTLP JSON via `otelcol.exporter.kafka`. The structure:

```json
{
  "resourceLogs": [{
    "resource": {
      "attributes": []
    },
    "scopeLogs": [{
      "logRecords": [
        {
          "body": {
            "stringValue": "{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",...}"
          },
          "attributes": [
            {"key": "cluster", "value": {"stringValue": "aks-prod-01"}},
            {"key": "environment", "value": {"stringValue": "production"}},
            {"key": "event_type", "value": {"stringValue": "Warning"}},
            {"key": "event_reason", "value": {"stringValue": "CrashLoopBackOff"}},
            {"key": "obj_kind", "value": {"stringValue": "Pod"}},
            {"key": "obj_namespace", "value": {"stringValue": "payments"}}
          ]
        }
      ]
    }]
  }]
}
```

Key points:
- **`body.stringValue`** contains the raw K8s event JSON as a string (needs `fromjson` in jq)
- **`attributes`** are Loki labels promoted by Alloy's `stage.labels` — `otelcol.receiver.loki` puts them as logRecord attributes by default
- The jq parser reads from both `attributes` (logRecord) and `resource.attributes` (resource) with fallbacks, so it works regardless of where Alloy places them
- Multiple events can be batched in one payload (via `otelcol.processor.batch`)

---

## Graceful Degradation

The workflow is designed to keep going when external services are unavailable:

| Service | If unavailable | What happens |
|---------|----------------|--------------|
| KAgent controller | validate-kagent fails | Workflow fails early (no analysis possible) |
| KAgent URL empty | validate-kagent warns | Workflow continues — analysis skipped, GitLab + Mattermost still fire |
| Specific agent missing | A2A call returns error | That event's analysis says "(A2A error: ...)", GitLab + Mattermost still fire |
| GitLab | Token missing or API error | Issue creation skipped, Mattermost still fires |
| Mattermost | Webhook empty or fails | Notification skipped, workflow still succeeds |

---

## Tested

Verified on proxmox-k8s (2026-02-23):

| Test | Result |
|------|--------|
| OTLP parsing (attributes in logRecord) | 2/4 events extracted correctly (2 critical, 1 Normal filtered, 1 non-critical Warning filtered) |
| OTLP parsing (attributes in resource) | Same result — fallback chain works |
| Realistic Alloy payload (extra OTLP fields) | Parsed correctly — jq ignores extra fields |
| Agent routing (default) | Both events → `sre-triage-agent` |
| Agent routing (namespace specialist) | payments → `sre-triage-agent`, cert-manager → `cert-manager-agent` |
| Graceful degradation (no KAgent/GitLab/Mattermost) | All steps green, skip messages logged |
| validate-kagent (empty URL) | Warns and continues |
| Full pipeline (4 steps) | 4/4 Succeeded in 30s |
