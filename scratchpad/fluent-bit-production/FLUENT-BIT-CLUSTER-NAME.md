# Fluent Bit Cluster Name Configuration

## Problem

The cluster name was showing as `none` because the `modify` filter's `Add` operation doesn't reliably expand environment variables.

## Solution

Changed from `modify` filter to `record_modifier` filter which properly supports environment variable expansion.

### Before (not working)
```ini
[FILTER]
    Name          modify
    Match         kube.events.*
    Add           cluster ${CLUSTER_NAME}
```

### After (working)
```ini
[FILTER]
    Name          record_modifier
    Match         kube.events.*
    Record        cluster ${CLUSTER_NAME}
    Record        cluster_region ${CLUSTER_REGION}
    Record        cluster_environment ${CLUSTER_ENVIRONMENT}
```

## Environment Variables Required

Update these in `02-fluent-bit-deployment.yaml` for each cluster:

```yaml
env:
  - name: CLUSTER_NAME
    value: "your-cluster-name"        # e.g., "uk8s-prod-weu-001"
  - name: CLUSTER_REGION
    value: "westeurope"               # e.g., "westeurope", "uksouth"
  - name: CLUSTER_ENVIRONMENT
    value: "production"               # e.g., "dev", "staging", "production"
```

## Data Passed to Event Hub

After the filters, each event sent to Event Hub contains:

### Added by Fluent Bit Filters
| Field | Source | Example |
|-------|--------|---------|
| `cluster` | `CLUSTER_NAME` env var | `uk8s-prod-weu-001` |
| `cluster_region` | `CLUSTER_REGION` env var | `westeurope` |
| `cluster_environment` | `CLUSTER_ENVIRONMENT` env var | `production` |

### From Kubernetes Events API
| Field | Description | Example |
|-------|-------------|---------|
| `type` | Event type | `Warning`, `Normal` |
| `reason` | Event reason | `CrashLoopBackOff`, `OOMKilled`, `FailedScheduling` |
| `message` | Human-readable description | `Back-off restarting failed container` |
| `count` | Number of occurrences | `5` |
| `firstTimestamp` | First occurrence | `2026-01-21T10:00:00Z` |
| `lastTimestamp` | Most recent occurrence | `2026-01-21T10:05:00Z` |
| `involvedObject.kind` | Resource type | `Pod`, `Node`, `Deployment` |
| `involvedObject.name` | Resource name | `my-app-7d8f9c6b5-abc12` |
| `involvedObject.namespace` | Namespace | `production` |
| `involvedObject.uid` | Resource UID | `a1b2c3d4-...` |
| `source.component` | Event source | `kubelet`, `scheduler` |
| `source.host` | Node name (if applicable) | `aks-nodepool1-12345-vmss000000` |

## Example Event Payload

```json
{
  "cluster": "uk8s-prod-weu-001",
  "cluster_region": "westeurope",
  "cluster_environment": "production",
  "type": "Warning",
  "reason": "CrashLoopBackOff",
  "message": "Back-off restarting failed container",
  "count": 5,
  "firstTimestamp": "2026-01-21T10:00:00Z",
  "lastTimestamp": "2026-01-21T10:05:00Z",
  "involvedObject": {
    "kind": "Pod",
    "name": "my-app-7d8f9c6b5-abc12",
    "namespace": "production",
    "uid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  },
  "source": {
    "component": "kubelet",
    "host": "aks-nodepool1-12345-vmss000000"
  }
}
```

## Deployment Steps

```bash
# 1. Update the environment variables in the deployment
# Edit 02-fluent-bit-deployment.yaml with correct values

# 2. Apply the updated config and deployment
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml

# 3. Restart Fluent Bit to pick up changes
kubectl rollout restart deployment/fluent-bit-events -n monitoring

# 4. Verify the pod started correctly
kubectl logs -n monitoring -l app=fluent-bit --tail=50

# 5. Check Event Hub is receiving events with cluster name
# (Use Azure Portal > Event Hub > Process data > Explore)
```

## Debugging

If cluster name is still `none`:

```bash
# 1. Check environment variables are set
kubectl exec -n monitoring deploy/fluent-bit-events -- env | grep CLUSTER

# 2. Check Fluent Bit is using the right config
kubectl exec -n monitoring deploy/fluent-bit-events -- cat /fluent-bit/etc/filters.conf

# 3. Check Fluent Bit logs for errors
kubectl logs -n monitoring -l app=fluent-bit -f
```
