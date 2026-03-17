# K8s Event Triage Platform — Handover Document

**Date:** 2026-03-12
**Cluster:** aks-event-triage-dev (kubectl context: `aks-event-triage-dev`)
**Region:** UK South

---

## What's Working

### AKS Cluster (ACTIVE)
- 2 nodes: `aks-systempool` (system) + `aks-default-jwwb7` (Karpenter-managed)
- K8s 1.32.11, Azure RBAC enabled, kubelogin azurecli mode
- Karpenter autoscaler active (provisions nodes on demand)

### Argo Events + Argo Workflows (Installed, Running)
- **EventBus** (JetStream): `argo-events/eventbus-default-js-0` — 3/3 Running
- **EventSource** (Kafka): `argo-events/eventhub-k8s-events` — connects to Event Hub via SASL_SSL
- **Sensor**: `argo-events/event-triage-sensor` — triggers `event-triage-template` workflow
- **WorkflowTemplate**: `argo/event-triage-template` — 3-step DAG (parse → llm-triage → create-gitlab-issue)
- **Argo Workflows controller + server**: Running in `argo` namespace

### Ollama LLM (Running, Model Ready)
- Deployment: `monitoring/ollama` — 1/1 Running
- Model: `qwen2.5:7b` (4.7 GB, pulled and ready)
- Service: `ollama.monitoring.svc.cluster.local:11434`
- PVC: `ollama-models` (10Gi, managed-csi)

### Azure Event Hub
- Namespace: `evhns-event-triage-dev` (Standard, Kafka enabled)
- Topic: `k8s-events` (2 partitions, recreated fresh — no backlog)
- Consumer group: `argo-events-consumer-v3`
- Connection string in K8s secret `eventhub-credentials` (argo-events namespace)

### TLS (Fixed)
- `eventhub-tls-ca` secret in `argo-events` namespace contains proper CA chain:
  - Microsoft TLS G2 RSA CA OCSP 16
  - Microsoft TLS RSA Root G2
  - DigiCert Global Root G2
- EventSource Kafka consumer connects successfully with this CA bundle

### GitLab Credentials (Placeholder)
- Secret `gitlab-credentials` in `argo` namespace exists but has placeholder values
- Points to `https://gitea.lab.xxx` — needs real token and project ID

---

## What's NOT Working / Needs Fixing

### 1. EVENT COLLECTOR: Replace Fluent Bit with Alloy Operator (CRITICAL)

**Problem:** I built the event collector using Fluent Bit (`08-fluent-bit.yaml`). David confirmed the stack uses **Grafana Alloy Operator**, not Fluent Bit.

**What needs to happen:**
- Delete the Fluent Bit deployment from `monitoring` namespace
- Deploy Alloy Operator to collect K8s events and forward to Event Hub via Kafka protocol
- Reference existing Alloy configs in the repo:
  - `k8s-event-triage-platform/deploy/03-alloy-collector-instance.yaml`
  - `k8s-event-triage-platform/charts/alloy-values.yaml`
  - `k8s-event-triage-platform/design-kro-resourcegraphdefinitions-for-the-platform/05-alloy-collector.yaml`

**Key requirements for the Alloy config:**
- Collect K8s events (Warning type only)
- Exclude events from infra namespaces: `argo`, `argo-events`, `monitoring`, `kube-system` (prevents feedback loop — see problem #2)
- Output to Event Hub Kafka endpoint: `evhns-event-triage-dev.servicebus.windows.net:9093`
- SASL_SSL auth with connection string from `eventhub-credentials` secret

### 2. FEEDBACK LOOP (CRITICAL — must be solved in Alloy config)

**Problem:** The triage pipeline creates Argo Workflow pods. Those pods generate K8s events (Scheduled, Pulled, Started, Created, etc.). If these events flow back into Event Hub, the Sensor triggers MORE workflows, creating an exponential feedback loop.

**Root cause:** Every workflow pod in `argo` namespace generates Normal events. Without filtering, they flow to Event Hub and trigger more workflows.

**Solution:** The event collector (Alloy) MUST filter out:
- All events from `argo`, `argo-events`, `monitoring`, `kube-system` namespaces
- Ideally only forward `type: Warning` events (reduces noise, the LLM triage handles severity classification)

### 3. EVENT PAYLOAD BASE64 ENCODING

**Problem:** The Argo Events Kafka EventSource delivers the event payload to the workflow as base64-encoded JSON.

**Status:** FIXED in `06-workflow-template.yaml`. The parse-event step now tries base64 decode first, then falls back to plain JSON.

### 4. WORKFLOW STORM FROM EVENT HUB BACKLOG

**Problem:** When the EventSource consumer group starts from the beginning of Event Hub (even with `oldest: false`), it consumes all historical messages, creating hundreds of workflows instantly.

**What was done:**
- Deleted and recreated the Event Hub topic `k8s-events` to clear backlog
- Changed consumer group to `argo-events-consumer-v3` (fresh offsets)
- Reduced EventSource `limitEventsPerSecond` to 2
- Reduced Sensor `rateLimit` to 3/Minute

**Note:** Argo Events Sensor `rateLimit` does NOT appear to work as a global throttle when consuming a backlog from EventBus JetStream. The events pile up in JetStream and the Sensor processes them all. The real fix is preventing the flood at the source (Alloy filtering).

### 5. GITLAB CREDENTIALS (TODO)

**Status:** Placeholder secret exists. Needs:
- Real Gitea/GitLab API token
- Correct project ID
- The `create-gitlab-issue` step in the workflow template is wired up and ready

---

## Current State (Scaled Down for Handover)

**Scaled to 0 (intentionally stopped):**
- EventSource deployment (stop consuming from Event Hub)
- Sensor deployment (stop triggering workflows)

**Running:**
- EventBus JetStream (3/3)
- Argo Events controller
- Argo Workflows controller + server
- Ollama (with qwen2.5:7b loaded)
- Fluent Bit (should be DELETED and replaced with Alloy)

**To resume pipeline:**
```bash
# Scale up EventSource
kubectl -n argo-events get deploy -l eventsource-name=eventhub-k8s-events -o name | \
  xargs -I{} kubectl -n argo-events scale {} --replicas=1

# Scale up Sensor
kubectl -n argo-events get deploy -l owner-name=event-triage-sensor -o name | \
  xargs -I{} kubectl -n argo-events scale {} --replicas=1
```

---

## Pipeline Architecture

```
K8s Warning Events
    |
    v
[Alloy Operator]  <-- NEEDS DEPLOYMENT (replaces Fluent Bit)
    | (Kafka SASL_SSL)
    v
[Azure Event Hub: k8s-events topic]
    |
    v
[Argo Events: Kafka EventSource]
    |
    v
[Argo Events: JetStream EventBus]
    |
    v
[Argo Events: Sensor (rate limited 3/min)]
    |
    v
[Argo Workflow: event-triage-template]
    |
    +-- Step 1: parse-event (Python, extracts K8s event fields)
    |
    +-- Step 2: llm-triage (Python, calls Ollama qwen2.5:7b)
    |       - Classifies severity (critical/warning/info)
    |       - Identifies root cause
    |       - Suggests remediation
    |       - Decides if GitLab issue should be created
    |       - Falls back to rule-based classification if LLM unavailable
    |
    +-- Step 3: create-gitlab-issue (conditional, only if create_issue=true)
            - Creates issue via GitLab/Gitea API
```

---

## File Inventory

### Pipeline Manifests (`deploy/pipeline/`)
| File | Status | Notes |
|------|--------|-------|
| `01-namespaces.yaml` | Applied | argo, argo-events, monitoring |
| `02-secrets.yaml` | Template | Connection strings, GitLab creds (applied manually with real values) |
| `03-eventbus.yaml` | Applied | JetStream v2.10.10, 1 replica, 5Gi |
| `04-eventsource.yaml` | Applied | Kafka consumer, consumer group v3, rate limit 2/s |
| `05-rbac.yaml` | Applied | SA + roles for Argo Events + Workflows |
| `06-workflow-template.yaml` | Applied | 3-step DAG, base64 decode fix applied |
| `07-sensor.yaml` | Applied | Rate limit 3/min |
| `08-fluent-bit.yaml` | **DELETE** | Wrong collector — replace with Alloy |
| `09-ollama.yaml` | Applied | Ollama + PVC + model pull job |

### Deployment Scripts (`deploy/`)
| File | Purpose |
|------|---------|
| `prereqs.sh` | Creates Azure prereqs (RG, VNet, UAMIs, LAW, role assignments) |
| `deploy.sh` | Full deployment with pre-flight checks |
| `cleanup.sh` | Safe teardown (KRO instances, waits for ASO, scales KRO to 0) |
| `00-aso-resourcegroup.yaml` | ASO ResourceGroup K8s resource |
| `01-cluster-instance.yaml` | AKS cluster KRO instance |

### Alloy Reference Configs (existing in repo)
- `deploy/03-alloy-collector-instance.yaml`
- `charts/alloy-values.yaml`
- `design-kro-resourcegraphdefinitions-for-the-platform/05-alloy-collector.yaml`

---

## Lessons Learned (for agent skills)

1. **Event Hub TLS**: Azure Event Hub uses Microsoft TLS G2 RSA CA OCSP 16 → Microsoft TLS RSA Root G2 → DigiCert Global Root G2. Extract with `openssl s_client -showcerts` and include all three intermediates + root.

2. **Feedback loop prevention**: Any event collector MUST exclude events from the pipeline's own namespaces (argo, argo-events, monitoring) or you get exponential workflow creation.

3. **Event Hub consumer group offsets**: New consumer groups on Azure Event Hub Standard tier start from earliest even with `oldest: false`. To skip backlog, either purge the topic (delete/recreate) or use a dedicated consumer group per deployment.

4. **Argo Events rate limiting**: Sensor `rateLimit` doesn't effectively throttle when EventBus JetStream has a backlog. The EventSource `limitEventsPerSecond` is more effective but still not a hard gate. Filtering at the source (collector) is the real solution.

5. **EventBus PVC Multi-Attach**: When Karpenter scales nodes, EventBus StatefulSet PVC can get stuck on the old node. Fix: delete the stale VolumeAttachment (`kubectl delete volumeattachment <name>`).

6. **Fluent Bit kubernetes_events format**: Events come as full K8s Event objects with `type`, `reason`, `involvedObject`, `metadata` at the top level. The grep filter `Regex key value` syntax works for top-level fields but nested field access requires Lua filter.

7. **Argo Events Kafka payload**: Delivered to workflows as base64-encoded JSON. The parse step must decode before parsing.

8. **Ollama image tag**: `ollama/ollama:0.6` doesn't exist. Use `ollama/ollama:latest`.

9. **Fluent Bit memory**: 128Mi limit is too low with debug logging or stdout output. Use 256Mi minimum.

10. **Use Alloy, not Fluent Bit**: The platform standard is Grafana Alloy Operator for event collection.

---

## Azure Resources

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | rg-event-triage-dev | UK South |
| AKS Cluster | aks-event-triage-dev | Standard_B4ms, K8s 1.32.11 |
| Event Hub NS | evhns-event-triage-dev | Standard, Kafka enabled |
| Event Hub | k8s-events | 2 partitions, freshly recreated |
| VNet | vnet-event-triage-dev | 10.0.0.0/16, subnet aks-subnet 10.0.0.0/22 |
| UAMI (CP) | uami-aks-cp-event-triage-dev | Control plane identity |
| UAMI (Kubelet) | uami-aks-kubelet-event-triage-dev | Node identity |
| LAW | law-event-triage-dev | Log Analytics workspace |
