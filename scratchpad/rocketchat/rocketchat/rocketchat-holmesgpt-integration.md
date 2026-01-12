# Rocket.Chat Outgoing Webhook Integration with HolmesGPT

This guide covers setting up outgoing webhooks in Rocket.Chat to integrate with HolmesGPT for automated incident analysis and chat-based investigations.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Permissions Required](#permissions-required)
- [Creating an Outgoing Webhook](#creating-an-outgoing-webhook)
- [Webhook Payload Format](#webhook-payload-format)
- [Integration Scripts](#integration-scripts)
- [Integration Patterns](#integration-patterns)
- [HolmesGPT API Reference](#holmesgpt-api-reference)
- [Rocket.Chat API Reference](#rocketchat-api-reference)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Rocket.Chat server (v8.0+)
- Admin access or integration permissions
- HolmesGPT webhook endpoint URL
- A bot user account for posting responses (e.g., `rocket.cat` or custom bot)

---

## Permissions Required

Users need one of these permissions to manage integrations:

| Permission | Scope | Default Role |
|------------|-------|--------------|
| `manage-outgoing-integrations` | Create/edit/delete ANY integration | admin |
| `manage-own-outgoing-integrations` | Create/edit/delete only own integrations | admin |
| `manage-incoming-integrations` | Manage incoming webhooks | admin |
| `manage-own-incoming-integrations` | Manage own incoming webhooks | admin |

To grant permissions to non-admin users:
1. Go to **Administration → Permissions**
2. Find the integration permissions
3. Add the desired roles

---

## Creating an Outgoing Webhook

### Via Admin UI

1. Navigate to **Administration → Integrations**
2. Click **+ New** → **Outgoing Webhook**
3. Configure the following fields:

| Field | Description | Example |
|-------|-------------|---------|
| **Name** | Display name for the integration | `HolmesGPT Analyzer` |
| **Enabled** | Toggle integration on/off | `true` |
| **Event** | When to trigger | `sendMessage` |
| **Channel** | Rooms to monitor | `#alerts, #incidents` |
| **Trigger Words** | Words that activate webhook | `@holmes, investigate` |
| **URLs** | HolmesGPT endpoint(s) | `https://holmes.example.com/api/chat` |
| **Username** | Bot user for responses | `rocket.cat` |
| **Token** | Security token (auto-generated) | Used to verify requests |

### Via REST API

```bash
curl -X POST "https://your-rocketchat.com/api/v1/integrations.create" \
  -H "X-Auth-Token: YOUR_AUTH_TOKEN" \
  -H "X-User-Id: YOUR_USER_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "webhook-outgoing",
    "name": "HolmesGPT Integration",
    "enabled": true,
    "username": "rocket.cat",
    "channel": "#alerts",
    "event": "sendMessage",
    "urls": ["https://holmes.example.com/api/chat"],
    "triggerWords": ["@holmes", "investigate"],
    "triggerWordAnywhere": false,
    "scriptEnabled": false,
    "retryFailedCalls": true,
    "retryCount": 3,
    "retryDelay": "powers-of-ten"
  }'
```

### Available Events

| Event | Description | Use Case |
|-------|-------------|----------|
| `sendMessage` | Message posted in channel | Chat-based queries to Holmes |
| `fileUploaded` | File uploaded to room | Analyze uploaded logs/configs |
| `roomCreated` | New room created | Auto-setup for incident rooms |
| `roomJoined` | User joins room | Notify Holmes of new participants |
| `roomLeft` | User leaves room | Track incident responders |
| `roomArchived` | Room archived | Close incident in Holmes |
| `userCreated` | New user account | Onboarding workflows |

---

## Webhook Payload Format

### sendMessage Event

When a message triggers the webhook, HolmesGPT receives:

```json
{
  "token": "integration-security-token",
  "bot": false,
  "trigger_word": "@holmes",
  "channel_id": "GENERAL",
  "channel_name": "alerts",
  "message_id": "abc123",
  "timestamp": "2025-12-23T10:30:00.000Z",
  "user_id": "user123",
  "user_name": "john.doe",
  "text": "@holmes investigate the pod crash in production",
  "siteUrl": "https://chat.example.com",
  "alias": null,
  "isEdited": false
}
```

### fileUploaded Event

```json
{
  "token": "integration-security-token",
  "bot": false,
  "channel_id": "GENERAL",
  "channel_name": "alerts",
  "message_id": "abc123",
  "timestamp": "2025-12-23T10:30:00.000Z",
  "user_id": "user123",
  "user_name": "john.doe",
  "text": "Upload log file for analysis",
  "user": { /* full user object */ },
  "room": { /* full room object */ },
  "message": { /* full message object with file attachments */ }
}
```

---

## Integration Scripts

Scripts allow custom logic for transforming requests and processing responses. Scripts run in an isolated VM sandbox with a 3-second timeout and 8MB memory limit.

### Script Structure

```javascript
class Script {
  /**
   * Called BEFORE sending request to HolmesGPT
   * Use to modify headers, transform data, or add context
   */
  prepare_outgoing_request({ request }) {
    // request.url - webhook URL
    // request.headers - HTTP headers
    // request.data - payload data

    return { request };
  }

  /**
   * Called AFTER receiving response from HolmesGPT
   * Use to parse response and post message to channel
   */
  process_outgoing_response({ request, response }) {
    // response.status_code - HTTP status
    // response.content - response body (string)
    // response.headers - response headers

    return {
      content: {
        text: "Analysis result here"
      }
    };
  }
}
```

### Example: HolmesGPT Integration Script

```javascript
class Script {
  prepare_outgoing_request({ request }) {
    // Extract the actual query (remove trigger word)
    const text = request.data.text || '';
    const query = text.replace(/^@holmes\s*/i, '').trim();

    // Transform to HolmesGPT /api/chat format
    // Note: HolmesGPT uses server-side LLM API keys, no bearer token needed
    request.data = {
      ask: query,
      conversation_history: [],
      stream: false
    };

    request.headers['Content-Type'] = 'application/json';

    return { request };
  }

  process_outgoing_response({ request, response }) {
    if (response.status_code !== 200) {
      return {
        content: {
          text: `:warning: Holmes analysis failed (HTTP ${response.status_code})`
        }
      };
    }

    try {
      const data = JSON.parse(response.content);

      // HolmesGPT returns 'analysis' field with full markdown response
      const attachments = [];

      // Optionally show tools that were used during investigation
      if (data.tool_calls && data.tool_calls.length > 0) {
        attachments.push({
          title: 'Tools Used',
          text: data.tool_calls.map(t => `• ${t.tool_name}`).join('\n'),
          color: '#36a64f'
        });
      }

      return {
        content: {
          text: data.analysis || 'Analysis complete',
          attachments: attachments
        }
      };
    } catch (e) {
      return {
        content: {
          text: response.content
        }
      };
    }
  }
}
```

### Available Sandbox Globals

| Global | Description |
|--------|-------------|
| `console` | Logging (console.log, console.error) |
| `serverFetch` | Async HTTP fetch function |
| `s` | String utility functions |

---

## Integration Patterns

### Pattern A: Chat-Triggered Analysis (Outgoing Webhook)

Users interact with Holmes directly in chat:

```
User: @holmes why is the payment service timing out?
Holmes Bot: Analyzing payment-service logs...

Investigation Results:
- Root Cause: Database connection pool exhausted
- Affected Pods: payment-service-7d8f9-xyz, payment-service-7d8f9-abc
- Recommendation: Increase pool size from 10 to 25

Confidence: 87%
```

**Configuration:**
- Event: `sendMessage`
- Trigger Words: `@holmes`
- Script: Transform query and format response

### Pattern B: Holmes Pushes to Rocket.Chat (Incoming Webhook)

Holmes proactively sends alerts/analysis to Rocket.Chat:

1. Create an **Incoming Webhook** in Rocket.Chat
2. Configure HolmesGPT to POST to the webhook URL
3. Messages appear in the designated channel

**Incoming Webhook Setup:**
```bash
curl -X POST "https://your-rocketchat.com/api/v1/integrations.create" \
  -H "X-Auth-Token: YOUR_AUTH_TOKEN" \
  -H "X-User-Id: YOUR_USER_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "webhook-incoming",
    "name": "HolmesGPT Alerts",
    "enabled": true,
    "username": "holmes-bot",
    "channel": "#incidents",
    "scriptEnabled": false
  }'
```

**HolmesGPT posts to:**
```bash
POST https://your-rocketchat.com/hooks/TOKEN/WEBHOOK_ID

{
  "text": "Alert: High error rate detected in checkout-service",
  "attachments": [{
    "title": "Automated Analysis",
    "text": "Root cause identified as upstream API timeout"
  }]
}
```

### Pattern C: Bidirectional Integration

Combine both patterns for full interaction:

1. **Incoming Webhook**: Holmes pushes alerts/analysis
2. **Outgoing Webhook**: Users query Holmes for details
3. **Shared Context**: Use channel/thread IDs to maintain conversation context

---

## HolmesGPT API Reference

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/chat` | Chat-based investigation (recommended for Rocket.Chat) |
| `POST` | `/api/investigate` | Alert investigation with structured output |
| `POST` | `/api/stream/investigate` | Streaming alert investigation |
| `GET` | `/healthz` | Health check endpoint |
| `GET` | `/readyz` | Readiness check endpoint |

### /api/chat Request Format

```json
{
  "ask": "Why is the payment service timing out?",
  "conversation_history": [],
  "model": "gpt-4.1",
  "stream": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ask` | string | Yes | The question or investigation request |
| `conversation_history` | array | No | Previous messages for multi-turn conversations |
| `model` | string | No | LLM model override (uses server default if omitted) |
| `stream` | boolean | No | Enable streaming response (default: false) |

### /api/chat Response Format

```json
{
  "analysis": "## Investigation Summary\n\nThe payment service is timing out due to...",
  "tool_calls": [
    {
      "tool_name": "kubectl_describe_pod",
      "result": "..."
    }
  ],
  "conversation_history": [...],
  "follow_up_actions": [
    {
      "id": "logs",
      "action_label": "Logs",
      "prompt": "Show me the relevant logs"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `analysis` | string | Full markdown analysis/response from Holmes |
| `tool_calls` | array | List of tools invoked during investigation |
| `conversation_history` | array | Updated conversation for follow-up questions |
| `follow_up_actions` | array | Suggested follow-up actions |

---

## Rocket.Chat API Reference

### REST Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/v1/integrations.create` | Create new integration |
| `PUT` | `/api/v1/integrations.update` | Update existing integration |
| `GET` | `/api/v1/integrations.list` | List all integrations |
| `GET` | `/api/v1/integrations.get` | Get single integration |
| `POST` | `/api/v1/integrations.remove` | Delete integration |
| `GET` | `/api/v1/integrations.history` | View execution history |

### List Integrations

```bash
curl -X GET "https://your-rocketchat.com/api/v1/integrations.list" \
  -H "X-Auth-Token: YOUR_AUTH_TOKEN" \
  -H "X-User-Id: YOUR_USER_ID"
```

### View Integration History

```bash
curl -X GET "https://your-rocketchat.com/api/v1/integrations.history?id=INTEGRATION_ID" \
  -H "X-Auth-Token: YOUR_AUTH_TOKEN" \
  -H "X-User-Id: YOUR_USER_ID"
```

---

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Webhook not triggering | Check channel name matches exactly (case-sensitive) |
| 403 Forbidden | Verify user has integration permissions |
| Script errors | Check **Integration History** for stack traces |
| No response posted | Ensure bot user exists and has room access |
| Timeout errors | Increase HolmesGPT response time or adjust retry settings |

### Debugging

1. **Check Integration History:**
   - Go to **Administration → Integrations → [Your Integration] → History**
   - View request/response data and any errors

2. **Enable Script Logging:**
   ```javascript
   prepare_outgoing_request({ request }) {
     console.log('Request data:', JSON.stringify(request.data));
     return { request };
   }
   ```

3. **Test HolmesGPT Endpoint:**
   ```bash
   curl -X POST "https://holmes.example.com/api/chat" \
     -H "Content-Type: application/json" \
     -d '{"ask": "what pods are running in the default namespace?"}'
   ```

### Retry Configuration

| Retry Delay | Pattern |
|-------------|---------|
| `powers-of-ten` | 100ms, 1s, 10s, 1m40s, 16m40s... |
| `powers-of-two` | 2s, 4s, 8s, 16s, 32s... |
| `increments-of-two` | 2s, 4s, 6s, 8s, 10s... |

---

## Key Source Files

For developers extending integration functionality:

| File | Purpose |
|------|---------|
| `packages/core-typings/src/IIntegration.ts` | TypeScript interfaces |
| `apps/meteor/app/integrations/server/lib/triggerHandler.ts` | Webhook execution engine |
| `apps/meteor/app/integrations/server/lib/isolated-vm/isolated-vm.ts` | Script sandbox |
| `apps/meteor/app/api/server/v1/integrations.ts` | REST API endpoints |
| `apps/meteor/client/views/admin/integrations/outgoing/OutgoingWebhookForm.tsx` | Admin UI form |

---

## Security Considerations

1. **Token Validation**: Always verify the `token` field in incoming requests matches your integration token
2. **HTTPS Only**: Use HTTPS for all webhook URLs
3. **LLM API Keys**: HolmesGPT uses server-side LLM API keys (OpenAI, Anthropic, etc.) configured via environment variables. No API key is passed from Rocket.Chat.
4. **Network Security**: If HolmesGPT is not publicly exposed, ensure Rocket.Chat can reach it (e.g., via internal network or VPN)
5. **Rate Limiting**: Consider rate limiting on HolmesGPT endpoint to prevent abuse
6. **Input Validation**: Sanitize user input before passing to Holmes

---

## Next Steps

1. Set up a test channel for integration development
2. Create the outgoing webhook with a simple echo script
3. Configure HolmesGPT to accept webhook payloads
4. Implement response formatting script
5. Test with real incident scenarios
6. Deploy to production channels
