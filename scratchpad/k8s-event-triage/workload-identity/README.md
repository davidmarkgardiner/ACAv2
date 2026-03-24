# Workload Identity Federation — OIDC Discovery + ASO FederatedIdentityCredentials

Automates workload identity setup across multiple AKS clusters in engineering. A single Job on the management cluster discovers OIDC issuer URLs and writes them to a ConfigMap. ASO FederatedIdentityCredential resources then reference that ConfigMap to bind UAMIs to service accounts on each cluster.

## How It Works

```
Management Cluster
──────────────────────────────────────────────────────────────────

  CronJob: oidc-discovery
    │
    │  az aks show --query oidcIssuerProfile.issuerUrl
    │  (for each cluster in engineering RGs)
    │
    ▼
  ConfigMap: aks-oidc-issuers
    │
    │  aks-eng-dev: https://oidc.prod-aks.azure.com/xxxx
    │  aks-eng-staging: https://oidc.prod-aks.azure.com/yyyy
    │  aks-eng-prod: https://oidc.prod-aks.azure.com/zzzz
    │
    ▼
  ASO FederatedIdentityCredential (one per cluster per SA)
    │
    │  issuerFromConfig:
    │    name: aks-oidc-issuers
    │    key: aks-eng-dev
    │  subject: system:serviceaccount:aks-mcp:aks-mcp
    │
    ▼
  Azure: UAMI federated credential created
    │
    │  Trust: aks-eng-dev's OIDC issuer → aks-mcp SA
    │
    ▼
  On aks-eng-dev: pod with SA "aks-mcp" can now
  authenticate as the UAMI (no secrets needed)
```

## Files

| File | Purpose |
|------|---------|
| `01-oidc-discovery-job.yaml` | CronJob + RBAC: discovers OIDC URLs, writes ConfigMap |
| `02-federated-credentials.yaml` | ASO FederatedIdentityCredential resources (one per cluster per SA) |

## Prerequisites

1. **Management cluster** with ASO installed
2. **UAMI** with `Reader` role on the resource groups containing AKS clusters (for `az aks show`)
3. **OIDC enabled** on all target AKS clusters (`oidcIssuerProfile.enabled: true`)
4. **kubectl access** from the Job pod to the management cluster API (for writing ConfigMap)

## Deploy

### Step 1: Run the OIDC discovery job

Edit `01-oidc-discovery-job.yaml`:
- Set `RESOURCE_GROUPS` to your engineering resource groups
- Set the UAMI client ID on the ServiceAccount annotation
- Replace the image with your private registry

```bash
kubectl apply -f 01-oidc-discovery-job.yaml

# Trigger a manual run to populate the ConfigMap immediately
kubectl create job --from=cronjob/oidc-discovery oidc-discovery-now \
  -n azureserviceoperator-system

# Watch it
kubectl logs -n azureserviceoperator-system -l app.kubernetes.io/name=oidc-discovery -f

# Verify the ConfigMap was created
kubectl get configmap aks-oidc-issuers -n azureserviceoperator-system -o yaml
```

Expected output:
```yaml
data:
  aks-eng-dev: "https://oidc.prod-aks.azure.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/"
  aks-eng-staging: "https://oidc.prod-aks.azure.com/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/"
  aks-eng-prod: "https://oidc.prod-aks.azure.com/zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz/"
```

### Step 2: Deploy the FederatedIdentityCredentials

Edit `02-federated-credentials.yaml`:
- Set `owner.name` to your UAMI ASO resource name
- Set `namespace` to where your UAMI lives
- Adjust `subject` to match the ServiceAccount on each target cluster
- Add/remove clusters as needed

```bash
kubectl apply -f 02-federated-credentials.yaml

# Check status — they'll show ConfigMapNotFound until the discovery job runs
kubectl get federatedidentitycredentials -n azureserviceoperator-system

# Once ready, check Azure
az identity federated-credential list \
  --identity-name aks-mcp-identity \
  --resource-group <RG> \
  --output table
```

## Adding a New Cluster

1. Add the resource group to `RESOURCE_GROUPS` in the CronJob (if not already there)
2. Wait for the CronJob to run (or trigger manually)
3. Add a new `FederatedIdentityCredential` block in `02-federated-credentials.yaml` with the cluster name as the `issuerFromConfig.key`
4. `kubectl apply -f 02-federated-credentials.yaml`

## Adding a New Service Account

Same OIDC issuer, different subject. Copy an existing FIC block and change:
- `metadata.name` — unique name for the FIC
- `spec.azureName` — unique Azure resource name
- `spec.owner.name` — the UAMI this SA should authenticate as
- `spec.subject` — `system:serviceaccount:{namespace}:{sa-name}` on the target cluster

## Configuration

### Discovery Job

| Env Var | Default | Description |
|---------|---------|-------------|
| `RESOURCE_GROUPS` | (required) | Comma-separated list of resource groups to scan |
| `DISCOVER_ALL` | `false` | If `true`, scans all AKS clusters in the subscription (ignores `RESOURCE_GROUPS`) |
| `CONFIGMAP_NAME` | `aks-oidc-issuers` | ConfigMap name to write |
| `CONFIGMAP_NAMESPACE` | `azureserviceoperator-system` | ConfigMap namespace |

### FederatedIdentityCredential

| Field | Description |
|-------|-------------|
| `owner.name` | ASO UserAssignedIdentity resource name (must exist in same namespace) |
| `audiences` | Always `["api://AzureADTokenExchange"]` for Azure AD |
| `issuerFromConfig.name` | ConfigMap name (`aks-oidc-issuers`) |
| `issuerFromConfig.key` | Cluster name (normalised: dots/underscores → dashes) |
| `subject` | `system:serviceaccount:{namespace}:{sa-name}` on the target cluster |

### ConfigMap Key Format

Cluster names are normalised for ConfigMap keys:
- `aks-eng-dev` → `aks-eng-dev` (no change)
- `aks.eng.dev` → `aks-eng-dev` (dots → dashes)
- `aks_eng_dev` → `aks-eng-dev` (underscores → dashes)

## Troubleshooting

### FIC stuck in ConfigMapNotFound

The ConfigMap doesn't exist yet. Run the discovery job:
```bash
kubectl create job --from=cronjob/oidc-discovery oidc-discovery-now \
  -n azureserviceoperator-system
```

### Discovery job fails with auth error

Check the UAMI has `Reader` on the resource groups:
```bash
az role assignment list --assignee <UAMI_CLIENT_ID> --output table
```

### OIDC URL is empty for a cluster

OIDC isn't enabled. Fix on the cluster:
```bash
az aks update --name <CLUSTER> --resource-group <RG> --enable-oidc-issuer
```

### FIC created in Azure but pod can't authenticate

Check on the target cluster:
1. ServiceAccount exists with the right labels
2. Pod has `azure.workload.identity/use: "true"` label
3. Workload Identity webhook is installed (`azure-wi-webhook-controller-manager` pod running)

```bash
kubectl get sa <SA_NAME> -n <NS> -o yaml | grep -A2 azure.workload.identity
kubectl get pods -n kube-system -l app.kubernetes.io/name=azure-workload-identity
```
