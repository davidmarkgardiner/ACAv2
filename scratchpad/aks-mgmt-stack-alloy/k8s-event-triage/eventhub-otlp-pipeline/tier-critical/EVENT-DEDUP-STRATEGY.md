# Event Deduplication Strategy

Three layers prevent duplicate K8s events from triggering redundant triage workflows.

```
K8s Event → [Layer 1: Alloy] → Event Hub → [Layer 2: Sensor] → [Layer 3: Argo memoize] → KAgent + GitLab + Mattermost
              drop count>1        rate limit 5/min         24h content-aware dedup
              rate limit 10/s
```

---

## Layer 1: Alloy (Workload Cluster)

**What it catches:** Same K8s event UID incrementing its count (e.g. CrashLoopBackOff firing repeatedly on the same pod).

**What it misses:** Pod deleted and recreated = new event UID, count resets to 1.

**File:** `workload-cluster/02-alloy-config.yaml`

### Drop repeated events (lines 90-94)

```yaml
stage.drop {
  source              = "event_count"
  expression          = "^[2-9]|^[1-9][0-9]+"
  drop_counter_reason = "duplicate_event"
}
```

K8s increments `event.count` each time the same event fires. This regex drops any event where count >= 2, so only the first occurrence (`count: 1`) is forwarded.

### Rate limit (lines 103-107)

```yaml
stage.limit {
  rate  = 10
  burst = 25
  drop  = true
}
```

Hard cap at 10 events/second sustained, 25 burst. Excess events are silently dropped. Prevents flooding Event Hub during event storms.

---

## Layer 2: Argo Events Sensor (Management Cluster)

**What it catches:** Workflow creation storms — caps how many workflows can be created per minute regardless of content.

**What it misses:** Not content-aware. 5 different pods each crashing once all get through. 5 of the same pod also all get through.

**File:** `tier-critical/sensor.yaml`

### Rate limit (lines 31-33)

```yaml
rateLimit:
  requestsPerUnit: 5
  unit: Minute
```

Maximum 5 workflow triggers per minute from this sensor. Any events beyond that are dropped by the sensor controller.

---

## Layer 3: Argo Workflows memoize (Management Cluster)

**What it catches:** Same reason + same namespace + same cluster within 24 hours, regardless of which pod triggered it. OOMKilled on pod-abc and pod-xyz in the same namespace = one alert.

**What it misses:** Nothing — this is the final dedup net.

**File:** `tier-critical/workflow-template.yaml`

### Memoize block on `investigate-and-report` template (lines 315-320)

```yaml
- name: investigate-and-report
  memoize:
    key: "{{inputs.parameters.cluster}}-{{inputs.parameters.object-namespace}}-{{inputs.parameters.event-reason}}"
    maxAge: "24h"
    cache:
      configMap:
        name: event-dedup-cache
```

The cache key is `{cluster}-{namespace}-{reason}`. On first occurrence, the full pipeline runs (KAgent analysis, GitLab issue, Mattermost notification) and the result is cached in ConfigMap `event-dedup-cache`. Any identical event within 24h is skipped — the step completes instantly without running. This means OOMKilled on different pods in the same namespace only triggers one alert per 24h window.

### What is NOT deduped (by design)

| Scenario | Deduped? | Why |
|----------|----------|-----|
| Same namespace, same reason, within 24h | Yes | Same cache key |
| Same namespace, same reason, after 24h | No | Cache entry expired |
| Same reason, different pod, same namespace | Yes | Pod name not in key |
| Same namespace, different reason | No | Different `event-reason` in key |
| Same reason, same namespace, different cluster | No | Different `cluster` in key |

### RBAC requirement

The Argo workflow controller (`system:serviceaccount:argo:argo`) needs ConfigMap `create` + `update` permissions for memoize. This is provided by a supplemental ClusterRole:

**File:** `00-controller-rbac-patch.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-memoize-configmaps
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["create", "update"]
```

This is separate from the Helm-managed `argo-cluster-role` so it won't be overwritten by Argo upgrades.

### Cache inspection

```bash
# View cached dedup keys
kubectl get configmap event-dedup-cache -n argo -o yaml

# Clear cache (forces fresh investigation on next event)
kubectl delete configmap event-dedup-cache -n argo --ignore-not-found
```

---

## Summary

| Layer | File | Lines | Mechanism | Scope |
|-------|------|-------|-----------|-------|
| **1. Alloy** | `workload-cluster/02-alloy-config.yaml` | 90-94, 103-107 | `stage.drop` (count>1) + `stage.limit` (10/s) | Per-UID, rate-based |
| **2. Sensor** | `tier-critical/sensor.yaml` | 31-33 | `rateLimit: 5/min` | Rate-based, not content-aware |
| **3. Argo memoize** | `tier-critical/workflow-template.yaml` | 315-320 | ConfigMap cache, 24h TTL | Content-aware (reason+ns+cluster) |
| **RBAC** | `00-controller-rbac-patch.yaml` | — | Supplemental ClusterRole | Controller ConfigMap access |
