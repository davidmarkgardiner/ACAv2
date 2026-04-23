# Cross-Bank Agent Orchestration — Demo Thinking

**What this doc is about:** how agents find each other, call each other, and
access shared resources across the bank — once they exist.

**What this doc is NOT about:** how to build an agent. That's a separate concern
(see "Agent Builder" skill — forthcoming). Here we assume agents already exist
and focus on how they compose into end-to-end flows.

## The two layers

```
┌─ Layer 2: FEDERATION (EASE / enterprise agent registry) ─────────────────┐
│   • Agent discovery (who can answer what)                                │
│   • Routing (cross-team calls)                                           │
│   • Policy / audit / rate limiting                                       │
│   • Shared resources (memory, lessons DB, observability)                 │
└──────────────────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────┴──────────────────────────────────────────────┐
│ Layer 1: EXECUTION (kagent on each team's cluster)                       │
│   • Agents run                                                           │
│   • Tools attached (MCP servers — kubectl, DBs, APIs, other agents)      │
│   • Memory / conversation state                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Layer 2's job is orchestration. Layer 1's job is execution. Agent authoring
(prompts, skills, tool lists) happens independently of both — that's the
agent-builder concern.

## How orchestration actually works

### 1. Agents don't call each other by URL — they call by capability

Team A's agent doesn't say "POST https://team-b.internal/agent/..." — it says
"I need an agent that can check change-freeze status." EASE does the lookup.

```
Agent A
  │
  │  1. "I need fraud-detection capability on a transaction"
  ▼
EASE registry
  │  lookup: capability=fraud-detection → fraud-detection-agent@TeamB
  │  policy check: is Agent A allowed to invoke this capability?
  │  rate limit check: under quota?
  │
  ▼
Agent B (fraud-detection-agent on Team B's cluster)
  │  executes
  ▼
Response flows back through EASE (audit logged)
  │
  ▼
Agent A continues reasoning with the answer
```

**Why capability-based:** Team B can move their agent, rename it, scale it out
— callers don't care. Only capability tags change when the underlying skill
changes.

### 2. Three orchestration patterns

**Agent-as-Tool (stateless):** Agent B becomes an entry in Agent A's tool list.
Agent A decides when to call, passes parameters, gets a result. No shared
session. Most common pattern.

```yaml
# Agent A's tool list
tools:
  - type: Agent
    agent:
      capability: change-freeze-check
      # EASE resolves this to whichever agent currently implements it
```

**Explicit handoff (stateful):** Agent A transfers the current conversation
to Agent B. Agent B takes over, Agent A is out of the loop until B hands back.
Used for long sub-tasks that need their own context.

**Fan-out / parallel (workflow-level):** Argo Workflows invokes N agents in
parallel, aggregates results, passes to the next step. The workflow
orchestrates, not an agent.

### 3. Resource access — always through MCP, never direct

Agents never talk to databases, APIs, or cluster state directly. Every
resource is wrapped in an MCP server that exposes typed tools.

```
┌─ Agent ─┐      ┌─ MCP Server ─┐        ┌─ Actual Resource ─┐
│         │─────▶│  typed tool   │──────▶│                   │
│         │      │  interface    │       │ kubectl / DB /    │
│         │◀─────│               │◀──────│ Azure API / etc   │
└─────────┘      └───────────────┘        └───────────────────┘
                  (kubeconfig /
                   credentials /
                   retries /
                   audit)
```

**Why this matters for cross-bank:** the MCP server is where you enforce
access control. Team A's agent calling `k8s_get_pods` via the Platform's
shared MCP server uses Platform's credentials — not Team A's. Same for
pgvector, Azure Resource Graph, ServiceNow, etc.

**Shared MCPs worth building once, using everywhere:**

| Capability | MCP server | Lives on |
|---|---|---|
| Cluster inspection | `aks-mcp` | Platform shared |
| Lessons recall (pgvector) | `lessons-mcp` | Platform shared |
| Change freeze status | `release-mcp` | Release team |
| Fraud scoring | `fraud-mcp` | FraudOps |
| On-call lookup | `oncall-mcp` | Platform shared |
| Ticket CRUD (GitLab / ServiceNow) | `ticket-mcp` | Platform shared |
| Secret lookup (Azure KV) | `secrets-mcp` | Platform shared |
| Observability (Prometheus / Loki / Tempo) | `obs-mcp` | Platform shared |

Every agent in the bank reaches these through the same tool interface — same
contract, same audit, same access model.

### 4. Context passing between agents

Three ways data flows between agents in a multi-agent flow:

| Mechanism | What flows | Used for |
|---|---|---|
| **Tool parameters** | Structured JSON in / JSON out | Direct Agent-as-Tool calls |
| **Shared state** (pgvector, blob, ConfigMap) | Arbitrary data | Long-running workflows, lessons, artifacts |
| **A2A session context** | Full conversation history | Explicit handoff where the next agent needs prior messages |

Rule of thumb: prefer tool parameters (explicit) over shared state (implicit).
Agents are easier to reason about when everything they need is in the call.

### 5. Error handling across the boundary

When Agent A calls Agent B and B fails:

- **Transient error** (timeout, 5xx): EASE retries with backoff. Bounded
  attempts, exposes total elapsed time to caller.
- **Policy denial** (not authorised, rate-limited): fails fast with a
  structured error. Caller decides: retry with different capability, escalate
  to human, degrade gracefully.
- **Agent returned `insufficient_data`**: Agent A reads the field, decides:
  prompt for more info, try a different agent, or give up with an explanation.
- **Agent returned junk / unparseable**: workflow's schema-validation step
  catches it, marks the flow as failed, creates a ticket.

Same error model for every cross-team call. Standardised at EASE.

## How a full orchestration looks in practice

Production alert → resolution, four agents, three teams:

```
           Argo Workflow orchestrator
                     │
                     ▼
  ┌──── payments-triage-agent ─────────────────────────────┐
  │  (Payments team cluster, kagent)                       │
  │  systemPrompt: "classify incident, gather context"     │
  │  tools:                                                │
  │    - aks-mcp.k8s_get_events        ← shared Platform   │
  │    - aks-mcp.k8s_get_pod_logs      ← shared Platform   │
  │    - agent(capability=lessons-recall)    ← calls Agent │
  │    - agent(capability=change-freeze-check) ← calls Agt │
  │    - agent(capability=networking-triage) ← calls Agt   │
  └─────┬──────────────┬──────────────┬────────────────────┘
        │              │              │
        ▼              ▼              ▼
  lessons-recall  change-freeze  networking-triage
  (Platform)      (Release team) (Platform)
        │              │              │
        └───(all return structured JSON via A2A)───┐
                                                   │
                                                   ▼
                        payments-triage synthesises
                                │
                                ▼
                  Argo: tier classification (T2)
                                │
                                ▼
                  Argo: Teams Adaptive Card (suspend)
                                │
                                ▼  approved
                  remediation-agent executes
                                │
                                ▼
                  lessons-write-agent stores outcome
                                │
                                ▼
                  shared lessons DB (pgvector via MCP)
```

Zero URLs in the agent configs — just capability names. EASE resolves at
runtime. If the Release team moves their change-freeze agent to a new cluster,
nothing above changes.

## Observability — one pane across all agents

Same `gen_ai.*` Prometheus metric labels from all kagent clusters:

```promql
# Tokens consumed by team, across all agents
sum by (team) (
  rate(agentgateway_gen_ai_client_token_usage_sum[5m]) * 60
)

# Cross-team calls volume (requires EASE to emit these)
sum by (caller_team, callee_team) (
  rate(ease_agent_invocations_total[5m])
)

# A specific incident — trace across agents
# Filter Tempo by trace_id; see span graph across all three clusters
```

Plus Loki for structured logs, Tempo for distributed traces (one trace ID
flowing through every agent call). Standard OTEL — no bespoke tooling.

## What EASE needs to do (as a service)

MVP feature list, orchestration-focused:

- [ ] **Registry API** — agents register with a capability list, well-known
  URL, auth requirements
- [ ] **Discovery API** — "which agents implement capability X?"
- [ ] **A2A proxy** — forward calls, terminate TLS, inject auth, emit audit
- [ ] **Policy check on each call** — "is caller from team A allowed to
  invoke capability Y?"
- [ ] **Rate limiting per caller / capability**
- [ ] **Audit log** — who called whom, when, with what arguments, for what
  result, traced in OTEL
- [ ] **Fan-out proxying** — for parallel multi-agent calls (workflow steps
  use this)

Not MVP but valuable later:
- Workflow composition DSL (declarative multi-agent flows)
- Cost allocation (token usage attributed to calling team)
- Capability-to-agent versioning (canary new agent implementations of an
  existing capability)

## Standards the bank agrees on

These are the dependencies between agents. Once every team observes them,
orchestration across teams works without custom adapters.

1. **A2A protocol** (already kagent native) — how agents talk
2. **MCP** (already kagent native) — how agents access resources
3. **Agent cards** at `/.well-known/agent-card.json` — what each agent can do
4. **Structured JSON** in a ```json fence for agent responses
5. **Risk tier vocabulary T0–T4** — shared remediation policy language
6. **`gen_ai.*` metric labels** — OTEL semantic conventions
7. **Capability names** — a controlled vocabulary (`networking-triage`,
   `change-freeze-check`, etc.) — governed by platform

No proprietary SDK. No team required to rewrite their agent. Agreement is at
the protocol level.

## The handoff to the Agent Builder skill

Everything above assumes agents exist. The Agent Builder skill (separate from
this doc) covers:

- How to write system prompts
- How to define skills / playbooks
- How to configure tools and memory
- How to test agent behaviour
- Prompt engineering patterns
- When to use GPT vs Qwen vs specialised models

When a team wants a new agent, they reach for the Agent Builder. When they
want to expose it to the bank, they publish its capability to EASE following
the standards above. Two separate concerns; two separate toolsets.

## Demo pitch — 30 seconds

> "Each team builds their own agents on their own kagent clusters. EASE is
> the enterprise registry: agents are listed by what they can do, not by URL.
> When Payments' triage agent needs to check a change freeze, it asks EASE
> 'who does change-freeze-check?' — EASE routes the call to Release's agent.
> When it needs to query the lessons DB, same thing. One alert, four agents,
> three teams, zero team-to-team integration work. We agreed on protocols
> once; composition is free after that."

## What to build first if we take this forward

1. **Define 10 initial capabilities** — the vocabulary everyone uses
2. **Build EASE MVP** — registry + proxy + audit (the orchestration plane)
3. **Onboard one cross-team flow** — payments-triage calling lessons-recall
   is the lowest-risk first integration
4. **Observability check** — confirm one trace_id flows through the full
   multi-agent path
5. **Publish the standards** — one-page reference for any team wanting to
   participate

Agent authoring is deferred to the Agent Builder skill.
