# KAgent A2A API — Chatting with Agents via curl

> Talk to any KAgent agent using the Agent-to-Agent (A2A) JSON-RPC protocol.

## Quick Reference

| Field | Value |
|-------|-------|
| **Controller service** | `kagent-controller.kagent.svc.cluster.local` |
| **Port** | `8083` |
| **A2A endpoint** | `POST /api/a2a/kagent/{agent-name}/` |
| **Protocol** | JSON-RPC 2.0, method `message/send` |
| **Trailing slash** | **Required** — without it you get a redirect/404 |

### Available Agents

| Agent | Purpose |
|-------|---------|
| `sre-triage-agent` | Investigate K8s issues, root cause analysis |
| `sre-remediation-agent` | Apply fixes to K8s resources |
| `k8s-agent` | General K8s operations |
| `helm-agent` | Helm chart management |
| `observability-agent` | Metrics, logs, observability |
| `promql-agent` | PromQL query generation |
| `kgateway-agent` | Gateway/ingress operations |

---

## From Your Machine (port-forward)

```bash
# Terminal 1: port-forward
kubectl port-forward svc/kagent-controller -n kagent 8083:8083

# Terminal 2: send a message
curl -s -X POST "http://localhost:8083/api/a2a/kagent/sre-triage-agent/" \
  -H "Content-Type: application/json" \
  --max-time 600 \
  -d '{
    "jsonrpc": "2.0",
    "method": "message/send",
    "id": "test-1",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "What pods are in CrashLoopBackOff across all namespaces?"}]
      }
    }
  }' | jq .
```

## From Inside the Cluster

```bash
kubectl run curl-test --rm -it --image=badouralix/curl-jq:alpine -n kagent -- \
  sh -c 'curl -s -X POST \
    "http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/sre-triage-agent/" \
    -H "Content-Type: application/json" \
    --max-time 600 \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"message/send\",
      \"id\": \"test-1\",
      \"params\": {
        \"message\": {
          \"role\": \"user\",
          \"parts\": [{\"kind\": \"text\", \"text\": \"List all unhealthy pods in the cluster\"}]
        }
      }
    }" | jq .'
```

## From an Argo Workflow Step

```yaml
- name: ask-agent
  script:
    image: badouralix/curl-jq:alpine
    command: [sh]
    source: |
      jq -n --arg question "What pods are failing in namespace default?" '{
        jsonrpc: "2.0",
        method: "message/send",
        id: "wf-query",
        params: {
          message: {
            role: "user",
            parts: [{"kind": "text", "text": $question}]
          }
        }
      }' > /tmp/request.json

      curl -s -o /tmp/response.json \
        --connect-timeout 10 --max-time 600 \
        -X POST "http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/sre-triage-agent/" \
        -H "Content-Type: application/json" \
        -d @/tmp/request.json

      # Extract the LLM response
      jq -r '[.result.artifacts[]?.parts[]? | select(.kind == "text" or .text) | .text] | join("\n")' \
        /tmp/response.json
```

---

## Request Format

```json
{
  "jsonrpc": "2.0",
  "method": "message/send",
  "id": "unique-request-id",
  "params": {
    "message": {
      "role": "user",
      "parts": [
        {"kind": "text", "text": "Your question here"}
      ]
    }
  }
}
```

## Response Format

```json
{
  "jsonrpc": "2.0",
  "id": "unique-request-id",
  "result": {
    "status": {
      "state": "completed"
    },
    "artifacts": [
      {
        "parts": [
          {
            "kind": "text",
            "text": "The LLM's full response here..."
          }
        ]
      }
    ]
  }
}
```

### Extract Just the Answer

```bash
# Pipe curl output to:
jq -r '[.result.artifacts[]?.parts[]? | .text // empty] | join("\n")'
```

### Check for Errors

```bash
# JSON-RPC error
jq -r '.error.message // empty'

# Agent status
jq -r '.result.status.state'  # "completed", "failed", "running"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Connection refused` | Wrong port or service name | Use `kagent-controller:8083` (not `kagent-controller-manager:8082`) |
| `404 Not Found` | Missing trailing slash | Add `/` at end of URL |
| `404 Not Found` | Agent doesn't exist | Check `kubectl get agents -n kagent` |
| Empty response | Timeout (LLM takes too long) | Increase `--max-time` (default 600s for triage) |
| `error.message` in response | A2A/LLM error | Check agent pod logs: `kubectl logs -n kagent deploy/{agent-name}` |
| `Connection refused` from Argo | Cross-namespace DNS | Use full FQDN: `kagent-controller.kagent.svc.cluster.local:8083` |

### Health Check (no LLM call)

```bash
# Just check the controller is alive
curl -s http://localhost:8083/api/v1/runs | jq .

# List available agents via API
curl -s http://localhost:8083/api/v1/agents | jq '.[].metadata.name'
```

### Check Agent Logs

```bash
# Controller logs (routing, A2A dispatch)
kubectl logs -n kagent deploy/kagent-controller --tail=50

# Specific agent logs (LLM calls, tool use)
kubectl logs -n kagent deploy/sre-triage-agent --tail=50
```

---

## Common Gotchas

1. **Port 8083, not 8082** — Some config files still reference the old port. The actual service is `kagent-controller:8083`.
2. **Trailing slash required** — `/api/a2a/kagent/sre-triage-agent/` not `/api/a2a/kagent/sre-triage-agent`
3. **Responses are slow** — Triage agents call the LLM + run kubectl tools. Expect 30s–10min depending on the model (QWEN 14b ~8-10 min).
4. **One question per request** — A2A is stateless. Each `message/send` is an independent conversation. No session/thread continuity.
5. **Service name** — It's `kagent-controller`, not `kagent-controller-manager`. Check with `kubectl get svc -n kagent`.
