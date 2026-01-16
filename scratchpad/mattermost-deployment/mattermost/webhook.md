# Mattermost Webhooks: Comprehensive Guide

This document provides a comprehensive guide to Mattermost webhooks (incoming and outgoing) and their integration with Argo Events/Sensors for Kubernetes-based event-driven workflows.

## Table of Contents

- [Overview](#overview)
- [Incoming Webhooks](#incoming-webhooks)
- [Outgoing Webhooks](#outgoing-webhooks)
- [Configuration](#configuration)
- [Environment Variables](#environment-variables)
- [Air-Gapped/Offline Deployment](#air-gappedoffline-deployment)
- [Argo Events Integration](#argo-events-integration)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)

---

## Overview

Mattermost supports two types of webhooks:

| Type | Direction | Purpose |
|------|-----------|---------|
| **Incoming Webhooks** | External → Mattermost | Allow external systems to post messages to Mattermost channels |
| **Outgoing Webhooks** | Mattermost → External | Trigger HTTP requests to external URLs when messages match specific patterns |

---

## Incoming Webhooks

Incoming webhooks allow external applications to post messages into Mattermost channels via HTTP POST requests.

### Endpoint

```
POST https://<mattermost-url>/hooks/<webhook-id>
```

### Creating an Incoming Webhook

**Via API:**
```bash
curl -X POST https://mattermost.example.com/api/v4/hooks/incoming \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "channel_id": "<channel-id>",
    "display_name": "My Webhook",
    "description": "Webhook for external notifications",
    "username": "webhook-bot",
    "icon_url": "https://example.com/icon.png"
  }'
```

### Payload Format

**JSON Format (Recommended):**
```json
{
  "text": "Hello from webhook!",
  "username": "WebhookBot",
  "icon_url": "https://example.com/icon.png",
  "channel": "general",
  "attachments": [
    {
      "color": "#FF0000",
      "title": "Alert Title",
      "title_link": "https://example.com",
      "text": "Detailed message text",
      "fields": [
        {
          "title": "Field 1",
          "value": "Value 1",
          "short": true
        }
      ]
    }
  ],
  "props": {
    "custom_key": "custom_value"
  }
}
```

**Form-encoded Format:**
```bash
curl -X POST https://mattermost.example.com/hooks/<webhook-id> \
  -d 'payload={"text":"Hello from webhook!"}'
```

### Supported Content Types

- `application/json`
- `application/x-www-form-urlencoded`
- `multipart/form-data`

### Channel Override

Messages can be directed to specific channels or users:

```json
{
  "text": "Message content",
  "channel": "#general"
}
```

```json
{
  "text": "Direct message",
  "channel": "@username"
}
```

> **Note:** Channel override requires `channel_locked: false` on the webhook.

### Data Model

```go
type IncomingWebhook struct {
    Id            string   // Unique webhook identifier
    CreateAt      int64    // Creation timestamp (ms)
    UpdateAt      int64    // Last update timestamp (ms)
    DeleteAt      int64    // Deletion timestamp (0 if active)
    UserId        string   // Owner user ID
    ChannelId     string   // Default target channel
    TeamId        string   // Team ID
    DisplayName   string   // Display name (max 64 chars)
    Description   string   // Description (max 500 chars)
    Username      string   // Override username (max 64 chars)
    IconURL       string   // Override icon URL (max 1024 chars)
    ChannelLocked bool     // If true, cannot post to other channels
}
```

---

## Outgoing Webhooks

Outgoing webhooks trigger HTTP POST requests to external URLs when messages matching specific trigger words are posted in Mattermost.

### Trigger Conditions

| TriggerWhen | Behavior |
|-------------|----------|
| `0` (Exact Match) | First word must exactly match trigger word |
| `1` (Starts With) | First word must start with trigger word |

### Creating an Outgoing Webhook

**Via API:**
```bash
curl -X POST https://mattermost.example.com/api/v4/hooks/outgoing \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-id>",
    "display_name": "Alert Webhook",
    "trigger_words": ["alert", "warning", "critical"],
    "callback_urls": ["https://your-service.example.com/webhook"],
    "content_type": "application/json",
    "trigger_when": 0
  }'
```

### Outgoing Payload (sent to your service)

```json
{
  "token": "abc123def456",
  "team_id": "team_id_here",
  "team_domain": "myteam",
  "channel_id": "channel_id_here",
  "channel_name": "general",
  "timestamp": 1609459200000,
  "user_id": "user_id_here",
  "user_name": "johndoe",
  "post_id": "post_id_here",
  "text": "alert Server is down!",
  "trigger_word": "alert",
  "file_ids": "file1,file2"
}
```

### Response Format (from your service)

Your service can respond with a message to post back to Mattermost:

```json
{
  "text": "Alert acknowledged!",
  "username": "AlertBot",
  "icon_url": "https://example.com/alert-icon.png",
  "attachments": [...],
  "response_type": "comment",
  "props": {}
}
```

| Field | Description |
|-------|-------------|
| `text` | Message to post back |
| `response_type` | Set to `"comment"` to reply in thread |
| `username` | Override display name |
| `icon_url` | Override avatar |

### Data Model

```go
type OutgoingWebhook struct {
    Id           string       // Unique webhook identifier
    Token        string       // Verification token (26 chars)
    CreateAt     int64        // Creation timestamp
    UpdateAt     int64        // Last update timestamp
    DeleteAt     int64        // Deletion timestamp
    CreatorId    string       // Creator user ID
    ChannelId    string       // Specific channel (empty = all channels)
    TeamId       string       // Team ID
    TriggerWords StringArray  // List of trigger words
    TriggerWhen  int          // 0=exact, 1=starts_with
    CallbackURLs StringArray  // Target URLs
    DisplayName  string       // Display name
    Description  string       // Description
    ContentType  string       // Request content type
    Username     string       // Override username for responses
    IconURL      string       // Override icon for responses
}
```

---

## Configuration

### System Console Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Incoming Webhooks | Allow creation of incoming webhooks | `true` |
| Enable Outgoing Webhooks | Allow creation of outgoing webhooks | `true` |
| Enable Post Username Override | Allow webhooks to override posting username | `false` |
| Enable Post Icon Override | Allow webhooks to override posting icon | `false` |

### config.json Settings

```json
{
  "ServiceSettings": {
    "EnableIncomingWebhooks": true,
    "EnableOutgoingWebhooks": true,
    "EnablePostUsernameOverride": true,
    "EnablePostIconOverride": true,
    "OutgoingIntegrationRequestsTimeout": 30,
    "AllowedUntrustedInternalConnections": ""
  }
}
```

---

## Environment Variables

Mattermost configuration can be overridden using environment variables with the `MM_` prefix.

### Webhook-Related Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS` | Enable incoming webhooks | `true` |
| `MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS` | Enable outgoing webhooks | `true` |
| `MM_SERVICESETTINGS_ENABLEPOSTUSERNAMEOVERRIDE` | Allow username override | `false` |
| `MM_SERVICESETTINGS_ENABLEPOSTICONOVERRIDE` | Allow icon override | `false` |
| `MM_SERVICESETTINGS_OUTGOINGINTEGRATIONREQUESTSTIMEOUT` | Timeout in seconds for outgoing requests | `30` |
| `MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS` | Internal hosts to allow connections to | `""` |
| `MM_SERVICESETTINGS_SITEURL` | Public URL of Mattermost server | `http://localhost:8065` |
| `MM_SERVICESETTINGS_ENABLELOCALMODE` | Enable local mode for CLI operations | `false` |

### Database Configuration

| Variable | Description |
|----------|-------------|
| `MM_SQLSETTINGS_DRIVERNAME` | Database driver (`postgres`) |
| `MM_SQLSETTINGS_DATASOURCE` | Database connection string |

### Example Docker Environment

```yaml
environment:
  - MM_SERVICESETTINGS_SITEURL=https://mattermost.example.com
  - MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS=true
  - MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS=true
  - MM_SERVICESETTINGS_ENABLEPOSTUSERNAMEOVERRIDE=true
  - MM_SERVICESETTINGS_ENABLEPOSTICONOVERRIDE=true
  - MM_SERVICESETTINGS_OUTGOINGINTEGRATIONREQUESTSTIMEOUT=60
  - MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS=argo-events-webhook-eventsource-svc.argo-events.svc.cluster.local
```

---

## Air-Gapped/Offline Deployment

For air-gapped or offline environments, additional configuration is required.

### Required Environment Variables

```bash
# Core Settings
MM_SERVICESETTINGS_SITEURL=https://mattermost.internal.local
MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS=true
MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS=true

# Allow internal network connections for webhooks
MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,*.svc.cluster.local"

# Disable external connectivity features
MM_SERVICESETTINGS_ENABLEOPENTRACING=false
MM_SERVICESETTINGS_ENABLESECURITYFIXALERT=false
MM_LOGSETTINGS_ENABLEDIAGNOSTICS=false

# Disable features requiring internet
MM_PLUGINSETTINGS_ENABLEMARKETPLACE=false
MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE=false
MM_SUPPORTSETTINGS_ENABLEASKCOMMUNITYSUPPORTLINK=false

# Push notifications (use local proxy or disable)
MM_EMAILSETTINGS_PUSHNOTIFICATIONSERVER=""
MM_EMAILSETTINGS_SENDPUSHNOTIFICATIONS=false

# Image proxy for airgapped (optional, use local proxy)
MM_IMAGEPROXYSETTINGS_ENABLE=false
```

### Kubernetes ConfigMap Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mattermost-config
  namespace: mattermost
data:
  MM_SERVICESETTINGS_SITEURL: "https://mattermost.internal.local"
  MM_SERVICESETTINGS_ENABLEINCOMINGWEBHOOKS: "true"
  MM_SERVICESETTINGS_ENABLEOUTGOINGWEBHOOKS: "true"
  MM_SERVICESETTINGS_ENABLEPOSTUSERNAMEOVERRIDE: "true"
  MM_SERVICESETTINGS_ENABLEPOSTICONOVERRIDE: "true"
  MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS: "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  MM_LOGSETTINGS_ENABLEDIAGNOSTICS: "false"
  MM_PLUGINSETTINGS_ENABLEMARKETPLACE: "false"
  MM_PLUGINSETTINGS_ENABLEREMOTEMARKETPLACE: "false"
```

### Key Considerations for Air-Gapped Environments

1. **Internal DNS Resolution**: Ensure all webhook callback URLs resolve within the internal network
2. **Certificate Trust**: Use internal CA for TLS or configure `MM_SERVICESETTINGS_ENABLEINSECUREOUTGOINGCONNECTIONS=true` (not recommended for production)
3. **AllowedUntrustedInternalConnections**: Must include all internal IP ranges and hostnames that webhooks will connect to
4. **Container Images**: Pre-pull and store in internal registry
5. **Database**: Use internal PostgreSQL instance

---

## Argo Events Integration

Argo Events is a Kubernetes-native event-driven workflow automation framework. It integrates with Mattermost webhooks in two primary patterns:

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────────┐     ┌──────────────┐     ┌─────────────────┐ │
│  │  Argo Events     │     │   EventBus   │     │     Sensor      │ │
│  │  EventSource     │────▶│   (NATS)     │────▶│                 │ │
│  │  (Webhook)       │     │              │     │                 │ │
│  └──────────────────┘     └──────────────┘     └────────┬────────┘ │
│                                                          │          │
│                                                          ▼          │
│  ┌──────────────────┐                          ┌─────────────────┐ │
│  │   Mattermost     │◀─────────────────────────│    Trigger      │ │
│  │   (Incoming      │   HTTP POST to webhook   │  (HTTP/Workflow)│ │
│  │    Webhook)      │                          │                 │ │
│  └──────────────────┘                          └─────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Pattern 1: Argo Events → Mattermost (Notifications)

Send notifications from Argo Events workflows to Mattermost.

#### Step 1: Create Mattermost Incoming Webhook

Create an incoming webhook in Mattermost and note the webhook URL:
```
https://mattermost.example.com/hooks/abc123xyz789
```

#### Step 2: Create Secret for Webhook URL

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-webhook-secret
  namespace: argo-events
type: Opaque
stringData:
  webhook-url: "https://mattermost.example.com/hooks/abc123xyz789"
```

#### Step 3: Configure HTTP Trigger in Sensor

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: mattermost-notification-sensor
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa
  dependencies:
    - name: webhook-event
      eventSourceName: my-eventsource
      eventName: my-event
  triggers:
    - template:
        name: mattermost-notification
        http:
          url: "https://mattermost.example.com/hooks/abc123xyz789"
          method: POST
          headers:
            Content-Type: "application/json"
          payload:
            - src:
                dependencyName: webhook-event
                dataKey: body.message
              dest: text
            - src:
                dependencyName: webhook-event
                dataKey: body.severity
              dest: attachments.0.color
          secureHeaders:
            - name: Authorization
              valueFrom:
                secretKeyRef:
                  name: mattermost-webhook-secret
                  key: webhook-url
```

#### Complete Sensor Example with Rich Formatting

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: deployment-notification-sensor
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa
  dependencies:
    - name: deployment-event
      eventSourceName: k8s-deployment-eventsource
      eventName: deployment-update
  triggers:
    - template:
        name: notify-mattermost
        http:
          url: "https://mattermost.example.com/hooks/abc123xyz789"
          method: POST
          headers:
            Content-Type: "application/json"
          payload:
            - src:
                dependencyName: deployment-event
                dataTemplate: |
                  {
                    "username": "Argo Events",
                    "icon_url": "https://argoproj.github.io/argo-events/assets/logo.png",
                    "text": "Deployment Event Detected",
                    "attachments": [{
                      "color": "#36a64f",
                      "title": "{{ .Input.body.metadata.name }}",
                      "fields": [
                        {
                          "title": "Namespace",
                          "value": "{{ .Input.body.metadata.namespace }}",
                          "short": true
                        },
                        {
                          "title": "Replicas",
                          "value": "{{ .Input.body.spec.replicas }}",
                          "short": true
                        }
                      ]
                    }]
                  }
              dest: ""
```

### Pattern 2: Mattermost → Argo Events (Triggering Workflows)

Trigger Argo workflows from Mattermost using outgoing webhooks.

#### Step 1: Deploy Argo Events Webhook EventSource

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: mattermost-eventsource
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    mattermost-trigger:
      port: "12000"
      endpoint: /mattermost
      method: POST
```

#### Step 2: Expose EventSource Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mattermost-webhook-svc
  namespace: argo-events
spec:
  selector:
    eventsource-name: mattermost-eventsource
  ports:
    - port: 12000
      targetPort: 12000
  type: ClusterIP
```

#### Step 3: Create Sensor to Handle Mattermost Events

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: mattermost-workflow-trigger
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa
  dependencies:
    - name: mattermost-event
      eventSourceName: mattermost-eventsource
      eventName: mattermost-trigger
      filters:
        data:
          - path: body.trigger_word
            type: string
            value:
              - "deploy"
              - "build"
  triggers:
    - template:
        name: trigger-workflow
        k8s:
          operation: create
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: mattermost-triggered-
              spec:
                entrypoint: main
                arguments:
                  parameters:
                    - name: trigger-word
                      value: ""
                    - name: user
                      value: ""
                    - name: channel
                      value: ""
                templates:
                  - name: main
                    steps:
                      - - name: execute
                          template: run-task
                  - name: run-task
                    container:
                      image: alpine:latest
                      command: [sh, -c]
                      args:
                        - |
                          echo "Triggered by: {{workflow.parameters.user}}"
                          echo "Command: {{workflow.parameters.trigger-word}}"
                          echo "Channel: {{workflow.parameters.channel}}"
          parameters:
            - src:
                dependencyName: mattermost-event
                dataKey: body.trigger_word
              dest: spec.arguments.parameters.0.value
            - src:
                dependencyName: mattermost-event
                dataKey: body.user_name
              dest: spec.arguments.parameters.1.value
            - src:
                dependencyName: mattermost-event
                dataKey: body.channel_name
              dest: spec.arguments.parameters.2.value
```

#### Step 4: Create Mattermost Outgoing Webhook

Configure an outgoing webhook in Mattermost:
- **Trigger Words**: `deploy`, `build`
- **Callback URL**: `http://mattermost-webhook-svc.argo-events.svc.cluster.local:12000/mattermost`
- **Content Type**: `application/json`

### Complete Bidirectional Integration Example

This example shows a workflow triggered from Mattermost that reports back to Mattermost when complete.

#### EventSource

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: mattermost-webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  webhook:
    mm-deploy:
      port: "12000"
      endpoint: /deploy
      method: POST
```

#### Sensor with Workflow and Notification

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: deploy-sensor
  namespace: argo-events
spec:
  template:
    serviceAccountName: operate-workflow-sa
  dependencies:
    - name: deploy-trigger
      eventSourceName: mattermost-webhook
      eventName: mm-deploy
  triggers:
    # Trigger 1: Run the deployment workflow
    - template:
        name: run-deployment
        k8s:
          operation: create
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: deploy-
              spec:
                entrypoint: deploy
                templates:
                  - name: deploy
                    container:
                      image: alpine:latest
                      command: [echo, "Deploying..."]
          parameters:
            - src:
                dependencyName: deploy-trigger
                dataKey: body.text
              dest: spec.arguments.parameters.0.value

    # Trigger 2: Send acknowledgment to Mattermost
    - template:
        name: notify-start
        http:
          url: "https://mattermost.example.com/hooks/abc123"
          method: POST
          headers:
            Content-Type: "application/json"
          payload:
            - src:
                dependencyName: deploy-trigger
                dataTemplate: |
                  {
                    "text": ":rocket: Deployment triggered by @{{ .Input.body.user_name }}",
                    "username": "Argo Deploy Bot"
                  }
              dest: ""
```

---

## Security Considerations

### Token Validation

For outgoing webhooks, always validate the token in your receiving service:

```python
EXPECTED_TOKEN = os.environ.get('MATTERMOST_WEBHOOK_TOKEN')

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    data = request.json
    if data.get('token') != EXPECTED_TOKEN:
        return 'Unauthorized', 401
    # Process webhook
```

### Network Security

1. **Use TLS**: Always use HTTPS for webhook URLs
2. **Network Policies**: Restrict egress from Mattermost to known webhook destinations
3. **RBAC**: Use proper Kubernetes RBAC for Argo Events service accounts

### Kubernetes Network Policy Example

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mattermost-webhook-egress
  namespace: mattermost
spec:
  podSelector:
    matchLabels:
      app: mattermost
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: argo-events
      ports:
        - protocol: TCP
          port: 12000
```

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Webhook returns 404 | Invalid webhook ID | Verify webhook exists and ID is correct |
| Connection refused | Network policy blocking | Check `AllowedUntrustedInternalConnections` |
| Timeout errors | Slow external service | Increase `OutgoingIntegrationRequestsTimeout` |
| Username not appearing | Override disabled | Enable `EnablePostUsernameOverride` |
| Channel override fails | Webhook locked | Set `channel_locked: false` on webhook |

### Debug Commands

**Check webhook configuration:**
```bash
curl -H "Authorization: Bearer <token>" \
  https://mattermost.example.com/api/v4/hooks/incoming/<hook-id>
```

**Test incoming webhook:**
```bash
curl -X POST https://mattermost.example.com/hooks/<webhook-id> \
  -H "Content-Type: application/json" \
  -d '{"text": "Test message"}'
```

**View Argo Events logs:**
```bash
kubectl logs -n argo-events -l eventsource-name=mattermost-webhook
kubectl logs -n argo-events -l sensor-name=deploy-sensor
```

### Argo Events Debugging

```bash
# Check EventSource status
kubectl get eventsources -n argo-events

# Check Sensor status
kubectl get sensors -n argo-events

# Describe for events
kubectl describe sensor deploy-sensor -n argo-events
```

---

## API Reference

### Incoming Webhooks API

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v4/hooks/incoming` | Create webhook |
| GET | `/api/v4/hooks/incoming` | List webhooks |
| GET | `/api/v4/hooks/incoming/{id}` | Get webhook |
| PUT | `/api/v4/hooks/incoming/{id}` | Update webhook |
| DELETE | `/api/v4/hooks/incoming/{id}` | Delete webhook |
| POST | `/hooks/{id}` | Post message (public) |

### Outgoing Webhooks API

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v4/hooks/outgoing` | Create webhook |
| GET | `/api/v4/hooks/outgoing` | List webhooks |
| GET | `/api/v4/hooks/outgoing/{id}` | Get webhook |
| PUT | `/api/v4/hooks/outgoing/{id}` | Update webhook |
| DELETE | `/api/v4/hooks/outgoing/{id}` | Delete webhook |
| POST | `/api/v4/hooks/outgoing/{id}/regen_token` | Regenerate token |

---

## References

- [Mattermost Webhooks Documentation](https://developers.mattermost.com/integrate/webhooks/)
- [Argo Events Documentation](https://argoproj.github.io/argo-events/)
- [Argo Events Webhook Setup](https://argoproj.github.io/argo-events/eventsources/setup/webhook/)
- [CloudEvents Specification](https://cloudevents.io/)
