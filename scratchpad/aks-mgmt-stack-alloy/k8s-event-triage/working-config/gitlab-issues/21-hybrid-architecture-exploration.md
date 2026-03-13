<!--
Labels: architecture, discussion, k8s-event-triage
Milestone: Architecture — Future
Assignee:
-->

# Architecture exploration: Hybrid management/worker cluster model

## Context

Current architecture centralises everything on the management cluster. A hybrid approach could:
- Move AI stack (KAgent, LiteLLM, Ollama) to **worker clusters** for self-healing application issues
- Keep management cluster for **critical cluster-level issues** that workers can't self-diagnose

## Proposed Hybrid Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      WORKER CLUSTER                              │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │ K8s Events   │───►│ Argo Events  │───►│ Triage Workflow  │   │
│  │ (local)      │    │ (no EventHub)│    │ (KAgent local)   │   │
│  └──────────────┘    └──────────────┘    └──────┬───────────┘   │
│                                                  │               │
│                                          ┌───────▼──────────┐   │
│                                          │ Self-Heal        │   │
│                                          │ (restart, scale,  │   │
│                                          │  rollback)        │   │
│                                          └──────────────────┘   │
│                                                                  │
│  Local AI Stack:                                                 │
│  ├── KAgent (namespace-specific agents)                          │
│  ├── LiteLLM proxy                                               │
│  └── Ollama (or remote LLM endpoint)                             │
│                                                                  │
│  Escalation path (critical/unresolvable):                        │
│  └──► Event Hub ──► Management Cluster                           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    MANAGEMENT CLUSTER                             │
│                                                                  │
│  Receives escalated events only:                                 │
│  ├── Node failures                                               │
│  ├── Cluster-wide networking issues                              │
│  ├── Control plane problems                                      │
│  ├── Cross-namespace incidents                                   │
│  └── Events the worker agent couldn't resolve                    │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │ Event Hub    │───►│ Argo Events  │───►│ Cluster Triage   │   │
│  │ (escalated)  │    │              │    │ (senior agents)  │   │
│  └──────────────┘    └──────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Benefits

| Aspect | Current (centralised) | Hybrid |
|--------|----------------------|--------|
| Latency | Event Hub round-trip (~seconds) | Direct in-cluster (ms) |
| Self-healing speed | Slow (cross-cluster) | Fast (local) |
| Event Hub dependency | All events go through | Only escalations |
| Event Hub cost | Higher (all events) | Lower (only critical) |
| Blast radius | Management cluster failure = blind | Workers can still self-heal |
| Complexity | Simpler (one pipeline) | More complex (two tiers) |

## Key Design Decisions

- [ ] **What goes to management vs stays local?**
  - Application pod issues (CrashLoop, OOM, ImagePull) → local
  - Node issues (NotReady, MemoryPressure) → management
  - Networking (DNS, Ingress, NetworkPolicy) → depends on scope
  - Storage (PVC, CSI) → depends on scope

- [ ] **How does the worker agent escalate?**
  - Option 1: Agent writes to Event Hub directly (existing path)
  - Option 2: Agent creates a K8s Event with `type: Escalation` → Alloy forwards
  - Option 3: Agent calls management cluster API directly

- [ ] **Ollama on every worker cluster?**
  - CPU-only: feasible but resource overhead per cluster
  - Shared remote LLM: lower resource cost, adds network dependency
  - Hybrid: small model locally (triage), large model remotely (complex remediation)

## Next Steps

- [ ] Prototype on one worker cluster (keep management pipeline as-is)
- [ ] Measure: what % of events could be self-healed locally?
- [ ] Measure: resource cost of AI stack per worker cluster
- [ ] Decision: proceed with hybrid or stay centralised

## Acceptance Criteria

- [ ] Architecture decision documented
- [ ] If proceeding: prototype plan created
- [ ] Cost/benefit analysis completed
