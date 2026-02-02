# HolmesGPT API Usage Guide

Programmatic investigation and remediation using the HolmesGPT REST API.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/investigate` | POST | Synchronous investigation, returns full result |
| `/api/stream/investigate` | POST | Streaming investigation via SSE |

## Request Schema (`InvestigateRequest`)

```json
{
  "source": "alertmanager",
  "title": "Pod CrashLoopBackOff",
  "description": "Pod my-app-xyz is in CrashLoopBackOff in namespace default",
  "subject": {
    "namespace": "default",
    "pod": "my-app-xyz"
  },
  "context": {},
  "source_instance_id": "ApiRequest",
  "include_tool_calls": false,
  "include_tool_call_results": false,
  "prompt_template": "builtin://generic_investigation.jinja2",
  "sections": null,
  "model": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | string | yes | Alert source (e.g. `alertmanager`, `prometheus`, `pagerduty`) |
| `title` | string | yes | Alert or issue title |
| `description` | string | yes | Detailed description of the problem |
| `subject` | object | yes | Metadata about the affected resource |
| `context` | object | yes | Additional alert context (can be `{}`) |
| `source_instance_id` | string | no | Defaults to `ApiRequest` |
| `include_tool_calls` | bool | no | Include tool call metadata in response |
| `include_tool_call_results` | bool | no | Include full tool call outputs in response |
| `prompt_template` | string | no | Jinja2 template for the investigation prompt |
| `sections` | object | no | Request structured output sections (see below) |
| `model` | string | no | Override the default LLM model |

## Response Schema (`InvestigationResult`)

```json
{
  "analysis": "Free-text LLM analysis of the issue...",
  "sections": {
    "Root Cause": "...",
    "Remediation": "...",
    "Impact": "..."
  },
  "tool_calls": [],
  "instructions": [],
  "metadata": {}
}
```

| Field | Type | Description |
|-------|------|-------------|
| `analysis` | string | Main LLM analysis text |
| `sections` | object | Structured key/value pairs (only if `sections` was set in request) |
| `tool_calls` | array | Tool calls made during investigation |
| `instructions` | array | Runbook instructions that were followed |
| `metadata` | object | Additional metadata (token usage, etc.) |

## Examples

### Basic investigation

```bash
RESPONSE=$(curl -s -X POST http://holmes-host:5000/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "alertmanager",
    "title": "Pod CrashLoopBackOff",
    "description": "Pod my-app-xyz is in CrashLoopBackOff",
    "subject": {"namespace": "default", "pod": "my-app-xyz"},
    "context": {}
  }')

# Extract the analysis
echo "$RESPONSE" | jq -r '.analysis'
```

### Structured sections

Pass `sections` with `null` values to get structured output you can parse field-by-field:

```bash
RESPONSE=$(curl -s -X POST http://holmes-host:5000/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "alertmanager",
    "title": "Pod CrashLoopBackOff",
    "description": "Pod my-app-xyz is in CrashLoopBackOff",
    "subject": {"namespace": "default", "pod": "my-app-xyz"},
    "context": {},
    "sections": {"Root Cause": null, "Remediation": null, "Impact": null}
  }')

echo "$RESPONSE" | jq -r '.sections["Root Cause"]'
echo "$RESPONSE" | jq -r '.sections.Remediation'
echo "$RESPONSE" | jq -r '.sections.Impact'
```

### Post analysis to a GitLab issue

```bash
ANALYSIS=$(echo "$RESPONSE" | jq -r '.analysis')

curl -s -X POST "https://gitlab.example.com/api/v4/projects/$PROJECT_ID/issues" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg title "Holmes: Pod CrashLoopBackOff" \
    --arg desc "$ANALYSIS" \
    '{title: $title, description: $desc}')"
```

### Post analysis to a webhook (Slack, Teams, etc.)

```bash
ANALYSIS=$(echo "$RESPONSE" | jq -r '.analysis')

curl -s -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg text "$ANALYSIS" '{text: $text}')"
```

### Full pipeline: investigate, extract sections, create GitLab issue

```bash
#!/usr/bin/env bash
set -euo pipefail

HOLMES_URL="http://holmes-host:5000"
GITLAB_URL="https://gitlab.example.com"
PROJECT_ID="12345"

RESPONSE=$(curl -s -X POST "$HOLMES_URL/api/investigate" \
  -H "Content-Type: application/json" \
  -d '{
    "source": "alertmanager",
    "title": "High Memory Usage",
    "description": "Container memory usage exceeds 90% in pod api-server-abc",
    "subject": {"namespace": "production", "pod": "api-server-abc"},
    "context": {},
    "sections": {"Root Cause": null, "Remediation": null, "Impact": null}
  }')

ROOT_CAUSE=$(echo "$RESPONSE" | jq -r '.sections["Root Cause"] // "Unknown"')
REMEDIATION=$(echo "$RESPONSE" | jq -r '.sections.Remediation // "None suggested"')
IMPACT=$(echo "$RESPONSE" | jq -r '.sections.Impact // "Unknown"')

BODY=$(cat <<EOF
## Holmes Investigation

### Root Cause
$ROOT_CAUSE

### Remediation
$REMEDIATION

### Impact
$IMPACT
EOF
)

curl -s -X POST "$GITLAB_URL/api/v4/projects/$PROJECT_ID/issues" \
  -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg title "Holmes: High Memory Usage" \
    --arg desc "$BODY" \
    '{title: $title, description: $desc}')"
```

## Enabling Runbooks

`runbooks_enabled` is not a flag you pass — it activates automatically when Holmes loads at least one valid runbook. Configure in your Helm `values.yaml`:

```yaml
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-custom-runbooks

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /etc/holmes/runbooks
```

And in your Holmes config:

```yaml
custom_runbooks:
  - /etc/holmes/runbooks/your-runbook.yaml

custom_runbook_catalogs:
  - /etc/holmes/runbooks/catalog.json
```

## Enabling Auto-Remediation

Set `llm_instructions` on your MCP server in `values.yaml`:

```yaml
mcp_servers:
  aks-mcp:
    description: "AKS MCP Server"
    url: "http://your-aks-mcp-url:8000"
    llm_instructions: |
      # ADMIN REMEDIATION MODE ENABLED
      You have ADMINISTRATOR privileges and are REQUIRED to execute
      remediations, not just recommend them.

      Use ONLY this tool for remediation: call_kubectl

      ## WORKFLOW
      1. Read the alert/issue context
      2. Execute the fix immediately using call_kubectl
      3. Verify with ONE kubectl get command
      4. Report what you did (not recommendations)
```

Ensure your MCP server is running with `--access-level readwrite` or `--access-level admin`.
