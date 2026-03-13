<!--
Labels: infrastructure, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #3
-->

# Resize EventBus from 1 to 3 replicas (HA)

## Context

Current PoC runs a single-replica JetStream EventBus. Production needs 3 replicas for quorum-based HA. See `PRODUCTION-PLAN.md` Phase 2 for full procedure.

## Tasks

- [ ] Schedule 5-minute maintenance window (events retained in Event Hub during downtime)
- [ ] Scale EventSource + Sensor to 0
- [ ] Delete existing EventBus and PVCs
- [ ] Apply 3-replica EventBus manifest (20Gi storage, JetStream R3)
- [ ] Wait for all 3 pods to be ready
- [ ] Scale EventSource + Sensor back to 1
- [ ] Verify events flowing through pipeline

## Rollback

```bash
# Revert to 1-replica if issues
kubectl scale deployment -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage --replicas=0
kubectl delete eventbus default -n argo-events
kubectl delete pvc -n argo-events -l controller=eventbus-controller
kubectl apply -f 04-eventbus.yaml  # original 1-replica
kubectl scale deployment -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage --replicas=1
```

## Acceptance Criteria

- [ ] `kubectl get pods -n argo-events -l controller=eventbus-controller` shows 3/3 Ready
- [ ] EventSource reconnects and consumes from Event Hub
- [ ] Sensor fires workflows successfully
