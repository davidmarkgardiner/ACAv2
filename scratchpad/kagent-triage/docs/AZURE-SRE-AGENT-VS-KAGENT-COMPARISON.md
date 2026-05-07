# Azure SRE Agent vs. kagent + Argo Workflows

A side-by-side evaluation of Microsoft's [Azure SRE Agent](https://github.com/microsoft/sre-agent)
and the in-house **kagent + Argo Workflows + AKS-MCP + LGTM** SRE platform,
plus guidance on when a hybrid of both makes sense.

> **Environment notes for this comparison.** The internal estate (a) has **no
> GitHub access at work** — code lives in GitLab, so Azure SRE Agent's
> headline "GitHub deep-context RCA" advantage does not apply here; (b) uses
> the **LGTM stack** (Loki, Grafana, Tempo, Mimir) for logs / metrics / traces /
> events; (c) standardises on **kagent native agents** for triage and
> remediation — HolmesGPT is **not** in the chosen stack.

| | |
|---|---|
| Author | David Gardiner |
| Date | 2026-05-07 |
| Status | For internal review |
| Scope | High-level architectural comparison and hybrid adoption guidance |

---

## 1. TL;DR

- **Azure SRE Agent** is a fully managed, GA-since-March-2026 SaaS agent that ships
  with deep Azure + GitHub integration, persistent memory, and enterprise governance
  primitives. It is fast to adopt and stable, **scoped primarily to Azure resources
  (AKS and Container Apps emphasis in public material; non-Azure cluster support is
  not advertised)**, billed on token-based "Anthropic Usage Units" (AAU) plus a
  4-AAU/agent/hour always-on charge, and tied to the Azure runtime. **The
  GitHub-deep-context advantage does not apply in our environment** because we do
  not have GitHub at work — code lives in GitLab.
- **The in-house kagent stack** is a self-hosted, multi-cluster, multi-LLM agent
  platform built around open standards (A2A, MCP, Argo Workflows, Argo Events,
  LGTM). It has a narrower out-of-box feature set, but **persistent memory is
  already addressable via the kagent `Memory` CRD** (Pinecone today, pgvector
  preferred internally), and the stack is **portable, cheap at fleet scale,
  multi-cluster by design, and extensible into non-SRE flows** (namespace
  onboarding, dev pipelines, app onboarding template factory).
- **Generic industry advice is "hybrid"; our specific recommendation is
  kagent-as-default, Azure SRE Agent only as a narrow specialist.** GitHub
  deep-context RCA — the managed product's headline benefit — does not apply
  here because code is on GitLab, and persistent memory (the next-biggest
  managed-side win) is already addressable today via the kagent `Memory` CRD
  (Pinecone or pgvector). See Section 7.

---

## 2. Side-by-side comparison

### 2.1 Skills / capabilities

| Capability | Azure SRE Agent | kagent stack |
|---|---|---|
| Triage | Alert correlation, alert merging, incident-handler subagent | `sre-triage-agent` (kagent native), ~55s ImagePullBackOff diagnosis |
| Remediation | Auto-fix Azure resources, restart, scale, credential rotation | `sre-remediation-agent` (kagent native, ~2 min via A2A from triage) |
| RCA with code context | GitHub OAuth, deep code search baked in | **Not applicable in our environment** — no GitHub access; GitLab token wired and a GitLab MCP / repo-search tool can be added to kagent if/when needed |
| Logs / metrics / traces | Native Log Analytics + App Insights MCP, KQL | **LGTM stack** (Loki for logs, Mimir for metrics, Tempo for traces, Grafana for UI / events) — agent reads via Loki / Mimir MCP or query tool |
| Custom Python | Code interpreter built in | `script` step in Argo Workflows |
| Governance | Stop hooks, PostToolUse hooks, approval gates as product | Build approvals yourself (Teams HITL design in flight) |
| Scheduled / proactive | Scheduled tasks, Terraform drift detection | Argo CronWorkflows + Argo Events (richer primitive) |

**Verdict:** Azure SRE Agent has a wider day-one menu. The kagent stack is narrower
out of the box but each component is more composable into bespoke workflows.

### 2.2 Context

- **Azure SRE Agent** ships with persistent memory across investigations, "Deep Context"
  (continuous repo + incident history), and background intelligence that runs without a
  human prompt. The guided onboarding flow connects code, logs, incidents, resources,
  and knowledge files in one pass. Note: the "code context" half of Deep Context
  is GitHub-only and **does not apply in our environment**.
- **kagent stack** has two memory paths, both available today:
  - **Native memory** — Postgres + pgvector (or SQLite + Turso), configured inline
    on the agent (`spec.declarative.memory`) with auto-extraction every 5 turns.
    This is the internally-preferred path: "one Postgres for HA + memory + lessons"
    (see `ai-platform/agentgateway/`).
  - **External memory** — kagent ships a separate `kagent.dev/Memory` v1alpha1 CRD;
    **Pinecone is the supported external provider today**. Configure
    `spec.provider: Pinecone` + index host + topK / scoreThreshold and reference
    it from the agent's `spec.memory: [<name>]`. Native and external memory can
    co-exist on the same agent.

**Net effect:** the persistent-memory gap that earlier drafts called out is
**largely closeable with kagent CRDs already shipped** — the work is integration
and indexing strategy, not building a memory substrate from scratch. The
remaining gap vs Azure SRE Agent is the **investigation-to-investigation
"learning" loop** (Microsoft's auto-summarisation across cases), which still
needs explicit design here.

### 2.3 Maturity

| | Azure SRE Agent | kagent stack |
|---|---|---|
| Status | GA (March 2026) | kagent v0.8.0-beta4, AKS-MCP v0.0.12 |
| Reference scale | 1,300+ internal MS deployments, 35K+ incidents, Ecolab GA customer | Internal pilot, single-team validation; kagent native triage / remediation agents proven on test scenarios |
| Stability gotchas | Few public ones | kagent Session API broken (auth bug); use A2A. Longhorn PVC unreliable; use local-path. Qwen 14B hallucinates namespaces without explicit "copy this string" prompts |

**Verdict:** Microsoft wins on stability and polish today. The in-house stack wins
on velocity-of-change and freedom from Microsoft's release cadence.

### 2.4 Cost

| | Azure SRE Agent | kagent stack |
|---|---|---|
| Idle cost | 4 AAUs / agent / hour always-on, every agent, every hour | Marginal pod cost on existing nodes; **plus** LLM-hosting compute (GPU node for Qwen-14B if self-hosted) and the **LGTM stack** (Loki / Mimir / Tempo / Grafana) which is sunk cost — already deployed and shared across the platform |
| Usage cost | Token-based AAU per model provider | Self-hosted Qwen via LiteLLM ≈ $0 inference once the GPU is paid for; Azure OpenAI charged at standard token rates when used |
| Build / sustain cost | Microsoft absorbs framework engineering | **Engineering FTE to close the persistent-memory, code-context, and approval-gate gaps** (Section 6) — not zero |
| Scaling | Linear in agents × tenants × hours | Roughly fixed compute; LLM cost only when workflows fire |
| Lock-in | Azure account, Azure billing, Azure runtime | Portable across K8s distributions and LLM providers |

For **N agents × M clusters**, Microsoft's bill scales with N and M. The kagent
stack scales sub-linearly because the heavy components (Argo, kagent controller,
LiteLLM, GPU host) are shared across all agents. At ~10+ teams or clusters the
always-on AAU charge typically exceeds the marginal cost of running another
agent on the in-house stack — but the in-house stack only wins **after** the
gap-closure engineering investment in Section 6 is funded.

### 2.5 Agent-to-agent communication

- **Azure SRE Agent** uses a hierarchical orchestrator → subagent model via Response
  Plans. Tools are scoped per subagent. **No documented peer A2A protocol** — closed
  hierarchy, internal to Microsoft's runtime.
- **kagent stack** speaks the open **A2A protocol** (`POST /api/a2a/kagent/{agent}/`,
  `message/send`). Agents are addressable peers. Argo Workflow → kagent triage → kagent
  remediation already chains end-to-end. The dev-pipeline POC uses Kimi as a coordinator
  orchestrating Qwen workers — heterogeneous models cooperating.

**Verdict:** The kagent stack is architecturally more open. Open A2A is
multi-vendor-friendly between kagent agents and any A2A-compliant peer. A2A
coverage today is kagent-to-kagent and workflow-to-kagent.

### 2.6 Tool calling

- **Azure SRE Agent** deliberately collapsed from 100+ tools / 50+ agents to **5 core
  tools + generalist agents** (per the team's "Context Engineering" post). MCP connectors
  cover everything else. A learned-the-hard-way design.
- **kagent stack** uses AKS-MCP `call_kubectl` (admin), **kagent's native k8s tools**
  (which avoid the bash-quoting failure modes that Qwen 14B exhibits when forced to
  shell out), Loki / Mimir / Tempo MCPs against the LGTM stack for log / metric /
  trace queries, and Argo's `resource:` / `script:` steps as a deterministic execution
  layer. The **template factory pattern** has agents author templates offline via PR;
  runtime is deterministic — agents do not `kubectl create` in production.

**Verdict:** Microsoft is more polished within its sandbox and offers Stop /
PostToolUse hooks for runtime gating. The kagent stack additionally constrains
agent power at the cluster boundary by **moving template authorship offline
into a PR review loop** — a different control point than runtime hooks.

---

## 3. Who should pick which

### Pick Azure SRE Agent if you are

- A primarily **Azure-resident** estate (AKS + Container Apps + Azure Monitor)
- Looking for **zero-ops** time-to-value within weeks
- A **GitHub-hosted** code shop (so the deep-context RCA actually applies — **does
  not apply in our environment**, where code is on GitLab)
- Comfortable with AAU billing and Microsoft as the agent runtime
- Procurement / audit teams want a managed-service checkbox

### Pick the kagent stack if you are

- **Multi-cluster, mixed estate** (AKS + on-prem + edge + dev kind/minikube)
- **Cost-sensitive at fleet scale** (10+ clusters or teams)
- Already invested in **Argo Workflows / Argo Events** as the orchestration plane
- Want **local-LLM optionality** (Qwen via LiteLLM is essentially free inference)
- Need **real A2A composition** — peers, not Microsoft's hierarchy
- Want to extend agents into **non-SRE flows** (namespace onboarding, dev pipelines,
  app onboarding template factories)

---

## 4. Who should run a hybrid

Hybrid is the right answer for most large Azure-heavy enterprises. The split is
not "one or the other" — it is **per workload tier and per cluster type**.

### 4.1 Personas that benefit from hybrid

#### A. Azure-heavy enterprise with a mixed estate

- **Production AKS, customer-facing**: Azure SRE Agent. Managed memory, audit
  story, and ops simplicity may be worth the AAU cost.
- **On-prem / edge / dev clusters**: kagent. Azure SRE Agent does not advertise
  support for non-Azure Kubernetes targets.
- *Note for our environment:* the GitHub-deep-context advantage does not apply
  (code on GitLab), which weakens the case for the managed agent on the AKS side.

#### B. Tiered reliability budget

- **Tier 1 production**: Azure SRE Agent for incident response (TTM matters more
  than $).
- **Tier 2/3 (staging, dev, internal tools)**: kagent. You do not need persistent
  memory or auto-remediation here, and the always-on AAU bill is hard to justify.

#### C. Compliance / sovereign workloads

- **Regulated cluster** (data residency, classified, air-gapped): kagent on local
  LLMs. Cannot legally route inspection telemetry through a managed Microsoft service.
- **Standard clusters**: Azure SRE Agent.

#### D. Multi-tenant SaaS

- **Customer-facing tenant clusters**: Azure SRE Agent (per-tenant managed identity,
  Azure Lighthouse cross-tenant delegation, audit trail).
- **Shared platform infrastructure**: kagent. A managed agent per shared service is
  cost-prohibitive.

#### E. Existing Argo Workflows investment

- **Keep Argo as the orchestration plane** and let kagent run the agentic steps.
- **Adopt Azure SRE Agent narrowly** for Azure-resource-specific incidents
  (Azure Monitor alert merging, ARM-side investigation, Lighthouse multi-tenant
  delegation). Treat it as one specialist tool in a wider workflow library, not
  the entire platform.

#### F. Migration / pilot

- **Start with Azure SRE Agent** to demonstrate value to leadership in 30 days
  on Azure-resource investigations specifically.
- **Build kagent in parallel** for portability and to absorb non-AKS scope as
  confidence grows. Migrate gradually.

#### G. Azure-resource ops vs. cluster / platform ops split

- **Azure-resource investigations** (Azure Monitor alerts, ARM drift, Container
  Apps, Lighthouse multi-tenant): Azure SRE Agent — direct integration with
  Azure-native data sources is hard to replicate in-house.
- **Cluster / platform ops** (Istio, cert-manager, NAP, Kyverno, KRO, namespace
  onboarding): kagent. These do not live in Azure-managed surfaces and are better
  served by the in-house tooling and LGTM observability.

### 4.2 Hybrid reference architecture

```
                           ┌─────────────────────────────────┐
                           │ Argo Events / AlertManager      │
                           │ (single ingestion plane)        │
                           └────────────────┬────────────────┘
                                            │
                ┌───────────────────────────┴───────────────────────────┐
                │                                                       │
                ▼ Azure-tagged alerts                                   ▼ Everything else
   ┌────────────────────────────┐                       ┌──────────────────────────────────┐
   │ Azure SRE Agent             │                       │ Argo Workflow + kagent           │
   │ - tier-1 prod AKS           │                       │ - non-AKS clusters               │
   │ - GitHub-linked apps        │                       │ - dev / staging                  │
   │ - persistent memory needed  │                       │ - regulated workloads            │
   │ - audit / compliance gate   │                       │ - infra / platform ops           │
   └────────────┬───────────────┘                       └────────────────┬─────────────────┘
                │                                                         │
                └────────────────────┬────────────────────────────────────┘
                                     ▼
                          ┌────────────────────┐
                          │ Common alerting +   │
                          │ Teams HITL approval │
                          │ (your existing)     │
                          └────────────────────┘
```

Key design choices in a hybrid setup:

1. **One ingestion plane.** Argo Events and/or AlertManager fan out to the right
   agent. Avoid two parallel pager paths.
2. **Tag-based routing.** Alerts carrying an Azure resource ID + tier=1 label go
   to Azure SRE Agent; everything else to kagent.
3. **One human approval gate.** Reuse the Teams HITL approval flow regardless of
   which agent proposed the action.
4. **Shared incident timeline.** Both agents post structured updates to the same
   channel / incident store so SREs see one narrative.
5. **One audit log.** Mirror Azure SRE Agent's tool-use trail into the same
   sink as Argo Workflow logs.

---

## 5. Cost-modelling rule of thumb

A back-of-envelope view to take into a budget conversation. Substitute real
AAU pricing from `aka.ms/sreagent/pricing` when you have it.

```
Azure SRE Agent annual cost
  = Σ_agents ( 4 AAU/hr × 8,760 hr × $/AAU )      # always-on
  + Σ_incidents ( token_AAU × $/AAU )             # usage

kagent stack annual cost
  = cluster compute for kagent + Argo pods                       (often sunk)
  + GPU host for self-hosted LLM         (~$5–15k/yr/GPU node depending on SKU)
  + LiteLLM / agentgateway ops cost                              (sunk)
  + LGTM stack ops cost (Loki + Mimir + Tempo + Grafana)         (sunk — shared)
  + Postgres + pgvector for kagent native memory  (sunk if shared with platform)
  + (optional) Pinecone subscription if external memory is preferred
  + LLM inference (≈ $0 if Qwen-local once GPU is paid for, else token cost)
  + ~0.25–0.5 engineering FTE for governance / approval-gate / agent learning loop
```

For 5 agents × 8,760 hours × 4 AAU at any non-trivial $/AAU rate, the always-on
charge alone is real money before a single incident is investigated. The kagent
stack pays a GPU + engineering tax up front instead, but most of the dependent
infrastructure (LGTM, Postgres, kagent controller, Argo) is already deployed
and shared, so the marginal cost of adding agents is low. **The cross-over
point is sensitive to AAU pricing, GPU SKU, and how much of the gap-closure
engineering is already done — a sensitivity table should be produced once AAU
pricing is known.** For most Azure-heavy estates with 10+ planned agents the
in-house stack wins on TCO once the platform investment is amortised; below
that, the managed service is hard to beat on time-to-value — though in our
specific environment (no GitHub, GitLab-hosted code) the headline managed-side
benefit of GitHub deep-context RCA does not apply, narrowing the case for
Azure SRE Agent further.

---

## 6. Honest gaps in the in-house stack today

Closing these is what makes the hybrid case lean further toward kagent over time.
The list is shorter than earlier drafts implied because of two material findings:

- **Persistent memory is already supported by kagent CRDs** — native Postgres +
  pgvector (preferred internally) or external Pinecone via the `kagent.dev/Memory`
  v1alpha1 CRD. The work is integration and indexing strategy, not building a
  substrate.
- **Code-context RCA on GitHub does not apply** in our environment because
  code is on GitLab.

Remaining gaps:

1. **Cross-investigation learning loop.** kagent native memory auto-extracts every
   5 turns within a session, but the "what did we learn last week / last month"
   summarisation that Microsoft markets as Deep Context still needs explicit
   design here.
2. **GitLab code-context tool.** If we want code-aware RCA, wire a GitLab MR /
   commit history MCP or tool into the kagent agents — modest scope.
3. **Approval gates as a first-class primitive.** Finish the Teams HITL design
   already in flight.
4. **LGTM-aware reasoning tools.** Loki LogQL and Mimir / Tempo MCPs (or thin
   query tools) so the agent can reach into LGTM during reasoning rather than
   relying on `kubectl logs`.
5. **Onboarding polish.** Microsoft spent serious engineering on the day-one
   useful experience. Ours is bring-your-own-config.

---

## 7. Recommendation

The general industry advice is "hybrid". **For our specific environment the
case for hybrid is weaker than the generic answer suggests, and the case for
kagent-as-default is correspondingly stronger** because:

- **No GitHub at work** — Azure SRE Agent's headline GitHub-deep-context RCA
  does not apply. We would be paying the always-on AAU charge without the
  feature most of the marketing leans on.
- **Persistent memory is already addressable in kagent** via the `Memory` CRD
  (Pinecone or pgvector). The "biggest functional gap" called out earlier is
  largely closed by configuration rather than greenfield engineering.
- **LGTM is already deployed** — observability sunk cost is on the kagent side
  of the ledger, not the Microsoft side.

### 7.1 Recommended posture

1. **Default to kagent + Argo Workflows + LGTM** across the estate (AKS,
   non-AKS, dev, regulated, edge). Use kagent native memory backed by pgvector
   for the persistent-memory layer; reserve Pinecone for cases where an
   external index is justified.
2. **Use Azure SRE Agent narrowly**, only where it has a feature kagent does
   not — Azure-resource-specific surfaces (Azure Monitor alert merging,
   Lighthouse multi-tenant, ARM drift). Treat it as a specialist tool callable
   from Argo, not the strategic agent platform.
3. **Reuse one ingestion plane, one approval gate, one incident timeline, one
   audit log** regardless of which agent acts.
4. **Fund the short remaining gap-list in Section 6** — cross-investigation
   learning loop, GitLab code-context tool, Teams HITL completion, LGTM MCPs.
   The total scope is modest now that memory is largely solved.

### 7.2 What would change this recommendation

- If GitHub access is granted at work, the GitHub-deep-context advantage of
  Azure SRE Agent becomes real and the hybrid case strengthens.
- If Microsoft published cross-cluster (non-Azure) support for SRE Agent.
- If AAU pricing comes in materially below current public expectations.

This captures Microsoft's day-one polish where it is worth paying for, keeps cost
linear in the open part of the estate, and avoids vendor lock-in for the workloads
that cannot or should not run on a managed agent.

---

## 8. References

- [microsoft/sre-agent (GitHub)](https://github.com/microsoft/sre-agent)
- [Azure/sre-agent-plugins](https://github.com/Azure/sre-agent-plugins)
- [Azure SRE Agent pricing blog](https://aka.ms/sreagent/pricing/blog)
- [Context Engineering: Lessons from Building Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/context-engineering-lessons-from-building-azure-sre-agent/4481200)
- [Azure SRE Agent GA announcement](https://aka.ms/sreagent/ga)
- In-house: `aks-mgmt-stack/holmes-argoworkflows/`, `kagent-triage/`,
  `infra-stack/kro-stack/definitions/`
