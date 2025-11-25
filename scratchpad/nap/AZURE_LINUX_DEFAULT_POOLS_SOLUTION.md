# Azure Linux Default Pools Solution for NAP

## Problem Statement

When enabling Node Auto-Provisioning (NAP) on AKS clusters, Azure automatically creates two default NodePools:

1. **"default"** - General purpose NodePool
2. **"system-surge"** - System workload surge NodePool

**Issue**: Both default pools use **Ubuntu2204** as the `imageFamily`, which is incompatible with certificate injection tools that require **Azure Linux**.

This causes the cluster to fail immediately after creation because:
- The certificate injection tool cannot inject certificates into Ubuntu nodes
- System pods fail to start without the required certificates
- The cluster becomes unstable before you can deploy custom NodePools via GitOps

## Root Cause

NAP (powered by Karpenter) automatically provisions these default NodePools when:
```yaml
nodeProvisioningProfile:
  mode: Auto
  # defaultNodePools: Auto  # This is the default if not specified
```

The default behavior (`defaultNodePools: Auto`) creates Ubuntu-based NodePools for immediate use.

## Solution: Prevent Default NodePools Creation

### Updated Cluster Configuration

Modify your `cluster.yaml` to explicitly set `defaultNodePools: None`:

```yaml
apiVersion: containerservice.azure.com/v1api20240402preview
kind: ManagedCluster
metadata:
  name: uk8s-tsshared-weu-gt025-int-prod
  namespace: azure-system
spec:
  # ... other configuration ...

  # Node provisioning with auto mode (NAP)
  # CRITICAL: Set defaultNodePools to "None" to prevent automatic creation of Ubuntu-based default pools
  nodeProvisioningProfile:
    mode: Auto
    defaultNodePools: None  # Prevents creation of default Ubuntu-based NodePools

  # Keep your existing system pool with Azure Linux
  agentPoolProfiles:
    - name: systempool
      mode: System
      count: 1
      osType: Linux
      osSKU: AzureLinux  # This pool uses Azure Linux
      # ... rest of configuration ...
```

### What This Does

1. **Enables NAP**: `mode: Auto` activates Node Auto-Provisioning
2. **Prevents Default Pools**: `defaultNodePools: None` stops automatic creation of Ubuntu-based pools
3. **Preserves System Pool**: Your existing `systempool` with Azure Linux continues to work
4. **Requires Custom NodePools**: You MUST deploy custom NodePools immediately after cluster creation

## Deployment Workflow

### Step 1: Deploy the Cluster

```bash
# Apply the cluster configuration with ASO
kubectl apply -f aso-stack/cluster.yaml

# Wait for cluster to be ready
kubectl wait --for=condition=Ready managedcluster/uk8s-tsshared-weu-gt025-int-prod \
  -n azure-system --timeout=30m
```

### Step 2: Immediately Deploy Custom Azure Linux NodePools

**CRITICAL**: NAP requires at least one NodePool to function. Deploy these immediately after cluster creation:

```bash
# Get cluster credentials
az aks get-credentials \
  --resource-group <resource-group> \
  --name uk8s-tsshared-weu-gt025-int-prod

# Deploy Azure Linux NodePools in sequence
kubectl apply -f NAP/Official/system-nodeclass-azurelinux.yaml
kubectl apply -f NAP/Official/system-nodepool.yaml

kubectl apply -f NAP/Official/default-nodepool-override.yaml
kubectl apply -f NAP/Official/system-surge-nodepool-override.yaml

# Verify NodePools are created
kubectl get nodepools
kubectl get aksnodeclasses
```

### Step 3: Verify System Pods Schedule on Azure Linux Nodes

```bash
# Check node OS distribution
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
OS-IMAGE:.status.nodeInfo.osImage,\
KERNEL:.status.nodeInfo.kernelVersion

# Verify critical system pods are running
kubectl get pods -n kube-system
kubectl get pods -n azure-system
```

## Custom NodePool Configuration Summary

You have three Azure Linux-based NodePools defined:

### 1. System NodePool (`system-nodepool.yaml`)
- **Purpose**: Critical system workloads
- **Image**: Azure Linux (`system-azurelinux` AKSNodeClass)
- **Capacity**: Max 3 nodes (24 vCPU limit)
- **VM Size**: Standard_D4s_v5, Standard_D8s_v5, Standard_B8ms
- **Taints**: `CriticalAddonsOnly=NoSchedule`, `node-role=system:NoSchedule`
- **Weight**: 100 (high priority)

### 2. Default NodePool Override (`default-nodepool-override.yaml`)
- **Purpose**: General user workloads
- **Image**: Azure Linux (`default-azurelinux` AKSNodeClass)
- **Capacity**: Max ~12 nodes (100 vCPU limit)
- **VM Size**: D-series (general purpose)
- **Weight**: 50 (standard priority)

### 3. System Surge NodePool Override (`system-surge-nodepool-override.yaml`)
- **Purpose**: System workload surge capacity
- **Image**: Azure Linux (`system-surge-azurelinux` AKSNodeClass)
- **Capacity**: EXACTLY 2 nodes (16 vCPU limit with D8s_v5 only)
- **VM Size**: Standard_D8s_v5 ONLY (enforced via requirements)
- **Taints**: `CriticalAddonsOnly=NoSchedule`, `node-role=system-surge:NoSchedule`, `system-surge=true:NoExecute`
- **Weight**: 150 (highest priority)

## GitOps Integration

### Flux Kustomization Structure

```yaml
# apps/nap/kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nap-nodepools
  namespace: flux-system
spec:
  interval: 5m
  path: ./NAP/Official
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  # CRITICAL: Deploy NAP NodePools immediately after cluster creation
  dependsOn:
    - name: azure-service-operator
  healthChecks:
    - apiVersion: karpenter.sh/v1
      kind: NodePool
      name: system-pool
      namespace: karpenter
    - apiVersion: karpenter.sh/v1
      kind: NodePool
      name: default
      namespace: karpenter
    - apiVersion: karpenter.sh/v1
      kind: NodePool
      name: system-surge
      namespace: karpenter
```

## Troubleshooting

### Issue: Cluster fails immediately after creation

**Cause**: No NodePools exist after setting `defaultNodePools: None`

**Solution**: Deploy custom NodePools immediately after cluster creation (within 5 minutes)

### Issue: Pods scheduled on Ubuntu nodes

**Cause**: Default Ubuntu NodePools still exist from previous cluster configuration

**Solution**: Delete the default Ubuntu-based NodePools manually:
```bash
kubectl delete nodepool default
kubectl delete nodepool system-surge
```

Then deploy the Azure Linux NodePools:
```bash
kubectl apply -f NAP/Official/default-nodepool-override.yaml
kubectl apply -f NAP/Official/system-surge-nodepool-override.yaml
```

### Issue: Certificate injection still failing

**Verification Steps**:
1. Confirm nodes are running Azure Linux:
   ```bash
   kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}'
   ```

2. Check NodePool image family:
   ```bash
   kubectl get aksnodeclasses -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.imageFamily}{"\n"}{end}'
   ```

3. Verify all NodePools reference Azure Linux NodeClasses:
   ```bash
   kubectl get nodepools -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.nodeClassRef.name}{"\n"}{end}'
   ```

## API Version Requirements

This solution requires ASO API version `v1api20240402preview` or later, which includes support for the `defaultNodePools` property.

```yaml
apiVersion: containerservice.azure.com/v1api20240402preview  # Required
kind: ManagedCluster
```

## References

- [Configure Node Pools for Node Auto-Provisioning (NAP) in AKS](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-node-pools)
- [Enable or Disable Node Auto-Provisioning (NAP) in AKS](https://learn.microsoft.com/en-us/azure/aks/use-node-auto-provisioning)
- [Azure Service Operator v2 API Reference](https://azure.github.io/azure-service-operator/reference/containerservice/v1api20240402preview/)

## Summary

**Before**: Cluster fails immediately because NAP creates Ubuntu-based default NodePools incompatible with certificate injection.

**After**:
1. Set `defaultNodePools: None` in cluster.yaml
2. Deploy custom Azure Linux NodePools via GitOps immediately after cluster creation
3. All nodes use Azure Linux, compatible with certificate injection
4. Cluster operates normally with full NAP capabilities

**Key Takeaway**: This is a **cluster creation-time configuration**. You cannot easily change this setting after cluster creation without manual NodePool deletion and recreation.
