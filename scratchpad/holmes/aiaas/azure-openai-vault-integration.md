# Azure OpenAI with HashiCorp Vault

This guide explains how to securely inject Azure service principal credentials from HashiCorp Vault into HolmesGPT for Azure OpenAI authentication.

## Overview

Instead of storing Azure credentials directly in Kubernetes secrets, you can use HashiCorp Vault to:

- Centrally manage secrets across multiple clusters
- Rotate credentials automatically
- Audit secret access
- Use dynamic secrets for enhanced security

## Prerequisites

- HashiCorp Vault instance (self-hosted or HCP Vault)
- Vault Agent Injector or External Secrets Operator installed in your cluster
- Azure service principal with access to Azure OpenAI
- HolmesGPT Helm chart

## Store Secrets in Vault

First, store your Azure credentials in Vault:

```bash
# Enable KV secrets engine (if not already enabled)
vault secrets enable -path=secret kv-v2

# Store Azure credentials
vault kv put secret/holmesgpt/azure \
  tenant_id="your-tenant-id" \
  client_id="your-client-id" \
  client_secret="your-client-secret" \
  api_base="https://your-resource.openai.azure.com" \
  api_version="2024-02-01"
```

## Option 1: Vault Agent Injector (Recommended)

The Vault Agent Injector automatically injects secrets into pods using annotations.

### Step 1: Configure Vault Kubernetes Auth

```bash
# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_HOST:443" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create policy for HolmesGPT
vault policy write holmesgpt - <<EOF
path "secret/data/holmesgpt/azure" {
  capabilities = ["read"]
}
EOF

# Create role for HolmesGPT service account
vault write auth/kubernetes/role/holmesgpt \
  bound_service_account_names=holmes-holmes \
  bound_service_account_namespaces=holmesgpt \
  policies=holmesgpt \
  ttl=1h
```

### Step 2: Configure HolmesGPT Helm Values

```yaml
# values.yaml
podAnnotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "holmesgpt"
  vault.hashicorp.com/agent-inject-secret-azure-creds: "secret/data/holmesgpt/azure"
  vault.hashicorp.com/agent-inject-template-azure-creds: |
    {{- with secret "secret/data/holmesgpt/azure" -}}
    export AZURE_TENANT_ID="{{ .Data.data.tenant_id }}"
    export AZURE_CLIENT_ID="{{ .Data.data.client_id }}"
    export AZURE_CLIENT_SECRET="{{ .Data.data.client_secret }}"
    export AZURE_API_BASE="{{ .Data.data.api_base }}"
    export AZURE_API_VERSION="{{ .Data.data.api_version }}"
    {{- end -}}

# Source the vault secrets before starting the application
command:
  - /bin/sh
  - -c
  - |
    source /vault/secrets/azure-creds
    exec python -m holmes.main server

modelList:
  azure-gpt4:
    model: azure/your-deployment-name
    api_base: "{{ env.AZURE_API_BASE }}"
    api_version: "{{ env.AZURE_API_VERSION }}"
    tenant_id: "{{ env.AZURE_TENANT_ID }}"
    client_id: "{{ env.AZURE_CLIENT_ID }}"
    client_secret: "{{ env.AZURE_CLIENT_SECRET }}"
    temperature: 0

config:
  model: "azure-gpt4"
```

### Step 3: Install HolmesGPT

```bash
helm upgrade --install holmes robusta/holmes \
  -f values.yaml \
  -n holmesgpt \
  --create-namespace
```

## Option 2: External Secrets Operator

The External Secrets Operator syncs secrets from Vault to Kubernetes secrets.

### Step 1: Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace
```

### Step 2: Create SecretStore

```yaml
# vault-secretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: holmesgpt
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "holmesgpt"
          serviceAccountRef:
            name: "holmes-holmes"
```

### Step 3: Create ExternalSecret

```yaml
# azure-external-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: holmes-azure-credentials
  namespace: holmesgpt
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: holmes-azure-credentials
    creationPolicy: Owner
  data:
    - secretKey: tenant-id
      remoteRef:
        key: holmesgpt/azure
        property: tenant_id
    - secretKey: client-id
      remoteRef:
        key: holmesgpt/azure
        property: client_id
    - secretKey: client-secret
      remoteRef:
        key: holmesgpt/azure
        property: client_secret
    - secretKey: api-base
      remoteRef:
        key: holmesgpt/azure
        property: api_base
    - secretKey: api-version
      remoteRef:
        key: holmesgpt/azure
        property: api_version
```

### Step 4: Apply External Secret Resources

```bash
kubectl apply -f vault-secretstore.yaml
kubectl apply -f azure-external-secret.yaml
```

### Step 5: Configure HolmesGPT Helm Values

```yaml
# values.yaml
additionalEnvVars:
  - name: AZURE_TENANT_ID
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: tenant-id
  - name: AZURE_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: client-id
  - name: AZURE_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: client-secret
  - name: AZURE_API_BASE
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: api-base
  - name: AZURE_API_VERSION
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: api-version

modelList:
  azure-gpt4:
    model: azure/your-deployment-name
    api_base: "{{ env.AZURE_API_BASE }}"
    api_version: "{{ env.AZURE_API_VERSION }}"
    tenant_id: "{{ env.AZURE_TENANT_ID }}"
    client_id: "{{ env.AZURE_CLIENT_ID }}"
    client_secret: "{{ env.AZURE_CLIENT_SECRET }}"
    temperature: 0

config:
  model: "azure-gpt4"
```

### Step 6: Install HolmesGPT

```bash
helm upgrade --install holmes robusta/holmes \
  -f values.yaml \
  -n holmesgpt \
  --create-namespace
```

## Option 3: Vault CSI Provider

Use the Vault CSI Provider to mount secrets as files.

### Step 1: Install Vault CSI Provider

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --set "injector.enabled=false" \
  --set "csi.enabled=true" \
  -n vault \
  --create-namespace
```

### Step 2: Create SecretProviderClass

```yaml
# vault-spc.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-azure-creds
  namespace: holmesgpt
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.example.com"
    roleName: "holmesgpt"
    objects: |
      - objectName: "tenant-id"
        secretPath: "secret/data/holmesgpt/azure"
        secretKey: "tenant_id"
      - objectName: "client-id"
        secretPath: "secret/data/holmesgpt/azure"
        secretKey: "client_id"
      - objectName: "client-secret"
        secretPath: "secret/data/holmesgpt/azure"
        secretKey: "client_secret"
      - objectName: "api-base"
        secretPath: "secret/data/holmesgpt/azure"
        secretKey: "api_base"
      - objectName: "api-version"
        secretPath: "secret/data/holmesgpt/azure"
        secretKey: "api_version"
  secretObjects:
    - secretName: holmes-azure-credentials
      type: Opaque
      data:
        - objectName: tenant-id
          key: tenant-id
        - objectName: client-id
          key: client-id
        - objectName: client-secret
          key: client-secret
        - objectName: api-base
          key: api-base
        - objectName: api-version
          key: api-version
```

### Step 3: Configure HolmesGPT Helm Values

```yaml
# values.yaml
extraVolumes:
  - name: vault-secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: vault-azure-creds

extraVolumeMounts:
  - name: vault-secrets
    mountPath: /mnt/secrets-store
    readOnly: true

additionalEnvVars:
  - name: AZURE_TENANT_ID
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: tenant-id
  - name: AZURE_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: client-id
  - name: AZURE_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: client-secret
  - name: AZURE_API_BASE
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: api-base
  - name: AZURE_API_VERSION
    valueFrom:
      secretKeyRef:
        name: holmes-azure-credentials
        key: api-version

modelList:
  azure-gpt4:
    model: azure/your-deployment-name
    api_base: "{{ env.AZURE_API_BASE }}"
    api_version: "{{ env.AZURE_API_VERSION }}"
    tenant_id: "{{ env.AZURE_TENANT_ID }}"
    client_id: "{{ env.AZURE_CLIENT_ID }}"
    client_secret: "{{ env.AZURE_CLIENT_SECRET }}"
    temperature: 0

config:
  model: "azure-gpt4"
```

## Verification

After deployment, verify the secrets are injected correctly:

```bash
# Check pod is running
kubectl get pods -n holmesgpt

# Check environment variables (be careful with sensitive data)
kubectl exec -it deployment/holmes-holmes -n holmesgpt -- env | grep AZURE

# Test HolmesGPT
kubectl exec -it deployment/holmes-holmes -n holmesgpt -- \
  curl -X POST http://localhost:5000/api/investigate \
  -H "Content-Type: application/json" \
  -d '{"source": "prometheus", "title": "Test", "description": "Test query"}'
```

## Troubleshooting

### Vault Agent Not Injecting Secrets

1. Check Vault Agent logs:
   ```bash
   kubectl logs deployment/holmes-holmes -c vault-agent -n holmesgpt
   ```

2. Verify the service account has the correct role binding:
   ```bash
   vault read auth/kubernetes/role/holmesgpt
   ```

### External Secrets Not Syncing

1. Check ExternalSecret status:
   ```bash
   kubectl describe externalsecret holmes-azure-credentials -n holmesgpt
   ```

2. Check External Secrets Operator logs:
   ```bash
   kubectl logs deployment/external-secrets -n external-secrets
   ```

### Authentication Errors

1. Verify Azure credentials are correct:
   ```bash
   # Test Azure AD token retrieval
   curl -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" \
     -d "client_id=$AZURE_CLIENT_ID" \
     -d "client_secret=$AZURE_CLIENT_SECRET" \
     -d "scope=https://cognitiveservices.azure.com/.default" \
     -d "grant_type=client_credentials"
   ```

2. Ensure the service principal has the "Cognitive Services OpenAI User" role on your Azure OpenAI resource.

## Security Best Practices

1. **Use short TTLs**: Configure Vault tokens with short TTLs and enable automatic renewal.

2. **Limit secret access**: Use fine-grained Vault policies to restrict which secrets HolmesGPT can access.

3. **Enable audit logging**: Enable Vault audit logging to track secret access.

4. **Rotate credentials**: Regularly rotate Azure service principal credentials in Vault.

5. **Use namespaces**: Use Vault namespaces (Enterprise) to isolate secrets per environment.

## Additional Resources

- [HashiCorp Vault Kubernetes Auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector)
- [External Secrets Operator](https://external-secrets.io/)
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Azure OpenAI Service Principal Authentication](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/managed-identity)
