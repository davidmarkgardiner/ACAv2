# Remediation Model — Two Options

How do we decide *what an agent is allowed to do without asking a human?*
Two viable models, plus a hybrid. Pick one before building the
tier-mapping ConfigMap (or building anything else that depends on it).

This doc supersedes the tier section of `HITL-USE-CASES.md` for the
"approve vs auto" decision. Use it together with `BOT-CONTRACT.md` (wire
format) and `README.md` (deploy mechanics).

---

## TL;DR

| | Option A — Tier-based | Option B — Capability-based | Hybrid (A+B) |
|---|---|---|---|
| Source of truth | One central ConfigMap | Per-agent `allowed_tools` list | Both |
| Decision lives | Workflow (`classify-tier`) | Inside the agent | Agent first, ConfigMap second |
| Adding a new action | Edit the ConfigMap | Edit the agent's allowlist | Both |
| Adding a new agent | Free — same rules apply | Declare its allowlist | Declare allowlist |
| Audit answer to "what can run unattended on cluster X?" | One file | Aggregate N agents | One file (tier ConfigMap) |
| Agent-to-agent handoff | Awkward | Natural | Natural |
| Time to first production action | Slow (enumerate everything) | Fast | Slow |

**Recommendation:** Start **Option B** (capability-based) for the first 1–2
agents. Add **Option A** (tier ConfigMap) when you have ≥3 agents and an
audit conversation forcing a single source of truth. Most banks land on
Hybrid within 6–12 months — but B-first lets you ship in weeks.

---

## Option A — Tier-based (centralised policy)

Every possible remediation action is pre-classified in a ConfigMap. The
workflow classifies *before* running anything. The agent proposes; the
ConfigMap decides.

### Flow

```
alert ─► triage agent (read-only, returns proposed action + target)
      ─► classify-tier (deterministic ConfigMap lookup)
              │
              ▼
      ┌── T0/T1: execute immediately
      ├── T2/T3: approval gate ─► execute on approve
      └── T4:   ticket only, fail fast
```

### What the ConfigMap looks like

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: remediation-tier-mapping
  namespace: argo
data:
  rules.yaml: |
    rules:
      - match: { verb: restart, kind: Pod,        env: non-prod } ; tier: T0
      - match: { verb: restart, kind: Deployment, env: non-prod } ; tier: T1
      - match: { verb: apply,   kind: NetworkPolicy }            ; tier: T2
      - match: { verb: patch,   kind: ConfigMap }                ; tier: T2
      - match: { verb: rollback, kind: Deployment }              ; tier: T2
      - match: { verb: cordon|drain, kind: Node }                ; tier: T3
      - match: { kind: Gateway|VirtualService|AuthorizationPolicy } ; tier: T3
      - match: { verb: delete,  kind: Node|PersistentVolume }    ; tier: T4
      - match: { kind: ClusterRole|ClusterRoleBinding|Role|RoleBinding } ; tier: T4
      - match: { kind: Secret,  verb: rotate|create|update }     ; tier: T4
    default: T4   # unknown action → ticket, never auto
```

The agent's `proposed_tier` is **only** used as a tie-breaker when no rule
matches, and is **bounded** — agent can never *lower* the tier the rules
returned.

### Pros

- Single document the change board / auditor reads
- Deterministic; no LLM influence on the privilege boundary
- Adding a new agent is free — same rules apply to it automatically
- Easy to answer "what runs unattended in prod?" — grep T0/T1
- Easy to ratchet down ("move all T1 Pod restarts to T2 in prod") in one place

### Cons

- Up-front enumeration work — every verb × kind × env combo
- Slow to evolve; new actions need a rule before they can ship
- Agents are passive — they propose, they don't reason about what they can do
- Doesn't model "agent X can do this, agent Y cannot" without extra fields
- The ConfigMap becomes a hot file — every agent change touches it

---

## Option B — Capability-based (per-agent tool allowlist)

Each agent declares its own `allowed_tools` list (and optionally
`allowed_namespaces` / `allowed_kinds`). The agent self-checks before
proposing. If the action is in its list → execute. If not → escalate.

Escalation has two flavours: **to a human** (Teams approval gate) or **to
another agent** with broader privileges. Agents stay narrow on purpose.

### Flow (your proposed shape)

```
alert ─► triage agent
      ─► "can I remediate this with my own tools?"
          │
          ▼
      ┌── YES → execute → verify → update GitLab → notify channel
      └── NO  → escalate (one of):
                  ├─ Teams approval ─► human runs it manually
                  │     ─► bot posts outcome ─► remediation-agent updates
                  │        GitLab + notifies channel
                  ├─ Send to another agent (higher-privilege)
                  │     ─► that agent re-runs the same decision
                  └─ Reject / won't-fix ─► close ticket with reason
```

The "can I remediate?" decision is a single **boolean** the agent emits in
its structured triage output:

```json
{
  "proposed_action":  "kubectl apply -f networkpolicy-dns-fix.yaml -n payments-app",
  "target":           "payments-app/networkpolicy/dns-egress",
  "rationale":        "...",
  "tool_required":    "kubectl_apply_networkpolicy",
  "in_my_allowlist":  false,                    ◄── the decision
  "escalation_hint":  "human|agent:network-admin-agent|reject"
}
```

The workflow reads `in_my_allowlist`. If `true` → run. If `false` → branch
on `escalation_hint`. The agent can suggest an escalation target but can't
force one — the workflow / SRE policy decides.

### Per-agent declaration

```yaml
# attached to each kagent Agent CR (or a sibling ConfigMap)
metadata:
  name: networking-triage-agent
spec:
  allowedTools:
    - kubectl_describe_networkpolicy
    - kubectl_get_endpoints
    - kubectl_logs
    # diagnostic-only — this agent NEVER mutates
  allowedNamespaces:
    - payments-app
    - shared-services
  escalationPaths:
    mutating:
      preferred: agent:network-remediation-agent
      fallback:  human
    out-of-scope-namespace:
      preferred: human
```

A separate `network-remediation-agent` declares the *write* tools and is
the natural escalation target. Same approval gate — different "execute"
identity on the other side of it.

### Pros

- Boundary lives next to the agent — least-privilege by construction
- Easy to add a new agent: declare its tools, done
- Agent-to-agent handoff is a first-class flow, not an afterthought
- Faster to ship — no exhaustive global enumeration before first run
- The agent itself reasons about its limits → better error messages
  ("I cannot patch ClusterRoles; routing to platform-rbac-agent")

### Cons

- No single document tells you "what can run unattended cluster-wide"
- Allowlist drift — agents accumulate tools without a global review
- Harder to ratchet centrally ("disable all Secret writes in prod" needs
  N edits across agents)
- "Tool" is a softer boundary than "verb × kind" — one tool can mutate
  many resources unless you constrain it

---

## Hybrid — both, layered

The agent allowlist limits *what the agent can even propose*. The tier
ConfigMap limits *which proposed actions auto-execute vs need approval*.
Defense in depth.

```
agent proposes action
  ─► allowlist check (Option B) — agent must be allowed to even try
  ─► tier classify (Option A)   — even if allowed, T2+ still gates
  ─► execute or approval
```

- Agent A proposes restart of `Pod` in `payments-app` → allowed by its
  list → tier rules say T0 → run.
- Agent A proposes `delete Secret` → not in its list → escalate to human
  or to `secret-rotation-agent`.
- `secret-rotation-agent` proposes `delete Secret` → in its list → tier
  rules say T4 → ticket only, never auto.

Both layers can refuse. Either alone is sufficient *most* of the time —
together they're robust to mistakes in either layer.

---

## Concrete flow for your proposed shape (Option B + GitLab loop)

This matches what you sketched: agent decides → escalate if needed →
after remediation, the remediation-agent closes the loop.

```
1.  Prometheus alert  ─► Argo Workflow starts
2.  triage-agent runs (read-only) ─► structured JSON output:
        - proposed_action
        - in_my_allowlist: false
        - escalation_hint: human
3.  workflow branches on in_my_allowlist:
       true  ─► remediation-agent (or same agent) executes ─► step 7
       false ─► step 4
4.  workflow POSTs approval request to Teams bot
        (action, rationale, target, GitLab ticket link)
5.  Teams card has buttons:
       [ Approve — I'll run it ]   [ Send to network-admin agent ]   [ Reject ]
6.  Decision returns via Argo Events Sensor:
       Approve  ─► human executes manually outside the workflow
                   ─► human clicks "I've done it" in a follow-up card
                   OR bot detects via cluster state polling
                   ─► remediation-agent invoked to verify + close
       Send to other agent ─► workflow re-enters step 2 with that agent
       Reject  ─► workflow stops, GitLab ticket closed as won't-fix
7.  remediation-agent (always runs at the end of any approved path):
       - verifies cluster state matches expected outcome
       - updates GitLab ticket: status, evidence, who approved, who ran
       - posts outcome FYI card to the same Teams channel
       - emits OTEL trace for the whole flow
```

### Why this shape works

- Triage is always automatic; only mutation gates.
- Agent self-knowledge of its tools is honest — it admits what it can't do.
- Human approval ≠ human execution. "Approve" can mean "yes, *you* run it"
  (manual remediation by SRE, agent just records) — useful for actions
  that aren't safe to automate yet but you still want logged.
- Agent-to-agent handoff is just "approve, route to agent X" — same gate,
  different executor.
- Ticket close-out is centralised in one *remediation-agent*, regardless
  of who actually ran the fix. One source of truth for "did this incident
  resolve, and how?"

---

## Decision matrix — which option for which situation

| If your situation is... | Pick |
|---|---|
| 1 triage agent, 1 remediation agent, want to ship in 2 weeks | **B** |
| Change board demands one document listing every permitted auto-action | **A** |
| Multiple agents with different privileges, want clean handoffs | **B** |
| Auditor will read the policy, not the code | **A** |
| You want "send to another agent" as a first-class flow | **B** |
| You're scaling past 3 agents and rules are getting copy-pasted | **Hybrid** |
| Heavily regulated env with annual policy review | **Hybrid** |
| You're not sure | **B**, plan to add Hybrid later |

---

## What changes in the existing files for each option

| File | Option A only | Option B only | Hybrid |
|---|---|---|---|
| `workflow-approval-template.yaml` | Add `classify-tier` step | Replace `classify-tier` with `check-allowlist` step | Both, in series |
| `BOT-CONTRACT.md` | Card shows tier | Card shows action + agent identity | Both fields |
| `tier-mapping-configmap.yaml` | Required | Skip | Required |
| Agent CRs (kagent) | No change | Add `allowedTools` + `escalationPaths` | Add fields |
| `sensor.yaml` | No change | Add "send to another agent" trigger branch | Add branch |

---

## Open questions for whichever option you pick

1. **Who owns the rules?** Platform team, or per-app squad? Affects review
   cadence and PR ownership.
2. **How is "human ran it manually" detected and reported back?** Polling
   cluster state, follow-up bot card with "done" button, or webhook from
   the SRE's tool? Affects close-loop reliability.
3. **What's the agent-to-agent escalation transport?** New workflow,
   workflow-of-workflows, or A2A direct call? Argo's
   `WorkflowTemplateRef` makes nesting cheap; direct A2A keeps state in
   one place.
4. **Allowlist source — agent CR field or sibling ConfigMap?** CR field
   is closer to the agent; ConfigMap is easier for platform team to
   centrally edit. Pick based on who owns the change.
5. **Reject reason capture.** Always optional comment, or required for
   T3+ / "send to other agent"? Required is more useful for learning;
   optional reduces friction.
