# Statement of Work
## Platform Engineering Modernisation
### GitOps-First Delivery · Fleet Automation · AI-Driven SRE
**Version:** 0.2 (Draft for Review)
**Duration:** 6 Months
**Team Size:** 5–6 Engineers

---

## 1. Executive Summary

The organisation operates a fleet of Kubernetes clusters provisioned manually and updated one-at-a-time through a combination of GitLab push pipelines and Azure DevOps pipelines. As the fleet grows to hundreds of clusters, this model becomes untenable. Namespace onboarding is slow and opaque; there is no real-time visibility into whether a namespace is live.

This engagement eliminates that approach entirely. GitLab pipelines are removed from the delivery path. Flux CD becomes the single reconciliation plane across all clusters. Namespace onboarding and cluster provisioning are driven by Git PRs and automated via Argo Workflows and ASO. Fleet updates are delivered in progressive waves rather than one cluster at a time. Because every cluster is fully defined in Git, a cluster that goes down is rebuilt automatically by ASO — teams onboard to dev clusters following portable patterns so they can transition between clusters without disruption. AI-driven SRE automation (kagent) reduces manual triage toil, and the kagent platform is opened to the wider business so any team can run agents on shared orchestration infrastructure.

Existing application workloads remain in place on their current clusters. ASO adopts the ARM-template-deployed clusters as-is — taking ownership of the underlying Azure resources without recreating them — so the transition is non-disruptive to running applications. Cluster recreate-from-Git applies to *new* clusters and disaster-recovery scenarios, not to the migration itself.

The PoC groundwork for all of these capabilities already exists in this repository and is ready to be hardened and delivered into production.

---

## 2. Current State & Problems

| Area | Current State | Problem |
|---|---|---|
| Infrastructure delivery | GitLab CI push pipelines | Slow, fragile, no drift detection, no rollback |
| Namespace onboarding | ADO pipeline | Cumbersome, no live status, manual steps |
| Cluster provisioning | Manual / scripted | Inconsistent, hard to audit, not reproducible |
| Fleet updates | One cluster per day | Unscalable — hundreds of clusters will take months |
| Dev cluster resilience | Single cluster, manual recovery | Teams blocked; no portable onboarding patterns; rebuild takes days |
| SRE triage | Manual investigation | High toil, slow MTTR, on-call fatigue |

---

## 3. Target State

```
Git Repository  (single source of truth)
       │
       │  PR raised → CI validates only (lint, scan, policy check)
       │  PR merged
       ▼
Flux CD  (management + worker clusters)
  ├── Infra layer      KRO + ASO → AKS cluster lifecycle
  ├── Platform layer   Argo Workflows, Argo Events, kagent, agentgateway
  ├── App layer        Application workloads, BYO-kagent agents
  └── Namespace layer  Quotas, network policies, RBAC (auto-reconciled)
       │
       │  Self-service namespace request (PR or web form)
       ▼
Argo Workflows  (orchestration plane)
  ├── Namespace onboarding workflow  → creates NS, quota, netpol → commits to Git
  ├── Cluster provisioning workflow  → KRO instance → ASO → AKS cluster
  ├── Fleet update pipeline          → progressive wave delivery across cluster rings
  └── SRE triage pipeline            → K8s event → kagent → diagnosis / remediation
       │
       ▼
kagent  (AI SRE layer)
  ├── sre-triage-agent     read-only root cause analysis
  ├── sre-remediation-agent  safe automated fixes with HITL gate
  └── network-insights-agent  AKS network diagnostics
```

**Fleet update model — clusters as cattle:**

```
Ring 0 (canary)  →  Ring 1 (dev clusters)  →  Ring 2 (staging)  →  Ring 3 (production)
   1 cluster            ~10% of fleet              ~30%                  remainder
   auto-promote          health gate              health gate         health gate + approval
```

---

## 4. Prior Art in This Repository

The following PoCs have been built and validated. This engagement productionises them.

| Component | Location | Status | What it proves |
|---|---|---|---|
| KRO UK8S cluster provisioning | `infra-stack/kro-stack/` | Working PoC | Full AKS cluster lifecycle declaratively via KRO + ASO |
| Flux GitOps stack | `infra-stack/kro-stack/definitions/` | Working PoC | Flux bootstrapped from KRO at cluster create time |
| Argo Workflows namespace onboarding | `application-stack/core/argo-workflows/` | Working PoC | Self-service NS + quota + netpol via workflow |
| Workload identity automation | `infra-stack/workload-identity/` | Working PoC | OIDC discovery CronJob + ASO FederatedIdentityCredentials |
| K8s event triage pipeline | `aks-mgmt-stack/k8s-event-triage/` | Working PoC | Warning events → kagent AI investigation → GitLab issue + notification |
| kagent SRE agents | `kagent-triage/` | Working PoC | A2A-based triage/remediation routing per namespace |
| agentgateway (AI gateway) | `ai-platform/agentgateway/` | Near-production | LLM + MCP + A2A routing, UAMI token refresh, zero-downtime rotation |
| BYO-kagent platform | `infra-stack/byo-kagent/` | Working PoC | Self-service agent onboarding with Kyverno admission enforcement |
| AKS-MCP server | `aks-mcp/` | Production tool | AI assistants + kubectl/az access via MCP |
| Kyverno policy library | `infra-stack/kyverno-policies/` | Working PoC | Admission enforcement for agents, tools, namespaces |
| Teams HITL approval gate | `ai-platform/teams-hitl/` | Working PoC | Human-in-the-loop for destructive remediation via Teams |
| ASO cluster-agent demo | `aks-mgmt-stack/aso-cluster-agent-demo/` | Working PoC | KAgent agent + Argo Workflow + KRO/ASO chain — user requests cluster in chat, agent extracts typed params, workflow provisions, cert workflow auto-fires `sre-triage-agent` for health verdict |

---

## 5. Scope of Work

---

### Workstream 1 — Eliminate GitLab Pipelines; Flux Becomes the Delivery Plane

**Objective:** Remove GitLab CD pipelines entirely. GitLab retains CI (lint, validate, security scan, policy check). Flux CD owns all delivery — reconciling Git state to clusters continuously, detecting and correcting drift, without human intervention.

**What changes:**
- All `kubectl apply`, `helm upgrade`, and `kustomize build | kubectl` steps are removed from GitLab pipelines
- Flux `GitRepository` + `Kustomization` resources replace pipeline-based deployments for every layer
- GitLab MR merge = delivery event; no pipeline step required to apply
- Drift detection enabled cluster-wide — divergence from Git triggers alert and auto-reconcile

**Deliverables:**
- Flux installed and managing the management cluster and all worker clusters (bootstrapped via KRO at cluster creation)
- GitLab CI pipelines refactored: validate, lint, policy check only — no apply steps
- Git repository structure formalised: `infra/`, `platform/`, `apps/`, `namespaces/` as separate Flux sync roots with dependency ordering
- Drift detection alerts wired to notification channel (Teams / Mattermost)
- Migration guide: how to convert existing pipeline-managed resources to Flux-managed GitOps

---

### Workstream 2 — Namespace Onboarding: ADO Pipeline → GitOps + Argo Workflows

**Objective:** Replace the ADO namespace onboarding pipeline with a self-service, Git-native flow backed by Argo Workflows and ASO. Engineers raise a PR (or submit a form); the workflow provisions the namespace end-to-end and reports live status. The resulting configuration is committed to Git so Flux manages it permanently.

**Flow:**

```
Engineer raises PR (namespace request YAML)
  → GitLab CI validates schema + Kyverno policy
  → PR merged
  → Argo EventSource detects merge
  → namespace-onboarding-template workflow triggers
       ├── Parse request payload
       ├── Create namespace on target AKS cluster (via ASO)
       ├── Apply ResourceQuota + LimitRange
       ├── Apply NetworkPolicy (default deny + explicit allows)
       ├── Apply RBAC (namespace admin binding for requesting team)
       ├── Commit namespace config to GitOps repo (Flux picks up and reconciles)
       └── Notify requestor: namespace is live, link to Argo UI run
```

**Deliverables:**
- Production `namespace-onboarding-template` Argo WorkflowTemplate (multi-cluster capable)
- PR template / web form for namespace requests (schema-validated)
- Argo Events integration: GitLab merge event → workflow trigger
- Real-time status visibility in Argo Workflows UI
- Teams / Mattermost notification on completion or failure with direct link
- Multi-cluster support: single workflow handles any registered target AKS cluster
- RBAC: least-privilege service account for provisioner workflow

---

### Workstream 3 — Fleet Management: Treat Clusters as Cattle

**Objective:** Move from updating one cluster per day to automated progressive delivery across the entire cluster fleet. Clusters are ephemeral and declarative — if a cluster is unhealthy, it is rebuilt from Git, not manually repaired. Fleet updates roll through rings with automated health gates.

**Progressive delivery model:**

```
Ring 0 — Canary     1 representative cluster, auto-promote after health gate (15 min)
Ring 1 — Dev        ~10% of fleet, auto-promote after health gate (1 hour)
Ring 2 — Staging    ~30% of fleet, auto-promote after health gate (4 hours)
Ring 3 — Production remainder, requires explicit approval gate (Teams HITL)
```

**Migration approach — adoption, not rebuild:**
Existing ARM-template-deployed clusters are adopted by ASO in place via the standard adoption pattern (manifest matches live state, `serviceoperator.azure.com/reconcile-policy: skip` initially, then promoted to full reconciliation after drift review). No workload migration; no cluster recreation. Recreate-from-Git applies to *new* clusters and DR scenarios only.

**Deliverables:**
- Cluster ring assignments defined in Flux `HelmRelease` / `Kustomization` substituion labels
- Automated promotion controller (Argo Workflow or Flux progressive delivery): promotes to next ring when health gate passes
- Health gate definition: pod restart rate, failed deployments, Prometheus alert firing on ring
- KRO-based cluster lifecycle: create, update, and delete AKS clusters via PR to `infra-stack/kro-stack/instances/` — no manual `az` commands
- `uk8scluster-public` RGD as the mandatory provisioning template (security defaults: local accounts disabled, Azure RBAC, Defender, standard tagging)
- ASO adoption runbook + per-cluster adoption manifests for the existing fleet; rollout sequenced cluster-by-cluster with reconcile-policy gating
- Cluster decommission workflow: drains workloads, deletes ASO resources, removes from Flux — triggered by deleting the KRO instance manifest from Git

**Agent co-pilot for cluster lifecycle (phased, non-blocking deliverable):**

The PoC at `aks-mgmt-stack/aso-cluster-agent-demo/` proves an interactive, agent-driven front door for cluster provisioning. This is hardened and rolled out alongside the deterministic PR-driven flow — both paths reach the same Argo Workflow, so the agent is additive, not on the critical path. If timeline pressure surfaces, agent rollout slides to Phase 4 without affecting Phases 1–3.

- **Interactive provisioning:** Engineers describe a cluster need in chat to the `aso-cluster-provisioner` agent; agent extracts typed params (name/region/size/SKU), validates against regex/enum, confirms with an explicit `yes, provision` gate, then submits an Argo Workflow. Agent never generates YAML — workflow renders manifests from a Secret holding platform defaults
- **Backend due-diligence:** Workflow validates inputs, checks platform-defaults ConfigMaps/Secrets are present and well-formed (subscription, VNet, identity IDs, SSH key, Flux URLs), renders the `UK8SClusterPublic` instance, applies via KRO + ASO, waits for `ACTIVE+Ready`, then chains the `UK8SCertificationV2` instance
- **Closed-loop health feedback:** Cert workflow runs the `sre-triage-agent` post-deploy; verdict (pass / warn / fail with reasons) flows back to the requesting user in the same chat thread and posts to Teams. Live status published to `provision-status-<workflow>` ConfigMap so the agent can answer "how's it going?" without re-reading workflow internals
- **Dry-run by default:** `DRY_RUN_DEFAULT=true` annotation prevents accidental Azure spend on dev/demo clusters; flipped to `false` per-environment via PR
- **RBAC split:** Agent SA can only submit Workflows; workflow-executor SA holds the KRO/ASO create permissions — agent cannot create Azure resources directly
- **Same pattern reused** for namespace onboarding (WS2), fleet ring promotions (this WS), and decommission — agent surfaces an interactive front door, workflow does the deterministic work

---

### Workstream 4 — Platform Resilience: Cluster-Portable Teams, Fast Recovery

**Objective:** Ensure application teams can transition seamlessly between clusters — and that when a dev cluster goes down, recovery is fast and automatic because everything is in Git. Teams should never be tied to a single cluster. In production, HA failover is already in place; this workstream focuses on making the development tier equally resilient through good patterns, not heroics.

**Pattern A — Cluster-portable onboarding:**
- All namespace configs (quota, netpol, RBAC, workload identity) are stored in Git and applied via Flux — not imperatively configured on a specific cluster
- Teams onboard to dev clusters using the same PR-driven namespace onboarding flow as staging and production
- Cluster assignment is a label, not a dependency — moving a team from one dev cluster to another is a one-line change in Git, not a migration project
- Runbooks and tooling assume multi-cluster from day one; no single-cluster shortcuts

**Pattern B — ASO-driven fast cluster recovery (new + DR scenarios):**
- Applies to *new* clusters provisioned under KRO + ASO and to disaster-recovery rebuilds — not to in-place adoption of the existing fleet
- Because every new cluster is defined in Git (KRO instance + Flux bootstrap), a cluster that goes down can be recreated by ASO without manual intervention
- Target RTO: cluster recreated and workloads reconciled in < 30 minutes from deletion
- Flux `OCIRepository` mirrors Helm charts and OCI images to a management-cluster registry — worker clusters reconcile from local cache and are not blocked by external registry outages
- ASO watches desired state; if a cluster is deleted or becomes unreachable, the KRO instance triggers rebuild automatically

**Pattern C — Graceful degradation for AI tooling:**
- agentgateway failover: primary LLM provider → secondary provider (e.g. Azure OpenAI → KubeAI local model) if upstream is unreachable
- kagent agents degrade gracefully: if the AI pipeline is unavailable, Argo Workflows emit a structured diagnostic payload to Teams rather than timing out silently

**Deliverables:**
- Cluster-portability pattern documented and enforced: namespace configs must be cluster-agnostic (Flux postBuild substitution for cluster-specific values)
- Dev cluster RTO < 30 min tested and documented (chaos test: delete cluster, measure rebuild via ASO + KRO)
- Flux OCI image cache configured on management cluster
- Dev cluster ring (Ring 1) distributed across ≥2 clusters so teams are redirected automatically during rebuild
- agentgateway failover config: primary + fallback LLM backend routing

---

### Workstream 5 — AI-Driven SRE: kagent + agentgateway

**Objective:** Deploy the AI SRE layer into production — kagent agents for triage and remediation, agentgateway as the unified AI gateway replacing LiteLLM, and the K8s event triage pipeline routing alerts to the right agents.

**Sub-components:**

#### 5a — agentgateway (AI Gateway)
Replace LiteLLM with agentgateway for unified LLM + MCP + A2A routing.
- Deploy agentgateway on management cluster behind Istio wildcard ingress
- Provider routing: Azure OpenAI (UAMI), KubeAI (local), vLLM/Qwen
- UAMI token refresh CronJob: zero-downtime secret rotation (proven in PoC)
- Per-team ModelConfig for cost attribution and usage monitoring

#### 5b — kagent SRE Agents
- `sre-triage-agent`: read-only root cause analysis via AKS-MCP + native k8s tools
- `sre-remediation-agent`: safe automated fixes (pod restart, image rollback, config rollback) with Teams HITL gate for destructive actions
- `network-insights-agent`: AKS network diagnostics (Phase 1 interactive, Phase 2 automated)
- Per-namespace agent routing: events from a namespace routed to that namespace's registered agent

#### 5c — K8s Event Triage Pipeline
```
K8s Warning Event (source cluster)
  → Grafana Alloy → Azure Event Hub
  → Argo Events EventSource → Sensor → Router Workflow
  → kagent triage agent (A2A: POST /api/a2a/kagent/{agent-name}/)
  → structured diagnosis
  → GitLab issue + Teams notification
  → if actionable: human approval → remediation agent
```

**Deliverables:**
- agentgateway deployed, all provider routes validated, monitoring dashboards live
- Three production kagent agents: triage, remediation, network
- K8s event triage pipeline end-to-end on management cluster
- Teams HITL approval workflow for remediation actions
- Agent decision audit log (structured JSON → Loki)
- Prometheus metrics: triage volume, agent latency, automation rate, MTTR delta

---

### Workstream 6 — Enterprise Agent Platform: kagent for the Business

**Objective:** Open the kagent orchestration platform to the wider business. Any team should be able to run agents on the platform — whether for SRE automation, developer tooling, data workflows, or business process automation — without building their own infrastructure. The platform handles routing, authentication, tool access, cost attribution, and policy enforcement. Teams bring their use case; the platform provides the runtime.

**Architecture options (to be decided during Phase 1):**

```
Option A — Dedicated Agent Cluster
  A single AKS cluster provisioned specifically to host agent workloads.
  Teams deploy Agent CRs into their allocated namespace.
  Agents connect to tools (AKS-MCP, GitLab-MCP, custom MCPs) via agentgateway.
  Isolated from application workloads; dedicated compute for AI inference.

Option B — Agent Namespaces on Management Cluster
  Agent workloads run in isolated namespaces on the existing management cluster.
  Lower operational overhead; suitable if agent density is moderate.
  Same security model (Kyverno, ToolGrants, RBAC) regardless of option chosen.
```

**Platform capabilities delivered:**

- **Self-service onboarding:** Teams request agents via Git PR — `byo-kagent-orchestrator` reviews the PR, validates against policy, posts feedback in GitLab MR, and approves merge when ready
- **Tool catalog:** Curated, verified MCP tools available to agents (`AKS-MCP`, `GitLab-MCP`, `kyverno-cli-MCP`, `yaml-lint-MCP`). New tools go through the MCP quarantine → verification → promotion pipeline before entering the catalog
- **Policy enforcement at admission:** Kyverno ClusterPolicies enforce that every agent declares its tools (`ToolGrant` CRs) and model (`ModelConfig`) before running — no agent runs without explicit authorisation
- **A2A interoperability:** Agents across teams can collaborate via the A2A protocol — a developer agent can hand off a triage task to an SRE agent without custom integration
- **Cost attribution:** Per-team `ModelConfig` routes LLM calls through agentgateway with usage tracked per team / cost centre
- **Audit trail:** All agent decisions, tool calls, and model interactions logged to Loki with structured JSON

**Deliverables:**
- Architecture decision: dedicated agent cluster vs. management cluster namespaces (with cost/isolation trade-off analysis)
- Agent cluster or namespace structure provisioned via GitOps (KRO instance if dedicated cluster)
- BYO-kagent platform: `ToolCatalogEntry` + `ToolGrant` CRDs, 6 Kyverno ClusterPolicies deployed
- `byo-kagent-orchestrator` agent live, reviewing team PRs end-to-end
- MCP tool quarantine pipeline: `mcp-onboarding-template` workflow for new tool onboarding
- Agent platform runbook: how any team in the business requests an agent, what tools are available, how to escalate for new tool types
- Pilot: 3–5 teams from different business areas onboarded with real use-case agents during the engagement

---

## 6. Team Structure

| Role | Count | Primary workstreams |
|---|---|---|
| Tech Lead / Architect | 1 | All — architecture decisions, stakeholder reporting, cross-workstream alignment |
| Platform Engineer — GitOps & Flux | 1 | WS1: GitLab pipeline removal, Flux rollout, repo structure |
| Platform Engineer — Argo Workflows & Namespace | 2 | WS2: Namespace onboarding; WS3: Fleet progressive delivery |
| Platform Engineer — AI Platform | 1 | WS5: kagent, agentgateway, event triage pipeline |
| Platform Engineer — Resilience & Agent Platform | 1 | WS4: Cluster portability + fast recovery; WS6: Enterprise agent platform |

---

## 7. Delivery Phases (6 Months)

| Phase | Months | Workstreams | Key Milestones |
|---|---|---|---|
| **Phase 1 — Foundation** | 1–2 | WS1, WS5a | GitLab CD pipelines removed; Flux owns delivery; agentgateway live |
| **Phase 2 — Automation** | 2–4 | WS2, WS3 | Namespace onboarding live; ASO adoption of existing fleet complete; first fleet ring delivery pipeline |
| **Phase 3 — Resilience & AI** | 3–5 | WS4, WS5b/c, WS3 agent co-pilot | Dev cluster RTO < 30 min chaos-tested; kagent SRE pipeline end-to-end; agent-driven cluster provisioning hardened from PoC |
| **Phase 4 — Agent Platform & Handover** | 5–6 | WS6, all | Enterprise agent platform live; 3–5 business teams onboarded; agent co-pilot rolled out to engineering teams; runbooks; training |

Phases overlap — Argo Workflows development starts in month 2 while Flux rollout is completing.

---

## 8. Success Criteria

| Metric | Baseline | Target |
|---|---|---|
| Namespace provisioning time | > 30 min (ADO) | < 5 min end-to-end |
| GitLab CD pipeline runs | Many per day | Zero — all delivery via Flux |
| Fleet update throughput | ~1 cluster/day | Full ring delivery in < 4 hours |
| Dev cluster RTO | Days (manual rebuild) | < 30 minutes via ASO + KRO GitOps rebuild |
| SRE triage automation rate | 0% | > 60% of common alert types |
| Mean Time to Diagnose (MTTD) | > 30 min manual | < 5 min for supported alert types |
| Provisioning visibility | None | 100% trackable in Argo Workflows UI |
| Cluster drift incidents | Unknown | Detected within 5 minutes, auto-remediated |
| Agent-driven cluster provisioning latency | n/a (manual ARM) | < 15 min chat-to-cert-verdict for small cluster (phased deliverable) |
| Existing-fleet ASO adoption | 0% | 100% adopted in place, no workload disruption |

---

## 9. Assumptions & Dependencies

- GitLab remains the code hosting and MR platform; CI stays; CD pipelines are removed as part of this engagement
- All AKS clusters run in Azure; ASO and KRO are installed or will be deployed on the management cluster
- Argo Workflows v3.x and Argo Events are deployed on the management cluster
- kagent v0.7+ is available; LLM endpoint (Azure OpenAI / KubeAI) is accessible from the management cluster
- Teams webhook access available for HITL and notifications
- Engineers have read/write access to the GitOps configuration repository
- Azure subscription with sufficient quota for ASO-provisioned resources
- Existing ARM-template-deployed AKS clusters remain in place and are adopted by ASO; no cluster recreation or application workload migration is required to complete this engagement
- KAgent v0.7+ and the `aso-cluster-agent-demo` PoC are the baseline for the agent co-pilot — productionisation, not green-field development

---

## 10. Out of Scope

- Refactoring, replatforming, or rewriting of existing application workloads or their deployment manifests — apps continue to run unchanged on the adopted clusters
- Rebuilding or recreating existing AKS clusters — ASO adopts them in place
- Non-Azure cloud providers
- End-user application code changes
- Backstage or developer portal UI (infrastructure only; UI integration is a future phase)
- LLM fine-tuning or model training

---

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GitLab pipeline removal disrupts active deliveries | Medium | High | Phased migration; pipelines coexist until Flux reconciliation is proven for each resource |
| ASO silently provisions Azure resources (cost exposure) | Medium | High | All KRO instances require PR + approval gate; ASO RBAC restricts who can create resources |
| Progressive delivery promotes a bad build to production | Low | High | Health gates are mandatory; production ring requires explicit Teams approval |
| kagent LLM quality insufficient for remediation decisions | Medium | Medium | Triage is always safe (read-only); remediation requires HITL approval; agents fail gracefully |
| Fleet ring delivery reveals unexpected inter-cluster dependencies | Medium | Medium | Ring 0 canary surfaces this early; post-ring-0 review gate before broader rollout |
| BYO-kagent scope creep (teams request many new tools) | High | Low | Tool catalog is curated; new tools go through the MCP quarantine pipeline, not ad-hoc |
| ASO adoption of existing cluster diverges from live ARM-deployed state | Medium | Medium | Adopt with `reconcile-policy: skip` first; review drift report before promoting to full reconciliation; per-cluster rollout |
| Agent extracts wrong cluster params from natural language | Medium | Low | Strict regex/enum validation in workflow; explicit `yes, provision` confirmation gate; dry-run default; agent never generates YAML |
| Agent co-pilot rollout delays core delivery | Medium | Low | WS3 agent co-pilot is explicitly phased and non-blocking — the deterministic PR-driven path ships independently in Phase 2; agent productionisation slides to Phase 3 or 4 if pressured |
