# HolmesGPT Multi-Cluster AKS Integration

Deploy HolmesGPT with AKS MCP to investigate multiple AKS clusters via MCP protocol.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MANAGEMENT CLUSTER                                   │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                           HolmesGPT                                    │  │
│  │  "Investigate OOMKilled pod in production"                            │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                      │                                       │
│                                      │ MCP protocol                          │
│                                      ▼                                       │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                         AKS MCP Server                                 │  │
│  │                                                                        │  │
│  │  1. Receives request with cluster context                             │  │
│  │  2. Runs: az aks get-credentials --name X --resource-group Y          │  │
│  │  3. Executes kubectl commands against target cluster                  │  │
│  │                                                                        │  │
│  │  [Workload Identity] ──► Azure RBAC ──► Target Clusters               │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                    │
                    │ on-demand credential fetch
                    ▼
     ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
     │aks-prod-     │  │aks-staging-  │  │aks-dev-      │
     │westeurope    │  │westeurope    │  │westeurope    │
     └──────────────┘  └──────────────┘  └──────────────┘
```

## How It Works

1. HolmesGPT receives an alert or investigation request
2. LLM instructions tell it which clusters are available
3. AKS MCP fetches credentials on-demand via `az aks get-credentials`
4. kubectl commands execute against the correct cluster
5. No CronJob needed - credentials are fetched when required

## Prerequisites

1. AKS MCP server deployed with Workload Identity
2. Managed Identity with RBAC on all target clusters
3. HolmesGPT configured with MCP server connection

## Quick Start

### 1. Configure Azure (One-time Setup)

```bash
# Create managed identity
az identity create \
  --name holmesgpt-aks-mcp-identity \
  --resource-group rg-management

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show --name holmesgpt-aks-mcp-identity --resource-group rg-management --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --name holmesgpt-aks-mcp-identity --resource-group rg-management --query principalId -o tsv)

# Grant access to each target cluster
for cluster in "sub1|rg-prod|aks-prod-westeurope" "sub1|rg-staging|aks-staging-westeurope"; do
  IFS='|' read -r SUB RG NAME <<< "$cluster"
  az role assignment create \
    --assignee-object-id $IDENTITY_PRINCIPAL_ID \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ContainerService/managedClusters/$NAME"
done

# Create federated credential for workload identity
az identity federated-credential create \
  --name holmesgpt-aks-mcp-fedcred \
  --identity-name holmesgpt-aks-mcp-identity \
  --resource-group rg-management \
  --issuer $(az aks show -n management-cluster -g rg-management --query oidcIssuerUrl -o tsv) \
  --subject system:serviceaccount:holmesgpt:aks-mcp \
  --audiences api://AzureADTokenExchange
```

### 2. Deploy AKS MCP Server

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: holmesgpt
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aks-mcp
  namespace: holmesgpt
  annotations:
    azure.workload.identity/client-id: "<YOUR_MANAGED_IDENTITY_CLIENT_ID>"
  labels:
    azure.workload.identity/use: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-mcp
  namespace: holmesgpt
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-mcp
  template:
    metadata:
      labels:
        app: aks-mcp
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: aks-mcp
      containers:
      - name: aks-mcp
        image: ghcr.io/azure/aks-mcp:latest
        args: ["--transport", "sse", "--port", "8000", "--access-level", "admin"]
        ports:
        - containerPort: 8000
        env:
        - name: AZURE_CLIENT_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.annotations['azure.workload.identity/client-id']
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: aks-mcp
  namespace: holmesgpt
spec:
  selector:
    app: aks-mcp
  ports:
  - port: 8000
    targetPort: 8000
```

### 3. Configure HolmesGPT

In your Holmes `config.yaml`, add the MCP server with cluster-aware instructions:

```yaml
model: anthropic/claude-sonnet-4-20250514

toolsets:
  kubernetes/core:
    enabled: false  # Disable built-in - we use AKS MCP instead
  kubernetes/logs:
    enabled: false

mcp_servers:
  aks-mcp:
    description: "Azure Kubernetes Service MCP server with multi-cluster access"
    url: "http://aks-mcp.holmesgpt.svc.cluster.local:8000/sse"
    llm_instructions: |
      ## Available AKS Clusters

      You have access to ONLY these clusters:

      | Friendly Name | Cluster Name           | Resource Group        | Subscription ID                      |
      |---------------|------------------------|-----------------------|--------------------------------------|
      | prod          | aks-prod-westeurope    | rg-prod-westeurope    | 00000000-0000-0000-0000-000000000000 |
      | staging       | aks-staging-westeurope | rg-staging-westeurope | 00000000-0000-0000-0000-000000000000 |
      | dev           | aks-dev-westeurope     | rg-dev-westeurope     | 00000000-0000-0000-0000-000000000000 |

      ## MANDATORY WORKFLOW

      1. IDENTIFY the target cluster from the user's request
         - "prod", "production" → aks-prod-westeurope
         - "staging", "stg" → aks-staging-westeurope
         - "dev", "development" → aks-dev-westeurope
         - If unclear, ASK the user which cluster

      2. GET CREDENTIALS before any kubectl command:
         az aks get-credentials --name <cluster-name> --resource-group <resource-group> --overwrite-existing

      3. VERIFY the context:
         kubectl config current-context

      4. RUN your diagnostic commands

      ## RULES

      - NEVER guess which cluster - if ambiguous, ask
      - ALWAYS use --resource-group with the cluster name
      - ALWAYS verify context before destructive operations
      - If credentials fail, report the error - do not try other clusters
```

### 4. Test

```bash
# Port-forward to Holmes
kubectl port-forward -n holmesgpt svc/holmes 5050:5050 &

# Test multi-cluster investigation
curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Test Multi-Cluster",
    "description": "List all pods in default namespace on production",
    "context": {}
  }'
```

## Adding New Clusters

1. Grant RBAC to the managed identity:
```bash
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "/subscriptions/SUB/resourceGroups/RG/providers/Microsoft.ContainerService/managedClusters/CLUSTER"
```

2. Update the `llm_instructions` in Holmes config with the new cluster details

3. Restart Holmes to pick up the config change

## Troubleshooting

### AKS MCP can't fetch credentials

```bash
# Check workload identity is configured
kubectl get sa aks-mcp -n holmesgpt -o yaml | grep azure

# Check pod has identity labels
kubectl get pod -n holmesgpt -l app=aks-mcp -o yaml | grep -A5 labels

# Test from MCP pod
kubectl exec -n holmesgpt deploy/aks-mcp -- az account show
kubectl exec -n holmesgpt deploy/aks-mcp -- az aks get-credentials --name aks-prod-westeurope --resource-group rg-prod-westeurope
```

### Holmes not connecting to MCP

```bash
# Check MCP service is reachable
kubectl exec -n holmesgpt deploy/holmes -- curl -s http://aks-mcp:8000/health

# Check Holmes logs for MCP errors
kubectl logs -n holmesgpt deploy/holmes | grep -i mcp
```

### Wrong cluster targeted

1. Check the `llm_instructions` - ensure cluster names are correct
2. Verify the LLM is following the mandatory workflow (look at Holmes logs)
3. Make instructions more explicit if needed

## Security Notes

- The managed identity has access to all target clusters
- Access control is via Azure RBAC on the identity
- Network policies can restrict which pods can reach AKS MCP
- Consider read-only RBAC roles for production clusters if Holmes shouldn't make changes
