<!--
Labels: infrastructure, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #6
-->

# Increase sensor rate limit from 5/min to 30/min

## Context

PoC rate limit of 5/min is too low for production volumes. A typical production cluster generates 200-500 events/hr across monitored namespaces. See `PRODUCTION-PLAN.md` Phase 4.

## Tasks

- [ ] Update sensor manifest: `requestsPerUnit: 30`, `unit: Minute`
- [ ] Apply updated sensor
- [ ] Monitor for rate-limited drops: `kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=100 | grep -c "rate limit"`
- [ ] If > 5% drops, consider increasing further

## Rollback

```bash
kubectl patch sensor k8s-event-triage -n argo-events --type=merge \
  -p '{"spec":{"triggers":[{"template":{"name":"triage-workflow","rateLimit":{"unit":"Minute","requestsPerUnit":5}}}]}}'
```

## Acceptance Criteria

- [ ] Sensor rate limit set to 30/min
- [ ] No workflow storm (EventBus handles the load)
- [ ] Rate-limited drop rate < 5%
