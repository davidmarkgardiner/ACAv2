# Mattermost + HolmesGPT Deployment Bundle

Replacement for RocketChat - designed for air-gapped environments with better compatibility.

## Why Mattermost over RocketChat?

| Feature | Mattermost | RocketChat |
|---------|------------|------------|
| Air-gap support | Excellent | Problematic |
| Database | PostgreSQL (simpler) | MongoDB (requires replica set) |
| Resource usage | Lower memory | Higher memory |
| Webhook API | Clean REST | Complex |
| Enterprise support | Strong | Variable |

## Architecture Overview

```
+======================== AUTOMATED PATH =========================+
|                                                                  |
|  K8s Events → Fluent Bit → Event Hub → EventSource → Sensor     |
|                                                                  |
+==================================================================+
                                                      |
                                                      v
                                        +-------------------------+
                                        | multi-cluster-triage    |
                                        | WorkflowTemplate        |
                                        |   - Holmes Analysis     |
                                        |   - GitLab Issue        |
                                        |   - Mattermost Notify   |
                                        +-------------------------+
                                                      ^
                                                      |
+========================== MANUAL PATH ==========================+
|                                                                  |
|  User @triage → Mattermost Webhook → EventSource → Sensor       |
|                                                                  |
+==================================================================+
```

## Quick Start (Local Kind Cluster)

### Step 1: Create Namespace

```bash
kubectl create namespace mattermost
```

### Step 2: Deploy PostgreSQL

```bash
kubectl apply -f mattermost/postgresql-standalone.yaml

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=ready pod -l app=postgresql -n mattermost --timeout=120s
```

### Step 3: Deploy Mattermost

```bash
kubectl apply -f mattermost/mattermost-standalone.yaml

# Wait for Mattermost to be ready (takes 1-2 minutes)
kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=180s
```

### Step 4: Access Mattermost

```bash
# Port forward to access locally
kubectl port-forward -n mattermost svc/mattermost 8065:8065

# Open http://localhost:8065 in browser
```

### Step 5: Initial Setup

1. Open http://localhost:8065
2. Create admin account (first user becomes admin)
3. Create a team (e.g., "Platform Team")
4. Done! You now have a working Mattermost instance

## Webhook Configuration

### Create Incoming Webhook (for bot responses)

1. Go to **Integrations** → **Incoming Webhooks** → **Add Incoming Webhook**
2. Configure:
   - **Title**: Holmes Bot
   - **Description**: AI triage responses
   - **Channel**: Town Square (or your channel)
   - **Username**: Holmes Bot
3. Click **Save**
4. Copy the webhook URL

### Update ConfigMap with Webhook URL

```bash
# Replace WEBHOOK_URL with the URL from step above
kubectl patch configmap mattermost-webhook-config -n argo-events \
  --type merge \
  -p '{"data":{"WEBHOOK_URL":"http://mattermost.mattermost.svc.cluster.local:8065/hooks/YOUR_HOOK_ID"}}'
```

### Create Outgoing Webhook (for @triage command)

1. Go to **Integrations** → **Outgoing Webhooks** → **Add Outgoing Webhook**
2. Configure:
   - **Title**: Manual Triage
   - **Content Type**: application/json
   - **Channel**: Any (leave blank for all channels)
   - **Trigger Words**: `@triage`
   - **Callback URLs**: `http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage`
3. Click **Save**

## Deploy Argo Events Integration

### Prerequisites

Ensure Argo Events is deployed:

```bash
# Check if Argo Events is running
kubectl get pods -n argo-events
kubectl get eventbus -n argo-events
```

### Deploy Integration

```bash
kubectl apply -f workflows/manual-triage-integration.yaml

# Verify
kubectl get eventsource,sensor -n argo-events
```

## Testing Webhooks

### Test Incoming Webhook

```bash
# Replace YOUR_HOOK_ID with actual hook ID
curl -X POST http://localhost:8065/hooks/YOUR_HOOK_ID \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Hello from curl!",
    "username": "Test Bot"
  }'
```

### Test Outgoing Webhook (inside cluster)

```bash
kubectl run test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST "http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "@triage default/nginx CrashLoopBackOff",
    "user_name": "test-user",
    "channel_name": "town-square",
    "team_domain": "platform-team"
  }'
```

### Test @triage Command

In Mattermost, type:
```
@triage default/nginx CrashLoopBackOff
```

Expected response: "Triage Started..." message followed by analysis results.

## Files Overview

```
mattermost-deployment/
├── README.md                           # This file
├── mattermost/
│   ├── postgresql-standalone.yaml      # PostgreSQL database
│   └── mattermost-standalone.yaml      # Mattermost server
├── workflows/
│   └── manual-triage-integration.yaml  # EventSource + Sensor for @triage
├── istio/                              # (Optional) Istio routing
│   └── ...
└── secrets/
    └── ...
```

## Configuration Reference

### Mattermost Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MM_SERVICESETTINGS_SITEURL` | Public URL | http://localhost:8065 |
| `MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS` | Enable incoming webhooks | true |
| `MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS` | Enable outgoing webhooks | true |
| `MM_FILESETTINGS_DRIVERNAME` | File storage driver | local |
| `MM_LOGSETTINGS_ENABLEDIAGNOSTICS` | Send telemetry | false (air-gap) |

### Air-Gap Considerations

This deployment is configured for air-gapped environments:
- Telemetry disabled
- Local file storage (no S3 required)
- Email disabled (no SMTP required)
- Security alerts disabled

### Resource Requirements

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| PostgreSQL | 100m | 256Mi | 500m | 512Mi |
| Mattermost | 200m | 512Mi | 2000m | 2Gi |

## Troubleshooting

### Mattermost won't start

```bash
# Check logs
kubectl logs -n mattermost deployment/mattermost

# Common issues:
# 1. PostgreSQL not ready - wait longer
# 2. Database connection error - check secret values
```

### Webhook not receiving requests

```bash
# Check EventSource pod
kubectl logs -n argo-events -l eventsource-name=manual-triage-webhook

# Check Sensor pod
kubectl logs -n argo-events -l sensor-name=manual-triage-sensor
```

### Database issues

```bash
# Connect to PostgreSQL
kubectl exec -it -n mattermost deployment/postgresql -- psql -U mattermost -d mattermost

# Check tables
\dt
```

## Migration from RocketChat

1. Export channels/users from RocketChat (if needed)
2. Deploy Mattermost stack
3. Update webhook URLs in:
   - `mattermost-webhook-config` ConfigMap
   - Any workflows that post to chat
4. Update integrations in Argo Events sensors
5. Test webhooks end-to-end

## Related Documentation

- [Mattermost Documentation](https://docs.mattermost.com/)
- [Mattermost Webhooks](https://developers.mattermost.com/integrate/webhooks/)
- [Argo Events Webhooks](https://argoproj.github.io/argo-events/eventsources/webhook/)
