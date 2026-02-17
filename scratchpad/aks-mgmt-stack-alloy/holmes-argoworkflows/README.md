# Holmes + Argo Workflows — AI-Powered K8s Incident Triage & Remediation

Automated pipeline that takes a Kubernetes alert, runs AI analysis (or full auto-remediation), creates a GitLab issue with findings, and notifies the team on Mattermost.

## How It Works

There are **two workflow templates**. Both run in the `argo` namespace as Argo `WorkflowTemplate` resources.

### Workflow 1: `local-llm-analysis` (Analysis Only)

**File:** `local-llm-analysis-only.yaml`

Calls your LLM directly via the OpenAI-compatible `/chat/completions` API. No tools, no cluster access — it just reasons about the alert parameters you pass in. Fast (~67s), lightweight, zero risk.

```
┌─────────────┐    ┌─────────────┐    ┌─────────────────┐    ┌────────────────┐
│  1. Validate │───▶│ 2. Call LLM  │───▶│ 3. GitLab Issue │───▶│ 4. Mattermost  │
│  (curl)      │    │ (curl+jq)   │    │ (node.js)       │    │ (curl)         │
└─────────────┘    └─────────────┘    └─────────────────┘    └────────────────┘
```

| Step | Template | Image | What it does |
|------|----------|-------|-------------|
| 1. validate | `validate-inputs` | `curlimages/curl:8.5.0` | Checks the LLM `/models` endpoint is reachable. Fails fast if not. |
| 2. investigate | `call-local-llm` | `badouralix/curl-jq:alpine` | Sends a structured prompt (SRE expert persona) with the alert details to the LLM's `/chat/completions` endpoint. Writes response to shared PVC at `/work/llm-response.json`. |
| 3. report | `create-gitlab-issue` | `node:22-alpine` | Reads the LLM response from PVC, strips any `<think>` tags (Qwen artifact), formats a structured GitLab issue with analysis, quick commands, and a checklist. Writes issue URL/IID to PVC. |
| 4. notify | `mattermost-notify` | `curlimages/curl:8.5.0` | Reads issue URL from PVC, posts a summary table to Mattermost via webhook. Skips gracefully if no webhook is configured. |

**When to use:** Quick triage of many alerts, first-pass analysis where you want speed over depth.

**Dependencies:** Just an OpenAI-compatible LLM endpoint + GitLab API token.

---

### Workflow 2: `holmes-remediation` (Investigation + Auto-Fix)

**File:** `holmes-remediation.yaml`

Calls the HolmesGPT API, which is an AI agent that can **execute kubectl commands** against the cluster via AKS-MCP. Holmes diagnoses with real `describe`, `logs`, `get` calls, then (if `remediate=true`) actually fixes the issue with `set image`, `create configmap`, `patch`, `rollout restart`, etc.

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌────────────────┐
│  1. Validate │───▶│ 2. Holmes API    │───▶│ 3. GitLab Issue │───▶│ 4. Mattermost  │
│  (curl)      │    │ (curl+jq)        │    │ (node.js)       │    │ (curl)         │
│              │    │                  │    │                 │    │                │
│ Check Holmes │    │ Holmes → LLM     │    │ Formats analysis│    │ Posts summary  │
│ /healthz     │    │ Holmes → MCP     │    │ + tool calls    │    │ with GitLab    │
│              │    │ Holmes → kubectl  │    │ into issue body │    │ issue link     │
└─────────────┘    └──────────────────┘    └─────────────────┘    └────────────────┘
```

| Step | Template | Image | What it does |
|------|----------|-------|-------------|
| 1. validate | `validate-inputs` | `curlimages/curl:8.5.0` | Checks Holmes `/healthz` is responding. Fails fast if not. |
| 2. holmes-investigate | `call-holmes` | `badouralix/curl-jq:alpine` | Builds the Holmes API request using `jq` (safe JSON construction). Sends to Holmes `/api/investigate` with either remediation or analysis-only instructions. Holmes then orchestrates multiple LLM+tool calls internally. Writes full response (including tool calls list) to shared PVC. |
| 3. report | `create-gitlab-issue` | `node:22-alpine` | Reads Holmes response from PVC, formats a GitLab issue showing: analysis, every tool call Holmes executed, whether remediation was applied, and a verification checklist. Uses `continueOn.failed: true` so notification still fires if GitLab is down. |
| 4. notify | `mattermost-notify` | `curlimages/curl:8.5.0` | Same as Workflow 1. Posts summary with remediation/analysis status. |

**The `remediate` parameter** controls Holmes behavior:
- `remediate=true` — Holmes diagnoses AND executes fixes (set image, create configmap, patch, rollout restart, etc.)
- `remediate=false` — Holmes diagnoses only using read commands, recommends fixes but does not execute them

**When to use:** Deep investigation where you need real cluster data (logs, describe output), or auto-fixing known issue patterns.

**Dependencies:** HolmesGPT service + AKS-MCP server + GitLab API token.

---

## File Reference

### Active Files (deploy these)

| File | Type | Purpose |
|------|------|---------|
| `local-llm-analysis-only.yaml` | WorkflowTemplate | Analysis-only workflow — direct LLM call, no tools |
| `holmes-remediation.yaml` | WorkflowTemplate | Holmes investigation + auto-fix workflow |
| `helm-values-proxmox.yaml` | Helm values | Holmes deployment config for proxmox-k8s cluster (LLM endpoint, MCP config, RBAC, disabled built-in tools) |

### Supporting Files

| File | Purpose |
|------|---------|
| `test-local-llm.sh` | Standalone test — checks LLM connectivity and runs a sample chat completion |
| `test-holmes-gitlab.sh` | Standalone test — checks Holmes, GitLab token, project access, creates a test issue |
| `INTEGRATION-README.md` | Detailed architecture, test results, deployment instructions, known limitations |
| `LIFT-AND-SHIFT.md` | Checklist for deploying to a different cluster (what values to change) |

### Superseded Files (do NOT deploy)

| File | Replaced By |
|------|-------------|
| `holmes-gitlab-workflow.yaml` | `holmes-remediation.yaml` |
| `holmes-gitlab-workflow-v2.yaml` | `holmes-remediation.yaml` |
| `local-llm-investigation-gitlab.yaml` | `local-llm-analysis-only.yaml` |
| `run-investigation.yaml` | Use `argo submit --from=workflowtemplate/...` instead |
| `holmes-gitlab-template.md` | GitLab issue format is now built into the workflow templates |
| `PROJECT-SUMMARY.md` | Historical — original project completion notes |

---

## Shared PVC Pattern

Both workflows use a `volumeClaimTemplate` (64Mi PVC on `longhorn`) named `work` to pass data between steps:

```
Step 2 writes:  /work/llm-response.json   (or /work/holmes-response.json)
Step 3 reads:   /work/*-response.json      → processes → writes /work/gitlab-issue-url.txt, /work/gitlab-issue-iid.txt
Step 4 reads:   /work/gitlab-issue-url.txt → includes in Mattermost notification
```

This is needed because each Argo step runs as a separate pod — they can't share files via the filesystem without a shared volume.

---

## Secrets

Both workflows expect these K8s Secrets in the `argo` namespace:

| Secret | Key | Used By | Required |
|--------|-----|---------|----------|
| `gitlab-token` | `GITLAB_TOKEN` | Step 3 (GitLab issue creation) | Yes |
| `mattermost-webhook` | `url` | Step 4 (Mattermost notification) | No (optional, skips if missing) |

```bash
kubectl create secret generic gitlab-token --namespace argo --from-literal=GITLAB_TOKEN='glpat-xxxxx'
kubectl create secret generic mattermost-webhook --namespace argo --from-literal=url='https://mattermost.example.com/hooks/xxx'
```

---

## Parameters

Both templates accept these parameters via `argo submit -p key=value`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `query` | "Investigate..." | Free-text investigation query |
| `event_type` | "Unknown" | K8s event type (BackOff, FailedMount, OOMKilled, etc.) |
| `cluster` | "proxmox-k8s" | Cluster name for labelling |
| `namespace` | "default" | Target namespace |
| `resource_kind` | "Pod" | Resource type |
| `resource_name` | "unknown" | Resource name |
| `severity` | "medium" | Alert severity |
| `error_message` | "" | Error text from the alert |

**Analysis-only extras:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `local_llm_url` | `http://kubeai.kubeai.svc.cluster.local/openai/v1` | OpenAI-compatible LLM endpoint |
| `llm_model` | `qwen3-14b` | Model name for `/chat/completions` |

**Remediation extras:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `holmes_url` | `http://holmes-holmes.holmesgpt.svc.cluster.local:80` | Holmes API endpoint |
| `remediate` | `true` | `true` = diagnose+fix, `false` = diagnose only |

---

## Quick Start

```bash
# Deploy templates
kubectl apply -f local-llm-analysis-only.yaml
kubectl apply -f holmes-remediation.yaml

# Run analysis only
argo submit -n argo --from=workflowtemplate/local-llm-analysis \
  -p query="Investigate CrashLoopBackOff for postgres" \
  -p event_type="BackOff" \
  -p namespace="ghostfolio" \
  -p resource_name="postgres-7ff6bbfb57-zdq79" \
  -p severity="high" \
  --watch

# Run remediation
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Fix ImagePullBackOff for web-frontend" \
  -p event_type="ImagePullBackOff" \
  -p namespace="holmes-test" \
  -p resource_name="web-frontend-xxx" \
  -p remediate="true" \
  --watch
```

---

## Holmes Architecture (Remediation Only)

Holmes acts as the bridge between the LLM and kubectl. This is what happens inside Step 2 of `holmes-remediation`:

```
Argo Workflow                   HolmesGPT                    AKS-MCP Server
     │                              │                              │
     │  POST /api/investigate       │                              │
     │─────────────────────────────▶│                              │
     │  (instructions, subject,     │  1. Sends prompt to LLM     │
     │   context, remediate flag)   │─────▶ Qwen 3 14B (vLLM)    │
     │                              │                              │
     │                              │  2. LLM decides tool calls  │
     │                              │─────────────────────────────▶│
     │                              │  call_kubectl(describe pod)  │
     │                              │◀─────────────────────────────│
     │                              │  (pod describe output)       │
     │                              │                              │
     │                              │  3. LLM analyzes output     │
     │                              │─────▶ Qwen 3 14B            │
     │                              │                              │
     │                              │  4. LLM decides fix         │
     │                              │─────────────────────────────▶│
     │                              │  call_kubectl(set image ...) │
     │                              │◀─────────────────────────────│
     │                              │  (image updated)             │
     │                              │                              │
     │  { analysis, tool_calls }    │                              │
     │◀─────────────────────────────│                              │
```

Holmes is deployed via Helm (`helm-values-proxmox.yaml`) with:
- **LLM**: `openai/qwen3-14b` via KubeAI (env: `OPENAI_API_BASE`)
- **Built-in k8s toolsets**: All disabled (forces everything through AKS-MCP for consistency)
- **MCP server**: AKS-MCP at `http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp` via `streamable-http` transport
- **Key rules in MCP instructions**: Never use `kubectl edit` (interactive), always check container names before `set image`

---

## Tested Scenarios

| Scenario | Workflow | Result |
|----------|----------|--------|
| CrashLoopBackOff analysis | `local-llm-analysis` | 67s, generic advice (no cluster access) |
| CrashLoopBackOff (WAL corruption) | `holmes-remediation` (remediate=false) | Found `PANIC: could not locate valid checkpoint record` from actual logs |
| ImagePullBackOff (bad tag) | `holmes-remediation` (remediate=true) | Holmes ran `set image` → pod Running |
| Missing ConfigMap | `holmes-remediation` (remediate=true) | Holmes ran `create configmap` → pod Running |
