<!--
Labels: security, architecture, documentation, k8s-event-triage
Milestone: Phase 3
Assignee:
-->

# Solution Architecture Document (SAD) — K8s Event Triage Platform

---

## 1. System Overview

### 1.1 Purpose

The K8s Event Triage Platform provides AI-powered Kubernetes event triage and remediation across multiple AKS clusters. When a Kubernetes Warning event occurs (pod crash, image pull failure, resource exhaustion, certificate expiry, etc.), the platform automatically diagnoses the root cause using AI agents and notifies the operations team with actionable remediation guidance.

### 1.2 Architecture Model

The platform uses a **hybrid management/worker cluster model**:

- **Worker clusters**: Run kagent with native k8s tools for application namespace triage. Events are processed locally without crossing cluster boundaries. Self-healing for common application issues.
- **Management cluster**: Runs specialized kagent agents for system-critical namespaces (`flux-system`, `cert-manager`, `aks-istio-ingress`). Receives escalated events from worker clusters that could not be resolved locally.

### 1.3 High-Level Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                         WORKER CLUSTER (per cluster)                    │
│                                                                         │
│  K8s Warning    Alloy          Local           Argo Events   Argo      │
│  Events ──────► (collector) ──► EventSource ──► Sensor ─────► Workflow  │
│                                                 (rate limit)  │         │
│                                                               ▼         │
│                                                         kagent (A2A)    │
│                                                           │    │        │
│                                                    native │    │ LLM    │
│                                                    k8s    │    │ call   │
│                                                    tools  ▼    ▼        │
│                                                        LiteLLM proxy    │
│                                                           │             │
│  Escalation (unresolvable) ──► Event Hub ──────────────────┘            │
│                                                                         │
│  Notification ◄── Teams/Telegram webhook                                │
└────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────┐
│                         MANAGEMENT CLUSTER                              │
│                                                                         │
│  Event Hub ──► EventSource ──► Sensor ──► Workflow ──► kagent (A2A)    │
│  (escalated                    (system                   │              │
│   + system                      NS only)          ┌──────┘              │
│   events)                                         ▼                     │
│                                              LiteLLM proxy              │
│                                                   │                     │
│  System namespaces:                               ▼                     │
│  ├── flux-system          ◄── MCP (cross-cluster) / native k8s         │
│  ├── cert-manager                                                       │
│  ├── aks-istio-ingress                                                  │
│  └── gateway                                                            │
│                                                                         │
│  Notification ◄── Teams/Telegram webhook                                │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.4 Key Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Alloy (Grafana) | Collects K8s Warning events, forwards to EventSource or Event Hub | `alloy` |
| Event Hub (Azure) | Cross-cluster event transport for system events and escalations | N/A (Azure PaaS) |
| Argo Events | Event routing: EventSource receives events, Sensors filter and trigger workflows | `argo-events` |
| Argo Workflows | Orchestrates triage pipeline: parse event, call agent, send notification | `argo` |
| kagent | AI agents that diagnose K8s issues via A2A protocol | `kagent` |
| LiteLLM | LLM proxy — routes to Azure OpenAI or local Ollama | `litellm` |
| Teams/Telegram | Notification channels for triage results | N/A (external) |

---

## 2. Component Architecture

### 2.1 Per-Worker-Cluster Stack

Each worker cluster runs its own complete triage pipeline:

| Component | Details |
|-----------|---------|
| kagent | Namespace-specific agents (e.g., `sre-triage-myapp`) with native k8s tools |
| LiteLLM proxy | Routes LLM calls to Azure OpenAI; fallback to local Ollama |
| Argo Events | EventBus (NATS), EventSource (K8s resource watcher), per-namespace Sensors |
| Argo Workflows | WorkflowTemplate for triage pipeline |
| Alloy | Collects Warning events, sends to local EventSource |

Worker cluster agents use **native k8s tools** directly (no MCP, no UAMI). This eliminates MCP overhead, shell quoting issues, and Azure identity complexity.

### 2.2 Management Cluster Stack

| Component | Details |
|-----------|---------|
| kagent | System namespace agents (`flux-system`, `cert-manager`, etc.) |
| LiteLLM proxy | Shared LLM proxy |
| Argo Events | EventSource consuming from Event Hub (escalated + system events) |
| Argo Workflows | WorkflowTemplate for system triage pipeline |
| Event Hub consumer | Receives events from worker clusters and local system namespaces |

Management cluster agents may use **MCP** (AKS-MCP) for cross-cluster operations where native tools are insufficient.

### 2.3 Shared Infrastructure

| Component | Details |
|-----------|---------|
| LLM Provider | Azure OpenAI (`gpt-4o`) or self-hosted Ollama (`qwen3-14b`) via LiteLLM |
| Event Hub | Azure Event Hubs Standard tier — cross-cluster event transport |
| GitOps | Flux v2 — all manifests in Git, reconciled automatically |
| Secrets | Azure Key Vault + External Secrets Operator (production); Teller (local dev) |

---

## 3. Security Architecture

### 3.1 RBAC — Per-Namespace Agent Service Accounts

Each kagent agent has a dedicated Kubernetes ServiceAccount with the minimum required permissions:

| Agent Type | Verbs | Scope |
|------------|-------|-------|
| Triage agent (default) | `get`, `list`, `watch` | Target namespace only (Role, not ClusterRole) |
| Remediation agent (future) | `get`, `list`, `watch`, `patch`, `update` | Target namespace only, gated by human-in-the-loop (#18) |

- No agent has ClusterRole access
- No agent can access namespaces outside its assignment
- Service account tokens are bound (short-lived, auto-rotated, K8s 1.24+)

### 3.2 Network Security

| Policy | Effect |
|--------|--------|
| Default deny in `kagent` namespace | No traffic unless explicitly allowed |
| kagent egress allow | LiteLLM (port 4000), K8s API (port 6443), DNS (port 53) only |
| kagent ingress allow | From `argo` namespace only (workflow pods calling A2A API) |
| No external ingress | kagent A2A API is ClusterIP only — no Ingress, no LoadBalancer, no NodePort |
| LiteLLM egress allow | Azure OpenAI endpoint only |

### 3.3 Secrets Management

| Environment | Method |
|-------------|--------|
| Local development | Teller (`.teller.yml`) — injects secrets as env vars |
| Production (AKS) | Azure Key Vault + External Secrets Operator (ESO) |
| CI/CD | Azure DevOps variable groups linked to Key Vault |

Secrets inventory:
- Event Hub SAS tokens (Send for Alloy, Listen for EventSource)
- LiteLLM API key
- Azure OpenAI API key
- Teams/Telegram webhook URLs
- GitLab token (for Argo Workflows GitOps steps)

### 3.4 Authentication

| Component | Auth Method |
|-----------|-------------|
| kagent A2A API | Internal only (ClusterIP) — no external authentication needed |
| LiteLLM proxy | API key in `Authorization` header (K8s Secret) |
| Event Hub | SAS tokens (scoped: Send-only for producers, Listen-only for consumers) |
| Argo Server UI | OAuth2 (Authentik) for human access; ServiceAccount token for API |
| Azure OpenAI | API key (stored in Key Vault, synced via ESO) |

### 3.5 Workload Protection

Kyverno policies enforce:
- Only kagent controller and Argo workflow SA can create pods in `kagent` namespace
- All workloads in `kagent` must have label `app.kubernetes.io/managed-by: kagent`
- ResourceQuota caps total resource usage in `kagent` namespace
- LimitRange caps per-pod resources
- No LoadBalancer or NodePort services in `kagent` namespace

See #25 for detailed policies.

### 3.6 Audit Trail

| What | Where |
|------|-------|
| Agent API calls | Kubernetes audit logs → Alloy → Loki |
| Workflow execution history | Argo Workflows UI + API (retained per Argo GC policy) |
| LLM token usage | LiteLLM `/spend/logs` endpoint + Prometheus metrics |
| Agent triage output | Workflow logs + notification messages |
| Configuration changes | Git history (GitOps via Flux) |

---

## 4. Data Flow

### 4.1 Worker Cluster — Local Triage (Happy Path)

```
1. K8s Warning Event (e.g., Pod CrashLoopBackOff in namespace "myapp")
       │
2.     ▼ Alloy collects event (DaemonSet, watches K8s API)
       │
3.     ▼ Alloy forwards to local EventSource (HTTP webhook or K8s resource watcher)
       │
4.     ▼ Sensor matches: namespace="myapp", event.type="Warning"
       │   Rate limit: 5 events/min per namespace
       │
5.     ▼ Argo Workflow triggered:
       │   Step 1: parse-event (extract namespace, pod, reason, message)
       │   Step 2: find-agent (lookup kagent agent for namespace "myapp")
       │   Step 3: call-agent (A2A POST to kagent sre-triage-myapp)
       │   Step 4: send-notification (Teams/Telegram with triage result)
       │
6.     ▼ kagent agent receives A2A request:
       │   - Uses native k8s tools: get pods, describe pod, get events, get logs
       │   - Sends context to LLM (LiteLLM → Azure OpenAI)
       │   - Returns structured diagnosis + remediation steps
       │
7.     ▼ Notification sent to Teams/Telegram with:
           - Event summary
           - Root cause analysis
           - Recommended remediation
           - Severity assessment
```

### 4.2 Management Cluster — System Triage

```
1. K8s Warning Event in system namespace (e.g., cert-manager certificate renewal failure)
       │
2.     ▼ Alloy forwards to Event Hub (cross-cluster transport)
       │
3.     ▼ Management cluster EventSource consumes from Event Hub
       │
4.     ▼ Sensor matches: namespace="cert-manager", event.type="Warning"
       │
5.     ▼ Argo Workflow triggered (same template as worker, different agent)
       │
6.     ▼ kagent cert-manager agent:
       │   - Uses native k8s tools + cert-manager CRD tools
       │   - Checks Certificate, CertificateRequest, Issuer, ClusterIssuer
       │   - Returns diagnosis
       │
7.     ▼ Notification sent
```

### 4.3 Escalation Path

```
1. Worker cluster agent cannot resolve issue (unknown error, cross-namespace, node-level)
       │
2.     ▼ Agent response includes: status="escalation_needed"
       │
3.     ▼ Workflow escalation step: write event to Event Hub with type="escalation"
       │
4.     ▼ Management cluster EventSource picks up escalation
       │
5.     ▼ Senior agent on management cluster triages with broader context
       │
6.     ▼ Notification sent (marked as escalated)
```

---

## 5. Failure Modes and Resilience

### 5.1 LLM Provider Down

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Azure OpenAI unreachable | Agents cannot diagnose events | LiteLLM fallback to local Ollama (`qwen3-14b`) |
| Ollama pod crash | Fallback LLM unavailable | Liveness probe restarts Ollama; events queue in Sensor |
| Both LLMs down | No diagnosis possible | Workflow fails with retry (backoff: 30s, 1m, 5m); raw event forwarded to notification channel |

### 5.2 Event Hub Down

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Event Hub unavailable | Cross-cluster events lost | Worker clusters continue local triage; only escalations and system events affected |
| Event Hub partition offline | Some events delayed | Event Hub auto-recovers; Alloy retries with backoff |
| Consumer group lag | Events delayed | Monitor consumer group lag metric; alert at > 100 events behind |

### 5.3 Agent Timeout

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| kagent A2A call hangs | Workflow step blocks | Workflow timeout: 120s per agent call; retry with backoff |
| Agent returns error | Diagnosis incomplete | Workflow retry (up to 3 attempts); fall back to raw event notification |

### 5.4 Sensor Flood

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Rapid pod restarts | Hundreds of Warning events/min | Sensor rate limiting: 5 events/min per namespace (configurable) |
| CrashLoopBackOff storm | Duplicate triage runs | Deduplication in Alloy config (hash-based, 5-min window) |
| Event Hub burst | Consumer overwhelmed | Event Hub partitioning + consumer scaling |

### 5.5 Component Failure Matrix

| Component Down | Self-Heals? | Impact | Recovery |
|----------------|-------------|--------|----------|
| Alloy | Yes (DaemonSet) | Events not collected | Pod restart via DaemonSet controller |
| Argo Events controller | Yes (Deployment) | Sensors stop triggering | Pod restart; events buffered in EventBus |
| Argo Workflows controller | Yes (Deployment) | Workflows not scheduled | Pod restart; pending workflows resume |
| kagent | Yes (Deployment) | Agents unavailable | Pod restart; A2A calls retry |
| LiteLLM | Yes (Deployment) | LLM calls fail | Pod restart; agent calls retry |
| EventBus (NATS) | Yes (3-replica HA) | Event routing disrupted | NATS cluster self-heals |

---

## 6. Deployment Model

### 6.1 GitOps via Flux

All platform manifests are stored in Git and reconciled by Flux v2:

```
aks-mgmt-stack/k8s-event-triage/
├── working-config/
│   ├── alloy-config.yaml           # Alloy event collection
│   ├── eventsource-*.yaml          # Argo Events EventSources
│   ├── sensor-*.yaml               # Argo Events Sensors
│   ├── workflow-template-*.yaml    # Argo WorkflowTemplates
│   ├── kagent/                     # Agent CRDs
│   └── rbac/                       # RBAC manifests
```

Changes flow: Git PR → Review → Merge → Flux reconcile → K8s apply.

### 6.2 AKS Cluster Provisioning

- AKS clusters provisioned via Azure Service Operator or Terraform
- Node pools: system pool (3 nodes) + user pool (auto-scaling)
- AI stack node affinity: schedule kagent, LiteLLM, Ollama on dedicated node pool (optional)

### 6.3 kagent Deployment

- kagent controller: Helm chart (`kagent` namespace)
- Agent CRDs: declarative YAML applied via Flux
- Agent configuration: system prompt, tools, model, namespace scope — all in CRD spec
- Portable: same agent CRD YAML works on any cluster with kagent installed

### 6.4 LiteLLM Deployment

- Helm chart (`litellm` namespace)
- Config: model routing, API keys, rate limits, fallback chain
- Prometheus metrics endpoint for monitoring (#20)

---

## 7. Compliance and Governance

### 7.1 Data Privacy

| Concern | Status |
|---------|--------|
| PII in event data | No PII in K8s Warning events (pod names, namespace names, error messages only) |
| LLM data residency | Azure OpenAI: data stays within Azure region; self-hosted Ollama: data stays in cluster |
| LLM data retention | Azure OpenAI: no data retention (opted out); Ollama: no persistence |
| Event Hub data | Retained for 24h (configurable), no PII |

### 7.2 LLM Boundary

- **Azure OpenAI**: All LLM calls route through Azure OpenAI within the Azure boundary. No data leaves Azure.
- **Self-hosted Ollama**: LLM runs in-cluster. No data leaves the Kubernetes cluster.
- **LiteLLM proxy**: Acts as a routing layer only — does not store prompts or responses (unless logging is explicitly enabled for debugging).

### 7.3 Auditability

| Action | Audit Source |
|--------|-------------|
| Agent triage decision | Argo Workflow logs (step outputs) |
| Agent k8s API calls | Kubernetes audit log |
| LLM prompt/response | LiteLLM spend logs (token counts; full prompts only if debug logging enabled) |
| Configuration change | Git commit history (Flux GitOps) |
| Secret access | Azure Key Vault access logs |

### 7.4 Human-in-the-Loop

- Current state: All agents are **read-only triage** — no automated remediation
- Future state (#18): Remediation agents will require human approval before executing destructive actions
- Approval mechanism: Teams Adaptive Card with Approve/Reject buttons → Argo Workflow suspend/resume
- No destructive operation (delete pod, scale deployment, rollback) executes without human confirmation

### 7.5 Change Management

- All pipeline configuration changes go through Git PR review
- Flux GitOps ensures cluster state matches Git (drift detection)
- Agent prompt changes are versioned in Git (CRD spec)
- Breaking changes require go/no-go checklist (#17)

---

## Appendix A: Component Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Kubernetes (AKS) | 1.31.x | Managed by Azure |
| Argo Workflows | 3.6.4 | `argo` namespace |
| Argo Events | 1.9.x | `argo-events` namespace |
| kagent | 0.7.x | `kagent` namespace |
| LiteLLM | latest | `litellm` namespace |
| Alloy (Grafana) | latest | `alloy` namespace |
| Kyverno | 1.12.x | `kyverno` namespace |
| Flux v2 | 2.x | `flux-system` namespace |

## Appendix B: Related Issues

| # | Title | Relevance |
|---|-------|-----------|
| 18 | Human-in-the-loop approval | Remediation governance |
| 19 | KAgent observability via LGTM | Audit logging |
| 20 | LiteLLM monitoring | Token/cost tracking |
| 21 | Hybrid architecture exploration | Architecture decision |
| 22 | SAD security & compliance | Security documentation |
| 23 | kagent worker cluster migration | Hybrid deployment |
| 24 | RBAC lockdown | Access control |
| 25 | Unsolicited workload protection | Namespace protection |
