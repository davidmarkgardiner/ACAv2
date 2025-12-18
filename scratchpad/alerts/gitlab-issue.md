Here's a GitLab issue for you:

---

**Title:** Implement Actionable Observability & Alerting for Platform Engineering

---

**Description:**

## Background

Observability and alerting for this platform has been a stated deliverable for over 12 months. Significant investment has been made — both financially and in headcount (several engineers assigned to this work).

**To date, Engineering has no functional alerting in place.**

We only discover issues when engineers manually encounter them while doing unrelated work. This is not sustainable and is actively impacting velocity, release quality, and user trust.

## Current State

- **No alerts are being routed to Engineering**
- When alerts are turned on, we're told we'll be flooded with noise — which will just be ignored
- There is no targeted alerting for critical platform components
- Users are reporting bugs in production and development before we're aware of them
- Clusters are going down with no visibility — this morning, 2 out of 3 clusters I tried were broken with no alerts fired

## What's Missing

This work should have been completed months ago. The following gaps exist:

1. **No alerting to Engineering teams** — we are operating blind
2. **No tuning or noise reduction** — the current setup is unusable if enabled
3. **No targeted alerts for critical applications** — Helm charts, core platform pods, ingress health
4. **No proactive health checks** — we should know clusters are unhealthy before users do
5. **No accountability or ownership** — issues go unnoticed and unresolved

## Requirements

### Phase 1: Critical Alerting (Immediate Priority)

- [ ] **Pod health alerts** — Alert when any critical platform pods (Helm chart deployments) are unhealthy, crashlooping, or not ready
- [ ] **Ingress / HTTPS health checks** — Verify HTTPS is serving correctly on each cluster, which also validates DNS and cert-manager are functioning
- [ ] **Cluster health baseline** — Basic alerting that gives confidence our clusters are healthy

### Phase 2: Alerting Infrastructure

- [ ] **Targeted routing** — Alerts go to the right teams, not a shared inbox
- [ ] **Noise reduction** — Alerts are tuned to be actionable, not overwhelming
- [ ] **Clear ownership** — Defined accountability for responding to and resolving alerts

### Phase 3: Continuous Improvement

- [ ] **Feedback loop** — When incidents occur, review: Was an alert fired? Was it picked up? If not, fill the gap
- [ ] **Living documentation** — This issue (or a linked runbook) should be actively updated as we identify gaps
- [ ] **Coverage expansion** — Add alerting for additional components as we learn what breaks

## Acceptance Criteria

- [ ] Engineering receives actionable alerts for critical platform components
- [ ] Alerts are tuned — no alert fatigue, no noise
- [ ] We know about cluster/pod/ingress issues before users report them
- [ ] Clear process exists for reviewing incidents and improving alert coverage

## Notes

This has been raised repeatedly over the past 12 months via emails, Teams messages, and direct conversations. Requirements have been shared multiple times. It is unclear why this has not been delivered or why there has been no accountability for the lack of progress.
