# Holmes + Argo Workflows Integration

## Architecture

```
                                    ┌──────────────────────────────────┐
                                    │  Workflow 1: ANALYSIS ONLY       │
                                    │  (direct LLM, fast, lightweight) │
K8s Event ──► Argo Events ────────► validate → Qwen 3 14B → GitLab   │
              (future)              │                       → Mattermost│
                                    └──────────────────────────────────┘

                                    ┌──────────────────────────────────┐
                                    │  Workflow 2: HOLMES REMEDIATION  │
                                    │  (agent with tools, thorough)    │
K8s Event ──► Argo Events ────────► validate → Holmes API → GitLab    │
              (future)              │    (Qwen + AKS-MCP call_kubectl) │
                                    │                       → Mattermost│
                                    └──────────────────────────────────┘
```

### Component Stack

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Argo Workflows | `argo` | Workflow orchestration |
| KubeAI + Qwen 3 14B | `kubeai` | Local LLM ($0 cost) |
| HolmesGPT | `holmesgpt` | AI agent with tool use |
| AKS-MCP | `aks-mcp` | kubectl/helm/az tool server (admin) |
| GitLab | external | Issue tracking |
| Mattermost | `mattermost` | Team notifications |

## Quick Start

### Prerequisites
- Argo Workflows v3.6.4 in `argo` namespace
- KubeAI with `qwen3-14b` model in `kubeai` namespace
- GitLab token in K8s Secret (`gitlab-token` in `argo` namespace)

### Deploy Everything
```bash
# 1. AKS-MCP server (admin access for remediation)
kubectl apply -f ../../application-stack/apps/holmesgpt/aks-mcp-local-admin.yaml

# 2. HolmesGPT (connects to KubeAI + AKS-MCP)
helm upgrade --install holmes robusta/holmes \
  --namespace holmesgpt --create-namespace \
  -f helm-values-proxmox.yaml

# 3. Workflow templates
kubectl apply -f local-llm-analysis-only.yaml
kubectl apply -f holmes-remediation.yaml
```

### Run Analysis Only (fast, 67s)
```bash
argo submit -n argo --from=workflowtemplate/local-llm-analysis \
  -p query="Investigate CrashLoopBackOff for postgres pod" \
  -p event_type="BackOff" \
  -p cluster="proxmox-k8s" \
  -p namespace="ghostfolio" \
  -p resource_kind="Pod" \
  -p resource_name="postgres-7ff6bbfb57-zdq79" \
  -p severity="high" \
  -p 'error_message=Back-off restarting failed container' \
  --watch
```

### Run Holmes Remediation (thorough, ~2 min)
```bash
# Analysis + remediation (Holmes uses MCP tools to fix)
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Investigate and fix CrashLoopBackOff for postgres pod" \
  -p event_type="BackOff" \
  -p cluster="proxmox-k8s" \
  -p namespace="ghostfolio" \
  -p resource_kind="Pod" \
  -p resource_name="postgres-7ff6bbfb57-zdq79" \
  -p severity="high" \
  -p 'error_message=Back-off restarting failed container' \
  -p remediate="true" \
  --watch

# Analysis only (Holmes diagnoses but does NOT fix)
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p remediate="false" \
  ...same params...
  --watch
```

## Workflow Templates

| Template | File | Purpose | LLM Path | Status |
|----------|------|---------|----------|--------|
| `local-llm-analysis` | `local-llm-analysis-only.yaml` | Fast analysis, no tools | Direct Qwen 3 14B | Tested |
| `holmes-remediation` | `holmes-remediation.yaml` | Full investigation + fix | Holmes → Qwen + AKS-MCP | Tested |

### When to use which?

| Scenario | Use |
|----------|-----|
| Quick triage of many alerts | `local-llm-analysis` (fast, 67s) |
| Deep investigation with real kubectl | `holmes-remediation` (remediate=false) |
| Auto-fix known issue patterns | `holmes-remediation` (remediate=true) |

## Test Results

### Workflow 1: Analysis Only (GitLab #404)
| Metric | Value |
|--------|-------|
| Total duration | 67 seconds |
| LLM inference | 15 seconds |
| Tokens | 673 |
| Tool calls | 0 (direct LLM) |
| Finding | Generic CrashLoopBackOff advice |

### Workflow 2: Holmes Analysis (GitLab #405)
| Metric | Value |
|--------|-------|
| Total duration | 2 min 18 sec |
| Holmes investigation | 76 seconds |
| LLM calls | 2 |
| Tool calls | 1 (fetch_pod_logs via built-in k8s tools) |
| Finding | `PANIC: could not locate a valid checkpoint record` (actual root cause from logs) |

### Workflow 2: Holmes Remediation - ImagePullBackOff (auto-fixed)
| Metric | Value |
|--------|-------|
| Total duration | 2 min 2 sec |
| Tool calls | `call_kubectl describe`, `call_kubectl set image` |
| Fix applied | `set image deployment/web-frontend web-frontend=nginx:stable` |
| Result | Pod transitioned to Running |

### Workflow 2: Holmes Remediation - Missing ConfigMap (auto-fixed)
| Metric | Value |
|--------|-------|
| Total duration | 2 min 10 sec |
| Tool calls | `call_kubectl describe`, `call_kubectl create configmap` |
| Fix applied | `create configmap app-config-missing --from-literal=app.conf=placeholder` |
| Result | Pod transitioned to Running |

## Secrets

```bash
# GitLab token (already created)
kubectl get secret gitlab-token -n argo

# To recreate:
kubectl create secret generic gitlab-token \
  --namespace argo \
  --from-literal=GITLAB_TOKEN='glpat-xxxxx'
```

## Holmes Configuration

Holmes is deployed via Helm with:
- **LLM**: `openai/qwen3-14b` via KubeAI (OpenAI-compatible API, `OPENAI_API_BASE`)
- **Built-in k8s tools**: Disabled (all operations routed through AKS-MCP)
- **MCP tools**: AKS-MCP (`call_kubectl` with admin access via streamable-http)
- **Helm values**: `helm-values-proxmox.yaml`

```bash
# Check Holmes status
kubectl get pods -n holmesgpt
kubectl logs -n holmesgpt -l app=holmes --tail=20

# Verify MCP connection
kubectl logs -n holmesgpt -l app=holmes | grep "aks-mcp"

# Test Holmes API directly
kubectl exec -n holmesgpt deploy/holmes-holmes -- curl -s http://localhost:5050/healthz
```

## Key Design Decisions

1. **Built-in k8s toolsets disabled** - Forces all kubectl operations through AKS-MCP `call_kubectl`, ensuring Holmes uses the same tool for both reads and writes.
2. **jq-based JSON construction** - The `call-holmes` step uses `jq -n --arg` to safely build the API request, preventing JSON injection from parameter values.
3. **`continueOn.failed: true` on GitLab step** - Ensures Mattermost notification fires even if GitLab issue creation fails.
4. **Instructions via heredoc file** - Remediation instructions written to a file first, then read into a variable, avoiding shell/JSON escaping issues.
5. **`kubectl edit` explicitly banned** - Holmes MCP instructions prohibit `kubectl edit` (interactive), enforcing `patch`, `set image`, `set resources` instead.

## Files

| File | Purpose |
|------|---------|
| `local-llm-analysis-only.yaml` | Analysis-only WorkflowTemplate (direct LLM) |
| `holmes-remediation.yaml` | Holmes remediation WorkflowTemplate |
| `helm-values-proxmox.yaml` | Holmes Helm values for proxmox-k8s |
| `local-llm-investigation-gitlab.yaml` | Original v2 (superseded) |
| `holmes-gitlab-workflow-v2.yaml` | Original Holmes variant (superseded) |
| `run-investigation.yaml` | Example Workflow submission |
| `INTEGRATION-README.md` | This file |

## Known Limitations

- **Mattermost webhook URL** is hardcoded as a default parameter (should be moved to a K8s Secret)
- **AKS-MCP ClusterRole** has broad permissions including Secrets access (consider restricting for production)
- **Storage class** is hardcoded to `longhorn` (proxmox-k8s specific)
- **GitLab project ID** is hardcoded as a default parameter
