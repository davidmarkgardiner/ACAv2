# NAP Priority-Based Node Pool Failover

## Overview

This guide explains how to configure AKS Node Auto Provisioning (NAP) to use cheaper VM SKUs as the primary option, with automatic failover to more expensive (or more available) SKUs when:

- The primary pool hits resource limits
- Azure has capacity constraints for the primary SKUs
- Subscription quotas are exhausted

## How NAP Priority Works

NAP uses the `weight` field to determine node pool priority:

| Weight | Priority | Behavior |
|--------|----------|----------|
| Higher (e.g., 100) | **First choice** | NAP tries this pool first |
| Lower (e.g., 10) | **Fallback** | Used when higher-weight pools can't provision |

### Failover Triggers

| Scenario | NAP Behavior |
|----------|--------------|
| Pool hits `limits` (cpu/memory) | Falls to next eligible pool |
| Azure capacity unavailable | Tries other SKUs, then next pool |
| Subscription quota exhausted | Falls to next pool (if different SKU family) |
| SKU not available in region | Tries alternatives in pool, then next pool |

---

## Configuration Examples

### Example 1: Cheap vs Expensive SKU Failover

Primary pool uses older-gen cheaper VMs; fallback uses newer-gen more available VMs.

```yaml
# PRIMARY: Cheaper older-generation VMs (tried first)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cheap-primary
  annotations:
    kubernetes.io/description: "Primary pool with cost-optimized older-gen SKUs"
spec:
  weight: 100  # Highest priority - tried first

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    expireAfter: Never

  template:
    metadata:
      labels:
        cost-tier: cheap
        failover-priority: primary
    spec:
      requirements:
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # Older v3 generation - typically cheaper
            - Standard_D4s_v3
            - Standard_D8s_v3
            - Standard_D16s_v3
            # AMD v4 - cost effective
            - Standard_D4as_v4
            - Standard_D8as_v4
            - Standard_D16as_v4

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: standard-config

  # When this limit is hit, NAP uses the fallback pool
  limits:
    cpu: "200"
    memory: 400Gi

---
# FALLBACK: More expensive but more available VMs
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: expensive-fallback
  annotations:
    kubernetes.io/description: "Fallback pool with newer-gen SKUs for availability"
spec:
  weight: 50  # Lower priority - used as fallback

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    expireAfter: Never

  template:
    metadata:
      labels:
        cost-tier: standard
        failover-priority: secondary
    spec:
      requirements:
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # Newer v5 generation - more available
            - Standard_D4s_v5
            - Standard_D8s_v5
            - Standard_D16s_v5
            - Standard_D32s_v5
            # AMD v5 alternatives
            - Standard_D4as_v5
            - Standard_D8as_v5
            - Standard_D16as_v5

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: standard-config

  limits:
    cpu: "500"
    memory: 1000Gi

---
# LAST RESORT: Premium SKUs with highest availability
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: premium-last-resort
  annotations:
    kubernetes.io/description: "Last resort pool with premium SKUs"
spec:
  weight: 10  # Lowest priority

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    expireAfter: Never

  template:
    metadata:
      labels:
        cost-tier: premium
        failover-priority: last-resort
    spec:
      requirements:
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # Latest gen with best availability
            - Standard_D4ds_v5
            - Standard_D8ds_v5
            - Standard_D16ds_v5
            - Standard_E4s_v5   # Memory-optimized fallback
            - Standard_E8s_v5

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: premium-config

  limits:
    cpu: "1000"
    memory: 2000Gi
```

---

### Example 2: AMD Primary with Intel Fallback

Use cheaper AMD SKUs first, fall back to Intel if AMD capacity is exhausted.

```yaml
# PRIMARY: AMD VMs (10-15% cheaper than Intel)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd-primary
  annotations:
    kubernetes.io/description: "AMD EPYC VMs - cost optimized primary"
spec:
  weight: 100

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    expireAfter: Never

  template:
    metadata:
      labels:
        cpu-manufacturer: amd
        failover-priority: primary
    spec:
      requirements:
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # AMD Dasv5 series (EPYC Milan)
            - Standard_D4as_v5
            - Standard_D8as_v5
            - Standard_D16as_v5
            - Standard_D32as_v5
            # AMD Dasv6 series (EPYC Genoa) - latest
            - Standard_D4as_v6
            - Standard_D8as_v6
            - Standard_D16as_v6

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: amd-config

  limits:
    cpu: "300"
    memory: 600Gi

---
# FALLBACK: Intel VMs (higher availability)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: intel-fallback
  annotations:
    kubernetes.io/description: "Intel Xeon VMs - fallback for availability"
spec:
  weight: 50

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    expireAfter: Never

  template:
    metadata:
      labels:
        cpu-manufacturer: intel
        failover-priority: secondary
    spec:
      requirements:
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # Intel Dsv5 series (Ice Lake)
            - Standard_D4s_v5
            - Standard_D8s_v5
            - Standard_D16s_v5
            - Standard_D32s_v5

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: intel-config

  limits:
    cpu: "500"
    memory: 1000Gi
```

---

### Example 3: Spot Primary with On-Demand Fallback

Use Spot instances for cost savings, fall back to On-Demand when Spot is evicted or unavailable.

```yaml
# PRIMARY: Spot instances (up to 90% cheaper)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-primary
  annotations:
    kubernetes.io/description: "Spot instances for cost savings"
spec:
  weight: 100

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    expireAfter: 168h  # Rotate weekly

  template:
    metadata:
      labels:
        capacity-type: spot
        failover-priority: primary
    spec:
      requirements:
        # Wide range of SKUs for better Spot availability
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D  # General purpose
            - F  # Compute optimized

        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "5"

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - spot  # Spot only

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: spot-config

  limits:
    cpu: "500"
    memory: 1000Gi

---
# FALLBACK: On-Demand (guaranteed availability)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ondemand-fallback
  annotations:
    kubernetes.io/description: "On-Demand fallback for guaranteed capacity"
spec:
  weight: 50

  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
    expireAfter: Never

  template:
    metadata:
      labels:
        capacity-type: on-demand
        failover-priority: secondary
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D

        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "5"

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand  # On-Demand only

        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: ondemand-config

  limits:
    cpu: "1000"
    memory: 2000Gi
```

---

### Example 4: Region/Zone Capacity Failover

Configure pools that can span availability zones for better capacity.

```yaml
# PRIMARY: Specific zone (cheaper/preferred)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: zone1-primary
spec:
  weight: 100

  template:
    spec:
      requirements:
        - key: topology.kubernetes.io/zone
          operator: In
          values:
            - eastus-1  # Preferred zone

        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: zone1-config

  limits:
    cpu: "200"

---
# FALLBACK: Any zone
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: any-zone-fallback
spec:
  weight: 50

  template:
    spec:
      requirements:
        - key: topology.kubernetes.io/zone
          operator: In
          values:
            - eastus-1
            - eastus-2
            - eastus-3  # All zones available

        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D
            - E  # Additional family for availability

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: multizone-config

  limits:
    cpu: "500"
```

---

## AKSNodeClass Configurations

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: standard-config
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 128
  maxPods: 110
  tags:
    Environment: production
    ManagedBy: NAP

---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: premium-config
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 256
  maxPods: 110
  kubelet:
    cpuManagerPolicy: static
  tags:
    Environment: production
    ManagedBy: NAP
    Tier: premium

---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: amd-config
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 128
  maxPods: 110
  tags:
    cpuManufacturer: amd
    ManagedBy: NAP

---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: intel-config
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 128
  maxPods: 110
  tags:
    cpuManufacturer: intel
    ManagedBy: NAP
```

---

## Verification Commands

### Check NodePool Weights

```bash
# List all NodePools with their weights
kubectl get nodepools -o custom-columns=\
NAME:.metadata.name,\
WEIGHT:.spec.weight,\
CPU-LIMIT:.spec.limits.cpu,\
MEMORY-LIMIT:.spec.limits.memory

# Example output:
# NAME                 WEIGHT   CPU-LIMIT   MEMORY-LIMIT
# cheap-primary        100      200         400Gi
# expensive-fallback   50       500         1000Gi
# premium-last-resort  10       1000        2000Gi
```

### Monitor Failover Behavior

```bash
# Watch node provisioning events
kubectl get events --field-selector reason=Provisioned -w

# Check which pool provisioned each node
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
POOL:.metadata.labels.karpenter\\.sh/nodepool,\
INSTANCE:.metadata.labels.node\\.kubernetes\\.io/instance-type,\
ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone

# Check pool resource usage vs limits
kubectl get nodepools -o yaml | grep -A 3 "limits:"
```

### Test Failover

```bash
# Deploy pods to trigger scaling
kubectl create deployment test-scale --image=nginx --replicas=50

# Watch which pools are used
watch -n 2 'kubectl get nodes -l karpenter.sh/nodepool --no-headers | \
  awk "{print \$1}" | \
  xargs -I {} kubectl get node {} -o jsonpath="{.metadata.labels.karpenter\.sh/nodepool}{\"\\n\"}" | \
  sort | uniq -c'

# Clean up
kubectl delete deployment test-scale
```

---

## Best Practices

### 1. Design Mutually Exclusive Pools

Ensure pools have clear distinctions to avoid ambiguity:

```yaml
# Good: Clear SKU separation
cheap-primary:    [D4s_v3, D8s_v3]     # weight: 100
expensive-fallback: [D4s_v5, D8s_v5]   # weight: 50

# Avoid: Overlapping SKUs
pool-a: [D4s_v5, D8s_v5]  # weight: 100
pool-b: [D4s_v5, D16s_v5] # weight: 50  ❌ D4s_v5 in both
```

### 2. Set Appropriate Limits

```yaml
# Primary pool: Lower limits to trigger failover sooner
limits:
  cpu: "200"      # Hit this → use fallback

# Fallback pool: Higher limits for burst capacity
limits:
  cpu: "1000"     # More headroom
```

### 3. Use Labels for Observability

```yaml
template:
  metadata:
    labels:
      cost-tier: cheap|standard|premium
      failover-priority: primary|secondary|last-resort
      cpu-manufacturer: amd|intel
```

### 4. Consider Consolidation Timing

```yaml
# Primary: Faster consolidation (cost optimization)
disruption:
  consolidateAfter: 1m

# Fallback: Slower consolidation (stability)
disruption:
  consolidateAfter: 5m
```

---

## Cost Optimization Tips

| Strategy | Implementation | Savings |
|----------|----------------|---------|
| AMD primary | Use `as` suffix SKUs first | 10-15% |
| Older generation | Use v3/v4 before v5/v6 | 5-20% |
| Spot primary | Spot first, On-Demand fallback | Up to 90% |
| Regional arbitrage | Prefer cheaper zones | Varies |

---

## Troubleshooting

### Pool Not Failing Over

1. Check limits haven't been reached:
   ```bash
   kubectl describe nodepool <name> | grep -A 5 "Status:"
   ```

2. Verify SKUs are actually different between pools

3. Check for pod affinity/nodeSelector that restricts pools

### Wrong Pool Being Selected

1. Verify weight values (higher = preferred)
2. Check if pod requirements match multiple pools
3. Look for node selectors that override pool selection

### Capacity Issues Not Triggering Failover

Azure capacity issues within a pool may just try other SKUs in the same pool. Ensure fallback pool has different SKU families:

```yaml
# Primary pool: D-series only
- key: karpenter.azure.com/sku-family
  values: [D]

# Fallback pool: E-series (different family)
- key: karpenter.azure.com/sku-family
  values: [E, D]  # E first, D as backup
```

---

## Summary

| Goal | Configuration |
|------|---------------|
| Cheaper SKUs first | Higher weight on cheap pool, lower limits |
| AMD before Intel | AMD pool weight > Intel pool weight |
| Spot before On-Demand | Spot pool weight > On-Demand pool weight |
| Zone preference | Preferred zone in high-weight pool |
| Automatic failover | Set `limits` on primary pool |

NAP will automatically select the highest-weight pool that:
1. Matches pod requirements
2. Has available capacity (within `limits`)
3. Can provision the requested SKU in Azure

When these conditions fail, NAP falls to the next eligible pool by weight.
