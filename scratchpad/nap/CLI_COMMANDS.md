# Azure CLI Commands for NAP Default Pools

## Create New Cluster WITHOUT Default NodePools

### Option 1: Disable Default Pools (Recommended for Azure Linux requirement)

```bash
az aks create \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools None \
  --kubernetes-version 1.32 \
  --location uksouth \
  # ... other flags ...
```

**Key Flag**: `--node-provisioning-default-pools None`

This prevents Azure from creating the default Ubuntu-based "default" and "system-surge" NodePools.

### Option 2: Enable Default Pools (Default Behavior)

```bash
az aks create \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools Auto \
  # ... other flags ...
```

**Key Flag**: `--node-provisioning-default-pools Auto` (this is the default)

This creates two Ubuntu-based NodePools automatically:
- `default` - general purpose
- `system-surge` - system workload surge

## Update Existing Cluster

### Enable NAP on Existing Cluster

```bash
az aks update \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --node-provisioning-mode Auto
```

**Warning**: This will create default Ubuntu-based NodePools if they don't exist.

### Disable NAP on Existing Cluster

```bash
az aks update \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --node-provisioning-mode Disabled
```

## Manual NodePool Management

### Delete Default Ubuntu NodePools (if already created)

If you enabled NAP with default pools and need to switch to Azure Linux:

```bash
# List existing NodePools
kubectl get nodepools

# Delete the default Ubuntu-based NodePools
kubectl delete nodepool default
kubectl delete nodepool system-surge

# Immediately deploy Azure Linux NodePools
kubectl apply -f NAP/Official/default-nodepool-override.yaml
kubectl apply -f NAP/Official/system-surge-nodepool-override.yaml
kubectl apply -f NAP/Official/system-nodepool.yaml
```

**Critical**: NAP requires at least one NodePool to function. Deploy custom NodePools immediately after deletion.

### Verify NodePools Configuration

```bash
# Check NodePool configuration
kubectl get nodepools -o yaml

# Check AKSNodeClass configuration
kubectl get aksnodeclasses -o yaml

# Verify nodes are using Azure Linux
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
OS-IMAGE:.status.nodeInfo.osImage,\
KERNEL:.status.nodeInfo.kernelVersion
```

## Complete Example: Create Cluster with Azure Linux NodePools

### Step 1: Create Cluster WITHOUT Default Pools

```bash
az aks create \
  --resource-group rg-my-aks-cluster \
  --name uk8s-tsshared-weu-gt025-int-prod \
  --location uksouth \
  --kubernetes-version 1.32 \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools None \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-policy cilium \
  --network-dataplane cilium \
  --service-cidr 10.251.0.0/17 \
  --dns-service-ip 10.251.0.10 \
  --pod-cidr 10.251.128.0/17 \
  --load-balancer-sku standard \
  --enable-workload-identity \
  --enable-oidc-issuer \
  --enable-managed-identity \
  --node-count 1 \
  --node-vm-size Standard_B8ms \
  --node-osdisk-size 128 \
  --os-sku AzureLinux \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 3 \
  --zones 1 \
  --enable-defender \
  --enable-azure-rbac \
  --enable-aad \
  --aad-admin-group-object-ids 80f7067f-5b5b-4e80-84ae-af0d59b4e439 \
  --enable-addons azure-keyvault-secrets-provider,azure-policy \
  --enable-secret-rotation \
  --tags environment=dev project=uk8s costCenter=BT-TS-INFRA- managedBy=azure-cli
```

### Step 2: Get Cluster Credentials

```bash
az aks get-credentials \
  --resource-group rg-my-aks-cluster \
  --name uk8s-tsshared-weu-gt025-int-prod \
  --overwrite-existing
```

### Step 3: Deploy Azure Linux NodePools

```bash
# Deploy AKSNodeClasses first
kubectl apply -f NAP/Official/system-nodeclass-azurelinux.yaml

# Deploy NodePools
kubectl apply -f NAP/Official/system-nodepool.yaml
kubectl apply -f NAP/Official/default-nodepool-override.yaml
kubectl apply -f NAP/Official/system-surge-nodepool-override.yaml
```

### Step 4: Verify Configuration

```bash
# Check NodePools
kubectl get nodepools
# Expected output:
# NAME           WEIGHT   READY
# system-pool    100      True
# default        50       True
# system-surge   150      True

# Check AKSNodeClasses
kubectl get aksnodeclasses
# Expected output:
# NAME                      AGE
# system-azurelinux         1m
# default-azurelinux        1m
# system-surge-azurelinux   1m

# Verify all use Azure Linux
kubectl get aksnodeclasses -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.imageFamily}{"\n"}{end}'
# Expected output:
# system-azurelinux         AzureLinux
# default-azurelinux        AzureLinux
# system-surge-azurelinux   AzureLinux
```

## Comparison: ASO vs CLI

### Azure Service Operator (ASO)

```yaml
apiVersion: containerservice.azure.com/v1api20240402preview
kind: ManagedCluster
spec:
  nodeProvisioningProfile:
    mode: Auto
    defaultNodePools: None
```

**Pros**:
- GitOps-friendly
- Declarative
- Version controlled
- Reproducible

### Azure CLI

```bash
az aks create \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools None
```

**Pros**:
- Quick for testing
- No Kubernetes operator required
- Direct Azure API access

## Troubleshooting

### Check Current NAP Configuration

```bash
# Get cluster NAP settings
az aks show \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --query "nodeProvisioningProfile" \
  -o json
```

### Common Issues

#### Issue: "NAP requires at least one NodePool"

**Cause**: Set `defaultNodePools: None` but didn't deploy custom NodePools

**Solution**:
```bash
kubectl apply -f NAP/Official/system-nodepool.yaml
kubectl apply -f NAP/Official/default-nodepool-override.yaml
```

#### Issue: Nodes still showing Ubuntu

**Cause**: Default Ubuntu NodePools still exist

**Solution**:
```bash
# Check which NodePools exist
kubectl get nodepools

# Delete Ubuntu-based pools
kubectl delete nodepool default
kubectl delete nodepool system-surge

# Deploy Azure Linux pools
kubectl apply -f NAP/Official/
```

## Flag Availability

The `--node-provisioning-default-pools` flag is available in:
- Azure CLI version 2.50.0 or later
- API version 2024-02-01 or later

Check your Azure CLI version:
```bash
az version
```

Update Azure CLI if needed:
```bash
# macOS
brew upgrade azure-cli

# Linux
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Windows
# Download and run the MSI installer from:
# https://aka.ms/installazurecliwindows
```

## References

- [Configure Node Pools for Node Auto-Provisioning (NAP) in AKS](https://learn.microsoft.com/en-us/azure/aks/node-auto-provisioning-node-pools)
- [Create Node Pools in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/create-node-pools)
- [az aks CLI Reference](https://learn.microsoft.com/en-us/cli/azure/aks/nodepool?view=azure-cli-latest)
- [Manage node pools in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/manage-node-pools)
