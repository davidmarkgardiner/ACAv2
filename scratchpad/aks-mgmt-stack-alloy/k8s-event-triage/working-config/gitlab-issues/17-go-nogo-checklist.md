<!--
Labels: release, priority::high, k8s-event-triage
Milestone: Go-Live
Assignee:
Depends on: #1-#12
-->

# Production go/no-go checklist and cutover

## Context

Final checklist before promoting the k8s-event-triage pipeline to production. All previous tickets must be completed first.

## Pre-Deployment Checklist

```
INFRASTRUCTURE
[ ] Workflow controller manages argo-events namespace (#3)
[ ] EventBus 3/3 replicas healthy (#4)
[ ] Ollama running, qwen2.5:7b model available (#5)
[ ] All secrets present with exact key names (#8)
[ ] All images mirrored to private registry (#12)

PIPELINE
[ ] WorkflowTemplate v2 tested with manual submission (#6)
[ ] Sensor rate limit set to 30/min (#7)
[ ] Alloy watching all application namespaces (#9)
[ ] No forbidden namespaces in Alloy config (#9)

OBSERVABILITY
[ ] Prometheus alerts configured (#10)
[ ] Azure Monitor alerts configured (#10)
[ ] Grafana dashboard deployed (#10)
[ ] Health check script passes (#10)

TESTING
[ ] Smoke test passes end-to-end (#11)
[ ] At least 1 workflow reaches Succeeded state
[ ] Gitea issue created for test warning event
[ ] Mattermost notification received for test event
[ ] No workflow failures in 15-minute observation window

KAGENT (if applicable)
[ ] cert-manager agent tested and signed off (#14)
[ ] external-dns agent tested and signed off (#15)
[ ] ingress-nginx agent tested and signed off (#16)

DOCUMENTATION
[ ] Old configs cleaned up (#2)
[ ] HANDOVER.md up to date
[ ] GOTCHAS.md up to date
[ ] AGENT-ROSTER.md up to date
```

## Cutover Procedure

1. Final smoke test on dev cluster
2. Apply all manifests to production cluster (in deployment order from PRODUCTION-PLAN.md)
3. Monitor for 30 minutes — watch workflow success rate
4. If any failures: execute rollback per PRODUCTION-PLAN.md Section 5
5. Announce to team

## Rollback Triggers

Immediately rollback if:
- Workflow failure rate > 20% in first 30 minutes
- EventBus pod count < 2/3 for > 5 minutes
- Event Hub consumer lag > 5000 messages
- Ollama unresponsive for > 10 minutes
- Any feedback loop detected (argo-events namespace generating events that trigger workflows)

## Acceptance Criteria

- [ ] All checklist items green
- [ ] Pipeline running in production for 24h with < 5% failure rate
- [ ] At least one real K8s warning event triaged end-to-end
- [ ] Rollback procedure tested (at least scale-to-zero verified)
