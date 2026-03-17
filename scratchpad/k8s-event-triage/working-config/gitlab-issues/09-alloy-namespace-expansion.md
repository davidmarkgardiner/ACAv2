<!--
Labels: infrastructure, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #6, #7
-->

# Expand Alloy to watch additional application namespaces

## Context

Currently Alloy watches a limited set of namespaces. For production, expand to cover all application namespaces. See `PRODUCTION-PLAN.md` Phase 5.

## CRITICAL: Forbidden Namespaces

**NEVER add these** (causes feedback loops, event storms, cost spikes):
- `argo`
- `argo-events`
- `monitoring`
- `kube-system`
- `flux-system`
- `gatekeeper-system`

## Tasks

- [ ] Identify all application namespaces to monitor
- [ ] Update Alloy ConfigMap `namespaces` list
- [ ] Review against forbidden list (double-check)
- [ ] Rollout restart Alloy: `kubectl rollout restart deployment/alloy -n monitoring`
- [ ] Verify events from new namespaces arrive in Event Hub
- [ ] Verify workflows fire for events from new namespaces

## Acceptance Criteria

- [ ] Alloy watches all application namespaces
- [ ] No forbidden namespaces in the watch list
- [ ] Events from newly-added namespaces trigger workflows
