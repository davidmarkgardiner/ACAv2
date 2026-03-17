# kagent Controller API Reference

The kagent controller exposes a REST API for managing agents and conversations. The controller runs as `kagent-controller` service in the `kagent` namespace on port **8083**.

**In-cluster base URL:** `http://kagent-controller.kagent:8083`
**Port-forwarded URL:** `http://localhost:8083` (via `kubectl port-forward svc/kagent-controller -n kagent 8083:8083`)

---

## Agents

### List All Agents

```
GET /api/agents
```

Returns all registered kagent agents.

**Response:**
```json
{
  "agents": [
    {
      "name": "test-ns-agent",
      "namespace": "kagent",
      "labels": {
        "app.kubernetes.io/name": "test-ns-agent",
        "app.kubernetes.io/part-of": "kagent",
        "kagent-triage": "enabled",
        "managed-namespace": "test-ns"
      },
      "description": "A namespace-scoped Kubernetes diagnostic agent specialized for test-ns namespace troubleshooting.",
      "type": "Declarative",
      "status": {
        "conditions": [
          {
            "type": "Ready",
            "status": "True"
          }
        ]
      }
    }
  ]
}
```

**Example:**
```bash
# In-cluster (from a workflow pod)
curl -s http://kagent-controller.kagent:8083/api/agents

# Port-forwarded
kubectl port-forward svc/kagent-controller -n kagent 8083:8083 &
curl -s http://localhost:8083/api/agents | jq '.agents[].name'
```

### Get Agent by Name

```
GET /api/agents/{agent-name}
```

Returns a specific agent's configuration and status.

**Parameters:**
| Parameter | Location | Description |
|-----------|----------|-------------|
| `agent-name` | path | Name of the agent (e.g., `test-ns-agent`) |

**Example:**
```bash
curl -s http://localhost:8083/api/agents/test-ns-agent | jq
```

---

## Conversations (Chat)

### Create Conversation / Send Message

```
POST /api/chat/{agent-name}
```

Creates a new conversation with an agent or continues an existing one. The agent will use its configured tools (MCP server) to investigate and respond.

**Parameters:**
| Parameter | Location | Description |
|-----------|----------|-------------|
| `agent-name` | path | Name of the agent to chat with |

**Request Body:**
```json
{
  "message": "Diagnose this error: ImagePullBackOff on pod nginx-abc123 in test-ns",
  "conversation_id": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `message` | string | Yes | The diagnostic query or question |
| `conversation_id` | string | No | Existing conversation ID to continue. `null` creates new conversation. |

**Response:**
```json
{
  "response": "🔍 **Issue**: ImagePullBackOff on pod nginx-abc123\n📋 **Affected Resource**: test-ns/Pod/nginx-abc123\n🔬 **Root Cause**: Image tag 'nonexistent-tag-xyz123' does not exist...\n🛠️ **Remediation**: Update the image tag to a valid version...",
  "conversation_id": "conv-abc123-def456"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `response` | string | The agent's diagnostic response |
| `conversation_id` | string | Conversation ID for follow-up messages |

**Timeout:** The agent may take 30-120 seconds to respond as it uses tools to investigate the cluster.

**Example:**
```bash
# Send a diagnostic query
curl -s -X POST http://localhost:8083/api/chat/test-ns-agent \
  -H "Content-Type: application/json" \
  -d '{
    "message": "List all pods in test-ns namespace and report their status.",
    "conversation_id": null
  }' | jq

# Continue a conversation
curl -s -X POST http://localhost:8083/api/chat/test-ns-agent \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Can you check the logs for the failing pod?",
    "conversation_id": "conv-abc123-def456"
  }' | jq
```

### List Conversations

```
GET /api/conversations
```

Returns all conversations across all agents.

**Query Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `agent` | string | Filter by agent name |
| `limit` | int | Maximum number of results |

**Example:**
```bash
curl -s http://localhost:8083/api/conversations?agent=test-ns-agent | jq
```

### Get Conversation

```
GET /api/conversations/{conversation-id}
```

Returns a specific conversation with full message history.

**Example:**
```bash
curl -s http://localhost:8083/api/conversations/conv-abc123 | jq
```

---

## Tools (MCP Server)

kagent agents use tools via an MCP (Model Context Protocol) server. The tools are Kubernetes operations exposed through `kagent-tool-server`.

### Available Tools

| Tool Name | Description |
|-----------|-------------|
| `k8s_get_resources` | List resources (pods, deployments, etc.) |
| `k8s_get_pod_logs` | Get container logs |
| `k8s_describe_resource` | Describe a resource (like `kubectl describe`) |
| `k8s_get_resource_yaml` | Get resource YAML definition |
| `k8s_get_events` | Get K8s events for a namespace |
| `k8s_apply_manifest` | Apply a YAML manifest |
| `k8s_create_resource` | Create a resource |
| `k8s_create_resource_from_url` | Create resource from URL |
| `k8s_delete_resource` | Delete a resource |
| `k8s_patch_resource` | Patch a resource |
| `k8s_execute_command` | Execute command in a pod |
| `k8s_label_resource` | Add labels |
| `k8s_remove_label` | Remove labels |
| `k8s_annotate_resource` | Add annotations |
| `k8s_remove_annotation` | Remove annotations |
| `k8s_check_service_connectivity` | Check service connectivity |
| `k8s_get_available_api_resources` | List available API resources |
| `k8s_get_cluster_configuration` | Get cluster configuration |

These tools are defined in the `RemoteMCPServer` CR named `kagent-tool-server` in the `kagent` namespace.

---

## Model Configuration

### ModelConfig CR

The `ModelConfig` CRD defines which LLM provider and model agents use.

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: OpenAI        # OpenAI-compatible API
  model: kimi-for-coding  # Model name
  apiKeySecret: litellm-key
  apiKeySecretKey: api-key
  openAI:
    baseUrl: http://litellm-proxy.kagent:4000/v1  # LiteLLM proxy URL
```

**Supported Providers:**
- `OpenAI` — Direct OpenAI or OpenAI-compatible (LiteLLM, vLLM, KubeAI)
- `Anthropic` — Claude models
- `AzureOpenAI` — Azure OpenAI Service

---

## Health & Status

### Controller Health

```bash
# Check controller pod
kubectl get pods -n kagent -l app.kubernetes.io/component=controller

# Check controller logs
kubectl logs -n kagent -l app.kubernetes.io/component=controller --tail=50

# Verify API is responding
curl -sf http://localhost:8083/api/agents && echo "OK"
```

### Agent Status

```bash
# Check all agents
kubectl get agents -n kagent

# Check specific agent status
kubectl get agent test-ns-agent -n kagent -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Describe agent for events
kubectl describe agent test-ns-agent -n kagent
```

---

## Usage in Argo Workflows

The triage WorkflowTemplate calls the kagent API in two steps:

### Step 1: Find Agent
```python
# GET /api/agents — find agent matching the event namespace
agents = requests.get("http://kagent-controller.kagent:8083/api/agents").json()
for agent in agents["agents"]:
    if namespace in agent["name"]:
        return agent["name"]
# Fallback: k8s-agent (cluster-wide)
```

### Step 2: Create Conversation
```python
# POST /api/chat/{agent_name}
response = requests.post(
    f"http://kagent-controller.kagent:8083/api/chat/{agent_name}",
    json={
        "message": f"K8s event in {namespace}: {reason} on {kind}/{name}. Message: {message}. Please diagnose and suggest remediation.",
        "conversation_id": None
    }
)
diagnosis = response.json()["response"]
```

---

## Rate Limiting

The Argo Sensor includes rate limiting to prevent workflow floods:
- **Max 5 triggers per minute** (12-second minimum interval between triggers)
- Configure in the Sensor's `policy.allow.duration` field

The WorkflowTemplate has a TTL of 300 seconds — completed workflows are cleaned up after 5 minutes.
