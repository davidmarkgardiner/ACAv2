<!--
Labels: architecture, kagent, migration, k8s-event-triage
Milestone: Phase 3 — Production Security & Migration
Assignee:
-->

# Migrate kagent to worker clusters — hybrid management/worker model

## Context

Following the architecture exploration in #21, this ticket tracks the actual migration of kagent to worker clusters. The hybrid model places kagent with native k8s tools on worker clusters for application namespace triage, while specialized agents remain on the management cluster for system-critical namespaces only.

## Overview

The hybrid approach splits responsibility:

- **Worker cluster agents**: Run locally on each worker cluster, use native k8s tools directly (no MCP overhead), handle application namespace triage and remediation
- **Management cluster agents**: Specialized agents for system namespaces (`flux-system`, `cert-manager`, `aks-istio-ingress`) that require cross-cluster context or elevated privileges

```
┌─────────────────────────────────────────────────────────────────┐
│                      WORKER CLUSTER                              │
│                                                                  │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────────────┐  │
│  │ K8s      │──►│ Local        │──►│ Argo Events Sensor     │  │
│  │ Warning  │   │ EventSource  │   │ (per-namespace filter) │  │
│  │ Events   │   │ (no EventHub)│   └────────┬───────────────┘  │
│  └──────────┘   └──────────────┘            │                   │
│                                     ┌───────▼──────────┐        │
│  ┌──────────┐                       │ Argo Workflow    │        │
│  │ LiteLLM  │◄──────────────────────│ (kagent A2A)    │        │
│  │ proxy    │                       └───────┬──────────┘        │
│  └────┬─────┘                               │                   │
│       │                             ┌───────▼──────────┐        │
│       ▼                             │ Notification     │        │
│  ┌──────────┐                       │ (Teams/Telegram) │        │
│  │ Azure    │                       └──────────────────┘        │
│  │ OpenAI / │                                                    │
│  │ Ollama   │   Escalation (unresolvable):                      │
│  └──────────┘   └──► Event Hub ──► Management Cluster           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    MANAGEMENT CLUSTER                             │
│                                                                  │
│  System namespace agents only:                                   │
│  ├── flux-system (GitOps controller health)                      │
│  ├── cert-manager (certificate lifecycle)                        │
│  ├── aks-istio-ingress (service mesh ingress)                    │
│  └── Escalated events from worker clusters                       │
└─────────────────────────────────────────────────────────────────┘
```

## Benefits

| Benefit | Detail |
|---------|--------|
| No MCP overhead | Worker agents use native k8s tools directly — no AKS-MCP proxy, no UAMI, no RemoteMCPServer |
| No UAMI complexity | Worker agents use in-cluster service accounts, not Azure Managed Identity |
| Self-healing per cluster | Each worker cluster can triage and remediate independently |
| Reduced Event Hub traffic | Only escalations and system events cross the Event Hub boundary |
| Lower latency | In-cluster event processing (ms) vs Event Hub round-trip (seconds) |
| Resilience | Management cluster outage does not blind worker clusters |

## Worker Cluster Agents

- Run as kagent CRDs on the worker cluster
- Use native k8s tools (`get`, `describe`, `logs`, `patch`) via kagent's built-in k8s toolset
- Namespace-scoped RBAC: each agent has a dedicated service account with access only to its target namespace
- Handle application namespaces: app workloads, CrashLoopBackOff, OOMKilled, ImagePullBackOff, resource quota violations

## Management Cluster Agents

- Specialized agents for system-critical namespaces
- May use MCP for cross-cluster operations (e.g., checking Flux source status across clusters)
- Handle: `flux-system`, `cert-manager`, `gateway`, `aks-istio-ingress`
- Receive escalated events from worker clusters that could not be resolved locally

## Migration Steps

### Phase 1: Deploy AI stack on worker cluster
- [ ] Deploy LiteLLM proxy on worker cluster (Helm chart, `litellm` namespace)
- [ ] Configure LiteLLM to point at Azure OpenAI (or local Ollama as fallback)
- [ ] Deploy kagent on worker cluster (Helm chart, `kagent` namespace)
- [ ] Create namespace-scoped agent CRDs for target application namespaces

### Phase 2: Deploy event pipeline on worker cluster
- [ ] Deploy Argo Events controller + EventBus on worker cluster
- [ ] Create local EventSource (K8s resource watcher or webhook)
- [ ] Configure Alloy to send Warning events to local EventSource instead of Event Hub for local namespaces
- [ ] Deploy per-namespace Sensors with rate limiting (5/min per namespace)

### Phase 3: Wire up workflows
- [ ] Deploy Argo Workflows controller on worker cluster
- [ ] Create WorkflowTemplate for kagent A2A triage (reuse existing template)
- [ ] Deploy notification step (Teams webhook)
- [ ] End-to-end test: inject fault → local triage → notification

### Phase 4: Management cluster scope reduction
- [ ] Remove application namespace sensors from management cluster
- [ ] Keep only system namespace sensors (`flux-system`, `cert-manager`, etc.)
- [ ] Configure escalation path: worker agents write unresolvable events to Event Hub
- [ ] Management cluster consumes escalated events via existing EventSource

### Phase 5: Validation
- [ ] Worker cluster self-triages CrashLoopBackOff without management cluster
- [ ] Worker cluster self-triages ImagePullBackOff without management cluster
- [ ] Management cluster handles flux-system reconciliation failures
- [ ] Escalation path works: worker agent cannot resolve → Event Hub → management cluster picks up

## Acceptance Criteria

- [ ] Worker cluster can self-triage application namespace issues without management cluster involvement
- [ ] Management cluster handles system-level issues only (`flux-system`, `cert-manager`, `aks-istio-ingress`)
- [ ] Event Hub traffic reduced to escalations and system events only
- [ ] No MCP or UAMI dependencies on worker cluster agents
- [ ] Escalation path tested end-to-end
- [ ] Runbook documented for adding new worker clusters to the hybrid model
