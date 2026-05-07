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
| Usage cost | Token-based AAU per model provider | Direct LLM API spend via agentgateway (Azure OpenAI, Anthropic, etc.) at provider list rates; self-hosted Qwen ≈ $0 inference once the GPU is paid for |
| Build / sustain cost | Microsoft absorbs framework engineering | **Engineering FTE to close the persistent-memory, code-context, and approval-gate gaps** (Section 6) — not zero |
| Scaling | Linear in agents × tenants × hours | Roughly fixed compute; LLM cost only when workflows fire |
| Lock-in | Azure account, Azure billing, Azure runtime | Portable across K8s distributions and LLM providers |

For **N agents × M clusters**, Microsoft's bill scales with N and M. The kagent
stack scales sub-linearly because the heavy components (Argo, kagent controller,
agentgateway, GPU host) are shared across all agents. At ~10+ teams or clusters the
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
- Want **flexible LLM routing via agentgateway** (mix Anthropic / Azure OpenAI / self-hosted Qwen per task tier)
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

## 5. Cost comparison with concrete figures

### 5.0 What actually drives cost in our environment

The kagent + Argo + LGTM control plane is essentially **free at the margin** —
the pods run on existing K8s nodes, the controllers are tiny, the observability
stack is already deployed for the wider platform. There is no GPU bill unless
we choose to self-host an LLM, and we are not doing that as the default path.

**The only real variable cost is LLM token spend.** Everything else either
runs on sunk infrastructure or is a one-off engineering investment.

So the right question is not "what does the in-house stack cost" but:
**"how many tokens will our agents burn per investigation, how many
investigations per day, on which model, and what is the unit token price?"**
That answer evolves over time and needs measurement, not a static spreadsheet.

The Azure SRE Agent comparison then collapses to a much simpler shape:

| | Azure SRE Agent | kagent stack |
|---|---|---|
| Fixed always-on baseline | **4 AAU/agent/hour** ($3,504/yr/agent at $0.10/AAU) | **$0** |
| Variable LLM cost | Tokens × MS's AAU rate | Tokens × direct provider rate |
| Provider choice | Anthropic, OpenAI (MS-mediated) | Any — Azure OpenAI direct, Anthropic API, self-hosted, OpenRouter, mix per agent |
| Engineering tail | None (managed) | Modest — gap-closure FTE in Year 1, low after |

**The structural advantage is the missing always-on charge** plus freedom to
route cheap models to cheap tasks. The numbers below are sized to make those
levers concrete.

All Microsoft figures use the published rates from
[learn.microsoft.com/azure/sre-agent/pricing-billing](https://learn.microsoft.com/en-us/azure/sre-agent/pricing-billing)
and the **$0.10 per AAU illustrative figure** from Microsoft's April 2026
billing-model blog. There is no free tier and pricing varies by region; treat
$0.10/AAU as a reference point, not a contractual rate.

### 5.1 Azure SRE Agent — always-on baseline (per agent)

| Period | AAUs | $ at $0.10/AAU |
|---|---|---|
| Hour | 4 | **$0.40** |
| Day (24h) | 96 | **$9.60** |
| Month (30d) | 2,880 | **~$288** |
| Year (8,760h) | 35,040 | **~$3,504** |

This is what you pay **before any work happens**, for every agent that exists,
24/7. Stopping an agent does not stop this charge — only deletion does.

### 5.2 Active flow per task (Microsoft's published scenarios)

| Scenario | AAUs (Claude Opus 4.6) | $ | AAUs (GPT 5.3 Codex) | $ |
|---|---|---|---|---|
| Quick question (~20K in / 2K out + cache) | 3.8 | $0.38 | 1.6 | $0.16 |
| Incident investigation (~200K in / 15K out + cache) | 35.5 | $3.55 | 13.7 | $1.37 |
| Full remediation (~500K in / 40K out + cache) | 86.5 | $8.65 | 33.9 | $3.39 |

Anthropic models are roughly **2.5× the cost per task** of OpenAI GPT-5.x on
this product. Microsoft notes Opus often reaches a conclusion in fewer
reasoning steps, so the per-task delta in practice is smaller than the
per-token delta.

### 5.3 Worked example — single agent, GPT 5.3 Codex, moderate use

| Component | Calculation | Annual $ |
|---|---|---|
| Always-on | 35,040 AAU × $0.10 | **$3,504** |
| 100 quick questions / month × 12 | 1,200 × 1.6 AAU × $0.10 | $192 |
| 50 incident investigations / month × 12 | 600 × 13.7 AAU × $0.10 | $822 |
| 10 full remediations / month × 12 | 120 × 33.9 AAU × $0.10 | $407 |
| **Total — 1 agent / yr** | | **~$4,925** |

Switch to Claude Opus 4.6 and the per-task figures roughly 2.5×, pushing this
single-agent total to **~$7,400 / year**.

### 5.4 Fleet scenarios

The always-on charge is what dominates at scale. Active-flow usage is
sub-linear (one agent can serve many tasks).

| Fleet size | Always-on / yr | + ~$1,400 active-flow / agent / yr (GPT) | Total / yr |
|---|---|---|---|
| 1 agent | $3,504 | $1,400 | **~$4,900** |
| 5 agents | $17,520 | $7,000 | **~$24,500** |
| 10 agents | $35,040 | $14,000 | **~$49,000** |
| 25 agents | $87,600 | $35,000 | **~$122,600** |

For a meaningful estate (one agent per service team, or per cluster) you are
looking at **mid-five-figures to low-six-figures USD/year just for the SaaS
agent**, before any GPU- or engineering-side savings the in-house stack would
also incur.

### 5.5 kagent stack — token-cost forecast model

Pods, controllers, observability, and Postgres are sunk cost in our
environment. The variable bill is the LLM API spend, which is a function of
**token volume** and **provider rate**.

#### LLM rate card (public list prices, May 2026)

These are reference rates per 1M tokens. Real Azure OpenAI / Anthropic
contract rates may be lower under EA / committed-use discounts.

| Model | Input $/1M | Output $/1M | Suitable for |
|---|---|---|---|
| Claude Opus 4.6 (Anthropic / AWS Bedrock) | ~$15 | ~$75 | Hardest investigations, root-cause synthesis |
| Claude Sonnet 4.6 | ~$3 | ~$15 | Default for investigations / remediation reasoning |
| Claude Haiku 4.5 | ~$1 | ~$5 | Cheap classification, alert summarisation |
| GPT-5.x (Azure OpenAI) | ~$5 | ~$30 | Comparable to Sonnet for most tasks |
| Qwen3-14B (self-hosted) | ~$0 | ~$0 | Once GPU is paid for; high-volume noise filtering |

**Implication:** Microsoft's AAU pricing translates roughly to retail token
rates ($10/1M Opus input × Microsoft = ~$15/1M direct), so the per-token
*active-flow* charge is similar in shape to going direct. The **win comes
from removing the always-on tax and being able to mix models per task tier**.

#### Per-investigation token model

Calibrated against Microsoft's published task scenarios (which we have no
reason to believe are wildly off for our workloads):

| Task tier | Input tokens | Output tokens | Default model |
|---|---|---|---|
| Triage / classification | ~30K | ~3K | Sonnet or Haiku |
| Incident investigation | ~200K | ~15K | Sonnet (fallback Opus) |
| Full remediation | ~500K | ~40K | Sonnet, Opus only if remediation involves code synthesis |

#### Cost per investigation by model

Direct token cost (no AAU markup, no always-on baseline):

| Model | Triage | Investigation | Remediation |
|---|---|---|---|
| Claude Opus 4.6 | $0.68 | $4.13 | $10.50 |
| Claude Sonnet 4.6 | $0.14 | $0.83 | $2.10 |
| Claude Haiku 4.5 | $0.05 | $0.28 | $0.70 |
| GPT-5.x (Azure OpenAI) | $0.24 | $1.45 | $3.70 |
| Qwen3-14B self-hosted | ~$0 | ~$0 | ~$0 |

**Compare with Azure SRE Agent's published per-task costs** (Section 5.2):
roughly the same order of magnitude per task at the GPT tier, but Microsoft
adds ~$3,504/yr/agent always-on **on top**.

#### Volume-driven annual forecast

Pick volume assumptions for an "average" agent and multiply. Three sample
volumes — Low / Mid / High — with all investigations on Sonnet 4.6 (a
sensible default) and triage on Haiku 4.5:

| Volume / agent / month | Triage (Haiku) | Investigations (Sonnet) | Remediations (Sonnet) | Monthly $ | Annual $ |
|---|---|---|---|---|---|
| Low | 100 × $0.05 = $5 | 20 × $0.83 = $16.60 | 2 × $2.10 = $4.20 | **~$26** | **~$310** |
| Mid | 500 × $0.05 = $25 | 100 × $0.83 = $83 | 10 × $2.10 = $21 | **~$129** | **~$1,550** |
| High | 2,000 × $0.05 = $100 | 500 × $0.83 = $415 | 50 × $2.10 = $105 | **~$620** | **~$7,440** |

Switch the High-volume row to all-Opus and it becomes ~$5,500/month
(~$66k/yr/agent) — which is why **model choice per task tier matters more than
fleet size**. This is the lever Azure SRE Agent partially gives up because it
charges by AAU regardless of which provider you pick.

### 5.6 Crossover analysis

Total annual cost / agent (LLM spend only on the kagent side; always-on +
matched active-flow on the Microsoft side):

| Per-agent / yr | Azure SRE Agent (GPT 5.3) | kagent (Sonnet) | Ratio |
|---|---|---|---|
| Low volume | $3,504 + $192 = **$3,696** | **$310** | ~12× |
| Mid volume | $3,504 + $822 = **$4,326** | **$1,550** | ~2.8× |
| High volume | $3,504 + $4,200 = **$7,700** | **$7,440** | ~1× (flat) |

For 10 agents at mid-volume:

| | Year 1 | Year 2+ |
|---|---|---|
| Azure SRE Agent | ~$43,000 | ~$43,000 |
| kagent stack | ~$15,500 LLM + ~$50k FTE = **~$65k** | ~$15,500 LLM + small ops tail = **~$18k** |

**Crossover behaviour:**

- **Low- / mid-volume agents**: kagent wins immediately on a per-agent basis,
  even before fleet effects, because the always-on baseline dominates.
- **High-volume agents on heavy models**: the two converge — at that point the
  decision is on features and control, not cost.
- **The biggest cost lever is which model handles which task tier**, not which
  platform hosts the agent. Use Sonnet/Haiku by default and reserve Opus for
  the cases where it materially shortens the investigation.

### 5.7 What we actually need to do

Because the bill is dominated by tokens, and tokens are dominated by volume
and model choice, **forecasts in a static doc go stale fast**. The plan
should be to **measure**:

1. **Instrument agentgateway** to emit per-call token counts to Mimir (we
   already run LGTM). Tag by agent, task tier, and model.
2. **Build a Grafana dashboard** for daily / monthly token spend by agent and
   by model.
3. **Set a monthly budget alert** in Grafana and a soft cap in agentgateway.
4. **Review the model-routing config every quarter** — promote tasks down to
   Haiku where Sonnet was overkill; promote up to Opus where Sonnet was
   missing diagnoses.

Once the dashboard exists, we replace the assumptions in 5.5 / 5.6 with real
30-day rolling numbers and the comparison in this section becomes evidence-
based instead of model-based.

### 5.8 Caveats

- **$/AAU is illustrative.** The $0.10 reference is from a Microsoft blog
  example; real EA / CSP pricing may differ. A 30% Microsoft discount narrows
  but does not close the always-on gap.
- **List prices for Anthropic / Azure OpenAI** are public list rates — real
  EA / committed-use discounts can lower the kagent side too.
- **Token-per-task assumptions** are calibrated against Microsoft's own
  scenarios; once we have 30 days of measured data we should replace them.
- **Microsoft's internal data** (35K incidents / 1,300 agents = ~27
  incidents/agent/yr) suggests average usage is closer to the Low row than
  the High row. If our volumes are similar, the always-on tax is the dominant
  Microsoft cost and the kagent side stays well under $1,000/agent/yr.

The headline: **what we're really committing to is an LLM bill that scales
with how often agents run, not a per-agent SaaS subscription**. That gives us
direct levers (model choice, prompt length, caching, batching) that
Azure SRE Agent partially abstracts away.

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
- [Pricing and Billing for Azure SRE Agent (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/sre-agent/pricing-billing) — source for AAU rates and per-task scenarios
- [Azure SRE Agent pricing page](https://azure.microsoft.com/en-us/pricing/details/sre-agent/)
- [Azure SRE Agent pricing blog (April 2026 active-flow update)](https://aka.ms/sreagent/pricing/blog) — source for $0.10/AAU illustrative rate
- [Context Engineering: Lessons from Building Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/context-engineering-lessons-from-building-azure-sre-agent/4481200)
- [Azure SRE Agent GA announcement](https://aka.ms/sreagent/ga)
- In-house: `aks-mgmt-stack/holmes-argoworkflows/`, `kagent-triage/`,
  `infra-stack/kro-stack/definitions/`
