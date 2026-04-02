# A2A Agent-as-Tool POC (Tested on Red Cluster)

Proof of concept: one kagent agent calling another agent as a tool via A2A protocol.

**Tested:** 2026-04-02 on red cluster, kagent with `default-model-config` (kimi-for-coding)

## What This Proves

- Agent A (`hello-caller-agent`) can call Agent B (`hello-responder-agent`) as a tool
- No manual service/URL/auth configuration needed — just `type: Agent` in the tools list
- kagent handles service discovery, A2A HTTP call, and response routing automatically
- Context is passed through: the responder echoed back the caller's message including "David"

## Test Result

```
Sent:     "Hello! My name is David. Can you say hello to me?"
Received: "Hello David! It's nice to meet you — I'm happy to say hello back!"
Status:   A2A working
```

Tool call visible in history:
```json
{
  "name": "kagent__NS__hello_responder_agent",
  "args": { "request": "Hello! My name is David. Can you say hello to me?" }
}
```

## Prerequisites

- kagent installed (CRDs + controller + tools)
- A `ModelConfig` resource (any LLM will do)
- Both agents in the same namespace (cross-namespace also works with `namespace` field)

## Deploy

```bash
# 1. Apply both agents
kubectl apply -f hello-responder-agent.yaml
kubectl apply -f hello-caller-agent.yaml

# 2. Wait for both to be Ready
kubectl get agents -n kagent | grep hello
# NAME                     TYPE          RUNTIME   READY   ACCEPTED
# hello-caller-agent       Declarative   python    True    True
# hello-responder-agent    Declarative   python    True    True
```

## Test via A2A

```bash
# 3. Port-forward to the caller agent
kubectl port-forward -n kagent svc/hello-caller-agent 9090:8080 &

# 4. Send A2A message (A2A protocol v0.3.0 requires messageId)
curl -s -X POST http://localhost:9090/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "a2a-test-1",
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-001",
        "role": "user",
        "parts": [{"kind": "text", "text": "Please call the hello-responder-agent and ask it to say hello. Tell it your name is David."}]
      }
    }
  }' | jq .
```

## Test via kagent UI

Alternatively, open the kagent UI and chat with `hello-caller-agent`:
```bash
kubectl port-forward -n kagent svc/kagent-ui 3000:8080
# Open http://localhost:3000 → select hello-caller-agent → type "Say hello to the other agent"
```

## How It Works

```
User
  │
  │ A2A message/send
  ▼
hello-caller-agent (port 8080)
  │
  │ Sees "type: Agent" tool → kagent__NS__hello_responder_agent
  │ Makes internal A2A call to hello-responder-agent.kagent:8080
  ▼
hello-responder-agent (port 8080)
  │
  │ Receives request, generates greeting
  │ Returns response via A2A
  ▼
hello-caller-agent compiles final output
  │
  │ Returns to user
  ▼
User sees: Sent / Received / Status
```

## Key Learnings

### A2A Protocol v0.3.0 Changes (from what we used before)
- `messageId` is now **required** in the message object (was optional in earlier versions)
- Agent endpoint is the **service root** (`/`), not `/api/a2a/kagent/{name}/`
- Agent card at `/.well-known/agent.json` — useful for debugging
- `parts` still requires `"kind": "text"` (unchanged)

### What You Need for Agent-as-Tool

On the **caller** agent:
```yaml
tools:
  - type: Agent
    agent:
      name: hello-responder-agent    # just the agent name
      namespace: kagent               # optional if same namespace
```

On the **target** agent:
```yaml
a2aConfig:
  skills:                             # metadata describing capabilities
    - id: greet
      name: Greet
      description: Responds with a friendly greeting
```

That's it. No service creation, no URL config, no auth setup.

### Cross-Namespace A2A

If agents are in different namespaces, just set `namespace` on the tool reference:
```yaml
tools:
  - type: Agent
    agent:
      name: gitops-agent
      namespace: gitops              # different namespace
```

The target agent needs `allowedNamespaces` if you want to restrict who can call it:
```yaml
spec:
  allowedNamespaces:
    from: Selector
    selector:
      matchLabels:
        kagent-access: allowed
```

## Cleanup

```bash
kubectl delete agent hello-caller-agent hello-responder-agent -n kagent
```

## Next Step: Triage → Remediation

This same pattern applies to the triage-to-remediation pipeline:
```yaml
# On cert-manager-agent (triage)
tools:
  - type: McpServer        # k8s tools for diagnosis
    mcpServer: ...
  - type: Agent            # gitops agent for remediation
    agent:
      name: gitops-remediation-agent
      namespace: kagent
```

See: `MEMORY-AND-A2A-REMEDIATION-DESIGN.md` for the full architecture.
