# HolmesGPT Token Usage Profiles

This guide provides three configuration profiles to control token consumption based on your needs and budget.

## Quick Reference

| Setting | Low | Medium | High |
|---------|-----|--------|------|
| `max_steps` | 5 | 15 | 40 |
| `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT` | 5 | 15 | 25 |
| `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS` | 5,000 | 25,000 | 50,000 |
| `MAX_OUTPUT_TOKEN_RESERVATION` | 4,096 | 16,384 | 32,768 |
| `include_tool_call_results` | false | false | true |
| Estimated tokens per investigation | ~20-50K | ~50-150K | ~150-500K |

---

## Profile 1: Low Token Usage

Best for: Cost-sensitive deployments, simple investigations, high-volume alerting.

### Helm Values (`values.yaml`)

```yaml
additionalEnvVars:
  - name: MAX_STEPS
    value: "5"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
    value: "5"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
    value: "5000"
  - name: MAX_OUTPUT_TOKEN_RESERVATION
    value: "4096"
```

### Helm Install Command

```bash
helm upgrade --install holmes robusta/holmes \
  --set additionalEnvVars[0].name=MAX_STEPS \
  --set additionalEnvVars[0].value="5" \
  --set additionalEnvVars[1].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT \
  --set additionalEnvVars[1].value="5" \
  --set additionalEnvVars[2].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS \
  --set additionalEnvVars[2].value="5000" \
  --set additionalEnvVars[3].name=MAX_OUTPUT_TOKEN_RESERVATION \
  --set additionalEnvVars[3].value="4096"
```

### API Request Parameters

When calling the API, also set:

```json
{
  "include_tool_calls": false,
  "include_tool_call_results": false
}
```

### Raw Kubernetes Manifests (Alternative)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
data:
  config.yaml: |
    max_steps: 5
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmes
spec:
  template:
    spec:
      containers:
        - name: holmes
          env:
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
              value: "5"
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
              value: "5000"
            - name: MAX_OUTPUT_TOKEN_RESERVATION
              value: "4096"
```

### Trade-offs

- Investigations may be less thorough (fewer tool calls)
- Large log outputs will trigger "narrow your query" errors more often
- Best paired with specific, focused questions

---

## Profile 2: Medium Token Usage (Recommended)

Best for: Production deployments balancing cost and investigation quality.

### Helm Values (`values.yaml`)

```yaml
additionalEnvVars:
  - name: MAX_STEPS
    value: "15"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
    value: "15"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
    value: "25000"
  - name: MAX_OUTPUT_TOKEN_RESERVATION
    value: "16384"
```

### Helm Install Command

```bash
helm upgrade --install holmes robusta/holmes \
  --set additionalEnvVars[0].name=MAX_STEPS \
  --set additionalEnvVars[0].value="15" \
  --set additionalEnvVars[1].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT \
  --set additionalEnvVars[1].value="15" \
  --set additionalEnvVars[2].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS \
  --set additionalEnvVars[2].value="25000" \
  --set additionalEnvVars[3].name=MAX_OUTPUT_TOKEN_RESERVATION \
  --set additionalEnvVars[3].value="16384"
```

### API Request Parameters

When calling the API, set:

```json
{
  "include_tool_calls": true,
  "include_tool_call_results": false
}
```

### Raw Kubernetes Manifests (Alternative)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
data:
  config.yaml: |
    max_steps: 15
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmes
spec:
  template:
    spec:
      containers:
        - name: holmes
          env:
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
              value: "15"
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
              value: "25000"
            - name: MAX_OUTPUT_TOKEN_RESERVATION
              value: "16384"
```

### Trade-offs

- Good balance of depth and cost
- Handles most Kubernetes investigations well
- May need multiple follow-up questions for complex issues

---

## Profile 3: High Token Usage

Best for: Deep investigations, complex multi-service issues, debugging sessions where thoroughness matters more than cost.

### Helm Values (`values.yaml`)

```yaml
additionalEnvVars:
  - name: MAX_STEPS
    value: "40"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
    value: "25"
  - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
    value: "50000"
  - name: MAX_OUTPUT_TOKEN_RESERVATION
    value: "32768"
```

### Helm Install Command

```bash
helm upgrade --install holmes robusta/holmes \
  --set additionalEnvVars[0].name=MAX_STEPS \
  --set additionalEnvVars[0].value="40" \
  --set additionalEnvVars[1].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT \
  --set additionalEnvVars[1].value="25" \
  --set additionalEnvVars[2].name=TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS \
  --set additionalEnvVars[2].value="50000" \
  --set additionalEnvVars[3].name=MAX_OUTPUT_TOKEN_RESERVATION \
  --set additionalEnvVars[3].value="32768"
```

### API Request Parameters

When calling the API, set:

```json
{
  "include_tool_calls": true,
  "include_tool_call_results": true
}
```

### Raw Kubernetes Manifests (Alternative)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
data:
  config.yaml: |
    max_steps: 40
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmes
spec:
  template:
    spec:
      containers:
        - name: holmes
          env:
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT
              value: "25"
            - name: TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS
              value: "50000"
            - name: MAX_OUTPUT_TOKEN_RESERVATION
              value: "32768"
```

### Trade-offs

- Most thorough investigations
- Higher cost per investigation
- Best for complex, multi-component issues

---

## Configuration Reference

### `max_steps`

Controls the maximum number of tool call iterations per investigation.

- **Location**: `config.yaml` or `MAX_STEPS` environment variable
- **Default**: 40
- **Impact**: Each step can invoke multiple tools; fewer steps = faster, cheaper investigations

### `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT`

Limits each tool response to a percentage of the model's context window.

- **Default**: 15 (15%)
- **Range**: 0-100 (0 or >100 disables the limit)
- **Behavior**: When exceeded, returns an error asking the LLM to narrow the query

### `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS`

Absolute maximum tokens for a single tool response.

- **Default**: 25,000
- **Behavior**: Hard cap regardless of percentage setting

### `MAX_OUTPUT_TOKEN_RESERVATION`

Tokens reserved for LLM output in conversations.

- **Default**: 16,384
- **Impact**: Affects how much context is available for tool results

### `include_tool_calls` / `include_tool_call_results`

API request parameters controlling response verbosity.

- **`include_tool_calls`**: Include tool call metadata (which tools were called, with what parameters)
- **`include_tool_call_results`**: Include full tool output in response (can be very large)
- **Default**: Both `false`

---

## Monitoring Token Usage

To understand your actual token consumption:

1. Enable debug logging to see per-request token counts
2. Monitor your LLM provider's usage dashboard
3. Track the number of tool calls per investigation in your observability stack

## Tips for Reducing Tokens

1. **Ask specific questions**: "Why is pod X crashlooping?" uses fewer tokens than "What's wrong with my cluster?"
2. **Use namespaces**: Scope investigations to specific namespaces when possible
3. **Disable verbose toolsets**: If you don't need AWS or Grafana tools, disable them in your toolset config
4. **Set `include_tool_call_results: false`**: This is the single biggest win for most deployments
