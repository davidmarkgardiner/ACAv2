# KAgent SRE Alert Triage Architecture

Architecture diagram and reference for the AI-enhanced Prometheus alerting pipeline using KAgent for automated triage and remediation.

**Diagram file:** `kagent-prometheus-alerting-architecture.excalidraw` (open with [Excalidraw](https://excalidraw.com) or VS Code Excalidraw extension)

**Original (non-KAgent) diagram:** `prometheus-alerting-architecture.excalidraw` — the base pipeline without AI components

---

https://excalidraw.com/#json=As6xnKJTGfx_wsXGpJmff,4IdDOIrCp4VWStQVRJFdLA

## What This Diagram Shows

This is an extension of the original Prometheus alerting pipeline. The original pipeline routes alerts from Prometheus through AlertManager into Argo Events, which triggers a workflow that creates GitLab issues and sends Mattermost notifications.

The enhanced version adds an **AI triage layer** between the Argo Workflow and the reporting outputs. Instead of just forwarding raw alerts, the workflow now calls KAgent to analyse the alert using LLM-powered agents before creating issues and notifications.

---

## Pipeline Flow (7 Steps)

### Step 1: COLLECT — Scrape & Evaluate

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **Pods / Containers** | various | Application workloads exposing `/metrics` endpoints |
| **PrometheusRule CRDs** | `monitoring` | Custom alert rules (OOMKilled, PodHighRestarts, FailedScheduling, CPU/Memory/PVC thresholds) |
| **Prometheus** | `monitoring` | Scrapes metrics from pods, evaluates PrometheusRule CRDs to determine if alerts should fire |
| **Grafana** | `monitoring` | Queries Prometheus as a datasource for dashboard visualisation |

### Step 2: ALERT — Webhook to Argo

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **AlertManager** | `monitoring` | Receives firing alerts from Prometheus. The `argo-events-webhook` receiver routes matching alerts via HTTP POST to the EventSource |
| **EventSource** | `argo-events` | Webhook listener on port `12000`, endpoint `/alerts`. Receives AlertManager POST payloads |

### Step 3: TRIAGE — Filter & Trigger

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **EventBus (NATS)** | `argo-events` | Message bus connecting EventSource to Sensor. EventSource publishes alert events, Sensor subscribes |
| **Sensor** | `argo-events` | Filters for `status: firing` alerts, rate-limited to 5/minute. Triggers the `kagent-sre-workflow` WorkflowTemplate |
| **WorkflowTemplate** | `argo-events` | `kagent-sre-workflow` — DAG workflow that orchestrates KAgent triage, GitLab issue creation, and Mattermost notification |

### Step 4: AI TRIAGE — KAgent A2A Call

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **KAgent Controller** | `kagent` | Receives A2A (Agent-to-Agent) HTTP requests from the workflow. Routes to the appropriate agent based on the alert type and mode (triage or remediation) |
| **sre-triage-agent** | `kagent` | **Read-only** agent. Analyses the alert, checks pod status, logs, and events. Produces a root cause analysis without making any changes |
| **sre-remediation-agent** | `kagent` | **Read-write** agent. Can take corrective action (restart pods, scale deployments, patch resources) based on the triage analysis |

The workflow calls the KAgent controller via the A2A protocol:
```
POST /api/a2a/kagent/{agent-name}/
Method: message/send
```

### Step 5: INVESTIGATE — Agents + MCP Tools

| Component | Namespace | Description |
|-----------|-----------|-------------|
| **AKS-MCP** | `kagent` | MCP (Model Context Protocol) tool server providing Kubernetes tools (`kubectl`, `helm`) to the agents. Both triage and remediation agents use AKS-MCP to inspect or modify cluster resources |
| **AKS Cluster** | external | The target workload cluster. AKS-MCP connects to the cluster's Kubernetes API server to execute commands on behalf of the agents |

### Step 6: LLM — Model Inference

| Component | Location | Description |
|-----------|----------|-------------|
| **LiteLLM Gateway** | in-cluster | LLM routing proxy. Agents send inference requests here, and LiteLLM forwards to the configured backend |
| **KubeAI (Qwen3-14b)** | self-hosted | Open-source LLM running on the cluster via KubeAI. Model: `qwen3-14b`. No external API calls, full data privacy. Referred to as `openai/qwen3-14b` in LiteLLM routing config |
| **OpenAI API (GPT-4o)** | cloud | Alternative cloud-hosted LLM backend. Higher capability but requires external API access and incurs per-token costs |

LiteLLM can route to **either** backend. The `OR` relationship means you configure one or both — KubeAI for self-hosted/private workloads, OpenAI for higher-quality analysis when needed.

### Step 7: REPORT — GitLab + Mattermost

| Component | Location | Description |
|-----------|----------|-------------|
| **GitLab** | external API | Creates an issue containing: alert summary, KAgent triage analysis, root cause, recommended actions, pod logs/events |
| **Mattermost** | `mattermost` namespace | Sends colour-coded webhook notification with alert details, KAgent analysis summary, and a link to the GitLab issue |

---

## Component Summary

### Namespaces

| Namespace | Components | Purpose |
|-----------|------------|---------|
| `monitoring` | Prometheus, AlertManager, Grafana, PrometheusRule CRDs | Metrics collection and alerting |
| `argo-events` | EventSource, EventBus, Sensor, WorkflowTemplate | Event-driven workflow orchestration |
| `kagent` | KAgent Controller, sre-triage-agent, sre-remediation-agent, AKS-MCP | AI-powered triage and remediation |
| `mattermost` | Mattermost | Chat notifications |

### External Services

| Service | Protocol | Purpose |
|---------|----------|---------|
| GitLab API | HTTPS | Issue creation for alert tracking |
| OpenAI API | HTTPS | Cloud LLM inference (optional) |
| AKS Cluster | Kubernetes API | Target cluster for agent investigation/remediation |

---

## Diagram Colour Legend

| Colour | Hex (Background / Stroke) | Meaning |
|--------|---------------------------|---------|
| Blue | `#a5d8ff` / `#1971c2` | Prometheus stack (Prometheus, AlertManager, Grafana) |
| Green | `#b2f2bb` / `#2f9e44` | Argo Events (EventSource, EventBus, Sensor, WorkflowTemplate) |
| Orange | `#ffd8a8` / `#e8590c` | Alerts and notifications (Mattermost) |
| Grey | `#dee2e6` / `#495057` | Kubernetes resources (Pods, PrometheusRule CRDs) |
| Red/Coral | `#ffc9c9` / `#e03131` | External integrations (GitLab) |
| Purple | `#d0bfff` / `#7048e8` | AI / KAgent (Controller, agents, LiteLLM, LLM backends) |
| Teal | `#96f2d7` / `#0ca678` | MCP tools (AKS-MCP, AKS Cluster) |
| Dashed border | — | Namespace boundary |

---

## Key Design Decisions

### Two-Agent Pattern (Triage vs Remediation)

- **sre-triage-agent** is read-only — it can inspect pods, logs, events, and describe resources but cannot modify anything. Safe for automated triggering on every alert.
- **sre-remediation-agent** is read-write — it can restart pods, scale deployments, apply patches. Should only be invoked after triage confirms the issue and a remediation path.

This separation ensures that automated alerts don't accidentally trigger destructive actions.

### LiteLLM as LLM Gateway

LiteLLM sits between the agents and the actual LLM backends. This provides:
- **Model routing** — switch between self-hosted Qwen3-14b and cloud GPT-4o without changing agent config
- **Fallback** — if the self-hosted model is overloaded, requests can fall back to OpenAI
- **Cost tracking** — LiteLLM tracks token usage per model
- **API compatibility** — both KubeAI and OpenAI expose OpenAI-compatible APIs, so agents use a single interface

### AKS-MCP for Kubernetes Access

Agents don't run `kubectl` directly. Instead, they call AKS-MCP via the Model Context Protocol, which provides structured Kubernetes tools (`call_kubectl`, `call_helm`). This:
- Avoids shell quoting issues that plague direct kubectl execution
- Provides structured input/output rather than raw shell text
- Enables access control at the MCP server level

---

## Related Files

| File | Description |
|------|-------------|
| `prometheus-alerting-architecture.excalidraw` | Original pipeline diagram (without KAgent) |
| `kagent-prometheus-alerting-architecture.excalidraw` | **This diagram** — enhanced with KAgent AI layer |
| `01-alertmanager-values.yaml` | AlertManager webhook receiver config |
| `02-custom-alerting-rules.yaml` | PrometheusRule CRDs |
| `03-eventsource-alertmanager.yaml` | Argo Events webhook EventSource |
| `04-workflow-template.yaml` | Original workflow template (non-KAgent) |
| `05-sensor.yaml` | Argo Events Sensor with rate limiting |
| `../../holmes-argoworkflows/kagent-sre-workflow.yaml` | KAgent SRE workflow template (the actual DAG) |
| `../../holmes-argoworkflows/kagent-alert-triage.yaml` | Bridge workflow connecting Sensor to KAgent workflow |
