---
name: byoa-agent-builder
description: Interactive wizard that interviews a user and produces a ready-to-apply kagent Agent CRD YAML for the BYOA (Bring Your Own Agent) triage platform. Use when a team wants to onboard their own namespace triage agent, when building a new platform agent, or when editing an existing agent's system prompt or tool set.
metadata:
  openclaw:
    emoji: "🧙"
    requires:
      anyBins: ["kubectl"]
---

# BYOA Agent Builder

Conduct a structured interview with the user and produce a complete, ready-to-apply `kagent.dev/v1alpha2` Agent CRD.

Read `references/tool-catalog.md` and `references/system-prompt-patterns.md` before starting. Reference `assets/agent-template.yaml` as the base structure.

---

## Interview Workflow

Run the interview in **three stages**. Ask one stage at a time. Wait for answers before moving to the next stage. Never ask more than 4 questions per turn.

### Stage 1 — Identity & Scope

Ask:
1. **Team name** — what team or squad owns this agent? (used for labels and naming)
2. **Target namespaces** — which namespaces should this agent cover? (list them all)
3. **Agent type** — triage only (read-only investigation) or remediation (can apply fixes)?
4. **Agent name** — do they have a preferred name, or should it follow the convention `{team}-triage-agent` / `{team}-remediation-agent`?

### Stage 2 — Domain Knowledge

Ask:
1. **Services** — list the main services/deployments in those namespaces. For each: name, language/stack, and key dependencies (databases, queues, external APIs).
2. **Common failure modes** — what are the top 3–5 things that go wrong? For each, do they have a runbook or known fix?
3. **Sensitive data constraints** — any data that must never appear in triage output? (PII, card numbers, secrets, etc.)
4. **Escalation** — Slack channel, PagerDuty routing key, or on-call contact for when the agent can't resolve an issue?

### Stage 2b — Runbook Details (follow-up if needed)

If the user listed failure modes without runbooks, ask for each:
- What are the diagnostic steps?
- What is the fix, if known?
- When should a human be looped in?

### Stage 3 — Platform Configuration

Ask:
1. **Model** — use platform default (`default-model-config`) or a specific model config? (Options: `litellm-qwen-14b`, `litellm-azure-gpt4o`, or custom)
2. **Tool scope** — for triage agents: read-only tools are pre-selected. For remediation: confirm they want write tools (apply, patch, delete). Show the tool list from `references/tool-catalog.md` and ask if they want to add or remove any.
3. **Existing manifests** — do they already have any YAML to reference (Deployments, HelmReleases, etc.)? If yes, ask them to paste or reference the file — use it to enrich the system prompt.
4. **Testing preference** — does your team use `kagent invoke` CLI or direct A2A API for testing? Use the answer to tailor apply instructions.

---

## YAML Generation

After completing all three stages, generate the following artifacts:

### 1. Agent CRD

Use `assets/agent-template.yaml` as the base. Fill in:

- `metadata.name` — `{team}-{type}-agent` (e.g., `payments-triage-agent`)
- `metadata.labels` — include `platform.com/team: {team}` and `platform.com/type: {triage|remediation}`
- `spec.description` — one-paragraph summary including namespace list and domain
- `spec.declarative.systemMessage` — built from Stage 2 answers using patterns in `references/system-prompt-patterns.md`
- `spec.declarative.modelConfig` — from Stage 3
- `spec.declarative.tools[].mcpServer.toolNames` — triage set or remediation set from `references/tool-catalog.md`
- `spec.declarative.a2aConfig.skills` — one skill entry per agent type

Always include these in the system prompt (see patterns file for exact wording):
- Namespace anchoring: `CRITICAL: always use exact namespace '{namespace}' when investigating`
- Output format: Issue / Evidence / Root Cause / Fix / Risk / Verification
- Safety rules appropriate to agent type (triage: no writes; remediation: prefer rolling restarts, never delete PVs)

### 2. Namespace Annotations

Generate `kubectl annotate` commands for each namespace:

```bash
kubectl annotate ns {namespace} \
  triage.platform.com/agent={agent-name} \
  triage.platform.com/agent-namespace=kagent \
  platform.com/team={team} \
  --overwrite
```

### 3. Apply Instructions

Provide the deployment sequence:

```bash
# 1. Apply the Agent CRD
kubectl apply -f {agent-name}.yaml

# 2. Verify the agent is ready
kubectl get agent {agent-name} -n kagent

# 3. Annotate namespaces
# (paste the annotate commands from above)

# 4. Test the agent with the kagent CLI (preferred)
kagent invoke -t 'What is the health of namespace {namespace}?' --agent {agent-name} --stream

# 5. Or test the agent directly via A2A
curl -s -X POST http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/{agent-name}/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"test-1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"What is the health of namespace {namespace}?"}]}}}' \
  | jq -r '.result.artifacts[].parts[].text'

# 6. Collect diagnostics if the agent is not responding
kagent bug-report
```

---

## Iteration Loop

After delivering the YAML, ask: **"Does this look right? Anything to adjust — runbooks, tools, escalation, or wording?"**

Apply requested changes and re-output only the affected sections. Continue until the user confirms.

---

## Validation Checklist

Before finalising output, verify:
- [ ] `toolNames` list is not empty and contains only names from `references/tool-catalog.md`
- [ ] System prompt includes `CRITICAL: always use exact namespace` line for every namespace
- [ ] Triage agents have NO write tools (`k8s_apply_manifest`, `k8s_patch_resource`, `k8s_delete_resource`, `k8s_create_resource`, `k8s_execute_command`)
- [ ] Remediation agents include at least the core write tools
- [ ] `platform.com/team` and `platform.com/type` labels are present
- [ ] `a2aConfig.skills` has at least one skill entry
- [ ] `modelConfig` field matches an available ModelConfig (not `modelConfigRef` — that field was deprecated)
- [ ] `systemMessage` is used for the prompt field (live CRD confirmed) — NOT `systemPrompt`
- [ ] Every A2A message part includes `"kind": "text"` alongside `"text"`
- [ ] A2A tests use `method: "message/send"` and extract `.result.artifacts[].parts[].text`
- [ ] Session API is not used for kagent v0.8.0-beta4 — it is broken there; only the A2A protocol works
- [ ] Live CRD schema has been checked with `kubectl explain agent.spec.declarative`
- [ ] `kagent bug-report` is available in apply instructions for diagnostics

---

## Output Format

Output each artifact in its own fenced code block with a filename comment:

```yaml
# {agent-name}.yaml
apiVersion: kagent.dev/v1alpha2
...
```

```bash
# annotate-namespaces.sh
kubectl annotate ns ...
```

Then provide a one-paragraph summary of what was generated and the recommended next step.

---

## Deployed Builder Agents

Two ready-to-use interactive builder agents are already deployed in `kagent-triage/`. Recommend these to users who want to build agents via the KAgent UI chat interface instead of through this Claude skill.

| Agent | File | For |
|-------|------|-----|
| `byoa-builder-expert` | `kagent-triage/byoa-builder-expert.yaml` | Engineers who know Kubernetes — fast 3-round interview, generates YAML, can apply directly |
| `byoa-builder-guided` | `kagent-triage/byoa-builder-guided.yaml` | Platform newcomers — plain-English 7-topic flow, explanations at each step, output goes via PR review |

### Testing the deployed builders

```bash
# Port-forward if no LoadBalancer
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

# Test expert builder
curl -s -X POST http://localhost:8083/api/a2a/kagent/byoa-builder-expert/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Build me a triage agent for the payments namespace"}]}}}' \
  | jq -r '.result.artifacts[].parts[].text'

# Test guided builder
curl -s -X POST http://localhost:8083/api/a2a/kagent/byoa-builder-guided/ \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Hi, I want to set up an agent for my team"}]}}}' \
  | jq -r '.result.artifacts[].parts[].text'
```

### Key differences from this Claude skill

| | Claude skill (`byoa-agent-builder`) | KAgent UI (`byoa-builder-expert`) | KAgent UI (`byoa-builder-guided`) |
|---|---|---|---|
| Interface | Claude Code CLI | KAgent chat UI / A2A | KAgent chat UI / A2A |
| Can apply to cluster | No — generates YAML only | Yes — has `k8s_apply_manifest` | No — PR review gate |
| Audience | Platform engineers using Claude Code | GenTek / k8s-fluent engineers | Platform newcomers |
