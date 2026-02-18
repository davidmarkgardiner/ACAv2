# KAgent Prompt Improvements — 2026-02-17

Two prompt-level fixes that improved KAgent from 3-2 to 5-0 against Holmes across all comparison scenarios.

## Problem 1: Namespace Typo Bug (Scenario 3)

Qwen 14B (running on RTX 3060 via KubeAI) would retype namespace names from memory instead of copying them exactly. `triage-test` became `triaage-test` (extra 'a'), causing all tool calls to fail.

### Fix: Namespace Anchoring in Workflow Prompt

**File:** `kagent-sre-workflow.yaml` (both triage and remediation prompt sections)

Added before the tool-usage instructions:
```
CRITICAL: When calling any tool, you MUST use the exact namespace "{{workflow.parameters.namespace}}" — copy it exactly, do not retype it from memory.
```

This injects the exact namespace string into the prompt at request time, reinforcing that the LLM should copy it verbatim.

### Fix: Namespace Rule in Agent System Prompt

**File:** `ai-platform/kagent/sre-triage-agent.yaml` (`spec.declarative.systemMessage` Rules section)

Added:
```
- Always use the EXACT namespace provided in the investigation request. Never modify, abbreviate, or retype namespace names — copy them character-for-character.
```

Double-layered defence: the workflow prompt provides the exact string, and the system prompt tells the agent to always copy namespaces exactly.

## Problem 2: No YAML Examples in Output (Scenario 2)

KAgent correctly identified a missing ConfigMap but only said "create it" — no ready-to-use YAML. Holmes provided a copy-paste ConfigMap template, making its output more actionable.

### Fix: YAML Example Rule in Agent System Prompt

**File:** `ai-platform/kagent/sre-triage-agent.yaml` (`spec.declarative.systemMessage` Rules section)

Added:
```
- When recommending creation of a missing resource (ConfigMap, Secret, Service, etc.), always include a ready-to-use YAML example the user can apply directly.
```

## Results

| Scenario | Before Fix | After Fix |
|----------|-----------|-----------|
| 2. Missing ConfigMap | 114s, no YAML (Holmes won) | 40s, includes YAML template (**KAgent wins**) |
| 3. OOMKilled | 35s but all tool calls failed (Holmes won) | 161s, correct namespace, full pod data + detailed OOM analysis (**KAgent wins**) |

Overall score improved from **KAgent 3 – Holmes 2** to **KAgent 5 – Holmes 0**.

## Deployment

```bash
# Deploy updated workflow template
kubectl apply -f aks-mgmt-stack/holmes-argoworkflows/kagent-sre-workflow.yaml

# Deploy updated agent CRD (from ai-platform repo)
kubectl apply -f ~/Desktop/repo/ai-platform/kagent/sre-triage-agent.yaml
```

## Key Takeaway

Small, targeted prompt changes can fix LLM reliability issues without model upgrades. The namespace anchoring pattern (`CRITICAL: use exact value "X"`) is reusable for any parameter that a smaller model might hallucinate or misspell.
