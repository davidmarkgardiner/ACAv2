# AKS Node Auto Provisioning (NAP) - Node Pool Configuration Guide

## Overview

Node Auto Provisioning (NAP) in AKS uses **Karpenter** to automatically provision and manage nodes based on workload requirements. NAP evaluates pending pods and creates nodes that match their resource and scheduling requirements, supporting multiple node pool configurations for different workload types.

### Key Concepts

- **NodePool**: Defines constraints on nodes and pods (e.g., VM families, capacity types, resource limits)
- **AKSNodeClass**: Defines Azure-specific settings (VM image, OS disk, networking, kubelet config)
- NAP requires at least one NodePool to function
- Each NodePool references an AKSNodeClass via `spec.template.spec.nodeClassRef`
- Multiple NodePools can share the same AKSNodeClass

---

## Node Pool Types Configuration

### 1. Spot Instances Node Pool

Best for fault-tolerant, interruptible workloads with significant cost savings (up to 90% off).

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-pool
spec:
  weight: 5  # Lower priority than on-demand
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    expireAfter: Never
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - spot
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D  # General purpose
            - F  # Compute optimized
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: default
  limits:
    cpu: "500"
    memory: 500Gi
```

**Note**: NAP prioritizes Spot instances when both Spot and On-demand are specified in the same NodePool.

### 2. On-Demand Instances Node Pool

For critical workloads requiring guaranteed availability.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: on-demand-pool
spec:
  weight: 10  # Higher priority than spot
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
    expireAfter: 720h  # 30 days
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: default
  limits:
    cpu: "1000"
    memory: 1000Gi
```

### 3. General Purpose Node Pool

Balanced CPU-to-memory ratio for standard workloads (D-series VMs).

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-purpose
spec:
  weight: 10
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    expireAfter: Never
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - D  # D-series: balanced CPU/memory
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
            - spot
        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "3"  # v3 generation
            - "5"  # v5 generation
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: standard-config
```

### 4. High-Performance Compute Node Pool

Compute-optimized VMs with high CPU-to-memory ratio (F-series).

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: high-performance
spec:
  weight: 15
  disruption:
    consolidationPolicy: WhenEmpty
    expireAfter: Never
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - F  # F-series: compute optimized
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
        - key: karpenter.azure.com/sku-version
          operator: In
          values:
            - "5"  # Latest generation
        - key: karpenter.azure.com/sku-cpu
          operator: Gt
          values:
            - "8"  # Minimum 8 CPUs
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: performance-config
```

### 5. GPU-Enabled Node Pool

For AI/ML, rendering, and compute-intensive workloads (N-series VMs).

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-pool
spec:
  weight: 20  # Highest priority
  disruption:
    consolidationPolicy: WhenEmpty
    expireAfter: Never
    budgets:
      - nodes: "0"  # Prevent automatic disruption
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - N  # N-series: GPU VMs
        - key: karpenter.azure.com/sku-gpu-manufacturer
          operator: In
          values:
            - nvidia
        - key: karpenter.azure.com/sku-gpu-count
          operator: Gt
          values:
            - "0"  # Must have at least 1 GPU
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
      # Taint to ensure only GPU workloads land on these nodes
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: gpu-config
  limits:
    cpu: "200"
    memory: 1000Gi
    nvidia.com/gpu: "10"  # Limit GPU count
```

### 6. Memory-Optimized Node Pool

For memory-intensive workloads (E-series VMs).

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: memory-optimized
spec:
  weight: 12
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    expireAfter: Never
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values:
            - E  # E-series: memory optimized
        - key: karpenter.azure.com/sku-memory
          operator: Gt
          values:
            - "65536"  # Minimum 64 GiB memory
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
      nodeClassRef:
        apiVersion: karpenter.azure.com/v1beta1
        kind: AKSNodeClass
        name: memory-config
```

---

## AKSNodeClass Configurations

### Standard Configuration (General Purpose)

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: standard-config
spec:
  imageFamily: Ubuntu2204  # Options: Ubuntu2204, AzureLinux
  osDiskSizeGB: 128
  maxPods: 30  # Default for Azure CNI standard networking
  tags:
    Environment: "production"
    Team: "platform"
    Purpose: "general-workloads"
```

### Performance Configuration (High CPU/Memory)

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: performance-config
spec:
  imageFamily: Ubuntu2204
  osDiskSizeGB: 256  # Larger disk for caching
  maxPods: 50
  kubelet:
    cpuManagerPolicy: "static"  # CPU pinning for latency-sensitive workloads
    cpuCFSQuota: true
    imageGCHighThresholdPercent: 85
    imageGCLowThresholdPercent: 80
  tags:
    Environment: "production"
    Team: "platform"
    Purpose: "high-performance"
```

### GPU Configuration

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: gpu-config
spec:
  imageFamily: Ubuntu2204  # Both Ubuntu and AzureLinux support GPUs
  osDiskSizeGB: 512  # Larger disk for ML models/data
  maxPods: 30
  kubelet:
    cpuManagerPolicy: "static"
    topologyManagerPolicy: "best-effort"  # Coordinate CPU/GPU resources
    imageGCHighThresholdPercent: 90
    imageGCLowThresholdPercent: 80
  tags:
    Environment: "production"
    Team: "ml-platform"
    Purpose: "gpu-workloads"
    GPU: "nvidia"
```

### Ephemeral OS Disk Configuration

For workloads needing high disk I/O performance:

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: ephemeral-disk-config
spec:
  imageFamily: Ubuntu2204
  osDiskSizeGB: 128
  maxPods: 50
  tags:
    DiskType: "ephemeral"
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ephemeral-pool
spec:
  template:
    spec:
      requirements:
        # Ensure VMs have sufficient ephemeral storage
        - key: karpenter.azure.com/sku-storage-ephemeral-os-maxsize
          operator: Gt
          values: ["128"]
      nodeClassRef:
        kind: AKSNodeClass
        name: ephemeral-disk-config
```

---

## SKU Selector Reference

### VM Family Selectors

| Family | Description | Use Case |
|--------|-------------|----------|
| D-series | General-purpose (balanced CPU/memory) | Standard workloads |
| F-series | Compute-optimized (high CPU/memory) | Batch processing, analytics |
| E-series | Memory-optimized | Databases, caching |
| L-series | Storage-optimized | Big data, databases |
| N-series | GPU-enabled | AI/ML, rendering |

### Common SKU Selectors

```yaml
requirements:
  # Specific VM types
  - key: karpenter.azure.com/sku-name
    operator: In
    values:
      - Standard_D4s_v3
      - Standard_F8s_v2
  
  # VM generation
  - key: karpenter.azure.com/sku-version
    operator: In
    values:
      - "3"  # v3
      - "5"  # v5
  
  # CPU requirements
  - key: karpenter.azure.com/sku-cpu
    operator: Gt
    values:
      - "4"  # More than 4 CPUs
  
  # Memory requirements
  - key: karpenter.azure.com/sku-memory
    operator: Gt
    values:
      - "16384"  # More than 16 GiB (in MiB)
  
  # GPU requirements
  - key: karpenter.azure.com/sku-gpu-name
    operator: In
    values:
      - A100
      - V100
  
  # Accelerated networking
  - key: karpenter.azure.com/sku-networking-accelerated
    operator: In
    values:
      - "true"
  
  # Premium storage support
  - key: karpenter.azure.com/sku-storage-premium-capable
    operator: In
    values:
      - "true"
```

---

## Disruption Configuration

### Disruption Methods

1. **Expiration**: Nodes expire after a specified time
2. **Consolidation**: Remove/replace underutilized nodes
3. **Drift**: Handle configuration changes
4. **Manual**: Explicit deletion via kubectl

### Consolidation Policies

```yaml
spec:
  disruption:
    # WhenEmpty: Only consolidate empty nodes
    # WhenEmptyOrUnderutilized: Consolidate empty OR underutilized nodes
    consolidationPolicy: WhenEmptyOrUnderutilized
    
    # How long to wait before consolidating
    consolidateAfter: 30s
    
    # When nodes expire
    expireAfter: 720h  # 30 days, or Never
```

### Disruption Budgets

Control the rate of disruption to maintain availability:

```yaml
spec:
  disruption:
    budgets:
      # Allow 20% of nodes to be disrupted at once
      - nodes: "20%"
      
      # Cap at maximum 5 nodes
      - nodes: "5"
      
      # Block disruptions during business hours
      - nodes: "0"
        schedule: "0 9 * * 1-5"  # 9 AM Mon-Fri
        duration: 8h
      
      # Allow disruptions on weekends
      - nodes: "50%"
        schedule: "0 0 * * 6"  # Saturday midnight
        duration: 48h
```

### Prevent Disruption

Disable disruption for specific resources:

```yaml
# On a Pod
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"

# On a Node
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"

# On a NodePool
spec:
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"
```

---

## Networking Configuration

### Supported Configurations

✅ **Supported:**
- Azure CNI (recommended with Cilium)
- Azure CNI with Overlay
- kubenet

❌ **Not Supported:**
- Calico network policy
- Dynamic IP allocation

### Custom Subnet Configuration

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: custom-networking
spec:
  vnetSubnetID: "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet}"
```

### RBAC for Custom Subnets

Grant Network Contributor permissions:

```bash
# Get cluster managed identity
CLUSTER_IDENTITY=$(az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME --query identity.principalId -o tsv)

# Get VNet resource ID
VNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

# Assign Network Contributor role
az role assignment create \
  --assignee $CLUSTER_IDENTITY \
  --role "Network Contributor" \
  --scope $VNET_ID
```

### CIDR Considerations

Avoid conflicts between:
- Pod CIDR
- Service CIDR
- Custom subnet ranges

```bash
# Example conflict:
# Cluster Pod CIDR: 10.244.0.0/16
# Custom Subnet: 10.244.1.0/24  ❌ CONFLICT

# Safe configuration:
# Cluster Pod CIDR: 10.244.0.0/16
# Service CIDR: 10.0.0.0/16
# Custom Subnet: 10.1.0.0/24  ✅ NO CONFLICT
```

---

## Practical Deployment Examples

### Multi-Tier Architecture

```yaml
# Frontend: Spot instances for cost savings
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: frontend-spot
spec:
  weight: 5
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: [D]
      nodeClassRef:
        kind: AKSNodeClass
        name: frontend-class

# Backend: On-demand for reliability
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: backend-on-demand
spec:
  weight: 10
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [on-demand]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: [E]  # Memory optimized
      nodeClassRef:
        kind: AKSNodeClass
        name: backend-class

# ML Pipeline: GPU on-demand
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ml-gpu
spec:
  weight: 20
  template:
    spec:
      requirements:
        - key: karpenter.azure.com/sku-family
          operator: In
          values: [N]
        - key: karpenter.azure.com/sku-gpu-manufacturer
          operator: In
          values: [nvidia]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
      nodeClassRef:
        kind: AKSNodeClass
        name: gpu-class
```

### Cost-Optimized Configuration

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cost-optimized
spec:
  weight: 1  # Lowest priority
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s  # Aggressive consolidation
    expireAfter: 168h  # Rotate weekly
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: [spot]  # Spot-only
        - key: karpenter.azure.com/sku-family
          operator: In
          values: [D, F]  # Flexible VM types
      nodeClassRef:
        kind: AKSNodeClass
        name: cost-config
  limits:
    cpu: "1000"
```

---

## Node Pool Weights and Priority

When multiple NodePools match a pod's requirements, NAP selects based on weight:

```yaml
# Highest priority - GPU workloads
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-pool
spec:
  weight: 20  # Highest

---
# High priority - On-demand general purpose
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: on-demand-pool
spec:
  weight: 10

---
# Lower priority - Spot instances
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-pool
spec:
  weight: 5

---
# Lowest priority - Cost-optimized
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cost-pool
spec:
  weight: 1  # Lowest
```

---

## Resource Limits

Prevent runaway scaling:

```yaml
spec:
  limits:
    cpu: "1000"           # Total CPUs across all nodes
    memory: 1000Gi        # Total memory across all nodes
    nvidia.com/gpu: "10"  # Total GPUs across all nodes
```

---

## Default Node Pool Configuration

When you enable NAP, it creates a default `NodePool`:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    expireAfter: Never
  template:
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: [amd64]
        - key: kubernetes.io/os
          operator: In
          values: [linux]
        - key: karpenter.sh/capacity-type
          operator: In
          values: [on-demand]
        - key: karpenter.azure.com/sku-family
          operator: In
          values: [D]
```

Control default pool creation:

```bash
# Create cluster without default pools
az aks create \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools None

# Create cluster with default pools (default)
az aks create \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools Auto
```

---

## Best Practices

### 1. **Use Mutually Exclusive NodePools**
Design NodePools with distinct requirements to avoid ambiguity. Use weights to set priorities.

### 2. **Set Appropriate Resource Limits**
Prevent cost overruns by setting limits on CPU, memory, and GPU resources.

### 3. **Configure Disruption Budgets**
Maintain availability during consolidation by limiting concurrent disruptions.

### 4. **Use Taints for Specialized Workloads**
Ensure GPU nodes only run GPU workloads, preventing resource waste.

### 5. **Monitor and Adjust**
- Track node utilization and costs
- Adjust consolidation policies based on workload patterns
- Review and update SKU selections periodically

### 6. **Test in Non-Production First**
Especially when configuring kubelet settings or custom networking.

### 7. **Use Appropriate Image Families**
- Ubuntu2204: Default, well-tested
- AzureLinux: Microsoft's optimized distribution

### 8. **Plan Network Capacity**
Calculate required IP addresses for scaling and avoid CIDR conflicts.

### 9. **Tag Resources Appropriately**
Use Azure tags for cost tracking, compliance, and resource organization.

### 10. **Document Custom Configurations**
Maintain records of network design decisions and custom subnet configurations.

---

## Troubleshooting

### Node Not Provisioning

Check:
1. NodePool requirements match pod requirements
2. Azure quotas and limits
3. RBAC permissions for custom subnets
4. CIDR conflicts with custom networking
5. Drift detection on modified subnets

### Excessive Consolidation

Adjust:
```yaml
spec:
  disruption:
    consolidationPolicy: WhenEmpty  # More conservative
    consolidateAfter: 300s  # Wait longer
    budgets:
      - nodes: "10%"  # Limit disruption rate
```

### GPU Nodes Not Scaling

Verify:
1. GPU requirements in pod spec
2. Toleration for GPU taints
3. GPU resource limits in NodePool
4. Azure GPU quota

---

## Summary

NAP provides flexible node provisioning for diverse workload requirements:

- **Spot Instances**: Cost-optimized for fault-tolerant workloads
- **On-Demand**: Guaranteed availability for critical workloads
- **General Purpose** (D-series): Balanced CPU/memory for standard workloads
- **High-Performance** (F-series): CPU-intensive workloads
- **Memory-Optimized** (E-series): Memory-intensive applications
- **GPU-Enabled** (N-series): AI/ML and compute-intensive workloads

Configure NodePools with appropriate weights, limits, and disruption policies to optimize cost, performance, and availability based on your specific requirements.