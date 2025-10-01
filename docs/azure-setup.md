# Azure Service Principal Setup Guide

This guide covers setting up Azure authentication for the ACA platform to deploy Container Apps via Argo Workflows.

## Prerequisites

- Azure CLI installed (`az --version`)
- Azure subscription with Owner or Contributor role
- Kubernetes cluster with Argo Workflows installed
- kubectl configured to access the cluster

## 1. Create Azure Service Principal

### Option A: Using Azure CLI (Recommended)

```bash
# Set your Azure subscription
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# Create Service Principal with Contributor role
az ad sp create-for-rbac \
  --name "aca-platform-sp" \
  --role Contributor \
  --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID> \
  --sdk-auth

# Output will look like:
# {
#   "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
#   "clientSecret": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
#   "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
#   "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
#   "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
#   "resourceManagerEndpointUrl": "https://management.azure.com/",
#   ...
# }
```

**Save these credentials securely - they will be used in the next steps.**

### Option B: Using Azure Portal

1. Navigate to **Azure Active Directory** > **App registrations**
2. Click **New registration**
3. Name: `aca-platform-sp`
4. Click **Register**
5. Note the **Application (client) ID** and **Directory (tenant) ID**
6. Go to **Certificates & secrets** > **New client secret**
7. Create a secret and note the **Value** (client secret)
8. Go to your **Subscription** > **Access control (IAM)**
9. Click **Add role assignment**
10. Select **Contributor** role
11. Assign access to the Service Principal created above

## 2. Assign Required RBAC Permissions

The Service Principal needs the following permissions:

```bash
# Contributor role (already assigned above)
# Allows: Resource Group creation, Container App deployment, networking, monitoring

# If you need more granular permissions, use custom role:
az role definition create --role-definition '{
  "Name": "ACA Platform Deployer",
  "Description": "Can deploy Azure Container Apps and related resources",
  "Actions": [
    "Microsoft.App/containerApps/*",
    "Microsoft.App/managedEnvironments/*",
    "Microsoft.Resources/resourceGroups/*",
    "Microsoft.Network/virtualNetworks/*",
    "Microsoft.Network/networkSecurityGroups/*",
    "Microsoft.OperationalInsights/workspaces/*",
    "Microsoft.KeyVault/vaults/*"
  ],
  "AssignableScopes": ["/subscriptions/<YOUR_SUBSCRIPTION_ID>"]
}'

# Assign custom role to Service Principal
az role assignment create \
  --assignee <CLIENT_ID> \
  --role "ACA Platform Deployer" \
  --scope /subscriptions/<YOUR_SUBSCRIPTION_ID>
```

## 3. Create Kubernetes Secrets

### Store Azure Credentials in Kubernetes

```bash
# Create the argo namespace if it doesn't exist
kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -

# Create secret with Azure credentials
kubectl create secret generic azure-credentials \
  --namespace=argo \
  --from-literal=client-id=<YOUR_CLIENT_ID> \
  --from-literal=client-secret=<YOUR_CLIENT_SECRET> \
  --from-literal=tenant-id=<YOUR_TENANT_ID> \
  --from-literal=subscription-id=<YOUR_SUBSCRIPTION_ID>

# Verify secret was created
kubectl get secret azure-credentials -n argo

# View secret (base64 encoded)
kubectl get secret azure-credentials -n argo -o yaml
```

### Verify Secret Contents (Optional)

```bash
# Decode and view secret values (for debugging only)
kubectl get secret azure-credentials -n argo -o json | \
  jq '.data | map_values(@base64d)'

# Expected output:
# {
#   "client-id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
#   "client-secret": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
#   "subscription-id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
#   "tenant-id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# }
```

## 4. Test Azure Authentication

### Test from Local Machine

```bash
# Login with Service Principal
az login --service-principal \
  -u <CLIENT_ID> \
  -p <CLIENT_SECRET> \
  --tenant <TENANT_ID>

# Verify access
az account show
az group list

# Test Container Apps access
az containerapp list
```

### Test from Kubernetes Pod

```bash
# Create a test pod with Azure CLI
kubectl run azure-cli-test \
  --namespace=argo \
  --image=mcr.microsoft.com/azure-cli:latest \
  --restart=Never \
  --rm -it \
  --env="AZURE_CLIENT_ID=$(kubectl get secret azure-credentials -n argo -o jsonpath='{.data.client-id}' | base64 -d)" \
  --env="AZURE_CLIENT_SECRET=$(kubectl get secret azure-credentials -n argo -o jsonpath='{.data.client-secret}' | base64 -d)" \
  --env="AZURE_TENANT_ID=$(kubectl get secret azure-credentials -n argo -o jsonpath='{.data.tenant-id}' | base64 -d)" \
  --env="AZURE_SUBSCRIPTION_ID=$(kubectl get secret azure-credentials -n argo -o jsonpath='{.data.subscription-id}' | base64 -d)" \
  -- bash -c "az login --service-principal -u \$AZURE_CLIENT_ID -p \$AZURE_CLIENT_SECRET --tenant \$AZURE_TENANT_ID && az account show"
```

If successful, you'll see your subscription details.

## 5. Configure Argo Workflows

The workflows in `argo/workflows/` are already configured to use these secrets:

```yaml
env:
  - name: AZURE_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: azure-credentials
        key: client-id
  - name: AZURE_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: azure-credentials
        key: client-secret
  - name: AZURE_TENANT_ID
    valueFrom:
      secretKeyRef:
        name: azure-credentials
        key: tenant-id
  - name: AZURE_SUBSCRIPTION_ID
    valueFrom:
      secretKeyRef:
        name: azure-credentials
        key: subscription-id
```

## 6. Security Best Practices

### Rotate Credentials Regularly

```bash
# Create new client secret
NEW_SECRET=$(az ad sp credential reset \
  --id <CLIENT_ID> \
  --query password -o tsv)

# Update Kubernetes secret
kubectl create secret generic azure-credentials \
  --namespace=argo \
  --from-literal=client-id=<CLIENT_ID> \
  --from-literal=client-secret=$NEW_SECRET \
  --from-literal=tenant-id=<TENANT_ID> \
  --from-literal=subscription-id=<SUBSCRIPTION_ID> \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Use Azure Key Vault (Advanced)

For production, consider using Azure Key Vault with managed identity:

```bash
# Enable Azure Key Vault Provider for Secrets Store CSI Driver
helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
helm install csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --generate-name
```

### Restrict Secret Access

```yaml
# Create role that only allows reading azure-credentials secret
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: azure-credentials-reader
  namespace: argo
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["azure-credentials"]
  verbs: ["get"]
```

## 7. Troubleshooting

### Authentication Failures

```bash
# Check if secret exists
kubectl get secret azure-credentials -n argo

# Verify secret has correct keys
kubectl get secret azure-credentials -n argo -o jsonpath='{.data}' | jq 'keys'

# Test Service Principal login manually
az login --service-principal \
  -u <CLIENT_ID> \
  -p <CLIENT_SECRET> \
  --tenant <TENANT_ID>
```

### Permission Errors

```bash
# List role assignments for Service Principal
az role assignment list --assignee <CLIENT_ID> --all

# Check effective permissions
az role assignment list --assignee <CLIENT_ID> --scope /subscriptions/<SUBSCRIPTION_ID>
```

### Secret Not Available in Pod

```bash
# Check workflow pod logs
kubectl logs -n argo <workflow-pod-name>

# Verify ServiceAccount has access to secrets
kubectl get sa aca-workflow-sa -n argo -o yaml

# Check RBAC permissions
kubectl auth can-i get secrets --as=system:serviceaccount:argo:aca-workflow-sa -n argo
```

## 8. Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `AZURE_CLIENT_ID` | Application (client) ID of Service Principal | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_CLIENT_SECRET` | Client secret value | `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |
| `AZURE_TENANT_ID` | Directory (tenant) ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |

## 9. Next Steps

After completing Azure authentication setup:

1. Deploy Argo Workflows templates: `kubectl apply -f argo/workflows/`
2. Deploy Argo Events components: `kubectl apply -f argo/events/`
3. Test end-to-end deployment with sample payload
4. Configure monitoring and alerting for deployments
5. Set up credential rotation automation

## Additional Resources

- [Azure Service Principal Documentation](https://learn.microsoft.com/en-us/azure/active-directory/develop/app-objects-and-service-principals)
- [Azure RBAC Best Practices](https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices)
- [Kubernetes Secrets Management](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Argo Workflows Secret Management](https://argoproj.github.io/argo-workflows/workflow-secrets/)
