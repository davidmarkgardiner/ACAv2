# kagent Triage Logic App

Azure Logic App that receives kagent triage diagnoses via HTTP webhook. Designed to be wired to Teams, Mattermost, or any notification channel.

## Files

| File | Purpose |
|------|---------|
| `logic-app-definition.json` | Logic App workflow definition (used by CLI) |
| `arm-template.json` | ARM template (for `az deployment group create` or Flux) |
| `deploy-logic-app.sh` | CLI deploy script — creates Logic App + prints webhook URL |
| `test-payload.json` | Sample payload for testing |

## Deploy

### Option A: CLI
```bash
./deploy-logic-app.sh dev-rg uksouth
```

### Option B: ARM Template
```bash
az deployment group create \
  --resource-group dev-rg \
  --template-file arm-template.json \
  --parameters logicAppName=kagent-triage-webhook
```

### Option C: ASO (Kubernetes-native)
Create an ASO `Microsoft.Logic/workflows` resource pointing to the ARM template.

## Get Webhook URL

After deployment:
```bash
az rest --method POST \
  --uri "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Logic/workflows/kagent-triage-webhook/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv
```

## Create K8s Secret

```bash
kubectl create secret generic logic-app-webhook-secret \
  --from-literal=url="<WEBHOOK_URL>" \
  -n argo-events
```

## Payload Schema

The workflow sends this JSON to the Logic App:

```json
{
  "event_namespace": "test-ns",
  "event_reason": "BackOff",
  "resource_kind": "Pod",
  "resource_name": "crashloop-test-pod",
  "agent_diagnosis": "## Diagnosis Summary\n\nRoot cause: container exit code 1...\n\n## Remediation\nkubectl patch...",
  "risk_level": "Low",
  "timestamp": "2026-03-16T15:31:29Z",
  "source": "kagent-triage-workflow",
  "cluster": "kind-homelab"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `event_namespace` | string | Yes | K8s namespace where event occurred |
| `event_reason` | string | Yes | Event reason (BackOff, OOMKilled, etc.) |
| `resource_kind` | string | Yes | Resource type (Pod, Deployment, etc.) |
| `resource_name` | string | Yes | Name of affected resource |
| `agent_diagnosis` | string | Yes | Full AI diagnosis in markdown (max 4000 chars) |
| `risk_level` | string | No | Low / Medium / High / unknown |
| `timestamp` | string | No | ISO 8601 timestamp |
| `source` | string | No | Always `kagent-triage-workflow` |
| `cluster` | string | No | Cluster name |

## Wiring to Teams

In the Azure Portal Logic App Designer, add an action after the trigger:
1. **Post Adaptive Card in a chat or channel** (Microsoft Teams connector)
2. Map the trigger body fields to the card

## Test

```bash
curl -X POST "<WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -d @test-payload.json
```
