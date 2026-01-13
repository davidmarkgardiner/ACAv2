# RocketChat Setup Guide

Quick setup guide for RocketChat with manual triage integration.

## 1. Initial Setup

### Access RocketChat
```bash
kubectl port-forward -n rocketchat svc/rocketchat 3000:3000
```
Open: http://localhost:3000

### Create Admin Account
1. Click **Register a new account**
2. Fill in:
   - **Name**: Admin (or your name)
   - **Username**: admin
   - **Email**: admin@local.com
   - **Password**: (choose a password)
3. Complete the setup wizard:
   - Organization: (any name)
   - Site Name: K8s Triage
   - Server Type: Private Team
   - Skip the rest

## 2. Create Incoming Webhook (for notifications TO chat)

This allows the triage workflow to post results back to RocketChat.

1. Go to **Administration** (top-left menu) → **Integrations**
2. Click **+ New** → **Incoming WebHook**
3. Configure:

| Field | Value |
|-------|-------|
| **Enabled** | Yes |
| **Name** | Triage Results |
| **Post to Channel** | #general |
| **Post as** | Triage Bot |
| **Alias** | Triage Bot |

4. Click **Save**
5. **Copy the Webhook URL** - you'll need this!

### Update Kubernetes Secret

Replace `WEBHOOK_ID` and `TOKEN` with values from your webhook URL:

```bash
# Your webhook URL looks like:
# http://localhost:3000/hooks/WEBHOOK_ID/TOKEN

kubectl create secret generic rocketchat-incoming-webhook \
  --namespace=argo-events \
  --from-literal=webhook-url="http://rocketchat.rocketchat.svc.cluster.local:3000/hooks/WEBHOOK_ID/TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Update Workflow Templates

Edit these files and replace the webhook URL:

1. `k8s/rocketchat/manual-triage-integration.yaml` - line ~177
2. `k8s/holmesgpt/multi-cluster/workflow-multi-cluster-triage.yaml` - line ~300

Replace:
```
http://rocketchat.rocketchat.svc.cluster.local:3000/hooks/OLD_ID/OLD_TOKEN
```
With your new webhook URL (use internal cluster URL format).

Then apply:
```bash
kubectl apply -f k8s/rocketchat/manual-triage-integration.yaml
kubectl apply -f k8s/holmesgpt/multi-cluster/workflow-multi-cluster-triage.yaml
```

## 3. Create Outgoing Webhook (for triage FROM chat)

This allows users to trigger triage by typing `@triage` in chat.

1. Go to **Administration** → **Integrations**
2. Click **+ New** → **Outgoing WebHook**
3. Configure:

| Field | Value |
|-------|-------|
| **Enabled** | Yes |
| **Name** | Manual Triage |
| **Event Trigger** | Message Sent |
| **Channel** | #general |
| **Trigger Words** | @triage |
| **URLs** | http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage |
| **Impersonate User** | No |
| **Post as** | Triage Bot |
| **Script Enabled** | No |

4. Click **Save**

## 4. Test the Integration

### Test Incoming Webhook (notifications)
```bash
# Replace with YOUR webhook URL
curl -X POST "http://localhost:3000/hooks/YOUR_ID/YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Test notification from curl"}'
```
You should see "Test notification from curl" in #general.

### Test Outgoing Webhook (triage)

In RocketChat #general channel, type:
```
@triage default/test-pod CrashLoopBackOff
```

You should see:
1. "Triage Started..." notification
2. "Triage Complete" with GitLab issue link

## 5. Quick Reference

### Triage Command Format
```
@triage namespace/pod-name reason [cluster]
```

Examples:
```
@triage default/nginx CrashLoopBackOff
@triage payments/checkout-xyz OOMKilled
@triage kube-system/coredns ImagePullBackOff prod-cluster
```

### Supported Reasons
- CrashLoopBackOff
- OOMKilled
- ImagePullBackOff
- FailedScheduling
- BackOff
- Unhealthy

## Troubleshooting

### Webhook not triggering
```bash
# Check EventSource is running
kubectl get eventsource manual-triage-webhook -n argo-events

# Check EventSource logs
kubectl logs -n argo-events -l eventsource-name=manual-triage-webhook --tail=20
```

### No notification in chat
```bash
# Test webhook directly
curl -X POST "http://localhost:3000/hooks/ID/TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Test"}'

# Check sensor logs
kubectl logs -n argo-events -l sensor-name=manual-triage-sensor --tail=20
```

### Check workflows
```bash
kubectl get workflows -n argo-events -l app=manual-triage
```

## Architecture

```
User types "@triage ns/pod reason"
         │
         ▼
┌─────────────────────┐
│  RocketChat         │
│  Outgoing Webhook   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Argo Events        │
│  Webhook EventSource│
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐     ┌──────────────────┐
│  Sensor             │────►│ Notify Workflow  │──► "Triage Started"
│  (triggers both)    │     └──────────────────┘
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Triage Workflow    │
│  - Holmes Analysis  │
│  - GitLab Issue     │
│  - Notify Complete  │──► "Triage Complete" + Issue Link
└─────────────────────┘
```
