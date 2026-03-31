# Secret Rotation Runbook

Procedures for rotating every secret in the kagent triage pipeline. For each secret: the normal rotation path (via ESO + Key Vault), the emergency manual path, and verification.

---

## Prerequisites

- Azure CLI authenticated (`az login`)
- `kubectl` context set to the target cluster
- Access to Azure Key Vault

---

## 1. Event Hub SAS Token

**Used by:** Alloy (Send), EventSource (Listen)
**Secret:** `eventhub-credentials` in `argo-events` namespace
**Keys:** `username` (always `$ConnectionString`), `connection-string`

### Normal Rotation (ESO)

```bash
# 1. Regenerate SAS key in Azure Portal or CLI
az eventhubs namespace authorization-rule keys renew \
  --resource-group <RG> \
  --namespace-name <EH_NS> \
  --name <POLICY_NAME> \
  --key PrimaryKey

# 2. Get new connection string
NEW_CONN=$(az eventhubs namespace authorization-rule keys list \
  --resource-group <RG> \
  --namespace-name <EH_NS> \
  --name <POLICY_NAME> \
  --query primaryConnectionString -o tsv)

# 3. Update Azure Key Vault
az keyvault secret set \
  --vault-name <KV_NAME> \
  --name eventhub-connection-string \
  --value "$NEW_CONN"

# 4. ESO syncs within 1 hour, or force refresh:
kubectl annotate externalsecret eventhub-credentials -n argo-events \
  force-sync=$(date +%s) --overwrite
```

### Emergency Manual Rotation

```bash
kubectl create secret generic eventhub-credentials -n argo-events \
  --from-literal=username='$ConnectionString' \
  --from-literal=connection-string="$NEW_CONN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart affected pods
kubectl rollout restart deployment -n argo-events -l eventsource-name=eventhub-critical
```

### Verification

```bash
# EventSource pod should restart and reconnect
kubectl logs -n argo-events -l eventsource-name=eventhub-critical --tail=5
# Look for: "connected" or "subscription active"
```

---

## 2. GitLab Personal Access Token

**Used by:** Workflow pods (issue creation)
**Secret:** `gitlab-token` in `argo-events` namespace
**Keys:** `GITLAB_TOKEN`, `url`, `project-id`

### Normal Rotation (ESO)

```bash
# 1. Generate new PAT in GitLab:
#    Settings → Access Tokens → Create (scope: api, expiry: 90 days)

# 2. Update Key Vault
az keyvault secret set --vault-name <KV_NAME> --name gitlab-token --value "glpat-NEW_TOKEN"

# 3. ESO syncs within 1 hour, or force:
kubectl annotate externalsecret gitlab-token -n argo-events \
  force-sync=$(date +%s) --overwrite
```

### Emergency Manual Rotation

```bash
kubectl create secret generic gitlab-token -n argo-events \
  --from-literal=GITLAB_TOKEN="glpat-NEW_TOKEN" \
  --from-literal=url="https://gitlab.com" \
  --from-literal=project-id="<PROJECT_ID>" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Verification

```bash
# Test GitLab API with new token
curl -s -H "PRIVATE-TOKEN: glpat-NEW_TOKEN" \
  "https://gitlab.com/api/v4/projects/<PROJECT_ID>" | jq .name
# Should return project name
```

---

## 3. Logic App Webhook URL

**Used by:** Workflow pods (Teams notification)
**Secret:** `logic-app-webhook-secret` in `argo-events` namespace
**Keys:** `url`

### Rotation

Logic App webhook URLs contain a SAS signature. They don't expire automatically but can be regenerated.

```bash
# 1. Regenerate webhook URL
SUB_ID=$(az account show --query id -o tsv)
NEW_URL=$(az rest --method POST \
  --uri "/subscriptions/$SUB_ID/resourceGroups/<RG>/providers/Microsoft.Logic/workflows/<LOGIC_APP_NAME>/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv)

# 2. Update K8s secret
kubectl create secret generic logic-app-webhook-secret -n argo-events \
  --from-literal=url="$NEW_URL" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Verification

```bash
# Test with sample payload
curl -X POST "$NEW_URL" \
  -H "Content-Type: application/json" \
  -d '{"event_namespace":"test","event_reason":"test","resource_kind":"Pod","resource_name":"test","agent_diagnosis":"rotation test"}'
# Expect: HTTP 200
```

---

## 4. LiteLLM API Key

**Used by:** KAgent agents (LLM calls via LiteLLM proxy)
**Secret:** `litellm-key` in `kagent` namespace
**Keys:** `api-key`

### Normal Rotation (ESO)

```bash
# 1. Generate new key in LLM provider:
#    - Azure OpenAI: Azure Portal → OpenAI resource → Keys → Regenerate
#    - OpenAI: platform.openai.com → API keys → Create new

# 2. Update Key Vault
az keyvault secret set --vault-name <KV_NAME> --name litellm-api-key --value "NEW_KEY"

# 3. ESO syncs within 1 hour, or force:
kubectl annotate externalsecret litellm-key -n kagent \
  force-sync=$(date +%s) --overwrite
```

### Emergency Manual Rotation

```bash
kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key="NEW_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart LiteLLM to pick up new key
kubectl rollout restart deployment litellm -n kagent
```

### Verification

```bash
# Port-forward LiteLLM and test
kubectl port-forward -n kagent svc/litellm 4000:4000 &
curl -s http://localhost:4000/health | jq .
# Should return healthy status
```

---

## 5. Telegram Bot Token (optional)

**Used by:** Workflow pods (Telegram notification)
**Secret:** `telegram-bot-secret` in `argo-events` namespace
**Keys:** `token`

### Rotation

```bash
# 1. Regenerate via BotFather in Telegram:
#    /revoke → select bot → get new token

# 2. Update Key Vault
az keyvault secret set --vault-name <KV_NAME> --name telegram-bot-token --value "NEW_BOT_TOKEN"

# 3. ESO syncs, or manual:
kubectl create secret generic telegram-bot-secret -n argo-events \
  --from-literal=token="NEW_BOT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Verification

```bash
curl -s "https://api.telegram.org/botNEW_BOT_TOKEN/getMe" | jq .ok
# Should return true
```

---

## Rotation Schedule

| Secret | Rotation Frequency | Trigger |
|--------|-------------------|---------|
| Event Hub SAS | 90 days | Calendar reminder |
| GitLab PAT | Before PAT expiry (default 90 days) | GitLab notification |
| Logic App webhook URL | On-demand (if compromised) | Manual |
| LiteLLM API key | Per provider policy (Azure: 90 days) | Calendar reminder |
| Telegram bot token | On-demand (if compromised) | Manual |

---

## ESO Troubleshooting

```bash
# Check ExternalSecret status
kubectl get externalsecrets -A

# Check sync status
kubectl describe externalsecret <name> -n <ns>
# Look for: "SecretSynced" condition

# Force immediate sync
kubectl annotate externalsecret <name> -n <ns> \
  force-sync=$(date +%s) --overwrite

# Check ESO controller logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=20
```
