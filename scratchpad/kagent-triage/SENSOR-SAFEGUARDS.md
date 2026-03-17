# Sensor Safeguards — Preventing Cascade Loops

## The Problem

Kyverno generates `PolicyViolation` Warning events on pods that lack labels or resource limits. Argo Events workflows also generate Warning events when they fail. This creates a feedback loop:

```
K8s Warning → Sensor → Workflow → Workflow fails → K8s Warning → Sensor → ...
```

## Required Safeguards (ALL sensors must have these)

### 1. Rate Limiting
```yaml
triggers:
  - template:
      rateLimit:
        unit: Minute
        requestsPerUnit: 5
```

### 2. Event Reason Filtering
Exclude PolicyViolation events:
```yaml
filters:
  data:
    - path: body.reason
      type: string
      comparator: "!="
      value:
        - "PolicyViolation"
```

### 3. Namespace Exclusion
Never trigger on events from argo-events or argo namespaces:
```yaml
filters:
  data:
    - path: body.involvedObject.namespace
      type: string
      comparator: "!="
      value:
        - "argo-events"
        - "argo"
```

### 4. Cleanup Test Pods IMMEDIATELY
After testing with fault injection pods, delete them immediately:
```bash
kubectl delete all --all -n test-ns
```

**Never leave fault injection pods running while sensors are active.**

## Deployment Sequence

1. Ensure NO fault injection pods are running
2. Deploy sensor with all safeguards
3. Wait 30s, verify no cascade
4. THEN inject fault for testing
5. Verify workflow triggers correctly
6. Delete fault injection pod immediately
7. Verify sensor returns to idle

## Learned From

- 2026-03-16: Sensors deployed while test pods were generating continuous CrashLoopBackOff + ImagePullBackOff events. Combined with Kyverno PolicyViolation events, this created a cascade that burned through the Kimi API quota.
