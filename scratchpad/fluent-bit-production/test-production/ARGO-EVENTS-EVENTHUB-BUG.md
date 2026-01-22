# Argo Events Azure EventHub Bug - RESOLVED

## Status: FIXED

**Solution**: Downgrade to Argo Events **v1.9.5** (Helm chart **2.4.14**)

## Issue Summary

Argo Events **v1.9.6 through v1.9.9** have a bug in the Azure EventHub EventSource that causes a panic when receiving messages.

## Error

```
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1c52df4]

goroutine 165 [running]:
github.com/argoproj/argo-events/pkg/eventsources/sources/azureeventshub.(*EventListener).StartListening.func1({0x3de2ba8, 0x1})
    /home/runner/work/argo-events/argo-events/pkg/eventsources/sources/azureeventshub/start.go:133 +0x444
```

## Affected Versions

| Version | Status |
|---------|--------|
| v1.9.5 | ✅ Works |
| v1.9.6 | ❌ Bug |
| v1.9.7 | ❌ Bug |
| v1.9.8 | ❌ Bug |
| v1.9.9 | ❌ Bug |

## Fix

```bash
# Downgrade to v1.9.5
helm upgrade argo-events argo/argo-events \
  --namespace argo-events \
  --version 2.4.14 \
  --reuse-values \
  --wait

# Verify version
kubectl get deployment -n argo-events -o wide | grep argo-events
# Should show: quay.io/argoproj/argo-events:v1.9.5
```

## Verification

After downgrading, redeploy the EventSource:

```bash
# Delete and recreate EventSource to get new image
kubectl delete eventsource eventhub-k8s-events -n argo-events
kubectl apply -f 05-eventhub-eventsource.yaml

# Check logs - should show successful message processing
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20
```

Expected logs:
```
msg="received an event from eventshub..."
msg="dispatching the event to eventbus..."
msg="Succeeded to publish an event"
```

## GitHub Issue

This bug is tracked at: https://github.com/argoproj/argo-events/issues/3595

## Root Cause

The Azure EventHub SDK integration in Argo Events v1.9.6+ has a nil pointer dereference when processing received messages. This was introduced in a dependency update.

## Test Results (2026-01-20)

After applying the fix, the full pipeline works:

```
Azure EventHub → Argo EventSource (v1.9.5) → Sensor → Holmes AI → GitLab Issue → Mattermost
```

**Successful Workflows:**
- `eh-debug-87gh5` - Debug workflow
- `eh-debug-r95fn` - Debug workflow
- `eh-triage-4v6mw` - Full triage (Holmes → GitLab)

## Azure Resources

Resources created for testing (kept for production use):

| Resource | Name | Location |
|----------|------|----------|
| EventHub Namespace | `k8s-events-hub-fb` | uksouth |
| EventHub | `kube-events` | uksouth |
| Resource Group | `k8s-cluster` | uksouth |
| Consumer Group | `$Default` | Basic tier |
| K8s Secret | `eventhub-listener-secret` | argo-events |

## Notes on Sensor Filters

The complex expression-based filters in the sensor have issues with the EventHub payload format.

**Recommended approach**: Apply filtering at the **Fluent Bit level** (source) instead:

```ini
# Fluent Bit filter - only send critical events to EventHub
[FILTER]
    Name    grep
    Match   kube.events.*
    Regex   reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted)$

[FILTER]
    Name    grep
    Match   kube.events.*
    Exclude involvedObject.namespace ^(kube-system|kube-public|cert-manager)$
```

This is more efficient (less EventHub traffic and cost) than filtering at the sensor level.

## Related Files

| File | Purpose |
|------|---------|
| `05-eventhub-eventsource.yaml` | EventHub EventSource |
| `08-eventhub-sensor-simple.yaml` | Simple sensor (no filters) - WORKING |
| `06-eventhub-sensor-filtered.yaml` | Filtered sensor (expression filters have issues) |
