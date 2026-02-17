# Lift and Shift to Work Environment

## What to Deploy

You need **two workflow templates** (choose one or both):

| Template | File | What it does |
|----------|------|-------------|
| `local-llm-analysis` | `local-llm-analysis-only.yaml` | Fast analysis only — calls your vLLM directly, creates GitLab issue + notification. ~67s. No tools, no Holmes needed. |
| `holmes-remediation` | `holmes-remediation.yaml` | Full investigation + auto-fix — uses Holmes as the AI agent with AKS-MCP `call_kubectl` for diagnosis AND remediation. ~2min. Requires Holmes + AKS-MCP deployed. |

**Start with `local-llm-analysis-only.yaml`** — it only needs your vLLM endpoint and GitLab token. No Holmes or MCP dependencies.

## Values to Change

### local-llm-analysis-only.yaml

```yaml
# Line 42 — storage class (remove if cluster has a default)
storageClassName: longhorn  →  storageClassName: <your-storage-class>

# Line 55 — cluster name
value: "proxmox-k8s"  →  value: "<your-cluster-name>"

# Line 66 — GitLab project ID
value: "YOUR_PROJECT_ID"  →  value: "<your-project-id>"

# Line 71 — Mattermost webhook (configure via Secret or parameter)
value: ""  →  value: "http://your-mattermost/hooks/xxx"

# Line 73 — LLM endpoint (your vLLM URL)
value: "http://kubeai.kubeai.svc.cluster.local/openai/v1"  →  value: "http://<your-vllm-svc>.<namespace>.svc.cluster.local/v1"

# Line 75 — model name (must match your vLLM model ID)
value: "qwen3-14b"  →  value: "<your-model-name>"
```

### holmes-remediation.yaml

```yaml
# Line 38 — storage class
storageClassName: longhorn  →  storageClassName: <your-storage-class>

# Line 51 — cluster name
value: "proxmox-k8s"  →  value: "<your-cluster-name>"

# Line 65 — GitLab project ID
value: "YOUR_PROJECT_ID"  →  value: "<your-project-id>"

# Line 69 — Mattermost webhook (configure via Secret or parameter)
value: ""  →  value: "http://your-mattermost/hooks/xxx"

# Line 71 — Holmes URL (your Holmes service endpoint)
value: "http://holmes-holmes.holmesgpt.svc.cluster.local:80"  →  value: "http://<holmes-svc>.<namespace>.svc.cluster.local:<port>"
```

### helm-values-proxmox.yaml (if deploying Holmes)

```yaml
# Line 21 — your vLLM endpoint
value: "http://kubeai.kubeai.svc.cluster.local/openai/v1"  →  value: "http://<your-vllm-svc>/v1"

# Line 19 — model name (needs openai/ prefix for LiteLLM routing)
value: "openai/qwen3-14b"  →  value: "openai/<your-model-name>"

# Line 51 — AKS-MCP URL
url: http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp  →  url: http://<your-aks-mcp-svc>/mcp
```

## Prerequisites / Secrets

```bash
# 1. GitLab token (required for both templates)
kubectl create secret generic gitlab-token \
  --namespace argo \
  --from-literal=GITLAB_TOKEN='glpat-xxxxx'

# 2. Mattermost webhook (optional — templates skip notification if missing)
kubectl create secret generic mattermost-webhook \
  --namespace argo \
  --from-literal=url='https://your-mattermost/hooks/xxx'
```

## Deploy

```bash
# Analysis only (just needs vLLM + GitLab token)
kubectl apply -f local-llm-analysis-only.yaml

# Remediation (needs Holmes + AKS-MCP + GitLab token)
kubectl apply -f holmes-remediation.yaml
```

## Test Run

```bash
# Quick analysis
argo submit -n argo --from=workflowtemplate/local-llm-analysis \
  -p query="Investigate pod issue" \
  -p event_type="CrashLoopBackOff" \
  -p cluster="<your-cluster>" \
  -p namespace="<target-ns>" \
  -p resource_kind="Pod" \
  -p resource_name="<pod-name>" \
  -p severity="high" \
  -p 'error_message=Back-off restarting failed container' \
  --watch

# Full remediation
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Fix CrashLoopBackOff" \
  -p namespace="<target-ns>" \
  -p resource_name="<pod-name>" \
  -p remediate="true" \
  --watch
```

## What You Already Have vs What's New

| Component | Status | Notes |
|-----------|--------|-------|
| Argo Workflows | Already running | No changes needed |
| vLLM | Already running | Just need the service URL + model name |
| GitLab | Already have | Just need project ID + API token |
| Holmes | Deploy if needed | Only required for `holmes-remediation` template |
| AKS-MCP | Deploy if needed | Only required for `holmes-remediation` template |
| Mattermost/Slack | Optional | Templates gracefully skip if no webhook configured |

## If You Only Want Analysis (No Holmes)

Deploy just `local-llm-analysis-only.yaml`. It calls your vLLM directly via the OpenAI-compatible `/chat/completions` endpoint. No Holmes, no MCP, no extra infra.

The workflow pipeline: **validate LLM reachable → call vLLM → create GitLab issue → notify Mattermost**

## Image Notes

All images used are public and should work in most environments:

| Image | Used For |
|-------|----------|
| `curlimages/curl:8.5.0` | Validation + Mattermost notification |
| `badouralix/curl-jq:alpine` | Holmes/LLM API calls (curl + jq) |
| `node:22-alpine` | GitLab issue creation (Node.js https) |

If your environment requires pulling from an internal registry, update the `image:` fields accordingly.
