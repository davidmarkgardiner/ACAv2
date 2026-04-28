<!--
Name: UK8S Cluster Certification V2 — KAgent Triage Integration
Description: Implement structured handover from cert workflow to KAgent for automated triage of certification results.
Title: "Implement UK8S Certification V2 with KAgent SRE Triage Handover"
Labels: ~"argo-workflows" ~"kagent" ~"certification" ~"kro" ~"enhancement" ~"sre"
Assignees:
-->

## 📝 Description
The current UK8S cluster certification workflow (`uk8scertification.kro.run` v1) runs on a weekly cron and prints PASS/FAIL output to pod stdout. There is no automated analysis of failures and no machine-readable handoff to downstream systems. This issue tracks rolling out **V2**, which captures structured per-task results, hands them to the KAgent `sre-triage-agent` over A2A, and exposes a strict-schema severity verdict as Argo output parameters that downstream consumers (Teams notifier, GitHub issue bot, exit hook, etc.) can branch on.

V1 stays untouched. V2 is opt-in per cluster via a new RGD: `uk8scertificationv2.kro.run`.

## 🎯 Problem Statement
- Certification stdout dies with the pod — no historical record, no structured signal.
- A green/red verdict alone is insufficient — when a cert fails, an SRE has to manually open the workflow, scroll through 9 task logs, and identify which subsystem broke.
- No connection between the existing certification system and the KAgent triage agents we've already invested in (`sre-triage-agent`, `sre-remediation-agent`).
- Without a structured verdict on the workflow object itself, alert routing has to scrape pod logs — fragile and AlertManager-unfriendly.

## 💡 Proposed Solution
Sibling RGD (`uk8s-certification-v2.yaml`) that:

1. Creates a per-workflow `ConfigMap` (ownerReference = Workflow → auto-GC, no Minio/PVC dependency).
2. Each existing validation task appends one `kubectl patch configmap` line emitting `passed=N failed=N warnings=N`.
3. New `aggregate-certification` reads the ConfigMap, sums totals, emits a structured JSON `report` output parameter.
4. New `agent-triage` task POSTs the report to KAgent A2A (`/api/a2a/kagent/sre-triage-agent/`), parses a strict-schema response, emits `severity` and `verdict` output parameters.
5. Optional `gate-on-critical` task fails the workflow when the agent returns CRITICAL — gated behind `failOnCritical` flag (default false).

The handover is the thing — once `severity` is an Argo output parameter, every downstream system (Teams notifier, GitOps issue bot, dashboard) is one DAG task or one Argo Events Sensor away.

## 🏗 Architecture

```
[validation tasks (×7)]
   └─► kubectl patch configmap cert-results-<wf> (one line per task)

[aggregate-results]
   ├─► reads ConfigMap → sums passed/failed
   └─► outputs.parameters.report (structured JSON)

[agent-triage]
   ├─► jq -n builds A2A payload (rawfile-safe)
   ├─► POST http://kagent.kagent.svc.cluster.local/api/a2a/kagent/sre-triage-agent/
   ├─► parses result.artifacts[0].parts[0].text → strict schema
   │     {severity, blast_radius, failed_checks[], first_remediation}
   └─► outputs.parameters.severity / verdict

[downstream consumers]
   └─► branch on {{tasks.agent-triage.outputs.parameters.severity}}
```

## ✅ Implementation Plan / Tasks

### Phase 1: RGD + WorkflowTemplate (DONE — needs review)
- [x] Create `uk8s-certification-v2.yaml` with new RGD `uk8scertificationv2.kro.run`
- [x] Add schema field `agentAnalysis` (enabled, kagentService, kagentPort, agentName, timeoutSeconds, failOnCritical)
- [x] Add `init-results-configmap` task with ownerReference to Workflow
- [x] Add `kubectl patch configmap` line to each of 7 validation tasks
- [x] Refactor `aggregate-certification` to read ConfigMap, emit `report` output param
- [x] Add `agent-triage` task with strict-schema prompt and JSON-only verdict extraction
- [x] Add `gate-on-critical` task gated by `failOnCritical` + `severity == CRITICAL`
- [ ] **REVIEW:** code review of `uk8s-certification-v2.yaml`
- [ ] **REVIEW:** confirm KRO CEL expressions render correctly in target cluster

### Phase 2: RBAC & Networking
- [ ] Verify `argo-workflow-executor` ServiceAccount has `patch` verb on ConfigMaps in `argo` namespace (one-line Role amendment if not)
- [ ] Verify `argo-workflow-executor` has `get` verb on Workflows (needed to resolve UID for ownerReference)
- [ ] Confirm `kagent.kagent.svc.cluster.local` is reachable from a pod in `argo` namespace (NetworkPolicy or Cilium policy may need an allow rule)
- [ ] Add NetworkPolicy egress rule from `argo` → `kagent` namespace if cluster enforces deny-by-default

### Phase 3: Agent Validation
- [ ] Confirm `sre-triage-agent` is deployed in `kagent` namespace and responds to A2A `/api/a2a/kagent/sre-triage-agent/`
- [ ] Tune the system prompt of `sre-triage-agent` (in `kagent/sre-triage-agent.yaml`) so it reliably emits strict-schema JSON when given a UK8S cert report — based on test runs from Phase 4
- [ ] Add a regression test scenario for cert-style inputs to `COMPARISON-TEST-SCENARIOS.md`

### Phase 4: End-to-End Smoke Test
- [ ] Apply RGD to `kind-argo-workflow` (or whichever management cluster has KAgent)
- [ ] Create a `UK8SCertificationV2` instance pointing at a known-good test AKS cluster
- [ ] Trigger one workflow manually, confirm:
  - [ ] ConfigMap `cert-results-<wf>` is created with ownerReference
  - [ ] All 7 validation tasks patch the ConfigMap
  - [ ] `aggregate-results` produces valid JSON in its output parameter
  - [ ] `agent-triage` returns a parseable verdict (severity ∈ {INFO, WARNING, CRITICAL})
  - [ ] Workflow succeeds when severity != CRITICAL or when `failOnCritical=false`
  - [ ] ConfigMap is GC'd within 60s of deleting the Workflow
- [ ] Repeat against a deliberately-broken cluster (delete a flux deployment) → verify severity escalates and `failed_checks` includes `validate-flux`

### Phase 5: Failure-Mode Coverage
- [ ] Verify `AGENT_UNAVAILABLE` path: scale `kagent` deployment to 0, trigger cert → severity=AGENT_UNAVAILABLE, workflow still succeeds
- [ ] Verify `PARSE_ERROR` path: temporarily replace agent prompt with one that returns prose-only → severity=PARSE_ERROR, raw response in pod logs
- [ ] Confirm cert pass/fail signal is unchanged regardless of agent state (agent is advisory, not authoritative)

### Phase 6: Downstream Consumer (Teams)
- [ ] Decide: inline DAG task vs. separate Argo Events Sensor watching for completed workflows with `kro.run/version=v2` label
- [ ] Implement chosen path — read `severity` and `verdict` outputs, format Teams card
- [ ] Add Teams webhook secret to cluster (`teams-webhook-cert-v2`)
- [ ] Configure card to suppress on `severity ∈ {INFO, AGENT_UNAVAILABLE}` to avoid noise on healthy runs

### Phase 7: Rollout
- [ ] Pilot V2 alongside V1 on 1 dev cluster for 2 weeks
- [ ] Compare verdicts vs. manual SRE assessment of weekly runs
- [ ] If verdict accuracy ≥ 90%, enable on staging clusters
- [ ] After 1 month of staging, flip default `agentAnalysis.enabled` to true on all new clusters
- [ ] Once stable, deprecate V1 RGD (separate ticket)

## 🏁 Acceptance Criteria
- [ ] `uk8scertificationv2.kro.run` RGD shows `state: Active` in target cluster
- [ ] Workflow run against a healthy cluster returns severity=INFO end-to-end
- [ ] Workflow run against a broken cluster returns severity ∈ {WARNING, CRITICAL} with sensible `blast_radius`
- [ ] ConfigMap auto-GC verified
- [ ] Cert verdict (PASS/FAIL counts) unaffected by agent availability
- [ ] V2 runs in parallel with V1 on at least one dev cluster for ≥ 2 weeks without incidents
- [ ] Documentation in `UK8S-CERTIFICATION-V2.md` reflects any deviations discovered during rollout

## 🔍 Risk Register

| Risk | Mitigation |
|---|---|
| KAgent prompt drift causes verdict regressions | Pin agent CRD version; add regression scenarios to test suite before each agent bump |
| Qwen 14B hallucinates cluster name in response | Already mitigated via `CRITICAL: cluster name is exactly "X"` prompt anchoring (per memory note) |
| ConfigMap not GC'd if workflow UID lookup fails | `init-results-configmap` already falls back to no ownerRef and logs warning; add cleanup CronJob as belt-and-braces |
| Agent timeout under load blocks cert workflow | `agent-triage` is `set +e` with `--max-time` and never fails the workflow |
| RBAC gap on Workflow GET prevents UID resolution | Phase 2 task; one-line Role amendment |
| KRO CEL expression `${... ? 'true' : 'false'}` syntax breakage | Same pattern used by V1 `autoTrigger`; if it works there, works here |

## 🔗 References
- Implementation: [`uk8s-certification-v2.yaml`](./uk8s-certification-v2.yaml)
- Documentation: [`UK8S-CERTIFICATION-V2.md`](./UK8S-CERTIFICATION-V2.md)
- V1 baseline: [`uk8s-certification.yaml`](./uk8s-certification.yaml)
- KAgent A2A protocol notes: see project memory `KAgent API (Mar 2026)`
- Triage agent CRD: `kagent/sre-triage-agent.yaml` (ai-platform repo)
- Comparison scenarios: `COMPARISON-TEST-SCENARIOS.md`

## 📊 Estimated Effort
- Phase 1: ✅ done
- Phase 2 (RBAC/network): 0.5 day
- Phase 3 (agent prompt tuning): 1 day
- Phase 4 (smoke test): 1 day
- Phase 5 (failure modes): 0.5 day
- Phase 6 (Teams): 1–2 days (depending on Sensor vs inline)
- Phase 7 (rollout): 4–6 weeks elapsed, ~2 days work

**Total active work:** ~6 engineer-days. **Total elapsed:** 6–8 weeks including soak.

/label ~"argo-workflows" ~"kagent" ~"certification" ~"kro" ~"enhancement" ~"sre"
