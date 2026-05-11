# BYOA Self-Service Agent Platform

**Bring Your Own Agent** — teams create and own their own namespace triage agents without requiring platform team intervention.

> Background: [BYOA Platform Proposal](../aks-mgmt-stack/holmes-argoworkflows/BYOA-AGENT-PLATFORM-PROPOSAL.md)

---

## Overview

Instead of routing all alerts to a single generic agent, each team deploys an agent with their own domain knowledge: their services, their runbooks, their escalation paths.

```
Alert in payments-prod
  → Argo Events Sensor
  → Routing WorkflowTemplate (reads namespace annotation)
  → payments-triage-agent  ← team-owned, team-maintained
  → Diagnosis using payments runbooks
  → #payments-incidents Slack
```

Teams register their agent by annotating their namespace:
```bash
kubectl annotate ns payments-prod \
  triage.platform.com/agent=payments-triage-agent \
  triage.platform.com/agent-namespace=kagent \
  platform.com/team=payments \
  --overwrite
```

---

## Two Ways to Build Your Agent

### Option 1 — Interactive Builder (KAgent UI)

Chat with a builder agent directly in the KAgent UI. No YAML knowledge required.

| Builder | For | Access |
|---------|-----|--------|
| `byoa-builder-expert` | Engineers who know Kubernetes | KAgent UI → chat → generates + can apply directly |
| `byoa-builder-guided` | Teams new to the platform | KAgent UI → plain-English interview → PR for review |

**Start a session:**

```bash
# Port-forward if needed
kubectl port-forward -n kagent svc/kagent-controller 8083:8083

# Expert builder — or open the KAgent UI and select byoa-builder-expert
curl -s -X POST http://localhost:8083/api/a2a/kagent/byoa-builder-expert/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Build me a triage agent for my namespace"}]}}}' \
  | jq -r '.result.history[-1].parts[].text // .result.status.message.parts[].data.args.originalFunctionCall.args.questions[].question'
```

The builder conducts a structured interview:
- **Round 1**: agent name, namespaces, triage vs remediation, team label
- **Round 2**: services + dependencies, failure modes + runbooks, sensitive data, escalation path
- **Round 3**: model config, tool selection, apply immediately?

**Expert builder** generates YAML and offers to apply it directly with `kubectl apply`.
**Guided builder** generates YAML formatted for a pull request — platform team reviews and deploys.

### Option 2 — Claude Code Skill

If you work in Claude Code, use the `byoa-agent-builder` skill for the same interview workflow. Invoke it with:

```
/byoa-agent-builder
```

or just describe what you need:
```
Build me a triage agent for the payments namespace
```

The skill lives at `skills/byoa-agent-builder/` and contains the same interview logic plus reference docs for tool selection and system prompt patterns.

---

## What You Provide (The BYOA Contract)

To onboard, a team provides an Agent CRD with:

| Field | What to put |
|-------|------------|
| `metadata.labels.platform.com/team` | Your team name |
| `metadata.labels.platform.com/type` | `triage` or `remediation` |
| `spec.declarative.systemMessage` | Your domain knowledge: namespaces, services, runbooks, escalation |
| `spec.declarative.tools[].mcpServer.toolNames` | Read-only for triage; write tools for remediation |
| `spec.declarative.a2aConfig.skills` | At least one skill entry with description and examples |

Minimal working example:
```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: payments-triage-agent
  namespace: kagent
  labels:
    platform.com/team: payments
    platform.com/type: triage
spec:
  type: Declarative
  declarative:
    modelConfig: default-model-config
    systemMessage: |
      You are the payments triage agent.
      CRITICAL: always use exact namespace 'payments-prod' — copy character-for-character.
      ## Services
      - payment-api: Go, PostgreSQL + Stripe
      - payment-worker: Python, SQS
      ## Escalation
      Slack: #payments-incidents
    tools:
    - type: McpServer
      mcpServer:
        apiGroup: kagent.dev
        kind: RemoteMCPServer
        name: kagent-tool-server
        toolNames:
          - k8s_get_resources
          - k8s_describe_resource
          - k8s_get_pod_logs
          - k8s_get_events
          - k8s_get_resource_yaml
          - k8s_get_available_api_resources
          - k8s_get_cluster_configuration
          - k8s_check_service_connectivity
    a2aConfig:
      skills:
      - id: payments-triage
        name: Payments Triage
        description: Diagnose issues in payments-prod namespace
        tags: [payments, triage]
```

---

## What the Platform Provides

| Component | Description |
|-----------|-------------|
| **KAgent controller** | Runs and manages all agents |
| **kagent-tool-server** | MCP tools: kubectl equivalents (get, describe, logs, events, connectivity) |
| **LLM endpoint** | Shared model pool via LiteLLM (default: `default-model-config`) |
| **Argo Events pipeline** | Routes alerts to the correct agent based on namespace annotation |
| **Builder agents** | `byoa-builder-expert` and `byoa-builder-guided` for self-service onboarding |
| **Claude skill** | `byoa-agent-builder` for Claude Code users |

---

## Available Tools

### Read-Only (triage agents)
| Tool | Description |
|------|-------------|
| `k8s_get_resources` | List resources by kind/namespace |
| `k8s_describe_resource` | Describe a resource (kubectl describe) |
| `k8s_get_pod_logs` | Fetch container logs |
| `k8s_get_events` | Get K8s events |
| `k8s_get_resource_yaml` | Get raw YAML of a resource |
| `k8s_get_available_api_resources` | List available API types |
| `k8s_get_cluster_configuration` | Cluster-level config |
| `k8s_check_service_connectivity` | Test service-to-service connectivity |

### Write Tools (remediation agents only — requires explicit approval)
| Tool | Risk |
|------|------|
| `k8s_apply_manifest` | Medium |
| `k8s_create_resource` | Medium |
| `k8s_patch_resource` | Medium |
| `k8s_annotate_resource` / `k8s_label_resource` | Low |
| `k8s_delete_resource` | High — ask platform team |
| `k8s_execute_command` | High — ask platform team |

---

## Routing

Alerts route to agents based on namespace annotations (priority order):

| Priority | Condition | Routes to |
|----------|-----------|-----------|
| 1 | Alert matches platform agent type (cert-manager, node, storage) | Platform agent |
| 2 | Namespace has `triage.platform.com/agent` annotation | Team's BYOA agent |
| 3 | Namespace `team` label matches `{team}-triage-agent` by convention | Team agent (convention) |
| 4 | No match | `sre-triage-agent` (fallback) |

---

## Onboarding Checklist

- [ ] Chat with `byoa-builder-expert` or `byoa-builder-guided` in KAgent UI **or** run `/byoa-agent-builder` in Claude Code
- [ ] Review the generated Agent CRD YAML
- [ ] Submit PR to `kagent-triage/` (guided flow) **or** apply directly (expert flow)
- [ ] Annotate your namespaces with `triage.platform.com/agent`
- [ ] Test: trigger a fault injection and verify your agent responds

---

## Testing Your Agent

```bash
# Verify agent is running
kubectl get agent {agent-name} -n kagent

# Send a test query directly via A2A
curl -s -X POST http://localhost:8083/api/a2a/kagent/{agent-name}/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"What is the health of namespace {namespace}?"}]}}}' \
  | jq -r '.result.artifacts[].parts[].text'

# Collect diagnostics if not responding
kagent bug-report
```

---

## Files

| File | Purpose |
|------|---------|
| `kagent-triage/byoa-builder-expert.yaml` | Expert builder agent CRD |
| `kagent-triage/byoa-builder-guided.yaml` | Guided builder agent CRD |
| `skills/byoa-agent-builder/SKILL.md` | Claude Code skill |
| `skills/byoa-agent-builder/references/tool-catalog.md` | Full tool list with risk ratings |
| `skills/byoa-agent-builder/references/system-prompt-patterns.md` | Proven system prompt patterns |
| `skills/byoa-agent-builder/assets/agent-template.yaml` | Base Agent CRD template |
| `aks-mgmt-stack/holmes-argoworkflows/BYOA-AGENT-PLATFORM-PROPOSAL.md` | Original proposal + architecture |
