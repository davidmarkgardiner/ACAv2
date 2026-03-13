# AKS-MCP + UAMI: Cross-Cluster Access Troubleshooting

When AKS-MCP is deployed in-cluster using a User-Assigned Managed Identity (UAMI) and fails to connect to remote clusters, work through this checklist in order.

---

## Architecture

```
Management Cluster (aks-mcp pod)
  └── Service Account: aks-mcp (namespace: aks-mcp)
        └── Workload Identity annotation → UAMI Client ID
              └── Federated Credential → OIDC issuer of management cluster
                    └── UAMI (Azure resource)
                          └── Azure RBAC roles on target clusters
```

AKS-MCP authenticates to Azure via:
1. Workload Identity federation (pod → UAMI)
2. `az login --identity -u <CLIENT_ID>` (UAMI login)
3. `az aks get-credentials` to get kubeconfig for target clusters
4. `kubectl` commands against target clusters

---

## Step 1: Verify the UAMI Exists and Has the Right Client ID

```bash
# Get the UAMI client ID from the AKS-MCP deployment
kubectl get sa aks-mcp -n aks-mcp -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}'
echo ""

# Verify this UAMI exists in Azure
UAMI_CLIENT_ID=$(kubectl get sa aks-mcp -n aks-mcp -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}')
az identity list --query "[?clientId=='$UAMI_CLIENT_ID'].{name:name, rg:resourceGroup, clientId:clientId}" -o table
```

If empty: the UAMI doesn't exist or the client ID annotation is wrong.

---

## Step 2: Verify Workload Identity Is Enabled on the Management Cluster

```bash
# Check OIDC issuer is configured
az aks show -g <MGMT_RG> -n <MGMT_CLUSTER> --query "oidcIssuerProfile.issuerUrl" -o tsv

# Check workload identity is enabled
az aks show -g <MGMT_RG> -n <MGMT_CLUSTER> --query "securityProfile.workloadIdentity.enabled" -o tsv
# Must be: true
```

If OIDC issuer is empty or workload identity is not enabled:
```bash
az aks update -g <MGMT_RG> -n <MGMT_CLUSTER> \
  --enable-oidc-issuer \
  --enable-workload-identity
```

---

## Step 3: Verify the Federated Credential

The federated credential links the management cluster's OIDC issuer + service account to the UAMI.

```bash
# Get the UAMI resource ID
UAMI_NAME=$(az identity list --query "[?clientId=='$UAMI_CLIENT_ID'].name" -o tsv)
UAMI_RG=$(az identity list --query "[?clientId=='$UAMI_CLIENT_ID'].resourceGroup" -o tsv)

# List federated credentials on the UAMI
az identity federated-credential list \
  --identity-name "$UAMI_NAME" \
  --resource-group "$UAMI_RG" \
  -o table

# Check the details — issuer, subject, and audience must be correct
az identity federated-credential list \
  --identity-name "$UAMI_NAME" \
  --resource-group "$UAMI_RG" \
  --query "[].{name:name, issuer:issuer, subject:subject, audiences:audiences}" -o json
```

**Verify these match:**

| Field | Expected Value |
|-------|----------------|
| `issuer` | OIDC issuer URL of the **management cluster** (from Step 2) |
| `subject` | `system:serviceaccount:aks-mcp:aks-mcp` |
| `audiences` | `["api://AzureADTokenExchange"]` |

**Common mistakes:**
- Wrong OIDC issuer (pointing to a different cluster)
- Wrong subject (wrong namespace or SA name)
- Missing audience `api://AzureADTokenExchange`

**Fix:**
```bash
# Delete and recreate if wrong
az identity federated-credential delete \
  --identity-name "$UAMI_NAME" \
  --resource-group "$UAMI_RG" \
  --name <FEDCRED_NAME>

# Get the correct OIDC issuer
OIDC_ISSUER=$(az aks show -g <MGMT_RG> -n <MGMT_CLUSTER> --query "oidcIssuerProfile.issuerUrl" -o tsv)

az identity federated-credential create \
  --identity-name "$UAMI_NAME" \
  --resource-group "$UAMI_RG" \
  --name aks-mcp-fedcred \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:aks-mcp:aks-mcp" \
  --audiences "api://AzureADTokenExchange"
```

---

## Step 4: Verify the Service Account Has Workload Identity Labels

```bash
kubectl get sa aks-mcp -n aks-mcp -o yaml
```

**Must have:**
```yaml
metadata:
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: "<UAMI_CLIENT_ID>"
```

If the label is missing, the mutating webhook won't inject the token volume:
```bash
kubectl label sa aks-mcp -n aks-mcp azure.workload.identity/use=true
kubectl annotate sa aks-mcp -n aks-mcp azure.workload.identity/client-id=<UAMI_CLIENT_ID>
# Restart the pod to pick up the new token
kubectl rollout restart deployment/aks-mcp -n aks-mcp
```

---

## Step 5: Verify the Token Volume Is Mounted in the Pod

The workload identity mutating webhook should inject a projected token volume.

```bash
# Check the pod has the token volume
kubectl get pod -n aks-mcp -l app=aks-mcp -o jsonpath='{.items[0].spec.volumes[*].name}'
echo ""
# Should include: azure-identity-token (or similar)

# Check the token file exists inside the pod
kubectl exec -n aks-mcp deployment/aks-mcp -- ls -la /var/run/secrets/azure/tokens/
# Should show: azure-identity-token

# Check the injected env vars
kubectl exec -n aks-mcp deployment/aks-mcp -- env | grep -E "AZURE_|IDENTITY"
# Should show:
#   AZURE_CLIENT_ID=<your UAMI client ID>
#   AZURE_TENANT_ID=<your tenant ID>
#   AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
#   AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

If these env vars are missing:
- The workload identity webhook isn't installed or running
- The SA doesn't have `azure.workload.identity/use: "true"` label
- The pod was created before the label was added (restart it)

```bash
# Check webhook is running
kubectl get pods -n kube-system -l app=workload-identity-webhook
```

---

## Step 6: Test Azure Login from Inside the Pod

```bash
# Exec into the pod and test az login
kubectl exec -n aks-mcp deployment/aks-mcp -- az login --identity -u "$UAMI_CLIENT_ID" --output table

# If that fails, try federated token login (what AKS-MCP actually uses)
kubectl exec -n aks-mcp deployment/aks-mcp -- sh -c '
  az login --service-principal \
    -u "$AZURE_CLIENT_ID" \
    --tenant "$AZURE_TENANT_ID" \
    --federated-token "$(cat $AZURE_FEDERATED_TOKEN_FILE)" \
    --output table
'

# Verify the identity
kubectl exec -n aks-mcp deployment/aks-mcp -- az account show -o table
```

**Common errors:**
- `AADSTS70021: No matching federated identity record found` → Federated credential mismatch (Step 3)
- `AADSTS700016: Application not found in tenant` → Wrong client ID or UAMI doesn't exist
- `ManagedIdentityCredential authentication unavailable` → Token volume not mounted (Step 5)

---

## Step 7: Verify UAMI Has RBAC on Target Clusters

The UAMI needs Azure RBAC roles on **each target cluster** it needs to access.

```bash
# List the UAMI's role assignments
UAMI_PRINCIPAL_ID=$(az identity show --name "$UAMI_NAME" --resource-group "$UAMI_RG" --query principalId -o tsv)

az role assignment list --assignee "$UAMI_PRINCIPAL_ID" --all -o table

# Check specifically for AKS cluster access
az role assignment list --assignee "$UAMI_PRINCIPAL_ID" --all \
  --query "[?contains(scope, 'Microsoft.ContainerService/managedClusters')].{role:roleDefinitionName, scope:scope}" -o table
```

**Required roles per target cluster:**

| Role | Scope | Purpose |
|------|-------|---------|
| `Azure Kubernetes Service Cluster User Role` | Target AKS cluster resource | Get credentials (`az aks get-credentials`) |
| `Azure Kubernetes Service RBAC Reader` | Target AKS cluster resource | Read K8s resources (if using Azure RBAC for K8s) |
| `Azure Kubernetes Service RBAC Writer` | Target AKS cluster resource | Write K8s resources (if using Azure RBAC for K8s) |
| `Azure Kubernetes Service RBAC Admin` | Target AKS cluster resource | Admin access (if needed for remediation) |

**If using local K8s RBAC (not Azure RBAC for K8s auth):**

| Role | Scope | Purpose |
|------|-------|---------|
| `Azure Kubernetes Service Cluster User Role` | Target AKS cluster resource | Get credentials |
| `Azure Kubernetes Service Cluster Admin Role` | Target AKS cluster resource | Get admin credentials (bypasses K8s RBAC) |

**Assign missing roles:**
```bash
# Get the target cluster resource ID
TARGET_CLUSTER_ID=$(az aks show -g <TARGET_RG> -n <TARGET_CLUSTER> --query id -o tsv)

# Assign Cluster User Role (minimum for get-credentials)
az role assignment create \
  --assignee "$UAMI_PRINCIPAL_ID" \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "$TARGET_CLUSTER_ID"

# Assign RBAC Reader (for read-only kubectl access via Azure RBAC)
az role assignment create \
  --assignee "$UAMI_PRINCIPAL_ID" \
  --role "Azure Kubernetes Service RBAC Reader" \
  --scope "$TARGET_CLUSTER_ID"

# OR Assign RBAC Admin (for full kubectl access including remediation)
az role assignment create \
  --assignee "$UAMI_PRINCIPAL_ID" \
  --role "Azure Kubernetes Service RBAC Admin" \
  --scope "$TARGET_CLUSTER_ID"
```

**Note:** Role assignments can take up to **5 minutes** to propagate.

---

## Step 8: Test `az aks get-credentials` from Inside the Pod

```bash
# Try to get credentials for the target cluster
kubectl exec -n aks-mcp deployment/aks-mcp -- \
  az aks get-credentials -g <TARGET_RG> -n <TARGET_CLUSTER> --overwrite-existing

# Then test kubectl
kubectl exec -n aks-mcp deployment/aks-mcp -- kubectl get nodes
```

**Common errors:**
- `The client does not have authorization to perform action 'Microsoft.ContainerService/managedClusters/listClusterUserCredential/action'` → Missing `Azure Kubernetes Service Cluster User Role` on the target cluster
- `Unauthorized` after get-credentials → K8s RBAC or Azure RBAC for K8s not configured for this identity

---

## Step 9: Check if Target Cluster Uses Azure RBAC for K8s Auth

```bash
az aks show -g <TARGET_RG> -n <TARGET_CLUSTER> \
  --query "{aadProfile: aadProfile, azureRbac: aadProfile.enableAzureRBAC, localAccounts: disableLocalAccounts}" -o json
```

| Setting | Implication |
|---------|-------------|
| `enableAzureRBAC: true` | Need Azure K8s RBAC roles (Reader/Writer/Admin) on the UAMI |
| `enableAzureRBAC: false` | Need K8s RBAC (ClusterRole/ClusterRoleBinding) on the target cluster |
| `disableLocalAccounts: true` | Cannot use `--admin` flag, must use Azure AD auth |

**If Azure RBAC for K8s is disabled**, you need to create K8s RBAC on the target cluster:
```bash
# On the TARGET cluster, create a ClusterRoleBinding for the UAMI's AAD object
kubectl create clusterrolebinding aks-mcp-access \
  --clusterrole=cluster-admin \
  --user="$UAMI_PRINCIPAL_ID"
# Note: --user takes the AAD object ID (principal ID), not the client ID
```

---

## Step 10: Verify Network Connectivity

If the management cluster can't reach the target cluster's API server:

```bash
# Get the target cluster's API server FQDN
TARGET_FQDN=$(az aks show -g <TARGET_RG> -n <TARGET_CLUSTER> --query "fqdn" -o tsv)
echo "API Server: $TARGET_FQDN"

# Test connectivity from the AKS-MCP pod
kubectl exec -n aks-mcp deployment/aks-mcp -- sh -c "
  curl -sk --connect-timeout 5 https://$TARGET_FQDN:443/healthz && echo 'OK' || echo 'FAILED'
"
```

**If the target cluster is private:**
- The management cluster must have network line-of-sight (VNet peering, Private Link, etc.)
- DNS resolution must work for the private FQDN
- Check NSG rules on the target cluster's API server subnet

```bash
# Check if target is private
az aks show -g <TARGET_RG> -n <TARGET_CLUSTER> --query "apiServerAccessProfile" -o json
```

---

## Quick Reference: End-to-End Checklist

```
IDENTITY
[ ] UAMI exists in Azure with correct client ID
[ ] Workload Identity enabled on management cluster
[ ] OIDC issuer URL configured on management cluster
[ ] Federated credential exists with correct issuer, subject, audience
[ ] Service account has azure.workload.identity/use=true label
[ ] Service account has azure.workload.identity/client-id annotation
[ ] Token volume mounted in pod (/var/run/secrets/azure/tokens/)
[ ] AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE env vars present

AZURE RBAC (per target cluster)
[ ] Azure Kubernetes Service Cluster User Role assigned
[ ] Azure Kubernetes Service RBAC Reader/Writer/Admin assigned (if Azure RBAC for K8s)
[ ] OR K8s ClusterRoleBinding on target cluster (if local K8s RBAC)
[ ] Role assignments propagated (wait 5 mins after creating)

CONNECTIVITY
[ ] Management cluster can reach target cluster API server
[ ] DNS resolves target cluster FQDN from management cluster
[ ] No NSG/firewall blocking port 443 to target API server

AKS-MCP CONFIG
[ ] --access-level set correctly (admin for remediation)
[ ] AZURE_SUBSCRIPTION_ID set if target clusters are in different subscription
[ ] AKS-MCP pod restarted after SA annotation changes
```

---

## Common Error → Fix Quick Reference

| Error | Cause | Fix |
|-------|-------|-----|
| `AADSTS70021: No matching federated identity record found` | Federated credential mismatch | Check issuer URL, subject, audience (Step 3) |
| `AADSTS700016: Application not found` | Wrong client ID | Check SA annotation matches UAMI client ID (Step 4) |
| `listClusterUserCredential action not authorized` | Missing Azure role | Assign `AKS Cluster User Role` on target cluster (Step 7) |
| `Unauthorized` (kubectl) | Missing K8s RBAC | Assign Azure RBAC role or create K8s ClusterRoleBinding (Steps 7/9) |
| `dial tcp: i/o timeout` | Network issue | Check VNet peering, private cluster access (Step 10) |
| `token volume not found` | Workload Identity webhook | Check webhook running, SA label, restart pod (Step 5) |
| `AZURE_FEDERATED_TOKEN_FILE not set` | Token not injected | SA missing `azure.workload.identity/use` label (Step 4) |
