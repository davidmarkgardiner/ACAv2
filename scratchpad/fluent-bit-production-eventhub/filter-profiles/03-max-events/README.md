# Max Events Filter Profile

**Least restrictive** - ALL Warning events from whitelisted namespaces.

## What Gets Through

| Filter | Criteria |
|--------|----------|
| Event Type | `Warning` only |
| Namespaces | Whitelist: `monitoring`, `holmesgpt`, `grafana-test`, `mattermost`, `default`, `production`, `staging`, `dev` |
| Event Reasons | **ALL** (no filtering) |

## Estimated Volume

~200-1000+ events/day per cluster (depends on namespace activity)

## Use Cases

- Complete visibility into specific namespaces
- Debug/investigation mode
- Namespaces where you want ALL issues reported
- Development/staging environments
- Troubleshooting cluster-wide issues

## Warning

**High volume profile** - Ensure your downstream systems can handle the load:
- Holmes AI API rate limits
- GitLab issue creation limits
- EventHub throughput capacity
- Mattermost notification flooding

## Common Event Reasons (All Included)

| Category | Events |
|----------|--------|
| Critical | `CrashLoopBackOff`, `OOMKilled`, `NodeNotReady`, `FailedMount`, `FailedScheduling`, `Evicted` |
| Health | `Unhealthy`, `ProbeWarning`, `FailedKillPod`, `BackOff` |
| Image | `ImagePullBackOff`, `ErrImagePull`, `InvalidImageName` |
| Network | `FailedAttachVolume`, `FailedDetachVolume`, `NetworkNotReady` |
| Resource | `FailedCreate`, `FailedDelete`, `Killing` |
| Scheduling | `NotTriggerScaleUp`, `FailedBinding`, `ExceededGracePeriod` |

## Customization

### Change Whitelisted Namespaces

Edit `filters.conf` Step 2:

```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         involvedObject.namespace ^(your-ns1|your-ns2|your-ns3)$
```

### Add Event Reason Filtering (Reduce Volume)

If you want to reduce volume but keep namespace coverage, add after Step 2:

```ini
# Optional: Filter specific event reasons
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|...)$
```

## Deployment

```bash
# Deploy to source cluster
kubectl apply -f fluent-bit-config.yaml

# Restart Fluent Bit to pick up changes
kubectl rollout restart daemonset fluent-bit -n monitoring
```

## Verification

```bash
# Check Fluent Bit logs
kubectl logs -n monitoring -l app=fluent-bit --tail=50

# Monitor EventHub incoming messages (Azure Portal)
# Expect high message volume

# Monitor workflow creation rate
watch kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp
```

## Downgrade Path

If volume is too high:
1. Switch to `02-medium-noise` profile
2. Or add event reason filtering to this profile
3. Or reduce namespace whitelist
