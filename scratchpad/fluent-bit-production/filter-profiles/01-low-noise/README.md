# Low Noise Filter Profile

**Most restrictive** - Only critical events from whitelisted namespaces.

## What Gets Through

| Filter | Criteria |
|--------|----------|
| Event Type | `Warning` only |
| Namespaces | Whitelist: `monitoring`, `holmesgpt`, `grafana-test`, `mattermost` |
| Event Reasons | `CrashLoopBackOff`, `OOMKilled`, `NodeNotReady`, `FailedMount`, `FailedScheduling`, `Evicted` |

## Estimated Volume

~10-50 events/day per cluster (varies by cluster health)

## Use Cases

- Initial rollout / testing
- Production clusters where you want minimal noise
- High-value alerts only
- Cost-conscious environments (fewer EventHub messages)

## Customization

### Add Namespaces

Edit `filters.conf` Step 2:

```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         involvedObject.namespace ^(monitoring|holmesgpt|grafana-test|mattermost|YOUR-NEW-NAMESPACE)$
```

### Add Event Reasons

Edit `filters.conf` Step 3:

```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted|NEW-REASON)$
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

# Check EventHub incoming messages (Azure Portal)
# Should see significantly fewer messages than unfiltered
```
