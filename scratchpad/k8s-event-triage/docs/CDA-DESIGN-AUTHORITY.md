# CDA — Claude Design Authority

## K8s Event Triage Platform (kagent-triage)

**Document Owner:** Platform Engineering Team
**Version:** 1.0
**Date:** 2026-03-31
**Status:** Draft — Pending CDA Review

---

# 1. Summary

## What?

An AI-powered Kubernetes event triage platform that automatically detects, diagnoses, and reports on cluster warning events across multiple AKS worker clusters. The platform uses namespace-specific AI agents (kagent, CNCF Sandbox) to analyse Kubernetes warning events in real-time, produce root-cause diagnoses via LLM, and notify operations teams through GitLab issues and Microsoft Teams.

The system runs on a **management cluster** that orchestrates triage across remote **worker clusters** using workload identity and the AKS-MCP tool for cross-cluster access.

## Why?

- **Reduce Mean Time to Detect (MTTD):** K8s warning events are currently invisible until they escalate to incidents. This platform catches issues at the event level before they become outages.
- **Reduce Mean Time to Resolve (MTTR):** AI-generated diagnoses with structured remediation steps reduce the skill barrier and investigation time for operations teams.
- **Scale observability without scaling headcount:** Each new namespace is onboarded with a single agent+sensor pair — no additional human capacity required.
- **Standardise triage output:** Every triage produces a consistent GitLab issue with severity, root cause, remediation, and affected resources.

## Who?

| Role | Team/Individual | Responsibility |
|------|----------------|----------------|
| Platform Engineer (Owner) | Platform Engineering | Design, deploy, operate the triage pipeline |
| Security Reviewer | InfoSec | Approve threat model, RBAC, data classification |
| Data Governance | Data Office | Approve data flows, LLM data privacy, retention |
| Service Owner | Platform Engineering | Day-to-day operations, incident response |
| Consumers | SRE / Operations Teams | Receive triage output (GitLab issues, Teams notifications) |

## Where?

| Environment | Cluster | Purpose |
|-------------|---------|---------|
| Management Plane | AKS management cluster | Runs kagent, Argo Events, Argo Workflows, LiteLLM |
| Worker Clusters | AKS worker clusters (multiple) | Source of K8s warning events; targets for cross-cluster diagnostic reads |
| Azure Event Hub | Azure PaaS | Event transport between worker clusters and management cluster |
| GitLab | SaaS / Self-hosted | Triage issue destination |
| Microsoft Teams | Microsoft 365 | Notification channel via Logic App webhook |
| LLM Provider | Azure OpenAI / On-prem (Ollama/vLLM) | AI inference for diagnosis |

## Impact If Not Approved

- K8s warning events continue to go undetected until they escalate to P1/P2 incidents.
- Operations teams continue reactive firefighting without structured diagnostic data.
- No standardised triage output — diagnosis quality varies by who is on-call and their platform knowledge.
- Manual investigation time per incident remains at 30-60 minutes (vs. ~60 seconds automated).
- Namespace onboarding for triage remains a manual, error-prone process.

## Component Dependencies

| Component | Version | Dependency Type | Impact if Unavailable |
|-----------|---------|----------------|----------------------|
| kagent (CNCF Sandbox) | v0.8.0+ | Core — AI agent framework | No triage occurs |
| Argo Workflows | v3.6.4+ | Core — Orchestration | No triage occurs |
| Argo Events | v1.9+ | Core — Event routing | Events not consumed |
| Azure Event Hub | Standard tier | Transport — Cross-cluster events | Management cluster blind to worker events; worker-local triage unaffected |
| LiteLLM | Latest | Core — LLM proxy/gateway | No AI diagnosis; workflow degrades gracefully (creates GitLab issue with raw event only) |
| LLM Provider (Azure OpenAI / on-prem) | N/A | Core — AI inference | Same as LiteLLM unavailability |
| GitLab API | v4 | Output — Issue creation | Triage results not persisted (Telegram/Teams still fires) |
| Logic App (Teams webhook) | N/A | Output — Notifications | Teams notifications stop; GitLab issues still created |
| External Secrets Operator | v0.9+ | Support — Secret rotation | Secrets not auto-rotated; manual rotation required |

---

# 2. Threat Scenarios

## Risk Categories

The following threat scenarios are assessed against the CDA risk taxonomy. For each, we identify the threat, existing controls (preventive, detective, corrective), and residual risk.

### 2.1 Internal Data Theft

| Aspect | Detail |
|--------|--------|
| **Threat** | A user with management cluster access exfiltrates triage data (event metadata, LLM diagnoses, agent configurations) |
| **Controls** | RBAC: Only `platform-team-admins` Azure AD group can access `kagent` and `argo-events` namespaces. Kyverno admission policy denies non-platform users from managing kagent CRDs. All cluster access logged via Azure AD audit trail and K8s audit logs. |
| **Detection** | Azure AD sign-in logs, K8s audit logs forwarded to SIEM, Grafana dashboards for anomalous API access patterns |
| **Residual Risk** | **Low** — Data processed is operational metadata (pod names, event reasons, namespaces). No secrets, PII, or business data flows through the pipeline. A malicious insider with platform-team-admins access could read triage output, but this is the same data visible in `kubectl get events`. |

### 2.2 External Data Theft

| Aspect | Detail |
|--------|--------|
| **Threat** | An external attacker gains access to triage data via compromised credentials or network exposure |
| **Controls** | All pipeline components are **ClusterIP only** — zero external ingress. Event Hub uses SAS tokens with least-privilege (Send-only for Alloy, Listen-only for EventSource). KAgent A2A endpoint has no external network path. NetworkPolicies enforce default-deny on `kagent` and `argo-events` namespaces. |
| **Detection** | Network policy violation alerts, Event Hub access logs, Azure Activity Log |
| **Residual Risk** | **Very Low** — No external attack surface exists. The only external-facing components are Azure Event Hub (SAS-authenticated, TLS 1.2+) and outbound calls to GitLab/Logic App/LLM (HTTPS, token-authenticated). |

### 2.3 Access to Restricted Data

| Aspect | Detail |
|--------|--------|
| **Threat** | The AI agent or workflow accesses data beyond its intended scope (e.g., reading secrets from worker clusters, accessing namespaces outside its assignment) |
| **Controls** | Triage agents are **read-only** by default (get, list, watch only). Agents use namespace-scoped RBAC (Role, not ClusterRole). Agent system prompts include hard constraints: `CRITICAL: always use exact namespace "X"`. AKS-MCP UAMI is scoped to specific worker clusters, not subscription-wide. Remediation agents require explicit `remediate=true` parameter. |
| **Detection** | K8s audit logs for cross-namespace access attempts, KAgent controller logs all A2A calls, PrometheusRule for anomalous agent activity |
| **Residual Risk** | **Low** — RBAC is the hard boundary. The LLM prompt constraints are defence-in-depth but not relied upon as sole control. UAMI scope is verified via `az role assignment list`. |

### 2.4 Enforced Exposure of Data

| Aspect | Detail |
|--------|--------|
| **Threat** | An attacker crafts K8s events or prompt injection to force the LLM to expose internal data in triage output (GitLab issues, Teams notifications) |
| **Controls** | Events contain only K8s API-standard fields (reason, message, pod name, namespace) — no user-controllable free-text beyond pod names. LLM output truncated to 4000 chars before external notification. Agent prompts instruct: never output secret values. Triage output goes to authenticated channels only (GitLab project, Teams channel). |
| **Detection** | LiteLLM logs all prompts/completions for post-hoc review, GitLab issues labelled `auto-generated` for audit filtering |
| **Residual Risk** | **Low** — The attack surface for prompt injection is narrow (K8s event message field). Even if an attacker can create pods with malicious names, the triage output goes only to internal, authenticated channels. |

### 2.5 Unlawful Creation, Collection, or Processing of Information

| Aspect | Detail |
|--------|--------|
| **Threat** | The platform collects or processes personal data or data subject to regulatory constraints without proper basis |
| **Controls** | No PII is collected. Data processed is purely operational: pod names, namespace names, event reasons, event messages. These contain no personal data. If Azure OpenAI is used, a Data Processing Agreement (DPA) is in place and customer data is not used for model training. On-prem LLM: data never leaves the cluster network. |
| **Detection** | Data classification review (Section 2 of Compliance Checklist), regular audit of what data reaches the LLM |
| **Residual Risk** | **Very Low** — The data domain is Kubernetes operational metadata. No mechanism exists for PII to enter the pipeline unless someone names a pod with personal data (which would be a separate policy violation). |

### 2.6 Records Retention Not in Line with Regulation

| Aspect | Detail |
|--------|--------|
| **Threat** | Triage data retained longer than permitted, or not retained long enough for audit |
| **Controls** | Defined retention policy: Argo workflow history 30 days (TTL), Loki logs 30 days hot / 90 days cold, GitLab issues indefinite, Event Hub 24 hours, dedup ConfigMap 24-hour TTL per key. Retention policy reviewed with data governance team. |
| **Detection** | Automated TTL enforcement (Argo, Loki), periodic audit of GitLab issue retention |
| **Residual Risk** | **Low** — GitLab issues are indefinite by design (operational record). All other data has automated TTL. No regulatory retention requirements apply to K8s operational metadata. |

### 2.7 Failure to Dispose of Data Adequately

| Aspect | Detail |
|--------|--------|
| **Threat** | Triage data persists in caches, logs, or LLM provider systems after expected disposal |
| **Controls** | Argo workflow TTL auto-deletes completed workflows. Loki retention enforced by storage policy. LiteLLM database logs follow same Loki retention. Azure OpenAI: 30-day abuse monitoring log only (Microsoft DPA). On-prem LLM: no persistence beyond request/response cycle. Pod cleanup CronJob removes stale workflow pods. |
| **Detection** | Monitoring of workflow count and pod count over time, Loki storage size dashboards |
| **Residual Risk** | **Low** — All components have automated disposal. The one area requiring manual attention is GitLab issues, which are intentionally retained as operational record. |

### 2.8 External Denial or Disruption of Service

| Aspect | Detail |
|--------|--------|
| **Threat** | An external attacker disrupts the triage pipeline (e.g., DoS on Event Hub, exhausting LLM quota) |
| **Controls** | **3-layer deduplication:** Alloy drops count>1 events + 10/s rate limit; Sensor rate limit 5/min; Script-based dedup with 24h TTL. LiteLLM per-key rate limits (`max_parallel_requests`). Argo workflow `activeDeadlineSeconds: 900`. Event Hub Standard tier has built-in throttling. |
| **Detection** | PrometheusRule for anomalous token usage (>100k tokens/hour), Alloy export failure alerts, EventBus readiness alerts |
| **Residual Risk** | **Low** — No external attack surface. Event Hub requires SAS tokens. The most likely disruption is Azure service outage, which degrades to no-triage (not data loss). |

### 2.9 Inability to Fulfil Requests for Information

| Aspect | Detail |
|--------|--------|
| **Threat** | Unable to provide audit trail when requested (e.g., "what did the agent do on worker cluster X at time Y?") |
| **Controls** | Complete audit chain: Argo workflow history (30 days), KAgent controller logs (all A2A calls), LiteLLM logs (all prompts/completions with model, tokens, duration), GitLab issues (permanent record), Logic App Run History in Azure Portal. |
| **Detection** | Grafana dashboards for pipeline activity, LogQL queries for specific triage events |
| **Residual Risk** | **Low** — Multiple overlapping audit sources. The 30-day window for detailed logs is the main constraint; beyond 30 days, GitLab issues provide the summary record. |

### 2.10 Internal Denial or Disruption of Service

| Aspect | Detail |
|--------|--------|
| **Threat** | An internal user (accidentally or intentionally) disrupts the pipeline — e.g., deletes sensors, misconfigures agents, scales down controllers |
| **Controls** | RBAC limits `kagent` and `argo-events` namespace access to `platform-team-admins`. Kyverno policy denies non-platform users from managing kagent CRDs. GitOps: all manifests in Git, changes require PR review. Emergency procedures documented for disabling individual sensors without affecting others. |
| **Detection** | K8s audit logs, Git commit history, PrometheusRule for missing components (EventBus replicas, controller pods) |
| **Residual Risk** | **Low** — A platform-team-admin could disrupt the pipeline, but changes are auditable and recoverable from Git. |

### 2.11 Accidental Exposure of Data by the Firm

| Aspect | Detail |
|--------|--------|
| **Threat** | Triage output accidentally sent to wrong channel, GitLab project made public, Teams webhook exposed |
| **Controls** | GitLab project access controlled by project-level permissions. Teams webhook URL stored as K8s Secret (not in code). Logic App webhook SAS token scoped to single trigger. LLM response truncated to 4000 chars. Secrets scanning in CI (detect-secrets baseline). |
| **Detection** | GitLab project access audit, detect-secrets CI scan on every PR |
| **Residual Risk** | **Low** — Triage output is operational metadata (pod names, event reasons, diagnoses). Even if accidentally exposed, it contains no secrets or PII. The reputational risk of exposing internal architecture is the primary concern, mitigated by access controls on all output channels. |

---

# 3. Black Box View

## System Boundary Diagram

```
                                    ┌─────────────────────────────────────────────────┐
                                    │            K8s Event Triage Platform             │
                                    │              (Management Cluster)                │
                                    │                                                 │
  INPUTS                            │                                                 │          OUTPUTS
  ──────                            │                                                 │          ───────
                                    │                                                 │
  ┌───────────────────┐  Kafka/TLS  │  ┌─────────────┐    ┌──────────┐               │  HTTPS    ┌──────────────────┐
  │ Worker Cluster 1  │────────────►│  │ EventSource │───►│ Workflow │──────────────────────────►│ GitLab (Issues)  │
  │ (K8s Warning      │  (SAS auth) │  │             │    │ Engine   │               │           └──────────────────┘
  │  Events via Alloy)│             │  └─────────────┘    │          │               │
  └───────────────────┘             │                     │  ┌─────┐ │               │  HTTPS    ┌──────────────────┐
                                    │                     │  │Agent│ │──────────────────────────►│ Teams (via Logic  │
  ┌───────────────────┐  Kafka/TLS  │                     │  │(LLM)│ │               │           │ App webhook)     │
  │ Worker Cluster 2  │────────────►│  ┌─────────────┐    │  └─────┘ │               │           └──────────────────┘
  │ (K8s Warning      │  (SAS auth) │  │ Azure Event │    │          │               │
  │  Events via Alloy)│             │  │ Hub         │    └──────────┘               │      
                                    │                           │                    │           
  ┌───────────────────┐             │                    ┌──────▼──────┐              │
  │ Worker Cluster N  │  Kafka/TLS  │                    │ AKS-MCP     │              │
  │ (K8s Warning      │────────────►│                    │ (UAMI cross-│              │
  │  Events via Alloy)│  (SAS auth) │                    │  cluster    │              │
  └───────────────────┘             │                    │  kubectl)   │              │
                                    │                    └─────────────┘              │
                                    └─────────────────────────────────────────────────┘
```

## Data Flow Summary

| # | From | To | Data | Transport | Authentication |
|---|------|----|------|-----------|---------------|
| 1 | Worker cluster (Alloy) | Azure Event Hub | K8s warning event metadata (reason, message, pod, namespace) | Kafka over TLS 1.2+ | SAS token (Send-only policy) |
| 2 | Azure Event Hub | Management cluster (EventSource) | K8s warning event metadata | Kafka over TLS 1.2+ | SAS token (Listen-only policy) |
| 3 | Sensor | Argo Workflow | Filtered event payload (namespace-specific) | In-cluster (EventBus/NATS) | K8s service account |
| 4 | Workflow | KAgent controller | A2A JSON-RPC request with event context | HTTP (ClusterIP, in-cluster) | None (network-level isolation) |
| 5 | KAgent | LiteLLM | LLM prompt (event metadata + system prompt) | HTTP (ClusterIP, in-cluster) | API key |
| 6 | LiteLLM | LLM provider | LLM prompt | HTTPS | Provider API key |
| 7 | KAgent (via AKS-MCP) | Worker cluster K8s API | kubectl read commands (get pods, describe, logs) | HTTPS | Azure AD token (UAMI via workload identity) |
| 8 | Workflow | GitLab API | Triage issue (title, description, labels) | HTTPS | Personal Access Token (api scope, single project) |
| 9 | Workflow | Logic App | Triage summary (JSON payload) | HTTPS | Webhook URL with SAS |
| 10 | Workflow | Telegram | Triage notification (text) | HTTPS | Bot token |

## Who Accesses the System?

| Actor | Access Method | What They Access | Purpose |
|-------|-------------|------------------|---------|
| Platform Engineers | `kubectl` via Azure AD (platform-team-admins group) | Management cluster: `kagent`, `argo-events`, `argo` namespaces | Deploy, configure, operate the pipeline |
| AI Agents (kagent) | A2A protocol (in-cluster) | KAgent controller, LiteLLM, worker cluster K8s API (via AKS-MCP) | Diagnose K8s events, read cluster state |
| Argo Workflows | K8s service account | Workflow execution, secret access (GitLab token, webhook URLs) | Orchestrate triage steps |
| Alloy (worker clusters) | Kafka/TLS | Azure Event Hub (write-only) | Forward K8s warning events |
| SRE / Operations | GitLab UI, Teams | Triage issues, notifications | Consume triage output, act on recommendations |

## Supporting Documentation

| Document | Location |
|----------|----------|
| Architecture Diagram (Excalidraw) | `kagent-triage/architecture-hybrid-triage.excalidraw` |
| Threat Model (STRIDE) | `kagent-triage/docs/SAD-THREAT-MODEL.md` |
| Logging, Monitoring, Auth | `kagent-triage/docs/SAD-LOGGING-MONITORING-AUTH.md` |
| LLM Governance | `kagent-triage/docs/SAD-LOGGING-MONITORING-LLM.md` |
| Compliance Checklist | `kagent-triage/docs/SAD-COMPLIANCE-CHECKLIST.md` |
| Secret Rotation Runbook | `kagent-triage/docs/SECRET-ROTATION-RUNBOOK.md` |
| Shared Cluster RBAC | `kagent-triage/docs/SHARED-CLUSTER-RBAC.md` |
| Worker Cluster Bundle | `kagent-triage/worker-cluster-bundle/README.md` |
| Sensor Safeguards | `kagent-triage/SENSOR-SAFEGUARDS.md` |

---

# 4. White Box View

## Functional Layer Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                    USER LAYER                                           │
│                                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────────┐ │
│  │ GitLab UI    │  │ Teams Channel│  │       Grafana Dashboards          
│  │ (Issues)     │  │ (Cards)      │  │      (Pipeline Health, LLM Usage) 
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                  │                 │                        │
         ▼                  ▼                 ▼                        ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                   ACCESS LAYER                                          │
│                                                                                         │
│  ┌────────────────────┐  ┌─────────────────────┐  ┌──────────────────────────────────┐ │
│  │ Azure AD / RBAC    │  │ Event Hub SAS Auth   │  │ K8s Service Account Auth         │ │
│  │ (platform-team-    │  │ (Send-only / Listen- │  │ (argo-events-sa, kagent SAs)     │ │
│  │  admins group)     │  │  only policies)      │  │                                  │ │
│  └────────────────────┘  └─────────────────────┘  └──────────────────────────────────┘ │
│                                                                                         │
│  ┌────────────────────┐  ┌─────────────────────┐  ┌──────────────────────────────────┐ │
│  │ Kyverno Admission  │  │ NetworkPolicy        │  │ Workload Identity (UAMI)         │ │
│  │ (CRD restriction)  │  │ (default-deny)       │  │ (cross-cluster AKS-MCP)          │ │
│  └────────────────────┘  └─────────────────────┘  └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                          │                              │
         ▼                          ▼                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                  SERVICE LAYER                                          │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────────────────────────────┐ │
│  │ Argo Events      │  │ Argo Workflows    │  │ kagent Controller                     │ │
│  │                  │  │                   │  │                                        │ │
│  │ - EventSource    │  │ - WorkflowTemplate│  │ - Agent CRDs                          │ │
│  │   (K8s event     │  │   (kagent-triage) │  │ - A2A protocol endpoint               │ │
│  │    watcher)      │  │ - DAG: find →     │  │ - Tool server (namespace-scoped       │ │
│  │ - Sensors        │  │   diagnose →      │  │   kubectl equivalents)                │ │
│  │   (ns-filtered,  │  │   notify          │  │ - ModelConfig (LLM routing)           │ │
│  │    rate-limited)  │  │ - Dedup logic     │  │                                       │ │
│  │ - EventBus (NATS)│  │                   │  │                                        │ │
│  └─────────────────┘  └──────────────────┘  └────────────────────────────────────────┘ │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────────────────────────────┐ │
│  │ LiteLLM Proxy    │  │ AKS-MCP           │  │ Notification Services                 │ │
│  │ (LLM gateway,    │  │ (UAMI-backed      │  │ (GitLab issue creation,               │ │
│  │  rate limiting,   │  │  cross-cluster    │  │  Logic App/Teams webhook,             │ │
│  │  token tracking)  │  │  kubectl)         │  │  Telegram bot API)                    │ │
│  └─────────────────┘  └──────────────────┘  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────┘
         │                          │                              │
         ▼                          ▼                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                                 RESOURCE LAYER                                          │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────────────────────────────┐ │
│  │ Azure Event Hub  │  │ K8s etcd           │  │ LLM Provider                          │ │
│  │ (event transport │  │ (secrets, configs, │  │ (Azure OpenAI or on-prem              │ │
│  │  Standard tier)  │  │  workflow state)   │  │  Ollama/vLLM)                         │ │
│  └─────────────────┘  └──────────────────┘  └────────────────────────────────────────┘ │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌────────────────────────────────────────┐ │
│  │ Azure Key Vault  │  │ Loki               │  │ GitLab (issue storage)                │ │
│  │ (secret source   │  │ (log aggregation   │  │                                        │ │
│  │  for ESO)        │  │  and retention)     │  │                                        │ │
│  └─────────────────┘  └──────────────────┘  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                        HORIZONTAL / MULTI-LAYER FUNCTIONS                               │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐  │
│  │ Logging (Loki)   │  │ Monitoring         │  │ Secret Mgmt      │  │ GitOps          │ │
│  │ All namespaces   │  │ (Prometheus +      │  │ (ESO + Azure     │  │ (Git repo +     │ │
│  │ forward to Loki  │  │  Grafana + alerts) │  │  Key Vault)      │  │  PR reviews)    │ │
│  └─────────────────┘  └──────────────────┘  └──────────────────┘  └────────────────┘  │
│                                                                                         │
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐                       │
│  │ Audit Trail      │  │ Deduplication      │  │ Pod Cleanup       │                    │
│  │ (K8s audit log,  │  │ (3-layer: Alloy,  │  │ (CronJob: stale  │                     │
│  │  Argo history,   │  │  Sensor rate,      │  │  workflow pod     │                    │
│  │  LiteLLM logs)   │  │  script 24h TTL)   │  │  removal)         │                   │
│  └─────────────────┘  └──────────────────┘  └──────────────────┘                       │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

## Layer Descriptions

### User Layer
The consumption tier where operations teams interact with triage output. **No direct access to the platform is required** — all output is pushed to existing tools (GitLab, Teams, Telegram). Grafana dashboards provide operational visibility for the platform team.

### Access Layer
All authentication, authorisation, and network isolation controls. Six mechanisms work in concert:
- **Azure AD RBAC** — Human access to the management cluster, scoped to `platform-team-admins` group.
- **Event Hub SAS** — Least-privilege policies per direction (Send-only for producers, Listen-only for consumers).
- **K8s Service Accounts** — Workflow and agent identity, scoped to minimum required RBAC verbs.
- **Kyverno Admission** — Belt-and-braces CRD restriction, denying non-platform users at the admission controller level.
- **NetworkPolicy** — Default-deny on `kagent` and `argo-events` namespaces. Only explicitly allowed traffic passes.
- **Workload Identity (UAMI)** — Cross-cluster access from management to worker clusters via Azure AD federated identity credentials, scoped per-cluster.

### Service Layer
The functional components that execute the triage pipeline:
- **Argo Events** — Event ingestion (EventSource), filtering and routing (Sensors), internal messaging (EventBus/NATS).
- **Argo Workflows** — Orchestration engine. The `kagent-triage` WorkflowTemplate runs a DAG: find agent -> call agent (A2A) -> create GitLab issue -> notify Teams/Telegram.
- **kagent Controller** — Manages AI agent lifecycle. Exposes A2A protocol endpoint. Runs namespace-scoped tool servers for safe kubectl-equivalent operations.
- **LiteLLM** — LLM proxy/gateway. Provides rate limiting, token tracking, model routing, and Prometheus metrics. Single point of control for all LLM access.
- **AKS-MCP** — Cross-cluster diagnostic tool. Uses UAMI + workload identity to execute read-only kubectl commands on worker clusters from the management cluster.
- **Notification Services** — Outbound integrations (GitLab API, Logic App webhook, Telegram bot API).

### Resource Layer
The data stores and external services that the service layer depends on:
- **Azure Event Hub** — Durable event transport between clusters (Standard tier, 24h retention).
- **K8s etcd** — Secrets, ConfigMaps (dedup cache), workflow state.
- **LLM Provider** — AI inference (Azure OpenAI with DPA, or on-prem for data sovereignty).
- **Azure Key Vault** — Source of truth for secrets, synced to K8s via External Secrets Operator.
- **Loki** — Centralised log aggregation (30d hot, 90d cold retention).
- **GitLab** — Persistent triage issue storage (indefinite retention).

### Horizontal / Multi-Layer Functions
Cross-cutting concerns that span all layers:
- **Logging** — All components forward structured logs to Loki. Key LogQL queries documented.
- **Monitoring** — Prometheus scrapes all components. PrometheusRules fire on failure rate, LLM errors, token anomalies, EventBus health.
- **Secret Management** — External Secrets Operator syncs from Azure Key Vault (1h refresh). Rotation runbook documented.
- **GitOps** — All manifests in Git. Changes require PR review. No `kubectl edit` outside emergencies.
- **Audit Trail** — Overlapping audit sources: Argo workflow history, KAgent controller logs, LiteLLM request logs, GitLab issue trail.
- **Deduplication** — 3-layer dedup prevents event storms: Alloy (count>1 drop + 10/s rate), Sensor (5/min rate limit), Script (24h TTL keyed dedup).
- **Pod Cleanup** — CronJob removes stale workflow pods to prevent resource exhaustion.

---

# 5. RBAC Model

## Overview

The platform uses a layered RBAC model across two cluster types (management and worker) with cross-cluster access mediated by Azure workload identity. The principle of least privilege is enforced at every layer.

## Management Cluster — Human Access

| Role | Identity | Scope | Permissions | Purpose |
|------|----------|-------|-------------|---------|
| Platform Admin | Azure AD group: `platform-team-admins` | Namespaces: `kagent`, `argo-events`, `argo` | Full admin (via RoleBinding to `admin` ClusterRole) | Deploy, configure, and operate the triage pipeline |
| Platform Admin | Azure AD group: `platform-team-admins` | Cluster-wide (kagent CRDs) | ClusterRole: `kagent-admin` — all verbs on Agent, ModelConfig, RemoteMCPServer, Tools | Manage kagent agent definitions |
| Non-platform users | Any other Azure AD identity | `kagent`, `argo-events` namespaces | **Denied** — Kyverno ClusterPolicy `restrict-kagent-crds` enforces at admission | Cannot create/modify kagent resources even if RBAC is misconfigured |

## Management Cluster — Service Accounts

| Service Account | Namespace | Role Type | Resources | Verbs | Justification |
|----------------|-----------|-----------|-----------|-------|---------------|
| `argo-events-sa` | `argo-events` | Role | workflows, workflowtemplates | create, get, list, watch | Sensors trigger workflows |
| `argo-events-sa` | `argo-events` | Role | workflowtaskresults | create, patch, get, list, watch | Workflow pod step execution |
| `argo-events-sa` | `argo-events` | ClusterRole | pods, pods/log, events | get, list, watch | Read-only diagnostics (triage) |
| `argo-events-sa` | `argo-events` | ClusterRole | configmaps | create, update | Dedup cache (ConfigMap-based memoization) |
| `aks-mcp` | `aks-mcp` | ClusterRole | pods, deployments, services, etc. | all verbs | Cross-cluster kubectl on management cluster itself |

## Worker Cluster — Service Accounts

| Service Account | Namespace | Role Type | Resources | Verbs | Justification |
|----------------|-----------|-----------|-----------|-------|---------------|
| `argo-events-sa` | `argo-events` | Role | workflows, workflowtemplates | create, get, list, watch | Sensors trigger local workflows |
| `argo-events-sa` | `argo-events` | Role | workflowtaskresults | create, patch, get, list, watch | Workflow pod step execution |
| kagent tool-server SA | `kagent` | ClusterRole (read-only) | pods, pods/log, events, deployments, services | get, list, watch | Local K8s diagnostics only |

## Cross-Cluster Access — AKS-MCP via Workload Identity

This is the critical access path where the management cluster's AI agents can read state from worker clusters.

```
Management Cluster                          Azure AD                         Worker Cluster
┌─────────────────────┐                     ┌──────────┐                    ┌─────────────────┐
│ kagent Agent         │                     │          │                    │                 │
│   ↓ A2A call         │                     │  UAMI    │                    │  K8s API Server │
│ AKS-MCP pod         │─── Workload ────────►│  Token   │────Azure RBAC───►│  (read-only)    │
│ (ServiceAccount:     │   Identity          │  Issuer  │   (per-cluster)   │                 │
│  aks-mcp, ns:aks-mcp)│   FIC bound to SA   │          │                    │                 │
└─────────────────────┘                     └──────────┘                    └─────────────────┘
```

| Component | Detail |
|-----------|--------|
| **Identity** | User Assigned Managed Identity (UAMI) in Azure |
| **Binding** | Federated Identity Credential (FIC) bound to `aks-mcp` ServiceAccount in `aks-mcp` namespace |
| **Scope** | Azure role assignments scoped to **specific AKS clusters** (not subscription-wide) |
| **Operations** | Read-only kubectl commands: `get`, `describe`, `logs` (triage). Write commands only for explicit remediation with `remediate=true`. |
| **Verification** | `az role assignment list --assignee <UAMI_CLIENT_ID>` — must show per-cluster scope |

### Why Workload Identity?

- No static credentials — tokens are short-lived and auto-rotated by Azure AD.
- Scope is enforced at the Azure RBAC level — even if the pod is compromised, it can only access the clusters explicitly assigned.
- Audit trail: All token issuances and API calls logged in Azure AD sign-in logs and K8s audit logs on the worker cluster.

## Agent-Level RBAC

Beyond K8s RBAC, each kagent agent has **logical access controls** enforced at the agent definition level:

| Agent Type | K8s RBAC | Agent Prompt Constraints | Tool Access |
|------------|----------|------------------------|-------------|
| Triage agents (default) | Read-only (get, list, watch) | `CRITICAL: always use exact namespace "X"`. Never fetch secret content. | `get_pods`, `get_events`, `describe_resource`, `get_logs` |
| Remediation agents | Read + limited write | Explicit `remediate=true` required. Never delete CRDs. Never restart all replicas. | Above + `patch_resource`, `scale_deployment` |

## Data Plane Roles & Entitlements Summary

| Entitlement | Who/What | How Granted | Scope | Audit |
|-------------|----------|-------------|-------|-------|
| Manage kagent CRDs | Platform-team-admins (Azure AD) | ClusterRole + Kyverno policy | Cluster-wide | K8s audit log |
| Deploy to kagent/argo-events | Platform-team-admins (Azure AD) | RoleBinding to admin | Namespace | K8s audit log |
| Execute triage workflows | argo-events-sa (K8s SA) | Role (workflow verbs) | argo-events namespace | Argo workflow history |
| Read worker cluster state | AKS-MCP pod (UAMI) | Azure RBAC (per-cluster) | Specific AKS clusters | Azure AD sign-in + K8s audit |
| Write to Event Hub | Alloy (worker cluster) | SAS token (Send-only) | Specific Event Hub topic | Event Hub access logs |
| Read from Event Hub | EventSource (management) | SAS token (Listen-only) | Specific Event Hub topic | Event Hub access logs |
| Call LLM | KAgent agent pods | LiteLLM API key | Per-key rate limited | LiteLLM request logs |
| Create GitLab issues | Workflow pod | GitLab PAT (api scope) | Single project | GitLab audit log |
| Send Teams notifications | Workflow pod | Logic App webhook SAS | Single Logic App trigger | Logic App Run History |

---

# Appendix A: Document Cross-References

| CDA Section | Supporting Document | Location |
|-------------|-------------------|----------|
| Threat Scenarios | STRIDE Threat Model | `kagent-triage/docs/SAD-THREAT-MODEL.md` |
| Threat Scenarios | Compliance Checklist | `kagent-triage/docs/SAD-COMPLIANCE-CHECKLIST.md` |
| Black Box View | Architecture Diagram | `kagent-triage/architecture-hybrid-triage.excalidraw` |
| White Box View | Logging, Monitoring, Auth | `kagent-triage/docs/SAD-LOGGING-MONITORING-AUTH.md` |
| White Box View | LLM Governance | `kagent-triage/docs/SAD-LOGGING-MONITORING-LLM.md` |
| RBAC Model | Shared Cluster RBAC | `kagent-triage/docs/SHARED-CLUSTER-RBAC.md` |
| RBAC Model | Secret Rotation Runbook | `kagent-triage/docs/SECRET-ROTATION-RUNBOOK.md` |
| All | Worker Cluster Deployment Bundle | `kagent-triage/worker-cluster-bundle/README.md` |

# Appendix B: Glossary

| Term | Definition |
|------|-----------|
| **kagent** | CNCF Sandbox project for AI-powered Kubernetes agents. Provides Agent CRDs and A2A protocol. |
| **A2A** | Agent-to-Agent protocol. JSON-RPC over HTTP for inter-agent communication. |
| **AKS-MCP** | Azure Kubernetes Service Model Context Protocol tool. Enables cross-cluster kubectl via UAMI. |
| **UAMI** | User Assigned Managed Identity. Azure AD identity attached to pods via workload identity. |
| **FIC** | Federated Identity Credential. Binds a UAMI to a specific K8s service account. |
| **LiteLLM** | LLM proxy/gateway that provides rate limiting, token tracking, and model routing. |
| **ESO** | External Secrets Operator. Syncs secrets from Azure Key Vault to K8s Secrets. |
| **SAS** | Shared Access Signature. Azure token-based authentication for Event Hub. |
| **STRIDE** | Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege. |
