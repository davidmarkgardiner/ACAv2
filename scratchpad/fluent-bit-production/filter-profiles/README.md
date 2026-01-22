# Fluent Bit Filter Profiles

Pre-configured Fluent Bit filtering profiles for controlling event volume sent to Azure EventHub.

## Testing Status

**TESTED: 2026-01-21** on `kind-argo-workflow` cluster

| Test | Status | Evidence |
|------|--------|----------|
| Namespace filtering (whitelist) | **PASS** | Events from whitelisted namespaces captured |
| Namespace filtering (exclude) | **PASS** | Events from excluded namespaces: 0 |
| Event reason filtering | **PASS** | Only matching reasons captured |
| Metadata enrichment | **PASS** | `cluster` and `filter_profile` added |
| **Fluent Bit Throttle** | **PASS** | 12,126 events dropped, 10 passed (99.9% drop rate) |
| Sensor Rate Limit | **FAIL** | All events passed despite rateLimit config |

See `FILTER-TEST-RESULTS.md` for full test evidence.

## Why Filter at Fluent Bit Level?

Filtering at the **source** (Fluent Bit) rather than the **destination** (Argo Events Sensor) provides:

1. **Lower EventHub costs** - Fewer messages = lower Azure costs
2. **More reliable filtering** - Sensor expression filters have issues with EventHub payload format
3. **Better performance** - Less data transfer and processing
4. **Predictable behavior** - grep-based filters are simpler and more reliable

## Profiles Overview

| Profile | Folder | Namespaces | Events | Volume |
|---------|--------|------------|--------|--------|
| **Low Noise** | `01-low-noise/` | Whitelist only | Critical only | ~10-50/day |
| **Medium Noise** | `02-medium-noise/` | Blacklist system NS | Critical + Health | ~50-200/day |
| **Max Events** | `03-max-events/` | Whitelist only | ALL Warning | ~200-1000+/day |

## Quick Comparison

```
                    LOW NOISE                MEDIUM NOISE              MAX EVENTS
                    ─────────                ────────────              ──────────
Namespace Filter:   Whitelist               Blacklist                 Whitelist
                    (only specific NS)      (exclude system NS)       (only specific NS)

Event Reasons:      CrashLoopBackOff        CrashLoopBackOff          ALL Warning events
                    OOMKilled               OOMKilled                 (no filtering)
                    NodeNotReady            NodeNotReady
                    FailedMount             FailedMount
                    FailedScheduling        FailedScheduling
                    Evicted                 Evicted
                                           + Unhealthy
                                           + ProbeWarning
                                           + FailedKillPod
                                           + BackOff

Use Case:           Initial rollout         Production monitoring     Debug/investigation
                    Minimal alerts          Balanced coverage         Full visibility
```

## Recommended Rollout

```
Week 1-2: 01-low-noise
    │
    ▼ (if volume is manageable)
Week 3-4: 02-medium-noise
    │
    ▼ (for specific namespaces needing full coverage)
Week 5+:  03-max-events (targeted namespaces only)
```

## Deployment

### Step 1: Choose Profile

```bash
# View profiles
ls -la filter-profiles/
```

### Step 2: Customize Namespaces

Edit the `filters.conf` section in your chosen profile:

```yaml
# For whitelist (01-low-noise, 03-max-events):
Regex  involvedObject.namespace ^(your-ns1|your-ns2|your-ns3)$

# For blacklist (02-medium-noise):
Exclude  involvedObject.namespace ^(kube-system|kube-public|your-exclusion)$
```

### Step 3: Deploy to Source Cluster

```bash
# Copy to source cluster and apply
kubectl apply -f filter-profiles/01-low-noise/fluent-bit-config.yaml

# Restart Fluent Bit
kubectl rollout restart daemonset fluent-bit -n monitoring
```

### Step 4: Verify

```bash
# Check Fluent Bit logs
kubectl logs -n monitoring -l app=fluent-bit --tail=50 -f

# Monitor EventHub (Azure Portal)
# Check argo-events workflows
kubectl get workflows -n argo-events -w
```

## Event Reasons Reference

| Reason | Description | Profile |
|--------|-------------|---------|
| `CrashLoopBackOff` | Container crash loop | Low, Medium, Max |
| `OOMKilled` | Out of memory killed | Low, Medium, Max |
| `NodeNotReady` | Node health issue | Low, Medium, Max |
| `FailedMount` | Volume mount failure | Low, Medium, Max |
| `FailedScheduling` | Cannot schedule pod | Low, Medium, Max |
| `Evicted` | Pod evicted | Low, Medium, Max |
| `Unhealthy` | Health check failed | Medium, Max |
| `ProbeWarning` | Probe timeout/failure | Medium, Max |
| `FailedKillPod` | Cannot terminate pod | Medium, Max |
| `BackOff` | Container restart backoff | Medium, Max |
| `ImagePullBackOff` | Cannot pull image | Max only |
| `ErrImagePull` | Image pull error | Max only |
| `FailedCreate` | Resource creation failed | Max only |
| `Killing` | Pod being terminated | Max only |

## Rate Limiting Behavior

**IMPORTANT**: Events that don't match filters are **DROPPED**, not queued.

### Understanding Event Flow and Rate Limits

```
K8s Events → Fluent Bit Filters → EventHub → Argo Sensor → HolmesGPT
                 ↓                              ↓
            DROPPED here               OR  DROPPED here
         (doesn't match)             (rate limit exceeded)
```

### Rate Limiting Options

| Location | Mechanism | Events Over Limit | Best For |
|----------|-----------|-------------------|----------|
| **Fluent Bit** | Filter profiles | **DROPPED** (never reach EventHub) | Reducing EventHub costs |
| **Fluent Bit** | Throttle filter | **DROPPED** (rate-based) | Source-level rate limiting |
| **Argo Sensor** | `rateLimit` | **DROPPED** (no workflow created) | Protecting downstream (HolmesGPT) |
| **Argo Workflow** | `mutex` | **QUEUED** (waits for mutex) | Deduplication |

### For OpenAI Rate Limits (1 request/minute)

**WARNING**: Sensor `rateLimit` did NOT work in our tests (2026-01-21). All events were processed despite rate limit configuration.

**Recommended alternatives**:

1. **Fluent Bit Throttle** (at source):
```ini
[FILTER]
    Name     throttle
    Match    kube.events.*
    Rate     1
    Window   60
```

2. **Workflow Mutex** (deduplication, events queue):
```yaml
spec:
  synchronization:
    mutex:
      name: "triage-{{workflow.parameters.dedupe-key}}"
```

3. **Application-level rate limiting** in your workflow script

### What Happens to Dropped Events?

- **They are gone** - no recovery possible
- EventHub retains the raw event (if it passed Fluent Bit filters)
- No workflow is created for dropped events
- Use `filter_profile` metadata to identify which profile was active

## Troubleshooting

### Events Not Reaching EventHub

```bash
# Check Fluent Bit is running
kubectl get pods -n monitoring -l app=fluent-bit

# Check Fluent Bit logs for errors
kubectl logs -n monitoring -l app=fluent-bit --tail=100 | grep -i error

# Verify environment variables
kubectl exec -n monitoring deploy/fluent-bit -- env | grep EVENTHUB
```

### Too Many Events

1. Switch to a more restrictive profile
2. Reduce namespace whitelist
3. Add event reason filtering

### Events Being Filtered Unexpectedly

```bash
# Check filter_profile tag in EventHub messages
# Should show which profile is active

# Test with a simple debug filter first
# Remove event reason filter temporarily to verify namespace filter works
```

## Files

```
filter-profiles/
├── README.md                          # This file
├── 01-low-noise/
│   ├── fluent-bit-config.yaml        # ConfigMap with low noise filters
│   └── README.md                      # Profile documentation
├── 02-medium-noise/
│   ├── fluent-bit-config.yaml        # ConfigMap with medium filters
│   └── README.md                      # Profile documentation
└── 03-max-events/
    ├── fluent-bit-config.yaml        # ConfigMap with minimal filters
    └── README.md                      # Profile documentation
```
