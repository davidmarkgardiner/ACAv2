# HITL Integration Patterns & Use Cases

Where to place the Teams approval gate inside triage workflows, how to think
about auto-vs-ask boundaries, and the catalogue of other automated workflows
the same primitive unlocks.

Pairs with `README.md` (design + deploy) and `BOT-CONTRACT.md` (wire format).
This doc is the **architectural / product** view: *what should the bot gate*,
not *how is the gate wired*.

## TL;DR

- Gate the **mutation**, never the **diagnosis**. Triage is always auto; only
  the kubectl apply / merge / scale / delete needs approval.
- One gate per incident, not one per step. Approve the *plan*, not each line.
- **Tier classification is deterministic** — driven by a ConfigMap of
  action × namespace-label rules. Agents *propose*, the ConfigMap *decides*.
- Same primitive (`suspend → POST bot → Argo Events resume/stop`) is reusable
  for GitOps merges, break-glass access, cost actions, secret rotation,
  schema migrations, AKS upgrades, namespace decommission.

---

## 1. Where the gate goes in a triage DAG

```
alert ─► triage (read-only, ALWAYS auto)
      ─► classify-tier (deterministic, ConfigMap lookup)
      ─► T0/T1: execute               ─► verify ─► post outcome
         T2/T3: approval-gate ─► execute ─► verify ─► post outcome
         T4:    create ticket, fail fast
```

**Rules of the road**

| Rule | Why |
|---|---|
| Triage / evidence-gathering is always auto | Read-only. Latency matters. Approval fatigue if every diagnostic needs a click. |
| Tier classification is deterministic | An LLM that picks its own tier can self-grant T0. ConfigMap + namespace labels decide. |
| One gate per incident | Approving a 3-step plan once beats 3 separate clicks. Reduces rubber-stamping. |
| Verify is auto, post-execution | Closes the loop without another human round-trip. Send outcome card as FYI. |

## 2. Tier model — auto-up-to-a-point boundaries

Map by **blast radius**, not by agent confidence.

| Tier | Auto/Ask | Examples | Approver | Expiry |
|---|---|---|---|---|
| **T0** | Auto | logs, describe, restart 1 pod (non-prod), GET-only | — | — |
| **T1** | Auto + FYI | restart 1 deploy (non-prod), HPA bump, scale-up non-prod | FYI card after-the-fact | — |
| **T2** | Approve | NetworkPolicy / ConfigMap patch, image rollback (single ns) | Namespace owner | 4h |
| **T3** | Approve (senior) | node cordon/drain, cluster-wide policy, ingress / Istio change | Platform on-call | 1h |
| **T4** | Never auto → ticket | node delete, PV delete, RBAC change, secret rotation, control-plane | Change ticket + CAB | n/a |

The ConfigMap (`remediation-tier-mapping`) is the source of truth. Starter
shape:

```yaml
rules:
  - match: { verb: "restart",   scope: "pod",     env: "non-prod" }
    tier: T0
  - match: { verb: "restart",   scope: "deploy",  env: "non-prod" }
    tier: T1
  - match: { verb: "apply",     kind: "NetworkPolicy" }
    tier: T2
  - match: { verb: "patch",     kind: "ConfigMap" }
    tier: T2
  - match: { verb: "rollback",  kind: "Deployment" }
    tier: T2
  - match: { verb: "cordon|drain", scope: "node" }
    tier: T3
  - match: { kind: "Gateway|VirtualService|AuthorizationPolicy" }
    tier: T3
  - match: { verb: "delete",    kind: "Node|PersistentVolume" }
    tier: T4
  - match: { kind: "ClusterRole|ClusterRoleBinding|Role|RoleBinding" }
    tier: T4
  - match: { kind: "Secret",    verb: "rotate|create|update" }
    tier: T4
default: T4   # fail-safe: unknown action → ticket, not approve
```

`classify-tier` walks the rules in order; the agent's `proposed_tier` is only
used as a tie-breaker when no rule matches **and** is bounded — agent can
never *lower* the tier the ConfigMap returned.

## 3. Use cases — same primitive, different "execute" step

Ranked by ROI for a Kubernetes platform.

### 3.1 GitOps merge approval (highest leverage)

The agent opens an MR/PR with the proposed manifest change instead of running
kubectl. Bot card shows the diff. Approve = `glab mr merge` / `gh pr merge`.
The change reaches the cluster via your existing ArgoCD/Flux reconcile.

```
triage → generate manifest patch → open MR (draft)
       → approval gate (diff in card)
       → merge MR → ArgoCD syncs → verify
```

Why it's the right next step: T3 actions become *safer* than T2 kubectl
because the audit trail is the git history and the rollback is `git revert`.

### 3.2 Break-glass / JIT cluster access

Engineer requests temporary cluster-admin during a P1.

```
request → approval gate (who, namespace, duration, reason)
        → create RoleBinding with TTL annotation
        → start ttl-controller timer → revoke at expiry
        → audit log to SIEM
```

Default deny, time-boxed grant, full audit. Replaces the "Slack the SRE lead
for kubeconfig" anti-pattern.

### 3.3 Capacity / cost actions

Cost-impacting changes need a different approver than SRE.

- AKS node pool scale-out above N nodes
- SKU upgrade (D4s → D8s)
- PVC expansion above threshold
- Adding a new node pool

Approver group = FinOps or Platform owner, not on-call SRE.

### 3.4 Schema / data migrations

```
migration plan → dry-run → diff → approval gate
              → apply → verify row counts / consumers
              → post outcome
```

Particularly useful for stateful workloads (Postgres, MongoDB) where the
"plan" output of a migration tool is reviewable but the apply is destructive.

### 3.5 Chaos / failure injection

Approval gate before chaos experiments in shared environments. Card shows
target, duration, expected steady-state hypothesis.

### 3.6 Secret rotation

```
detect rotation due → generate new secret → propose
                   → approval gate
                   → write new secret → restart consumers in order
                   → verify each consumer healthy
                   → revoke old secret → post outcome
```

Gates the *rotation* event, not each consumer restart (one gate, multi-step
execute).

### 3.7 AKS upgrade / node image rotation

Multi-stage rollout where each stage has different blast radius — this is
the one case where *multiple* gates are justified.

```
plan upgrade → approval (gate 1: plan)
            → upgrade control plane → verify
            → upgrade pool 1 (non-prod) → verify → approval (gate 2: prod ok?)
            → upgrade pool 2 (prod canary) → verify → approval (gate 3: full?)
            → upgrade remaining pools → verify
            → post outcome
```

### 3.8 Namespace decommission

The reverse of onboarding. Lists everything that will be destroyed (PVCs,
secrets, configmaps, RBAC). Approve = run the destroy workflow.

### 3.9 Other candidates

| Use case | Trigger | Why HITL |
|---|---|---|
| Egress allow-list change | NetworkPolicy edit | Compliance / data-exfil risk |
| Image registry promotion (dev → prod) | Pipeline | Release governance |
| Cost spike auto-mitigation | Anomaly detection | Cap cost without surprising users |
| Certificate renewal failure | cert-manager event | Avoid 2am cert outages with audit |
| RBAC drift remediation | Kyverno / OPA finding | Policy says "fix"; human says "now" |
| Quota uplift requests | ResourceQuota hit | Self-service + governance |

## 4. Anti-patterns to avoid

| Anti-pattern | What goes wrong | Fix |
|---|---|---|
| Approval gate inside the diagnostic phase | Pages humans for read-only ops | Gate only mutations |
| Per-step approval for multi-step plans | Approval fatigue → rubber-stamps | One gate, plan-level |
| Letting the agent set its own tier | LLM hallucination → privilege escalation | ConfigMap-driven, agent can only propose |
| Same approver group for T2 and T3 | T3 changes get same scrutiny as T2 | Different groups, different expiries |
| 24h expiry for everything | Stale approvals get rubber-stamped | Tier-specific expiries (4h / 1h / 15m) |
| No outcome card | Approver never learns if their decision worked | Always post outcome FYI to the same channel |
| Card includes secrets / pod logs | Information disclosure | Card = high-level; "view in Argo" link for detail |
| Reject = workflow dies forever | Wastes triage work; alert just refires | Document re-triage path; capture reject reason |

## 5. Open product questions

Decide these before rolling beyond the first 1-2 use cases:

1. **Approver group resolution.** Static per-tier? Per-namespace owner via
   label? Per-team via OnCallSchedule? Likely a mix; start with per-tier
   static and add namespace-owner override later.

2. **Break-glass override.** P1 at 2am needs a path. Add `x-break-glass: true`
   header that triggers a different approver group + extra audit.

3. **Reject-with-reason → re-triage loop?** Today reject = die. Optional
   richer flow: reject with reason → triage agent re-plans → new approval.
   Defer until the cost of rejected workflows is measurable.

4. **Approval analytics.** Track approve/reject ratio per tier per namespace.
   If T2 approve rate is 99%, those rules belong in T1. Quarterly review.

5. **Audit retention.** How long do approval records live, where, and who
   can query them? Align with bank's change-record retention (likely 7y).

## 6. Rollout order

1. **Triage gate (T2 only).** One workflow, one tier, real Teams bot. Prove
   the loop end-to-end with low blast radius.
2. **Add T3.** Same workflow, senior approver group, shorter expiry.
3. **GitOps merge gate.** Different *execute* step, same primitive. Highest
   leverage second use case.
4. **Break-glass.** Different trigger entirely; reuses bot + sensor.
5. **Everything else** as demand emerges. Each new use case = one new
   WorkflowTemplate referencing the same `request-approval` /
   `wait-for-approval` templates.

## 7. Files to add for the next steps

| Need | File | Status |
|---|---|---|
| Tier-mapping ConfigMap with real rules | `tier-mapping-configmap.yaml` | TODO |
| GitOps merge variant of approval template | `workflow-gitops-merge-template.yaml` | TODO |
| Break-glass workflow | `workflow-breakglass-template.yaml` | TODO |
| Outcome FYI card sender | `templates/post-outcome.yaml` | TODO |
| Approver-group ConfigMap | `approver-groups-configmap.yaml` | TODO |
