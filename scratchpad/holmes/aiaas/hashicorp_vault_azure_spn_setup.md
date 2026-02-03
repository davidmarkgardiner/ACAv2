# LiteLLM + HashiCorp Vault + Azure OpenAI (SPN Auth)

This guide shows how to use HashiCorp Vault to securely retrieve Azure Service Principal credentials for LiteLLM.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   LiteLLM       │────▶│  HashiCorp Vault │     │  Azure OpenAI   │
│   Proxy         │     │  (Secrets)       │     │                 │
└────────┬────────┘     └──────────────────┘     └─────────────────┘
         │                                                │
         │  1. Fetch SPN credentials from Vault          │
         │  2. Get Azure AD token using SPN              │
         │  3. Call Azure OpenAI with token              │
         └───────────────────────────────────────────────┘
```

## Prerequisites

- LiteLLM Enterprise/Premium license
- HashiCorp Vault (KV v2 secrets engine)
- Azure Service Principal with access to Azure OpenAI

## Step 1: Store Secrets in Vault

Store your Azure SPN credentials in Vault KV v2. LiteLLM expects secrets under the `key` field:

```bash
# Store tenant_id
vault kv put secret/azure/tenant_id key="your-tenant-id"

# Store client_id
vault kv put secret/azure/client_id key="your-client-id"

# Store client_secret
vault kv put secret/azure/client_secret key="your-spn-client-secret"
```

## Step 2: Configure Vault Authentication

### Option A: Token Authentication

```bash
export HCP_VAULT_ADDR="https://your-vault.example.com:8200"
export HCP_VAULT_TOKEN="hvs.your-vault-token"

# Optional settings
export HCP_VAULT_NAMESPACE="your-namespace"      # If using namespaces
export HCP_VAULT_MOUNT_NAME="secret"             # KV mount name (default: secret)
export HCP_VAULT_PATH_PREFIX="azure"             # Path prefix for secrets
```

### Option B: AppRole Authentication (Recommended for Production)

```bash
export HCP_VAULT_ADDR="https://your-vault.example.com:8200"
export HCP_VAULT_APPROLE_ROLE_ID="your-role-id"
export HCP_VAULT_APPROLE_SECRET_ID="your-secret-id"
export HCP_VAULT_APPROLE_MOUNT_PATH="approle"    # Optional, default: approle

# Optional settings
export HCP_VAULT_NAMESPACE="your-namespace"
export HCP_VAULT_MOUNT_NAME="secret"
export HCP_VAULT_PATH_PREFIX="azure"
```

### Option C: TLS Certificate Authentication

```bash
export HCP_VAULT_ADDR="https://your-vault.example.com:8200"
export HCP_VAULT_CLIENT_CERT="/path/to/client-cert.pem"
export HCP_VAULT_CLIENT_KEY="/path/to/client-key.pem"
export HCP_VAULT_CERT_ROLE="your-cert-role"
```

## Step 3: Configure LiteLLM Proxy

Create `config.yaml`:

```yaml
general_settings:
  key_management_system: "hashicorp_vault"
  key_management_settings:
    access_mode: "read_only"

model_list:
  - model_name: gpt-4
    litellm_params:
      model: azure/gpt-4-deployment
      api_base: https://your-resource.openai.azure.com/
      api_version: "2024-02-15-preview"
      # Reference secrets from Vault using hashicorp/ prefix
      tenant_id: "hashicorp/azure/tenant_id"
      client_id: "hashicorp/azure/client_id"
      client_secret: "hashicorp/azure/client_secret"
      timeout: 600  # 10 minutes
```

## Step 4: Run LiteLLM Proxy

```bash
litellm --config config.yaml
```

## Step 5: Test the Connection

```bash
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-litellm-key" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hello!"}],
    "timeout": 600
  }'
```

## Environment Variables Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `HCP_VAULT_ADDR` | Yes | `http://127.0.0.1:8200` | Vault server address |
| `HCP_VAULT_TOKEN` | Yes* | - | Vault token (if using token auth) |
| `HCP_VAULT_APPROLE_ROLE_ID` | Yes* | - | AppRole role ID |
| `HCP_VAULT_APPROLE_SECRET_ID` | Yes* | - | AppRole secret ID |
| `HCP_VAULT_APPROLE_MOUNT_PATH` | No | `approle` | AppRole mount path |
| `HCP_VAULT_NAMESPACE` | No | - | Vault namespace |
| `HCP_VAULT_MOUNT_NAME` | No | `secret` | KV secrets engine mount |
| `HCP_VAULT_PATH_PREFIX` | No | - | Path prefix for secrets |
| `HCP_VAULT_REFRESH_INTERVAL` | No | `86400` | Cache TTL in seconds |

*One authentication method is required (Token OR AppRole OR TLS Cert)

## Vault Secret Format

LiteLLM expects secrets stored in KV v2 with the value under the `key` field:

```json
{
  "data": {
    "key": "your-secret-value"
  }
}
```

The Vault URL format is:
```
{VAULT_ADDR}/v1/{NAMESPACE}/{MOUNT_NAME}/data/{PATH_PREFIX}/{SECRET_NAME}
```

Example: `https://vault.example.com/v1/secret/data/azure/client_secret`

## Troubleshooting

### Enable Debug Logging

```bash
export LITELLM_LOG=DEBUG
litellm --config config.yaml
```

### Common Issues

1. **"premium_user" error**: HashiCorp Vault integration requires LiteLLM Enterprise license

2. **Authentication failed**: Verify your Vault credentials and that the auth method is properly configured

3. **Secret not found**: Check the path matches your Vault structure:
   - Mount name: `HCP_VAULT_MOUNT_NAME`
   - Path prefix: `HCP_VAULT_PATH_PREFIX`
   - Secret name in config: `hashicorp/<secret-path>`

4. **Timeout errors**: Increase timeout in `litellm_params`:
   ```yaml
   timeout: 600  # 10 minutes
   ```

## Security Best Practices

1. Use **AppRole auth** in production (not static tokens)
2. Set appropriate **Vault policies** limiting access to only required secrets
3. Enable **audit logging** in Vault
4. Rotate AppRole secret_id periodically
5. Use **namespaces** to isolate environments
