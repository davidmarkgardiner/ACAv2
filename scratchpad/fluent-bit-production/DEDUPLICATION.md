# Event Deduplication Strategies

Prevent duplicate workflows, GitLab issues, and notifications when Kubernetes generates multiple events for the same problem.

## The Problem

When a pod crashes, Kubernetes generates **multiple events** for the same issue:

```
10:00:01  BackOff           pod/my-app  Back-off restarting failed container
10:00:05  BackOff           pod/my-app  Back-off restarting failed container
10:00:15  CrashLoopBackOff  pod/my-app  Back-off restarting failed container
10:00:45  CrashLoopBackOff  pod/my-app  Back-off restarting failed container
10:01:15  CrashLoopBackOff  pod/my-app  Back-off restarting failed container
```

Without deduplication:
- **5 Holmes AI investigations** for the same pod
- **5 GitLab issues** created
- **5 Mattermost notifications**
- Wasted API costs and alert fatigue

## Deduplication Options

| Option | Complexity | Location | Best For |
|--------|------------|----------|----------|
| **1. Workflow Mutex** | Low | Workflow | Preventing concurrent duplicates |
| **2. Fluent Bit Throttle** | Low | Source | Reducing volume at source |
| **3. Sensor Rate Limit** | Low | Sensor | Global rate limiting |
| **4. Check-and-Skip** | Medium | Workflow | Time-based deduplication |
| **5. External Store** | High | External | Advanced correlation |

---

## Option 1: Workflow Mutex (Recommended)

Use Argo Workflows' built-in synchronization to ensure only ONE workflow runs per unique issue.

### How It Works

```
Event 1 (CrashLoopBackOff, my-pod) → Workflow 1 RUNS (acquires mutex)
Event 2 (CrashLoopBackOff, my-pod) → Workflow 2 WAITS (mutex held)
Event 3 (CrashLoopBackOff, my-pod) → Workflow 3 WAITS (mutex held)
Workflow 1 completes              → Mutex released
Workflow 2 RUNS                   → (or can be configured to skip)
```

### Implementation

Add to workflow template:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: multi-cluster-triage
spec:
  synchronization:
    mutex:
      # Mutex name based on dedupe-key parameter
      name: "triage-{{workflow.parameters.dedupe-key}}"

  arguments:
    parameters:
      - name: dedupe-key
        description: "Unique key: namespace-name-kind-reason"
```

### Dedupe Key Format

The sensor generates a dedupe key from the event:

```yaml
# In sensor parameters
- src:
    dependencyName: any-k8s-event
    dataTemplate: |
      {{- $d := (b64dec .Input.body) | mustFromJson -}}
      {{ printf "%s-%s-%s-%s"
         (dig "involvedObject" "namespace" "x" $d)
         (dig "involvedObject" "name" "x" $d)
         (dig "involvedObject" "kind" "x" $d)
         (dig "reason" "x" $d) }}
  dest: spec.arguments.parameters.0.value
```

**Example keys**:
- `monitoring-nginx-pod-abc123-Pod-CrashLoopBackOff`
- `production-api-deployment-xyz-Deployment-FailedCreate`
- `default-redis-StatefulSet-OOMKilled`

### Pros/Cons

| Pros | Cons |
|------|------|
| Built into Argo Workflows | Workflows queue up (don't skip) |
| No external dependencies | Mutex released on completion only |
| Simple to implement | Doesn't prevent workflow creation |

---

## Option 2: Fluent Bit Throttle (Recommended)

Deduplicate at the **source** before events reach EventHub.

### How It Works

```
Fluent Bit receives 10 CrashLoopBackOff events in 60s
         ↓
Throttle filter: 1 event per 60s per unique key
         ↓
Only 1 event sent to EventHub
```

### Implementation

Add to Fluent Bit `filters.conf`:

```ini
# Throttle: Max 1 event per resource per minute
[FILTER]
    Name                 throttle
    Match                kube.events.*
    Rate                 1
    Window               60
    Interval             60s
    Print_Status         true
```

### Advanced: Throttle by Resource

```ini
# Use Lua filter for field-based throttling
[FILTER]
    Name    lua
    Match   kube.events.*
    script  /fluent-bit/scripts/dedupe.lua
    call    dedupe_by_resource
```

`dedupe.lua`:
```lua
-- Simple in-memory deduplication (resets on pod restart)
local cache = {}
local TTL = 300  -- 5 minutes

function dedupe_by_resource(tag, timestamp, record)
    local key = string.format("%s-%s-%s-%s",
        record["involvedObject"]["namespace"] or "unknown",
        record["involvedObject"]["name"] or "unknown",
        record["involvedObject"]["kind"] or "unknown",
        record["reason"] or "unknown"
    )

    local now = os.time()
    if cache[key] and (now - cache[key]) < TTL then
        -- Skip duplicate
        return -1, 0, 0
    end

    cache[key] = now
    return 1, timestamp, record
end
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Reduces EventHub costs | State lost on pod restart |
| Prevents workflows entirely | Complex Lua for advanced cases |
| Filters at source | Limited to time-based |

---

## Option 3: Sensor Rate Limit

Global rate limiting at the sensor level.

### Implementation

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: eventhub-simple
spec:
  triggers:
    - template:
        name: triage-event
        conditions: "any-k8s-event"

        # Rate limit: max 3 workflows per minute (global)
        rateLimit:
          requestsPerUnit: 3
          unit: Minute
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Simple configuration | Global limit, not per-resource |
| Built into Argo Events | May miss important events |
| No code changes | Doesn't prevent duplicates |

---

## Option 4: Check-and-Skip Pattern

Add a workflow step that checks for recent triages before proceeding.

### Implementation

```yaml
templates:
  - name: main
    steps:
      - - name: check-duplicate
          template: check-recent-triage
      - - name: triage
          template: run-triage
          when: "{{steps.check-duplicate.outputs.result}} == 'PROCEED'"

  - name: check-recent-triage
    inputs:
      parameters:
        - name: dedupe-key
    script:
      image: badouralix/curl-jq:latest
      command: [sh]
      env:
        - name: GITLAB_TOKEN
          valueFrom:
            secretKeyRef:
              name: gitlab-mcp-secret
              key: GITLAB_PERSONAL_ACCESS_TOKEN
      source: |
        DEDUPE_KEY="{{inputs.parameters.dedupe-key}}"
        PROJECT_ID="your-project-id"
        GITLAB_URL="https://gitlab.com"

        # Check for issues created in last hour with this key in title
        ONE_HOUR_AGO=$(date -d '1 hour ago' -Iseconds 2>/dev/null || date -v-1H -Iseconds)

        RECENT=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
          "$GITLAB_URL/api/v4/projects/$PROJECT_ID/issues?search=$DEDUPE_KEY&created_after=$ONE_HOUR_AGO" \
          | jq 'length')

        if [ "$RECENT" -gt 0 ]; then
          echo "SKIP"
        else
          echo "PROCEED"
        fi
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Time-based deduplication | Requires API calls |
| Checks actual GitLab state | Adds latency |
| Flexible logic | More complex workflow |

---

## Option 5: External Store (Redis/ConfigMap)

Use external storage to track processed events.

### Implementation with ConfigMap

```yaml
- name: check-and-record
  script:
    image: bitnami/kubectl:latest
    command: [sh]
    source: |
      DEDUPE_KEY="{{inputs.parameters.dedupe-key}}"
      CM_NAME="triage-dedupe-cache"
      NS="argo-events"

      # Check if key exists in ConfigMap
      EXISTING=$(kubectl get configmap $CM_NAME -n $NS -o jsonpath="{.data['$DEDUPE_KEY']}" 2>/dev/null)

      if [ -n "$EXISTING" ]; then
        # Check if within cooldown (1 hour = 3600 seconds)
        NOW=$(date +%s)
        AGE=$((NOW - EXISTING))
        if [ $AGE -lt 3600 ]; then
          echo "SKIP - Last triage ${AGE}s ago"
          exit 0
        fi
      fi

      # Record this triage
      kubectl patch configmap $CM_NAME -n $NS --type merge \
        -p "{\"data\":{\"$DEDUPE_KEY\":\"$(date +%s)\"}}" 2>/dev/null || \
      kubectl create configmap $CM_NAME -n $NS \
        --from-literal="$DEDUPE_KEY=$(date +%s)"

      echo "PROCEED"
```

### Pros/Cons

| Pros | Cons |
|------|------|
| Persistent state | Requires RBAC for ConfigMap |
| Survives restarts | ConfigMap size limits |
| Flexible TTL | More infrastructure |

---

## Recommended Strategy

### Phase 1: Immediate (Low Effort)

1. **Add Workflow Mutex** - Prevents concurrent processing of same issue
2. **Add Sensor Rate Limit** - Global safety net (3/min)

```yaml
# Workflow template
spec:
  synchronization:
    mutex:
      name: "triage-{{workflow.parameters.dedupe-key}}"

# Sensor
spec:
  triggers:
    - template:
        rateLimit:
          requestsPerUnit: 3
          unit: Minute
```

### Phase 2: Short-term (Medium Effort)

3. **Add Fluent Bit Throttle** - Reduce EventHub volume

```ini
[FILTER]
    Name     throttle
    Match    kube.events.*
    Rate     1
    Window   60
```

### Phase 3: Long-term (Higher Effort)

4. **Implement Check-and-Skip** - Time-based deduplication against GitLab
5. **Consider Redis** - For multi-cluster correlation

---

## Deduplication Matrix

| Scenario | Mutex | Throttle | Rate Limit | Check-Skip |
|----------|-------|----------|------------|------------|
| Same pod, rapid events | ✅ Queues | ✅ Filters | ⚠️ Global | ✅ Skips |
| Same pod, 2 hours apart | ❌ Both run | ❌ Both sent | ❌ Both run | ✅ Skips |
| Different pods, same time | ✅ Parallel | ✅ Parallel | ⚠️ Limited | ✅ Parallel |
| Cluster restart flood | ⚠️ Queue buildup | ✅ Throttled | ✅ Limited | ✅ Skips |

---

## Files Reference

| File | Purpose |
|------|---------|
| `test-production/08-eventhub-sensor-simple.yaml` | Sensor with dedupe-key parameter |
| `test-production/02-workflow-template.yaml` | Workflow template (add mutex here) |
| `filter-profiles/*/fluent-bit-config.yaml` | Add throttle filter here |

---

## Monitoring Deduplication

```bash
# Check mutex contention
kubectl get workflows -n argo-events -o custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
MUTEX:.status.synchronization.mutex

# Count workflows per dedupe-key
kubectl get workflows -n argo-events -o json | \
  jq -r '.items[].spec.arguments.parameters[] | select(.name=="dedupe-key") | .value' | \
  sort | uniq -c | sort -rn | head -10

# Check Fluent Bit throttle stats
kubectl logs -n monitoring -l app=fluent-bit | grep -i throttle
```
