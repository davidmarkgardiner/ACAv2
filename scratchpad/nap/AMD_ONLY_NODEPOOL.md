# Provisioning AMD-Only Nodes with Azure NAP

## Problem: No Direct CPU Manufacturer Selector

Azure NAP (Node Auto-Provisioning) using Karpenter **does not currently provide** a `sku-cpu-manufacturer` requirement selector to filter nodes by CPU manufacturer (AMD vs Intel).

### Available SKU Selectors

According to [Microsoft Learn documentation](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-node-pools), these are the available selectors:

| Selector | Description |
|----------|-------------|
| `karpenter.azure.com/sku-family` | VM family (D, E, F, L, N) |
| `karpenter.azure.com/sku-name` | Specific VM SKU name |
| `karpenter.azure.com/sku-version` | VM generation (3, 5, etc.) |
| `karpenter.azure.com/sku-cpu` | CPU count |
| `karpenter.azure.com/sku-memory` | Memory in MiB |
| `karpenter.azure.com/sku-gpu-name` | GPU model (A100, V100, etc.) |
| `karpenter.azure.com/sku-gpu-manufacturer` | GPU manufacturer (nvidia) |
| `karpenter.azure.com/sku-gpu-count` | GPU count |
| `karpenter.azure.com/sku-networking-accelerated` | Accelerated networking support |
| `karpenter.azure.com/sku-storage-premium-capable` | Premium storage support |
| `karpenter.azure.com/sku-storage-ephemeralos-maxsize` | Ephemeral OS disk size |

**Note**: `sku-cpu-manufacturer` is **NOT** in this list.

## Solution: Use Explicit SKU Name Selection

The only reliable way to provision AMD-only nodes is to **explicitly specify AMD-based VM SKU names**.

### Azure VM SKUs by CPU Manufacturer

#### AMD-Based VM Series (EPYC Processors)

| Series | VM SKUs | CPU | Use Case |
|--------|---------|-----|----------|
| **Dasv5** | Standard_D2as_v5, D4as_v5, D8as_v5, D16as_v5, D32as_v5, D48as_v5, D64as_v5, D96as_v5 | AMD EPYC 7763v (Milan) | General purpose |
| **Dadsv5** | Standard_D2ads_v5, D4ads_v5, D8ads_v5, D16ads_v5, D32ads_v5, D48ads_v5, D64ads_v5, D96ads_v5 | AMD EPYC 7763v (Milan) | General purpose with local disk |
| **Dasv6** | Standard_D2as_v6, D4as_v6, D8as_v6, D16as_v6, D32as_v6, D48as_v6, D64as_v6, D96as_v6 | AMD EPYC 9004 (Genoa) | General purpose (latest) |
| **Easv5** | Standard_E2as_v5, E4as_v5, E8as_v5, E16as_v5, E20as_v5, E32as_v5, E48as_v5, E64as_v5, E96as_v5 | AMD EPYC 7763v (Milan) | Memory optimized |
| **Eadsv5** | Standard_E2ads_v5, E4ads_v5, E8ads_v5, E16ads_v5, E20ads_v5, E32ads_v5, E48ads_v5, E64ads_v5, E96ads_v5 | AMD EPYC 7763v (Milan) | Memory optimized with local disk |
| **Easv6** | Standard_E2as_v6, E4as_v6, E8as_v6, E16as_v6, E32as_v6, E48as_v6, E64as_v6, E96as_v6 | AMD EPYC 9004 (Genoa) | Memory optimized (latest) |
| **Fasv5** | Standard_F2as_v5, F4as_v5, F8as_v5, F16as_v5, F32as_v5, F48as_v5, F64as_v5 | AMD EPYC 7763v (Milan) | Compute optimized |
| **Lasv3** | Standard_L8as_v3, L16as_v3, L32as_v3, L48as_v3, L64as_v3, L80as_v3 | AMD EPYC 7763v (Milan) | Storage optimized |

#### Intel-Based VM Series (Xeon Processors)

For reference, these are Intel-based:
- **Dv3, Dsv3** - Intel Xeon E5-2673 v3/v4
- **Dv5, Dsv5** - Intel Xeon Platinum 8370C (Ice Lake)
- **Ev3, Esv3** - Intel Xeon E5-2673 v3/v4
- **Ev5, Esv5** - Intel Xeon Platinum 8370C (Ice Lake)
- **Fv2, Fsv2** - Intel Xeon Platinum 8168/8272CL

## AMD-Only NodePool Configuration

### Example 1: AMD General Purpose NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd-general-purpose
  annotations:
    kubernetes.io/description: "AMD EPYC-based general purpose node pool"
spec:
  weight: 50

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 3m
    expireAfter: Never

  template:
    metadata:
      labels:
        node-type: amd-general
        cpu-manufacturer: amd
        cpu-series: epyc
        workload-type: user-workloads

    spec:
      requirements:
        # AMD EPYC Milan (7763v) - Dasv5 series
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            - Standard_D4as_v5   # 4 vCPU, 16 GB RAM
            - Standard_D8as_v5   # 8 vCPU, 32 GB RAM
            - Standard_D16as_v5  # 16 vCPU, 64 GB RAM
            - Standard_D32as_v5  # 32 vCPU, 128 GB RAM
            - Standard_D48as_v5  # 48 vCPU, 192 GB RAM
            - Standard_D64as_v5  # 64 vCPU, 256 GB RAM

        # On-demand for reliability
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        # Architecture
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

        # OS
        - key: kubernetes.io/os
          operator: In
          values:
            - linux

        # Premium storage capability
        - key: karpenter.azure.com/sku-storage-premium-capable
          operator: In
          values:
            - "true"

        # Accelerated networking
        - key: karpenter.azure.com/sku-networking-accelerated
          operator: In
          values:
            - "true"

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: amd-azurelinux

  limits:
    cpu: "200"     # Maximum 200 vCPUs across all AMD nodes
    memory: 800Gi  # Maximum 800GB RAM
```

### Example 2: AMD Latest Generation (Genoa) NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd-genoa-latest
  annotations:
    kubernetes.io/description: "AMD EPYC Genoa (latest generation) node pool"
spec:
  weight: 60

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    expireAfter: Never

  template:
    metadata:
      labels:
        node-type: amd-genoa
        cpu-manufacturer: amd
        cpu-generation: genoa
        cpu-series: epyc-9004

    spec:
      requirements:
        # AMD EPYC Genoa (9004 series) - Dasv6 series - LATEST
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            - Standard_D4as_v6   # 4 vCPU, 16 GB RAM
            - Standard_D8as_v6   # 8 vCPU, 32 GB RAM
            - Standard_D16as_v6  # 16 vCPU, 64 GB RAM
            - Standard_D32as_v6  # 32 vCPU, 128 GB RAM
            - Standard_D48as_v6  # 48 vCPU, 192 GB RAM
            - Standard_D64as_v6  # 64 vCPU, 256 GB RAM

        # On-demand
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        # Architecture
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

        # OS
        - key: kubernetes.io/os
          operator: In
          values:
            - linux

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: amd-genoa-azurelinux

  limits:
    cpu: "256"
    memory: 1024Gi
```

### Example 3: AMD Memory-Optimized NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd-memory-optimized
  annotations:
    kubernetes.io/description: "AMD EPYC memory-optimized node pool (Easv5)"
spec:
  weight: 55

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    expireAfter: Never

  template:
    metadata:
      labels:
        node-type: amd-memory
        cpu-manufacturer: amd
        workload-type: memory-intensive

    spec:
      requirements:
        # AMD EPYC Milan - Easv5 series (memory optimized)
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            - Standard_E4as_v5   # 4 vCPU, 32 GB RAM
            - Standard_E8as_v5   # 8 vCPU, 64 GB RAM
            - Standard_E16as_v5  # 16 vCPU, 128 GB RAM
            - Standard_E20as_v5  # 20 vCPU, 160 GB RAM
            - Standard_E32as_v5  # 32 vCPU, 256 GB RAM
            - Standard_E48as_v5  # 48 vCPU, 384 GB RAM
            - Standard_E64as_v5  # 64 vCPU, 512 GB RAM

        # Minimum memory requirement
        - key: karpenter.azure.com/sku-memory
          operator: Gt
          values:
            - "32768"  # Minimum 32 GB (in MiB)

        # On-demand
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        # Architecture
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

        # OS
        - key: kubernetes.io/os
          operator: In
          values:
            - linux

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: amd-memory-azurelinux

  limits:
    cpu: "192"
    memory: 1536Gi  # Large memory limit for memory-intensive workloads
```

### Example 4: AMD Spot Instances (Cost-Optimized)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd-spot-cost-optimized
  annotations:
    kubernetes.io/description: "AMD EPYC spot instances for cost savings"
spec:
  weight: 10  # Lower priority than on-demand

  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m  # Aggressive consolidation for spot
    expireAfter: 168h  # Rotate weekly

  template:
    metadata:
      labels:
        node-type: amd-spot
        cpu-manufacturer: amd
        capacity-type: spot

    spec:
      requirements:
        # AMD VMs across multiple series for better spot availability
        - key: karpenter.azure.com/sku-name
          operator: In
          values:
            # Dasv5 - General purpose
            - Standard_D4as_v5
            - Standard_D8as_v5
            - Standard_D16as_v5
            # Dadsv5 - With local disk
            - Standard_D4ads_v5
            - Standard_D8ads_v5
            - Standard_D16ads_v5
            # Fasv5 - Compute optimized
            - Standard_F4as_v5
            - Standard_F8as_v5
            - Standard_F16as_v5

        # Spot instances for cost savings
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - spot

        # Architecture
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64

        # OS
        - key: kubernetes.io/os
          operator: In
          values:
            - linux

      nodeClassRef:
        group: karpenter.azure.com
        kind: AKSNodeClass
        name: amd-spot-azurelinux

  limits:
    cpu: "500"
    memory: 2000Gi
```

## AKSNodeClass Configuration for AMD Nodes

```yaml
---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: amd-azurelinux
  annotations:
    kubernetes.io/description: "Azure Linux node class optimized for AMD EPYC processors"
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 128
  maxPods: 110

  kubelet:
    kubeReserved:
      cpu: "100m"
      memory: "512Mi"
      ephemeral-storage: "1Gi"

    systemReserved:
      cpu: "100m"
      memory: "512Mi"
      ephemeral-storage: "1Gi"

    imageGCHighThresholdPercent: 85
    imageGCLowThresholdPercent: 80

  tags:
    cpuManufacturer: "amd"
    cpuSeries: "epyc"
    nodeType: "general"
    os: "azurelinux"

---
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: amd-genoa-azurelinux
  annotations:
    kubernetes.io/description: "Azure Linux optimized for AMD EPYC Genoa (9004 series)"
spec:
  imageFamily: AzureLinux
  osDiskSizeGB: 256
  maxPods: 110

  kubelet:
    kubeReserved:
      cpu: "200m"
      memory: "1Gi"
      ephemeral-storage: "1Gi"

    systemReserved:
      cpu: "200m"
      memory: "1Gi"
      ephemeral-storage: "1Gi"

    imageGCHighThresholdPercent: 85
    imageGCLowThresholdPercent: 80

  tags:
    cpuManufacturer: "amd"
    cpuSeries: "epyc-genoa"
    cpuGeneration: "9004"
    nodeType: "latest-gen"
    os: "azurelinux"
```

## Workload Targeting AMD Nodes

### Option 1: Node Selector

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: amd-workload
spec:
  nodeSelector:
    cpu-manufacturer: amd
  containers:
    - name: app
      image: myapp:latest
```

### Option 2: Node Affinity (Preferred)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: amd-workload-preferred
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: cpu-manufacturer
                operator: In
                values:
                  - amd
  containers:
    - name: app
      image: myapp:latest
```

### Option 3: Specific CPU Generation

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: genoa-workload
spec:
  nodeSelector:
    cpu-manufacturer: amd
    cpu-generation: genoa
  containers:
    - name: app
      image: myapp:latest
```

## Verification

### Check Node CPU Information

```bash
# Get nodes with AMD CPUs
kubectl get nodes -l cpu-manufacturer=amd

# Check actual CPU model on nodes
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

# Describe node to see full details
kubectl describe node <node-name> | grep -A 10 "System Info"

# Check VM SKU
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
INSTANCE-TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,\
ZONE:.metadata.labels.topology\.kubernetes\.io/zone
```

### Verify NodePool Configuration

```bash
# Check NodePools
kubectl get nodepools -o yaml | grep -A 5 "sku-name"

# Verify only AMD SKUs are listed
kubectl get nodepools amd-general-purpose -o jsonpath='{.spec.template.spec.requirements[?(@.key=="karpenter.azure.com/sku-name")].values}'
```

## Why This Approach is Necessary

1. **No Direct CPU Manufacturer Selector**: Azure NAP doesn't expose `sku-cpu-manufacturer` as a requirement
2. **VM Naming Convention**: Azure uses clear naming - `as` suffix indicates AMD (e.g., `D4as_v5`)
3. **Explicit Control**: Specifying exact SKU names gives complete control over CPU selection
4. **Cost Optimization**: AMD VMs often cost less than Intel equivalents

## AMD vs Intel Naming Convention

| Naming Pattern | CPU Manufacturer | Example |
|----------------|------------------|---------|
| `D4s_v5` | Intel | Standard_D4s_v5 |
| `D4as_v5` | AMD | Standard_D4as_v5 |
| `E8s_v5` | Intel | Standard_E8s_v5 |
| `E8as_v5` | AMD | Standard_E8as_v5 |

**Rule**: The **`as`** or **`a`** in the SKU name indicates AMD processors.

## Cost Comparison (Example)

AMD-based VMs typically cost **10-15% less** than Intel equivalents:

| Intel SKU | AMD SKU | Savings |
|-----------|---------|---------|
| Standard_D8s_v5 | Standard_D8as_v5 | ~10-15% |
| Standard_E16s_v5 | Standard_E16as_v5 | ~10-15% |
| Standard_F32s_v2 | Standard_F32as_v5 | ~10-15% |

## Future Enhancement Request

Consider requesting Microsoft to add `karpenter.azure.com/sku-cpu-manufacturer` selector:
- Would simplify AMD/Intel selection
- More maintainable than explicit SKU lists
- Aligns with GPU manufacturer selector pattern (`sku-gpu-manufacturer`)

## References

- [Configure Node Pools for NAP in AKS](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-node-pools)
- [Azure VM Sizes - General Purpose](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes-general)
- [AMD EPYC-based Azure VMs](https://azure.microsoft.com/en-us/blog/announcing-the-general-availability-of-azure-virtual-machines-with-amd-epyc-processors/)
- [AKS Karpenter Provider GitHub](https://github.com/Azure/karpenter-provider-azure)

## Summary

To provision **AMD-only nodes** in Azure NAP:

1. **Use explicit SKU names** in the `sku-name` requirement
2. **Look for `as` in SKU names** (e.g., `D4as_v5`, `E8as_v5`)
3. **Choose your AMD generation**: `v5` (Milan), `v6` (Genoa)
4. **Add node labels** for workload targeting (`cpu-manufacturer: amd`)
5. **Verify** nodes are using correct CPU after provisioning

There is currently **no direct CPU manufacturer selector** - explicit SKU naming is the only reliable method.
