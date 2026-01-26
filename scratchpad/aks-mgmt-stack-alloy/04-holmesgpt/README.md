# HolmesGPT Multi-Cluster Deployment

This directory contains the configuration for deploying HolmesGPT on a **management cluster** to investigate **remote target clusters**.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MANAGEMENT CLUSTER                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────────────┐ │
│  │ Argo Events │───►│ Argo        │───►│ HolmesGPT   │───►│ GitLab/      │ │
│  │ (Sensor)    │    │ Workflows   │    │ (AI Triage) │    │ Mattermost   │ │
│  └─────────────┘    └─────────────┘    └──────┬──────┘    └──────────────┘ │
│                                               │                              │
│                                               │ az aks get-credentials       │
│                                               │ kubectl --context            │
│                                               ▼                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Cluster Registry                              │   │
│  │  cluster-registry ConfigMap: maps cluster names to Azure resources  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        │ Uses kubeconfig contexts
                                        ▼
    ┌───────────────────────────────────────────────────────────────────────┐
    │                         TARGET CLUSTERS                                │
    │                                                                        │
    │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       │
    │  │ aks-prod-       │  │ aks-staging-    │  │ aks-dev-        │       │
    │  │ westeurope      │  │ westeurope      │  │ westeurope      │       │
    │  │                 │  │                 │  │                 │       │
    │  │ Fluent Bit ────────────► Event Hub ─────────► Management  │       │
    │  │ (K8s events)    │  │ (K8s events)    │  │      Cluster    │       │
    │  └─────────────────┘  └─────────────────┘  └─────────────────┘       │
    └───────────────────────────────────────────────────────────────────────┘
```

## Key Principle

**HolmesGPT on the management cluster should NEVER investigate itself.**

All investigations are performed against remote target clusters using:
1. Explicit cluster name passed via workflow parameters
2. `az aks get-credentials` to fetch cluster credentials if not cached
3. `kubectl --context=<cluster-name>` for all commands

## Files

| File | Description |
|------|-------------|
| `holmesgpt-multi-cluster.yaml` | Full deployment manifest with multi-cluster support |
| `holmesgpt-token-optimized.yaml` | Legacy single-cluster deployment (deprecated) |

## Prerequisites

### 1. Azure Workload Identity

HolmesGPT needs permissions to fetch AKS credentials for all target clusters.

```bash
# Create managed identity for HolmesGPT
az identity create \
  --name holmesgpt-identity \
  --resource-group rg-mgmt-cluster \
  --location westeurope

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show --name holmesgpt-identity --resource-group rg-mgmt-cluster --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --name holmesgpt-identity --resource-group rg-mgmt-cluster --query principalId -o tsv)

# Grant "Azure Kubernetes Service Cluster User Role" on each target cluster
for CLUSTER in aks-prod-westeurope aks-staging-westeurope aks-dev-westeurope; do
  CLUSTER_ID=$(az aks show --name $CLUSTER --resource-group "rg-${CLUSTER}" --query id -o tsv)
  az role assignment create \
    --assignee-object-id $IDENTITY_PRINCIPAL_ID \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope $CLUSTER_ID
done

# Create federated credential for Kubernetes service account
az identity federated-credential create \
  --name holmesgpt-fedcred \
  --identity-name holmesgpt-identity \
  --resource-group rg-mgmt-cluster \
  --issuer $(az aks show --name aks-mgmt-cluster --resource-group rg-mgmt-cluster --query oidcIssuerProfile.issuerUrl -o tsv) \
  --subject system:serviceaccount:holmesgpt:holmes \
  --audience api://AzureADTokenExchange
```

### 2. Cluster Registry ConfigMap

Update the `cluster-registry` ConfigMap with your target clusters:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-registry
  namespace: holmesgpt
data:
  clusters.yaml: |
    clusters:
      aks-prod-westeurope:
        resource_group: "rg-aks-prod-westeurope"
        subscription: "00000000-0000-0000-0000-000000000000"
        display_name: "Production West Europe"
      aks-staging-westeurope:
        resource_group: "rg-aks-staging-westeurope"
        subscription: "00000000-0000-0000-0000-000000000000"
        display_name: "Staging West Europe"
      aks-dev-westeurope:
        resource_group: "rg-aks-dev-westeurope"
        subscription: "00000000-0000-0000-0000-000000000000"
        display_name: "Development West Europe"
```

### 3. Secrets

Create the Holmes secrets with your API keys:

```bash
kubectl create secret generic holmes-secrets \
  --namespace holmesgpt \
  --from-literal=ANTHROPIC_API_KEY="your-anthropic-key" \
  --from-literal=OPENAI_API_KEY="optional-openai-key"
```

## Deployment

### Option 1: Using the Manifest

```bash
# Update the cluster registry first
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-registry
  namespace: holmesgpt
data:
  clusters.yaml: |
    clusters:
      # Add your clusters here
      aks-prod-westeurope:
        resource_group: "rg-aks-prod-westeurope"
        subscription: "your-subscription-id"
        display_name: "Production"
EOF

# Deploy HolmesGPT
kubectl apply -f holmesgpt-multi-cluster.yaml
```

### Option 2: Using Helm

```bash
helm upgrade --install holmes robusta/holmes \
  --namespace holmesgpt \
  --create-namespace \
  -f ../../../.claude/skills/holmesgpt-deployer/assets/helm-values-aks-integration.yaml \
  --set additionalEnvVars[6].value="aks-mgmt-cluster"  # Set your management cluster name
```

## How It Works

### Event Flow

1. **Fluent Bit** on target clusters sends Kubernetes events to **Azure Event Hub**
2. **Argo Events Sensor** consumes events and extracts cluster name from payload
3. **Argo Workflow** is triggered with cluster name as parameter
4. **Workflow validates** target cluster is reachable (not the management cluster)
5. **HolmesGPT** receives investigation request with explicit cluster context
6. **HolmesGPT** fetches credentials using `az aks get-credentials` if needed
7. **HolmesGPT** runs kubectl commands with `--context=<cluster-name>`
8. Results are posted to **GitLab** and **Mattermost**

### Safety Mechanisms

1. **Management Cluster Block**: Workflow fails if `cluster-name` matches management cluster
2. **Explicit Context Required**: HolmesGPT requires cluster in investigation request
3. **Context Verification**: Validates context after switching before running commands
4. **Disabled Local Toolsets**: Built-in kubernetes toolsets are disabled to prevent local access

## Workflow Template

The workflow template passes cluster context to HolmesGPT:

```yaml
# Investigation request sent to Holmes
{
  "source": "multi-cluster-automation",
  "title": "[aks-prod-westeurope] OOMKilled: default/my-pod",
  "description": "IMPORTANT: Investigate on cluster 'aks-prod-westeurope', NOT local",
  "subject": {
    "name": "my-pod",
    "namespace": "default",
    "kind": "Pod",
    "cluster": "aks-prod-westeurope"  # Explicit cluster
  },
  "context": {
    "cluster": "aks-prod-westeurope",  # Explicit cluster
    "target_cluster": "aks-prod-westeurope",  # Redundant but clear
    "investigation_scope": "remote_cluster_only"
  },
  "instructions": "You MUST investigate cluster 'aks-prod-westeurope', NOT the local cluster."
}
```

## Verification

### Check Deployment Status

```bash
# Check pods
kubectl get pods -n holmesgpt

# Check logs for startup
kubectl logs -n holmesgpt deploy/holmes -f
```

### Verify Cluster Registry

```bash
kubectl exec -n holmesgpt deploy/holmes -- cat /etc/holmes/clusters/clusters.yaml
```

### Check Available Contexts

```bash
kubectl exec -n holmesgpt deploy/holmes -- kubectl config get-contexts
```

### Test Multi-Cluster Investigation

```bash
# Test investigation against a target cluster
kubectl exec -n holmesgpt deploy/holmes -- curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Test Investigation",
    "description": "List pods in default namespace",
    "subject": {
      "name": "test",
      "namespace": "default",
      "cluster": "aks-prod-westeurope"
    },
    "context": {
      "cluster": "aks-prod-westeurope"
    }
  }'
```

### Verify Correct Cluster Targeting

Check Holmes logs for cluster context messages:

```bash
kubectl logs -n holmesgpt deploy/holmes | grep -E "(cluster|context)"
```

You should see:
- `Switching to cluster context: aks-prod-westeurope`
- `Executing kubectl command against cluster: aks-prod-westeurope`

You should NOT see commands running against the management cluster.

## Troubleshooting

### Holmes Can't Fetch Credentials

```bash
# Check Workload Identity is configured
kubectl get pods -n holmesgpt -o yaml | grep -A5 workload.identity

# Test az login with Workload Identity
kubectl exec -n holmesgpt deploy/holmes -c azure-cli-sidecar -- az account show
```

### Context Not Switching

```bash
# Check kubectl-wrapper script is mounted
kubectl exec -n holmesgpt deploy/holmes -- ls -la /etc/holmes/scripts/

# Test wrapper manually
kubectl exec -n holmesgpt deploy/holmes -- bash -c 'export HOLMES_TARGET_CLUSTER=aks-prod-westeurope && /etc/holmes/scripts/kubectl-wrapper.sh get nodes'
```

### Investigation Running on Wrong Cluster

Check workflow parameters:

```bash
# Get recent workflow
WORKFLOW=$(kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

# Check parameters
kubectl get workflow $WORKFLOW -n argo-events -o jsonpath='{.spec.arguments.parameters}'
```

Verify the `cluster-name` parameter matches expected target cluster.

## Adding New Target Clusters

1. **Update cluster registry ConfigMap**:
```bash
kubectl edit configmap cluster-registry -n holmesgpt
```

2. **Add Azure RBAC**:
```bash
CLUSTER_ID=$(az aks show --name NEW_CLUSTER --resource-group NEW_RG --query id -o tsv)
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope $CLUSTER_ID
```

3. **Restart Holmes to pre-fetch credentials**:
```bash
kubectl rollout restart deployment/holmes -n holmesgpt
```

## Related Files

- Workflow template: `../05-workflow/workflow-multi-cluster-triage-optimized.yaml`
- Event sensor: `../07-event-flow/02-sensor-production.yaml`
- Helm values: `../../.claude/skills/holmesgpt-deployer/assets/helm-values-aks-integration.yaml`
