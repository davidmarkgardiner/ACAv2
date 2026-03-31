# AKS Platform Automation — Proposal

**Date:** 2026-03-25
**Author:** David Gardiner
**Status:** Proposal — High-Level Design

---

## 1. Current State

### Onboarding
- A **Go program** generates Kubernetes manifests for namespace onboarding — **this is being replaced**
- Manifests are synced to clusters via **GitOps (Flux)** — Flux stays
- Teams get a bare namespace — no PDBs, security contexts, health checks, certs, virtual services, or ingress
- **No observability on the onboarding loop** — teams have no visibility into what's been created, what's pending, or what failed
- **No real-time feedback** — users submit a request and wait
- If teams need changes, they re-run the entire onboarding process
- Azure resources (workload identity, role assignments) are provisioned manually
- External resources (Key Vault, databases) require manual tickets and days of lead time
- RBAC applied ad-hoc with no audit trail

### Runtime
- **No effective monitoring or alerting** — the LGTM stack exists but alerts either don't fire or get ignored
- K8s Warning events (CrashLoopBackOff, OOMKilled, ImagePullBackOff) go completely unnoticed
- Issues discovered only when end users report them — MTTR measured in hours to days
- No automated diagnosis — engineers start from scratch every time
- No notification to application teams when their workloads are failing
- No audit trail of what was investigated

### Infrastructure
- No management cluster per environment
- No shared orchestration platform
- No LLM-based tooling in production
- No centralised monitoring of platform automation components

---

## 2. Desired State

### Onboarding
A self-service, observable, policy-compliant onboarding pipeline that provisions namespaces, applications, Azure resources, RBAC, and external dependencies — with best-practice defaults baked in, end-to-end visibility, and post-deploy validation. **The Go program is replaced by Argo Workflows.** Flux stays for GitOps sync — Argo Workflows generates manifests and commits to Git, Flux reconciles them to clusters.

### Runtime
An autonomous, event-driven system that triages Kubernetes issues in real-time, provides immediate diagnosis, creates audit records (GitLab), notifies application teams (Teams), and can execute remediation with human approval. Operates independently of the LGTM/AlertManager stack.

### Infrastructure
A management cluster per environment running shared platform components (Argo, kagent, LiteLLM, ASO, monitoring) that serves both onboarding and runtime triage. Fully observable — every component that builds or serves the solution is monitored, logged, and alertable.

---

## 3. Problem Statements

### Onboarding Problems

| # | Problem | Impact |
|---|---------|--------|
| O1 | No observability on the GitOps onboarding loop | Teams can't track progress — raises support tickets asking "is my namespace ready?" |
| O2 | Bare namespaces with no best-practice defaults | No PDBs, security contexts, health checks, certs, ingress — leads to production incidents |
| O3 | Azure resource provisioning is manual and error-prone | Workload identity misconfiguration is a top support ticket |
| O4 | External resource onboarding has no automation | Teams raise tickets and wait days for Key Vault/database access |
| O5 | RBAC applied ad-hoc with no audit trail | Over-permissioned service accounts, no least-privilege enforcement |
| O6 | No post-deployment validation | Issues discovered in production that should have been caught at deploy time |
| O7 | No incremental update path | Any change requires re-running the full onboarding process |

### Runtime Problems

| # | Problem | Impact |
|---|---------|--------|
| R1 | No effective monitoring or alerting in practice | Issues discovered only when users report them; MTTR hours to days |
| R2 | K8s Warning events go completely unnoticed | Workloads fail silently; teams don't know until end users complain |
| R3 | No automated first-pass diagnosis | Engineers start from scratch every time — no institutional knowledge captured |
| R4 | No real-time notification to application teams | Teams have no idea their pods are crashing |
| R5 | No audit trail of investigations | Knowledge lost after each incident; same issues investigated repeatedly |

### Infrastructure Problems (to solve along the way)

| # | Problem | Impact |
|---|---------|--------|
| I1 | No management cluster | No shared platform for orchestration, agent runtime, or Azure provisioning |
| I2 | No monitoring of the platform components themselves | If kagent, LiteLLM, Argo, or ASO fail, nobody knows |
| I3 | No LLM token governance | Runaway agents or loops could burn tokens unnoticed |
| I4 | No centralised logging for platform automation | Can't debug onboarding failures or triage issues across the pipeline |
| I5 | No security baseline for AI agents | Agents with k8s access need RBAC, network isolation, and approval gates |

---

## 4. Problems to Solve (Phased)

### Phase 0: Management Cluster Foundation
**Solves:** I1, I2, I4, I5
**Status:** BLOCKED — management cluster has been requested multiple times from the onboarding team. Currently blocked on IP availability in the target VNet. **This is a hard dependency — neither project can roll through environments without it.**

Stand up the management cluster with shared infrastructure. This is the foundation for both projects.

| What | Detail |
|------|--------|
| Argo Workflows controller | Workflow execution engine for both projects |
| Argo Events controller + NATS EventBus | Event-driven triggers (K8s events, webhooks) |
| kagent + kagent-controller | AI agent runtime |
| LiteLLM proxy + PostgreSQL | LLM routing, token tracking, spend dashboard (`/ui`) |
| Azure Service Operator (ASO) | Declarative Azure resource provisioning |
| kube-prometheus-stack | Prometheus + Grafana for monitoring the platform itself |
| Alloy → Loki | Log collection for all platform components |
| **Monitoring the solution itself:** | |
| - ServiceMonitor for LiteLLM | Token usage, latency, error rates → Prometheus |
| - ServiceMonitor for Argo Workflows | Workflow success/failure rates → Prometheus |
| - PrometheusRules for platform health | Alert on: LLM token anomaly, workflow failure rate, agent not ready |
| - Grafana dashboards | Platform health, LLM usage, pipeline activity |
| - LiteLLM UI dashboard | Visual spend tracking, per-model usage, request logs |

### Phase 1: Namespace Onboarding + Observability
**Solves:** O1, O7
**Approach:** Replace the Go program with Argo Workflows. Flux stays for GitOps sync.
**Rollout:** Engineers first, then SRE. Start with a basic hello-world app through the system, build from there.

- **Replace** the Go program with an Argo WorkflowTemplate that generates manifests and commits to Git
- Flux reconciles manifests to clusters (unchanged)
- Real-time progress tracking — teams see what's created, what's pending, what failed
- Notification on completion (Teams) with summary of what was provisioned
- Every namespace gets: ResourceQuota, LimitRange, NetworkPolicy, labels
- Audit trail via GitLab issues and workflow logs
- **First milestone:** Get a basic hello-world app through the onboarding pipeline end-to-end

### Phase 2: Runtime Triage on Worker Clusters
**Solves:** R1, R2, R3, R4, R5

- Deploy Argo Events on worker clusters
- K8s EventSource watches Warning events in real-time (not polling, not dependent on LGTM)
- Per-namespace Sensors filter and rate-limit events
- Shared WorkflowTemplate calls kagent A2A for diagnosis
- Per-namespace specialist agents (cert-manager, kyverno, flux, etc.)
- Diagnosis → GitLab issue + Teams notification immediately
- **Note:** Uses Alloy operator to scrape K8s events into EventSource — does NOT use AlertManager or LGTM alerts

### Phase 3: Application Onboarding + Best-Practice Defaults
**Solves:** O2, O3, O6
**Approach:** Start with basic structure, add components incrementally as the stack matures.

- Three input modes: JSON payload, raw manifests, Helm chart
- **Baked-in defaults** added incrementally (not all at once):
  - PodDisruptionBudgets (PDBs)
  - Security contexts (non-root, read-only filesystem, drop capabilities)
  - Health endpoints (liveness, readiness, startup probes)
  - Istio VirtualServices and DestinationRules
  - cert-manager Certificates for TLS ingress
  - NetworkPolicies (deny-all default + explicit allow)
- Workload identity via ASO (ManagedIdentity, FederatedCredential, RoleAssignment)
- Post-deploy validation via kagent
- Incremental updates — teams bolt on resources without re-running full onboarding
- Handoff to application team — they only add ConfigMaps and app-specific tweaks

### Phase 4: External Azure Resources (ASO)
**Solves:** O3, O4
**Dependency:** Phase 3 must establish the local K8s operator-based resources first. ASO comes after.

- **Azure Service Operator (ASO)** provisions external Azure resources declaratively:
  - ManagedIdentity + FederatedCredential (workload identity)
  - RoleAssignments (Azure RBAC linking identity to resources)
  - Key Vault access policies
  - Database resources (Azure SQL, Cosmos, etc.)
  - Storage accounts, Event Hubs
- Resources linked back to the application via federated credentials and workload identity
- External Secrets Operator syncs secrets from provisioned Key Vaults into K8s
- Same approval workflow governs all Azure provisioning

### Phase 5: RBAC Layer
**Solves:** O5
**Note:** RBAC must come with the ASO layer (Phase 4) and be baked into namespace onboarding (Phase 1). Without RBAC, application teams cannot access their namespace. This is not a later enhancement — it's a requirement from day one.

- **Namespace RBAC at onboarding time** — RoleBindings created as part of Phase 1 so teams have access immediately
- Azure RBAC aligned via ASO (role assignments on resource groups) — comes with Phase 4
- Azure AD group bindings for team access
- Periodic drift detection — compare actual vs declared state
- Break-glass procedure documented and auditable

### Phase 6: Autonomous Remediation
**Solves:** R1 (full resolution, not just diagnosis)

- Agents diagnose AND execute remediation — but **only from an explicit allowlist**
- **Allowlisted safe actions** (auto-remediation, no human approval needed):
  - Restart pod (delete pod, let controller recreate)
  - Scale deployment (up/down within defined bounds)
  - Rollback deployment to previous revision
  - Clear stuck jobs
  - Delete evicted/completed pods
- Anything not on the allowlist → diagnosis only + GitLab ticket + Teams notification
- All remediation actions logged: what was done, why, which agent, timestamp
- **HITL at work:** Teams incoming webhooks are one-way (send only, no callback for approve/reject). Options:
  - **Option A (recommended):** Allowlist-based auto-remediation for safe actions, no approval needed
  - **Option B:** kagent UI for approval (requires ingress or port-forward to kagent)
  - **Option C:** GitLab MR-based approval (agent creates MR with remediation manifest, human merges)
- Progressive trust: start with diagnosis-only, add allowlisted actions as confidence grows
- **Desired end state: autonomous real-time remediation for safe, well-understood failure patterns**

### Phase 7: LGTM Integration (future, requires LGTM team)
**Solves:** Expands R1 beyond K8s events

- Route AlertManager webhooks into Argo Events pipeline
- Triage based on Prometheus alerts (not just K8s events)
- Requires coordination with LGTM team
- Not a blocker — Phase 2 works independently

---

## 5. Tooling

### Core Platform (Management Cluster)

| Tool | Purpose | Solves |
|------|---------|--------|
| **Argo Workflows** | DAG-based workflow orchestration — deterministic, auditable | Both projects |
| **Argo Events** | Event-driven triggers — K8s events (triage), webhooks (onboarding) | Both projects |
| **kagent** | Kubernetes-native AI agents — triage diagnosis + post-deploy validation | Both projects |
| **LiteLLM + PostgreSQL** | LLM proxy — model routing, token tracking, spend dashboard | I3, monitoring |
| **Azure Service Operator (ASO)** | Declarative Azure resource provisioning from K8s | O3, O4 |

### Application Stack (Operators)

| Tool | Purpose | Solves |
|------|---------|--------|
| **cert-manager** | TLS certificate provisioning and renewal | O2 (certs/ingress) |
| **External Secrets Operator** | Secret injection from Key Vault into K8s | O4 |
| **Kyverno / Gatekeeper** | Policy enforcement on created resources | O2, O5 |
| **Istio** | Service mesh — VirtualServices, DestinationRules, mTLS | O2 (ingress/mesh) |
| **Flux** | GitOps — syncs manifests from Git to clusters | Existing, retained |

### Monitoring & Logging

| Tool | Purpose | Solves |
|------|---------|--------|
| **Prometheus (kube-prometheus-stack)** | Metrics collection, alerting rules | I2, I3 |
| **Grafana** | Dashboards — platform health, LLM usage, triage activity | I2 |
| **Loki** | Log aggregation | I4 |
| **Alloy** | Log/event collection agent — scrapes K8s events, ships to Loki and EventSource | R2, I4 |
| **LiteLLM UI** | Visual token spend tracking (`/ui` on LiteLLM proxy) | I3 |

### Notification & Audit

| Tool | Purpose | Solves |
|------|---------|--------|
| **GitLab** | Issue creation for audit trail, GitOps source of truth | O1, R5 |
| **Teams** | Real-time notification to application teams | O1, R4 |
| **NATS EventBus** | Internal event transport (Argo Events requirement) | R2 |

---

## 6. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    MANAGEMENT CLUSTER (per environment)                │
│                                                                       │
│  ┌────────────────────────┐     ┌──────────────────────────────────┐ │
│  │  Onboarding Engine      │     │  Runtime Triage Engine           │ │
│  │  Argo Workflows         │     │  Argo Events → Argo Workflows   │ │
│  │                         │     │                                   │ │
│  │  - Namespace + defaults │     │  - K8s EventSource (warnings)    │ │
│  │  - App + workload ID    │     │  - Per-namespace Sensors          │ │
│  │  - RBAC + Azure (ASO)   │     │  - kagent A2A triage              │ │
│  │  - Post-deploy (kagent) │     │  - GitLab + Teams notification    │ │
│  └────────────┬────────────┘     └───────────┬──────────────────────┘ │
│               │                               │                        │
│  ┌────────────▼───────────────────────────────▼────────────────────┐  │
│  │                    Shared Infrastructure                          │  │
│  │                                                                   │  │
│  │  kagent          LiteLLM + PG     ASO        ESO                 │  │
│  │  (agents)        (LLM proxy)      (Azure)    (secrets)           │  │
│  │                                                                   │  │
│  │  Prometheus      Grafana          Loki       Alloy               │  │
│  │  (metrics)       (dashboards)     (logs)     (collection)        │  │
│  │                                                                   │  │
│  │  Kyverno/Gatekeeper              Flux                            │  │
│  │  (policy)                         (GitOps)                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
          │                                          │
          ▼                                          ▼
 ┌─────────────────┐                     ┌─────────────────┐
 │ Worker Cluster A │                     │ Worker Cluster B │
 │ (app namespaces) │                     │ (app namespaces) │
 │                  │                     │                  │
 │ Local triage:    │                     │ Local triage:    │
 │ EventSource →    │                     │ EventSource →    │
 │ Sensor → kagent  │                     │ Sensor → kagent  │
 └─────────────────┘                     └─────────────────┘
```

---

## 7. Reference

### Diagrams
| Diagram | File |
|---------|------|
| Onboarding architecture | `diagram-onboarding.excalidraw` |
| Hybrid triage architecture | `diagram-runtime-triage.excalidraw` |

### Documentation
| Doc | File |
|-----|------|
| Worker cluster triage bundle | `README.md` (this folder) |
| Namespace onboarding guide | `ONBOARDING-NEW-NAMESPACE.md` |
| LiteLLM monitoring setup | In repo: `mission-control-shared/agents/LITELLM-MONITORING-SETUP.md` |
| Logging/monitoring SAD | In repo: `kagent-triage/docs/SAD-LOGGING-MONITORING-LLM.md` |
| Security/compliance SAD | In repo: `kagent-triage/docs/SAD-COMPLIANCE-CHECKLIST.md` |
| Threat model | In repo: `kagent-triage/docs/SAD-THREAT-MODEL.md` |
| RBAC design | In repo: `kagent-triage/docs/SHARED-CLUSTER-RBAC.md` |

### GitLab Issue
`GITLAB-ISSUE-PLATFORM-AUTOMATION.md` — copy into GitLab to create the tracking issue with phase checkboxes.

### Teams Message
`TEAMS-RESPONSE-PLATFORM-PROPOSAL.md` — copy-paste into Teams to share with stakeholders.
