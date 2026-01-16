# Simple Webhook Test

Minimal setup to debug Mattermost → Argo Events integration.

## Deploy

```bash
kubectl apply -f eventsource.yaml
kubectl apply -f sensor.yaml

# Verify
kubectl get eventsource,sensor -n argo-events
```

## Mattermost Outgoing Webhook Configuration

1. Go to **Integrations** → **Outgoing Webhooks** → **Add**
2. Configure:
   - **Title**: Test Triage
   - **Content Type**: `application/json`  ← IMPORTANT!
   - **Trigger Words**: `@triage`
   - **Callback URLs**: `http://test-webhook-svc.argo-events.svc.cluster.local:12000/triage`
3. Save

## Expected Payload from Mattermost

When you type `@triage test message` in Mattermost, it sends this JSON:

```json
{
  "channel_id": "abc123",
  "channel_name": "town-square",
  "team_id": "xyz789",
  "team_domain": "myteam",
  "post_id": "post123",
  "text": "@triage test message",
  "trigger_word": "@triage",
  "user_id": "user123",
  "user_name": "john.doe",
  "token": "webhook_token_here",
  "timestamp": 1234567890000,
  "file_ids": ""
}
```

## Test with curl (inside cluster)

```bash
# Simulate Mattermost payload
kubectl run test-curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -v -X POST "http://test-webhook-svc.argo-events.svc.cluster.local:12000/triage" \
  -H "Content-Type: application/json" \
  -d '{
    "channel_id": "test123",
    "channel_name": "town-square",
    "team_domain": "test-team",
    "text": "@triage default/nginx CrashLoopBackOff",
    "trigger_word": "@triage",
    "user_name": "testuser",
    "token": "abc123"
  }'
```

## Test from outside cluster (port-forward)

```bash
# Terminal 1: Port forward
kubectl port-forward -n argo-events svc/test-webhook-svc 12000:12000

# Terminal 2: Send test request
curl -v -X POST "http://localhost:12000/triage" \
  -H "Content-Type: application/json" \
  -d '{
    "channel_name": "town-square",
    "text": "@triage default/nginx CrashLoopBackOff",
    "trigger_word": "@triage",
    "user_name": "testuser"
  }'
```

## View Logs

```bash
# EventSource logs (see incoming requests)
kubectl logs -n argo-events -l eventsource-name=test-webhook -f

# Sensor logs (see event processing)
kubectl logs -n argo-events -l sensor-name=test-sensor -f
```

## Common Issues

### 1. "invalid character" or unmarshal errors

**Cause**: Mattermost Content-Type is set to `application/x-www-form-urlencoded` (default)

**Fix**: Change outgoing webhook Content-Type to `application/json`

### 2. Connection refused

**Cause**: Service not found or wrong namespace

**Fix**: Check service exists:
```bash
kubectl get svc -n argo-events test-webhook-svc
```

### 3. EventSource pod not running

```bash
kubectl get pods -n argo-events -l eventsource-name=test-webhook
kubectl describe eventsource test-webhook -n argo-events
```

## Cleanup

```bash
kubectl delete -f sensor.yaml
kubectl delete -f eventsource.yaml
```
