# EventHub Integration Testing Guide

Test the end-to-end pipeline: EventHub → Argo Events Sensor → Holmes → GitLab → Mattermost

## Status: WORKING (with v1.9.5)

Tested and verified on 2026-01-20. Full pipeline operational.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Azure EventHub │───►│  Argo Events    │───►│  Argo Workflow  │───►│  GitLab Issue   │
│  (kube-events)  │    │  EventSource    │    │  (Holmes AI)    │    │  + Mattermost   │
└─────────────────┘    └─────────────────┘    └─────────────────┘    └─────────────────┘
        ▲                      │
        │                      │ Filtering:
  Fluent Bit                   │ - Apply at Fluent Bit level (recommended)
  (AKS clusters)               │ - Critical events only
```

## Prerequisites

1. **Argo Events v1.9.5** (CRITICAL - v1.9.6+ has a bug, see [ARGO-EVENTS-EVENTHUB-BUG.md](ARGO-EVENTS-EVENTHUB-BUG.md))
2. **EventHub namespace and hub created**
3. **Argo Events deployed** with EventBus running
4. **Holmes deployed** in `holmesgpt` namespace
5. **Secrets configured** (Holmes API key, GitLab token)

## CRITICAL: Argo Events Version

**You MUST use Argo Events v1.9.5**. Versions 1.9.6 through 1.9.9 have a bug that causes the EventHub EventSource to crash.

```bash
# Check current version
kubectl get deployment -n argo-events -o wide | grep argo-events

# Downgrade if needed (must be v1.9.5)
helm upgrade argo-events argo/argo-events \
  --namespace argo-events \
  --version 2.4.14 \
  --reuse-values \
  --wait
```

## Quick Start

### Step 1: Create EventHub Secret

```bash
# Set variables
export EVENTHUB_NAMESPACE="k8s-events-hub-fb"
export RESOURCE_GROUP="your-resource-group"

# Get SAS key
KEY_NAME="RootManageSharedAccessKey"
KEY_VALUE=$(az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name $KEY_NAME --query primaryKey -o tsv)

# Create K8s secret
kubectl create secret generic eventhub-listener-secret \
  --namespace argo-events \
  --from-literal=sharedAccessKeyName="$KEY_NAME" \
  --from-literal=sharedAccessKey="$KEY_VALUE"

# Verify
kubectl get secret eventhub-listener-secret -n argo-events
```

### Step 2: Deploy EventSource

```bash
# Edit the FQDN in the file first!
kubectl apply -f 05-eventhub-eventsource.yaml

# Wait for it to be ready
kubectl get eventsources -n argo-events
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events
```

### Step 3: Deploy Sensor

**Recommended: Simple Sensor (no expression filters)**
```bash
# Processes all events - filtering done at Fluent Bit level
kubectl apply -f 08-eventhub-sensor-simple.yaml
```

**Alternative: Filtered Sensors (expression filters have issues)**
```bash
# Note: Expression-based filters may not work correctly with EventHub payload format
# Recommend filtering at Fluent Bit level instead

# Option A: Namespace Whitelist
kubectl apply -f 07-eventhub-sensor-namespace-whitelist.yaml

# Option B: System Namespace Blacklist
kubectl apply -f 06-eventhub-sensor-filtered.yaml
```

**Best Practice**: Apply filtering at the **Fluent Bit level** (source cluster) for:
- Lower EventHub costs (fewer messages)
- More efficient processing
- Reliable filtering behavior

### Step 4: Send Test Events

**Using Python (azure-eventhub package):**
```bash
pip install azure-eventhub

# Send CrashLoopBackOff event to 'monitoring' namespace (will trigger)
./send-eventhub-test.sh CrashLoopBackOff --namespace monitoring

# Send to kube-system (will be filtered)
./send-eventhub-test.sh CrashLoopBackOff --namespace kube-system

# Send non-critical event (will be filtered)
./send-eventhub-test.sh BackOff --namespace monitoring
```

**Using curl only:**
```bash
./send-eventhub-curl.sh CrashLoopBackOff monitoring
```

### Step 5: Verify Pipeline

```bash
# Watch for workflows
kubectl get workflows -n argo-events -w

# Check EventSource logs
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=50

# Check Sensor logs
kubectl logs -n argo-events -l sensor-name=eventhub-critical-events --tail=50
# OR for whitelist sensor:
kubectl logs -n argo-events -l sensor-name=eventhub-namespace-whitelist --tail=50
```

## Filter Configuration

### Critical Event Reasons (Phase 1)

Events that WILL trigger workflows:
- `CrashLoopBackOff` - Pod crash loop
- `OOMKilled` - Out of memory killed
- `NodeNotReady` - Node health issue
- `FailedMount` - Volume mount failure
- `FailedScheduling` - Cannot schedule pod
- `Evicted` - Pod evicted

### Excluded Namespaces (Blacklist Sensor)

Events from these namespaces are filtered out:
- `kube-system`
- `kube-public`
- `kube-node-lease`
- `cert-manager`
- `gatekeeper-system`
- `flux-system`
- `external-secrets`
- `azureserviceoperator-system`

### Whitelisted Namespaces (Whitelist Sensor)

Only events from these namespaces are processed:
- `monitoring`
- `holmesgpt`
- `grafana-test`
- `mattermost`

**To add namespaces**, edit `07-eventhub-sensor-namespace-whitelist.yaml`:
```yaml
- expr: 'namespace in ["monitoring", "holmesgpt", "grafana-test", "mattermost", "YOUR-NEW-NAMESPACE"]'
```

## Test Matrix

| Test Case | Reason | Namespace | Expected Result |
|-----------|--------|-----------|-----------------|
| Critical in whitelisted NS | CrashLoopBackOff | monitoring | WORKFLOW TRIGGERED |
| Critical in system NS | CrashLoopBackOff | kube-system | FILTERED (no workflow) |
| Non-critical in whitelisted NS | BackOff | monitoring | FILTERED (no workflow) |
| Critical in non-whitelisted NS | OOMKilled | default | FILTERED (whitelist) or TRIGGERED (blacklist) |

## Troubleshooting

### EventSource Not Receiving Events

```bash
# Check EventSource pod
kubectl get pods -n argo-events -l eventsource-name=eventhub-k8s-events

# Check logs for connection errors
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events

# Verify secret exists
kubectl get secret eventhub-listener-secret -n argo-events -o yaml
```

### Sensor Not Triggering Workflows

```bash
# Check sensor status
kubectl get sensors -n argo-events

# Check sensor logs for filter evaluation
kubectl logs -n argo-events -l sensor-name=eventhub-critical-events

# Deploy debug sensor to see raw events
kubectl apply -f 06-eventhub-sensor-filtered.yaml  # Includes debug sensor
kubectl get workflows -n argo-events -l purpose=eventhub-debug
```

### Workflow Fails

```bash
# Get workflow logs
kubectl get workflows -n argo-events
kubectl logs -n argo-events <workflow-name> -c main

# Check Holmes is reachable
kubectl exec -n argo-events deploy/webhook-prod-test-eventsource -- \
  curl -s http://holmesgpt.holmesgpt.svc.cluster.local:80/healthz
```

## Gradual Rollout Plan

### Week 1-2: Namespace Whitelist

1. Deploy `07-eventhub-sensor-namespace-whitelist.yaml`
2. Start with 2-3 low-volume namespaces
3. Monitor workflow volume and GitLab issue quality
4. Add namespaces one at a time

### Week 3-4: Expand Namespaces

1. Add application namespaces to whitelist
2. Or switch to blacklist approach (`06-eventhub-sensor-filtered.yaml`)
3. Monitor for noise issues

### Week 5+: Full Coverage

1. Enable all namespaces (except system)
2. Consider adding Phase 2 event reasons:
   - `Unhealthy`
   - `ProbeWarning`
   - `FailedKillPod`

## Files Reference

| File | Purpose | Status |
|------|---------|--------|
| `05-eventhub-eventsource.yaml` | EventSource connecting to Azure EventHub | ✅ Working |
| `08-eventhub-sensor-simple.yaml` | **Simple sensor (no filters) - RECOMMENDED** | ✅ Working |
| `06-eventhub-sensor-filtered.yaml` | Sensor with expression filters | ⚠️ Filter issues |
| `07-eventhub-sensor-namespace-whitelist.yaml` | Sensor with namespace whitelist | ⚠️ Filter issues |
| `send-eventhub-test.sh` | Send test events (Python azure-eventhub) | ✅ Working |
| `send-eventhub-curl.sh` | Send test events (curl only) | ✅ Working |
| `ARGO-EVENTS-EVENTHUB-BUG.md` | Bug documentation and fix | Reference |

## Recommended Fluent Bit Filtering

Instead of filtering at the sensor level, configure **Fluent Bit** on source clusters using our pre-built filter profiles:

### Filter Profiles (Ready to Use)

| Profile | Folder | Use Case | Volume |
|---------|--------|----------|--------|
| **Low Noise** | `../filter-profiles/01-low-noise/` | Initial rollout, critical only | ~10-50/day |
| **Medium Noise** | `../filter-profiles/02-medium-noise/` | Production monitoring | ~50-200/day |
| **Max Events** | `../filter-profiles/03-max-events/` | Debug, full visibility | ~200-1000+/day |

See [../filter-profiles/README.md](../filter-profiles/README.md) for complete documentation.

### Quick Deploy

```bash
# Deploy low-noise profile (recommended for initial rollout)
kubectl apply -f ../filter-profiles/01-low-noise/fluent-bit-config.yaml
kubectl rollout restart daemonset fluent-bit -n monitoring
```

### Example Filter (Low Noise Profile)

```ini
# /fluent-bit/etc/filters.conf

# Only capture critical events
[FILTER]
    Name    grep
    Match   kube.events.*
    Regex   reason ^(CrashLoopBackOff|OOMKilled|NodeNotReady|FailedMount|FailedScheduling|Evicted)$

# Whitelist namespaces
[FILTER]
    Name    grep
    Match   kube.events.*
    Regex   involvedObject.namespace ^(monitoring|holmesgpt|your-app-ns)$

# Add cluster identifier
[FILTER]
    Name    modify
    Match   kube.events.*
    Add     cluster ${CLUSTER_NAME}
```

This approach:
- Reduces EventHub message volume and costs
- Ensures only critical events reach the management cluster
- Avoids complex sensor expression parsing issues

## Metrics to Watch

- **EventHub incoming messages** - Azure Portal
- **Workflows triggered per hour** - `kubectl get workflows -n argo-events | wc -l`
- **GitLab issues created** - GitLab project issues page
- **Mattermost notifications** - Mattermost channel

## Rollback

If too many workflows are triggered:

```bash
# Delete the sensor to stop processing
kubectl delete sensor eventhub-critical-events -n argo-events
# OR
kubectl delete sensor eventhub-namespace-whitelist -n argo-events

# Clean up pending workflows
kubectl delete workflows -n argo-events -l source=eventhub
```
