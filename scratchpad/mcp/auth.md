# Multi-Cluster Authentication with Workload Identity

This guide explains how to configure the AKS MCP server to manage multiple AKS clusters across different subscriptions using Azure Workload Identity.

## Overview

The AKS MCP server supports dynamic multi-cluster management. With proper configuration, you can switch between clusters across subscriptions without storing credentials - workload identity handles authentication automatically.

**Key insight**: The server already has kubelogin installed (v0.2.10), and by setting the `AAD_LOGIN_METHOD=workloadidentity` environment variable, kubelogin automatically uses the pod's federated identity.

## Prerequisites

- AKS MCP server deployed with workload identity enabled (see [helm-workload-identity.md](./helm-workload-identity.md))
- Access level set to `admin` (required for `az aks get-credentials`)
- UAMI with appropriate RBAC on target clusters

## RBAC Configuration

Your User-Assigned Managed Identity (UAMI) needs permissions on each target cluster:

```bash
# For each target cluster
export TARGET_SUBSCRIPTION_ID="<target-subscription-id>"
export TARGET_RG="<target-resource-group>"
export TARGET_CLUSTER="<target-cluster-name>"
export UAMI_PRINCIPAL_ID="<your-uami-principal-id>"

# Required: Cluster User Role (for get-credentials without --admin)
az role assignment create \
  --role "Azure Kubernetes Service Cluster User Role" \
  --assignee-object-id $UAMI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/${TARGET_SUBSCRIPTION_ID}/resourceGroups/${TARGET_RG}/providers/Microsoft.ContainerService/managedClusters/${TARGET_CLUSTER}"

# Required: Reader on subscription to list/query clusters
az role assignment create \
  --role "Reader" \
  --assignee-object-id $UAMI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/${TARGET_SUBSCRIPTION_ID}"
```

**Note**: For clusters with local accounts disabled (recommended), you do NOT use `--admin` flag. The UAMI authenticates via Microsoft Entra ID.

## Helm Configuration

Add the `AAD_LOGIN_METHOD` environment variable to your Helm values:

```yaml
# values-multi-cluster.yaml
app:
  accessLevel: "admin"  # Required for get-credentials

workloadIdentity:
  enabled: true

azure:
  clientId: "<your-uami-client-id>"
  # Don't set subscriptionId - you'll switch dynamically

extraEnv:
  - name: AAD_LOGIN_METHOD
    value: "workloadidentity"
```

Install with:

```bash
helm upgrade --install aks-mcp ./chart -f values-multi-cluster.yaml
```

## Multi-Cluster Connection Workflow

Once configured, switching clusters is straightforward using the MCP tools:

```
# Step 1: Set subscription context
call_az: az account set --subscription <target-subscription-id>

# Step 2: Get credentials for the target cluster
az_aks_operations: operation="get-credentials", args="--resource-group <rg> --name <cluster> --overwrite-existing"

# Step 3: Use kubectl against that cluster
call_kubectl: get nodes
```

The `AAD_LOGIN_METHOD=workloadidentity` environment variable tells kubelogin to automatically use workload identity authentication - no manual `kubelogin convert-kubeconfig` step required.

## How It Works

1. **Workload Identity Injection**: When the pod starts, the AKS workload identity webhook injects:
   - `AZURE_CLIENT_ID` - from the service account annotation
   - `AZURE_TENANT_ID` - from the cluster
   - `AZURE_FEDERATED_TOKEN_FILE` - path to the projected service account token
   - `AZURE_AUTHORITY_HOST` - Azure AD endpoint

2. **Azure CLI Authentication**: The Azure CLI automatically picks up these environment variables and authenticates using federated credentials.

3. **Kubeconfig with exec**: `az aks get-credentials` creates a kubeconfig that uses the `exec` credential plugin (kubelogin).

4. **Kubelogin with Workload Identity**: When kubectl runs, kubelogin reads `AAD_LOGIN_METHOD=workloadidentity` and uses the pod's federated token to get a Kubernetes access token.

## Considerations

### Concurrency

The server runs as a single replica with shared kubeconfig state. Concurrent multi-cluster operations may conflict. Consider:
- Serializing cluster-switching operations
- Using separate MCP server instances per cluster group if high concurrency is needed

### Subscription Switching

When switching subscriptions:
1. Always call `az account set` before `get-credentials`
2. Use `--overwrite-existing` to replace the current kubeconfig context

### Cluster Registry (Optional)

For managing many clusters, consider a ConfigMap-based registry:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-registry
data:
  clusters.json: |
    {
      "clusters": [
        {
          "alias": "prod-uksouth",
          "subscriptionId": "sub-1-guid",
          "resourceGroup": "rg-prod-uksouth",
          "clusterName": "aks-prod-uksouth-01"
        },
        {
          "alias": "prod-westeurope",
          "subscriptionId": "sub-2-guid",
          "resourceGroup": "rg-prod-westeurope",
          "clusterName": "aks-prod-westeurope-01"
        }
      ]
    }
```

## Troubleshooting

### "get-credentials requires admin access level"

Ensure `app.accessLevel=admin` in your Helm values.

### Authentication failures after get-credentials

Verify:
1. `AAD_LOGIN_METHOD=workloadidentity` is set in the pod environment
2. The UAMI has "Azure Kubernetes Service Cluster User Role" on the target cluster
3. The federated credential is correctly configured (check service account namespace/name)

### Token errors

Check that the workload identity environment variables are injected:
```bash
kubectl exec -it <pod> -- env | grep AZURE
```

Expected output includes `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, and `AZURE_AUTHORITY_HOST`.

## References

- [kubelogin Workload Identity](https://azure.github.io/kubelogin/concepts/login-modes/workloadidentity.html)
- [AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Helm Workload Identity Guide](./helm-workload-identity.md)
