# kagent Triage Logic App

Azure Logic App that receives kagent triage diagnoses via HTTP webhook and posts rich Adaptive Cards to Microsoft Teams.

## What It Looks Like in Teams

The Adaptive Card displays:
- Risk-colored header (red/orange/green circle based on risk level)
- Cluster, namespace, and risk level in columns
- Event details (reason, resource, timestamp) in a fact set
- AI diagnosis with markdown formatting
- Full-width card layout

## Files

| File | Purpose |
|------|---------|
| `arm-template.json` | ARM template with Teams Adaptive Card integration |
| `logic-app-definition.json` | Standalone Logic App definition (no Teams) |
| `adaptive-card-template.json` | Reference Adaptive Card template (for Teams Designer) |
| `deploy-logic-app.sh` | CLI deploy script |
| `test-payload.json` | Sample payload for testing |

## Deploy

### Without Teams (webhook only)

```bash
az deployment group create \
  --resource-group dev-rg \
  --template-file arm-template.json \
  --parameters logicAppName=kagent-triage-webhook
```

### With Teams

1. Create a Teams Incoming Webhook:
   - Go to the Teams channel > Manage channel > Connectors > Incoming Webhook
   - Name it "KAgent Triage", copy the webhook URL

2. Deploy with the webhook URL:
```bash
az deployment group create \
  --resource-group dev-rg \
  --template-file arm-template.json \
  --parameters \
    logicAppName=kagent-triage-webhook \
    teamsWebhookUrl="https://YOUR_ORG.webhook.office.com/webhookb2/..."
```

The Logic App will accept payloads and post Adaptive Cards to your Teams channel automatically.

## Get Logic App Webhook URL

After deployment, get the URL that the Argo workflow will POST to:

```bash
SUB_ID=$(az account show --query id -o tsv)
az rest --method POST \
  --uri "/subscriptions/$SUB_ID/resourceGroups/<RG>/providers/Microsoft.Logic/workflows/kagent-triage-webhook/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv
```

## Create K8s Secret

```bash
kubectl create secret generic logic-app-webhook-secret \
  --from-literal=url="<WEBHOOK_URL>" \
  -n argo-events
```

## Test

```bash
curl -X POST "<WEBHOOK_URL>" \
  -H "Content-Type: application/json" \
  -d @test-payload.json
```

Expected: HTTP 200, Teams card appears in channel with risk indicator and diagnosis.

Without Teams configured: HTTP 200, payload is logged but no Teams message.

## Payload Schema

```json
{
  "event_namespace": "test-ns",
  "event_reason": "BackOff",
  "resource_kind": "Pod",
  "resource_name": "crashloop-test-pod",
  "agent_diagnosis": "## Diagnosis Summary\n\nRoot cause: ...",
  "risk_level": "Low",
  "timestamp": "2026-03-16T15:31:29Z",
  "source": "kagent-triage-workflow",
  "cluster": "aks-prod-01"
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
| `source` | string | No | `kagent-triage-workflow` or `k8s-triage-critical` |
| `cluster` | string | No | Cluster name |

## Adaptive Card Features

| Risk Level | Display |
|------------|---------|
| High | Red circle, red "HIGH" text, Attention color |
| Medium | Orange circle, orange "MEDIUM" text, Warning color |
| Low | Green circle, green "LOW" text, Good color |
| unknown | White circle, "Unknown" text |

The diagnosis is truncated to 3000 chars in the card (full version lives in the GitLab issue).

## Customising the Card

The `adaptive-card-template.json` file is a standalone Adaptive Card template you can preview at https://adaptivecards.io/designer/. Edit it there, then update the card body in `arm-template.json` to match.

