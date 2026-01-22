# Filter Profile Testing Results

## Test Environment

| Component | Value |
|-----------|-------|
| Cluster | `kind-argo-workflow` |
| Kubernetes Version | v1.35.0 |
| Fluent Bit Version | 3.2.10 |
| Test Date | 2026-01-21 |
| Profile Tested | `low-noise-test` |

---

## Test 1: Namespace Filtering

### Setup

**Whitelisted namespaces** (should pass filter):
- `default`
- `test-namespace`
- `monitoring`
- `holmesgpt`

**Excluded namespace** (should be filtered):
- `excluded-namespace`

### Test Commands

```bash
# Create test namespaces
kubectl create namespace test-namespace
kubectl create namespace excluded-namespace

# Generate events in whitelisted namespace
kubectl run filter-test-default --image=invalid-xyz -n default --restart=Never
kubectl run filter-test-ns --image=invalid-abc -n test-namespace --restart=Never

# Generate events in excluded namespace
kubectl run filter-test-excluded --image=invalid-xyz -n excluded-namespace --restart=Never
```

### Results

```
=== Namespace Distribution ===
  81 test-namespace      (whitelisted - CAPTURED)
  63 monitoring          (whitelisted - CAPTURED)
  56 default             (whitelisted - CAPTURED)
   0 excluded-namespace  (excluded - FILTERED OUT)
```

### Verdict: **PASS**

Namespace filtering works correctly:
- Events from whitelisted namespaces are captured
- Events from excluded namespaces are completely filtered out

---

## Test 2: Event Reason Filtering

### Filter Configuration

```ini
Regex reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted|BackOff|ImagePullBackOff|Failed|PolicyViolation)$
```

### Results

```
Captured event reasons:
  - PolicyViolation (from Kyverno policy checks)
  - Failed (image pull failures)
```

### Verdict: **PASS**

Only events with matching reasons are captured. Events with other reasons (like `Scheduled`, `Pulling`, etc.) are filtered out.

---

## Test 3: Event Type Filtering

### Filter Configuration

```ini
Regex type ^Warning$
```

### Evidence

All captured events have `type: "Warning"`. Normal events (type: "Normal") are filtered out.

### Verdict: **PASS**

---

## Test 4: Metadata Enrichment

### Filter Configuration

```ini
[FILTER]
    Name          modify
    Match         kube.events.*
    Add           cluster kind-argo-workflow
    Add           filter_profile low-noise-test
```

### Results

All captured events include:
- `"cluster": "kind-argo-workflow"`
- `"filter_profile": "low-noise-test"`

### Verdict: **PASS**

---

## Rate Limiting Behavior

### IMPORTANT: Sensor Rate Limit Test Results

**TESTED: 2026-01-21** - Sensor `rateLimit` did NOT work as documented!

| Test | Rate Limit | Requests Sent | Workflows Created | Expected |
|------|------------|---------------|-------------------|----------|
| Test 1 | 2/minute | 5 rapid | **5** | 2 |
| Test 2 | 1/minute | 3 (2s gaps) | **3** | 1 |

**Conclusion**: Argo Events Sensor `rateLimit` may not work as expected for protecting downstream systems. **Do NOT rely on it for OpenAI rate limiting.**

### Recommended Alternatives for 1 Request/Minute Limit

Since sensor rate limiting didn't work in our tests, use these instead:

1. **Fluent Bit Throttle** (at source) - TESTED, works
2. **Workflow Mutex** (deduplication) - prevents concurrent processing
3. **Application-level rate limiting** (in HolmesGPT workflow)

### Understanding the Options

There are **three different rate limiting mechanisms** - each behaves differently:

| Mechanism | Location | Events Over Limit | Use Case | Tested? |
|-----------|----------|-------------------|----------|---------|
| **Fluent Bit Throttle** | Source cluster | **DROPPED** | Reduce EventHub volume | **PASS** |
| **Sensor Rate Limit** | Argo Events | **Should be DROPPED** | Protect downstream | **FAILED** |
| **Workflow Mutex** | Argo Workflow | **QUEUED** | Prevent duplicate processing | Not yet |

### 1. Fluent Bit Throttle (Events DROPPED) - **TESTED & VERIFIED**

**TESTED: 2026-01-21** on `kind-argo-workflow` cluster

```ini
[FILTER]
    Name     throttle
    Match    kube.events.*
    Rate     1          # Max 1 event per Interval
    Window   5          # Sliding window in seconds
    Interval 5s         # Check/release events every 5 seconds
```

**Test Results**:
| Metric | Value |
|--------|-------|
| Total Warning events in cluster | 12,136 |
| Events passed through throttle | 10 |
| Events DROPPED | ~12,126 (99.9%) |
| Test duration | ~30 seconds |

**Configuration Notes**:
- `Rate`: Events allowed per `Interval` (NOT per Window!)
- `Window`: Sliding window size for averaging
- `Interval`: How often to check and release events
- For 1 event per 60 seconds: Use `Rate=1, Window=60, Interval=5s`

**Behavior**:
- First event in interval: **SENT**
- Subsequent events in same interval: **DROPPED (never reach EventHub)**

**Example** (with Rate=1, Interval=5s):
```
10:00:01 CrashLoopBackOff → SENT
10:00:02 CrashLoopBackOff → DROPPED
10:00:03 CrashLoopBackOff → DROPPED
10:00:05 CrashLoopBackOff → SENT (new interval)
10:00:07 CrashLoopBackOff → DROPPED
10:00:10 CrashLoopBackOff → SENT (new interval)
```

**Recommended for 1/minute rate limit**:
```ini
[FILTER]
    Name     throttle
    Match    kube.events.*
    Rate     1
    Window   60
    Interval 5s
    Print_Status true
```

### 2. Sensor Rate Limit (Events DROPPED)

```yaml
triggers:
  - template:
      rateLimit:
        requestsPerUnit: 1  # Max 1 workflow
        unit: Minute
```

**Behavior**:
- First event triggers workflow
- Additional events within the minute: **DROPPED (no workflow created)**

**Example**:
```
10:00:01 Event → Workflow CREATED
10:00:15 Event → DROPPED (rate limited)
10:00:30 Event → DROPPED (rate limited)
10:01:01 Event → Workflow CREATED (new window)
```

### 3. Workflow Mutex (Events QUEUED)

```yaml
spec:
  synchronization:
    mutex:
      name: "triage-{{workflow.parameters.dedupe-key}}"
```

**Behavior**:
- First workflow runs (acquires mutex)
- Subsequent workflows for same key: **QUEUED until mutex released**

**Example**:
```
10:00:01 Workflow 1 → RUNS (mutex acquired)
10:00:15 Workflow 2 → QUEUED (waiting for mutex)
10:00:30 Workflow 3 → QUEUED (waiting for mutex)
10:05:00 Workflow 1 completes → Mutex released
10:05:01 Workflow 2 → RUNS (acquires mutex)
```

### Recommended Configuration

For your use case (1 request/minute from OpenAI):

1. **Use Sensor Rate Limit** to enforce hard limit:
```yaml
rateLimit:
  requestsPerUnit: 1
  unit: Minute
```

2. **Add Fluent Bit Throttle** to reduce EventHub volume:
```ini
[FILTER]
    Name     throttle
    Match    kube.events.*
    Rate     1
    Window   60
```

3. **Use Workflow Mutex** for deduplication (events queue, don't drop):
```yaml
synchronization:
  mutex:
    name: "triage-{{workflow.parameters.dedupe-key}}"
```

---

## Summary: Events Ignored vs Queued

| Question | Answer |
|----------|--------|
| **Do events get ignored?** | YES, with Fluent Bit Throttle (works) or Sensor Rate Limit (doesn't work) |
| **Do events queue?** | YES, with Workflow Mutex only |
| **Which events are dropped?** | Events exceeding rate limit within the time window |
| **Can I recover dropped events?** | NO - they're gone. Use EventHub if you need history |
| **Best for your 1/min OpenAI limit?** | **Fluent Bit Throttle** (proven to work) + Workflow Mutex (deduplicates) |

### Test Summary Table

| Test | Status | Notes |
|------|--------|-------|
| Namespace filtering (whitelist) | **PASS** | Events from whitelisted NS captured |
| Namespace filtering (exclude) | **PASS** | Events from excluded NS: 0 |
| Event reason filtering | **PASS** | Only matching reasons captured |
| Metadata enrichment | **PASS** | `cluster` and `filter_profile` added |
| Fluent Bit Throttle | **PASS** | 12,126 events dropped, 10 passed |
| Sensor Rate Limit | **FAIL** | All events passed despite limit |

---

## Test Cleanup

```bash
# Delete test pods
kubectl delete pod filter-test-default -n default --ignore-not-found
kubectl delete pod filter-test-ns -n test-namespace --ignore-not-found
kubectl delete pod filter-test-excluded -n excluded-namespace --ignore-not-found

# Delete test namespaces
kubectl delete namespace test-namespace --ignore-not-found
kubectl delete namespace excluded-namespace --ignore-not-found

# Delete Fluent Bit test deployment
kubectl delete deployment fluent-bit-events -n monitoring
kubectl delete configmap fluent-bit-config -n monitoring
kubectl delete clusterrole fluent-bit-events
kubectl delete clusterrolebinding fluent-bit-events
kubectl delete serviceaccount fluent-bit-events -n monitoring
```

---

## Files Created During Testing

| File | Purpose |
|------|---------|
| `test-local/fluent-bit-test-config.yaml` | ConfigMap with low-noise filter for testing |
| `test-local/fluent-bit-test-deployment.yaml` | Deployment for local testing (no EventHub) |
| `test-local/fluent-bit-debug-config.yaml` | Debug config with no filters |
| `test-local/fluent-bit-throttle-test.yaml` | Initial throttle test (grep filters blocked events) |
| `test-local/fluent-bit-throttle-only-test.yaml` | Throttle test without grep filters |
| `test-local/fluent-bit-throttle-correct-test.yaml` | Correct throttle configuration |
| `FILTER-TEST-RESULTS.md` | This document |

---

## Conclusion

For protecting downstream systems like HolmesGPT from OpenAI rate limits:

1. **Use Fluent Bit Throttle** - Tested and verified to drop events
2. **Do NOT rely on Argo Events Sensor rateLimit** - Failed testing
3. **Consider Workflow Mutex** for deduplication (events queue, not drop)
