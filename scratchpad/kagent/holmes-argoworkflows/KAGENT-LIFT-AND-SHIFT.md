# KAgent Lift-and-Shift — Homelab to AKS

> Deploy the KAgent incident triage platform on shared AKS clusters.
> Validated on homelab (KAgent 5-0 vs Holmes across 5 scenarios).

---

## What We're Deploying

```
┌─────────────────────────────────────────────────────────────────┐
│                    AKS Management Cluster                        │
│                                                                  │
│  ┌──────────┐   ┌──────────┐   ┌──────────────┐                │
│  │  KubeAI   │   │ LiteLLM  │   │   KAgent     │                │
│  │ (or Azure │──▶│ (proxy)  │◀──│  controller  │                │
│  │  OpenAI)  │   │          │   │  + tools     │                │
│  └──────────┘   └──────────┘   │  + agents    │                │
│                                 └──────┬───────┘                │
│                                        │ A2A                     │
│  ┌──────────┐                  ┌───────┴────────┐               │
│  │ AKS-MCP  │◀─────────────── │  SRE Agents    │               │
│  │ (kubectl  │  MCP tools      │  triage (RO)   │               │
│  │  helm, az)│                 │  remediation   │               │
│  └──────────┘                  └───────┬────────┘               │
│                                        │                         │
│  ┌──────────┐   ┌──────────┐   ┌──────┴───────┐                │
│  │  Argo    │──▶│ Argo     │──▶│ Workflow:     │                │
│  │  Events  │   │ Workflows│   │ kagent-sre    │                │
│  │ (sensor) │   │          │   │ -workflow     │                │
│  └──────────┘   └──────────┘   └──────────────┘                │
│                                        │                         │
│                                ┌───────┴────────┐               │
│                                │  Reporting      │               │
│                                │ GitLab · Slack  │               │
│                                │ · PagerDuty     │               │
│                                └────────────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

### Routing Architecture (future: BYOA)

```
AlertManager / K8s Events
         │
    Argo Events Sensor
    (filters: namespace, event_type, severity, labels)
         │
    ┌────┴─────────────────────────────┐
    │       Route by domain/team       │
    ├──────────────┬───────────────────┤
    │              │                   │
    ▼              ▼                   ▼
 Platform       Platform           App Team
 Agents         Agents             BYOA Agents

 cert-manager   external-dns       team-X-agent
 ingress        node-health        (team's own
 storage        gitops              runbooks)
```

Each agent is a K8s CRD — versioned in Git, deployed via Flux/ArgoCD, scoped tools per agent. Teams can bring their own agent with their own runbooks. See `BYOA-AGENT-PLATFORM-PROPOSAL.md` for the full vision.

---

## 1. Container Images to Pull

Pull these to your ACR/internal registry before deployment.

### KAgent Stack

| Image | Tag | Size | Purpose |
|-------|-----|------|---------|
| `ghcr.io/kagent-dev/kagent/controller` | `0.7.13` | ~50MB | KAgent controller |
| `ghcr.io/kagent-dev/kagent/app` | `0.7.13` | ~80MB | Agent runtime (1 pod per agent) |
| `ghcr.io/kagent-dev/kagent/tools` | `0.0.13` | ~100MB | MCP tool server (k8s + helm tools) |
| `ghcr.io/kagent-dev/kagent/ui` | `0.7.13` | ~30MB | Web UI (optional) |
| `ghcr.io/kagent-dev/kmcp/controller` | `0.2.5` | ~40MB | KMCP controller (manages MCP servers) |

### AKS-MCP

| Image | Tag | Purpose |
|-------|-----|---------|
| `ghcr.io/azure/aks-mcp` | `v0.0.12` | kubectl/helm/az CLI via MCP protocol |

### LiteLLM (if using self-hosted model proxy)

| Image | Tag | Purpose |
|-------|-----|---------|
| `ghcr.io/berriai/litellm` | `main-latest` | OpenAI-compatible proxy to model backends |

### KubeAI (if using self-hosted models — skip if using Azure OpenAI)

| Image | Tag | Purpose |
|-------|-----|---------|
| `ghcr.io/substratusai/kubeai` | `v0.23.1` | Model orchestrator |
| Ollama model images | varies | Qwen 14B / 70B model weights |

### Argo Workflow Step Images

| Image | Tag | Purpose |
|-------|-----|---------|
| `curlimages/curl` | `8.5.0` | Validation + Mattermost notification steps |
| `badouralix/curl-jq` | `alpine` | KAgent A2A call step (needs curl + jq) |
| `node` | `22-alpine` | GitLab issue creation step |
| `alpine/socat` | `latest` | UI port forwarding sidecar (optional) |

### Pull Commands

```bash
# Set your ACR name
ACR="youracr.azurecr.io"

# KAgent stack
KAGENT_IMAGES=(
  "ghcr.io/kagent-dev/kagent/controller:0.7.13"
  "ghcr.io/kagent-dev/kagent/app:0.7.13"
  "ghcr.io/kagent-dev/kagent/tools:0.0.13"
  "ghcr.io/kagent-dev/kagent/ui:0.7.13"
  "ghcr.io/kagent-dev/kmcp/controller:0.2.5"
)

# AKS-MCP
AKS_MCP_IMAGES=(
  "ghcr.io/azure/aks-mcp:v0.0.12"
)

# LiteLLM (skip if using Azure OpenAI directly)
LITELLM_IMAGES=(
  "ghcr.io/berriai/litellm:main-latest"
)

# Workflow step images
WORKFLOW_IMAGES=(
  "curlimages/curl:8.5.0"
  "badouralix/curl-jq:alpine"
  "node:22-alpine"
)

# Pull and push all images
for img in "${KAGENT_IMAGES[@]}" "${AKS_MCP_IMAGES[@]}" "${LITELLM_IMAGES[@]}" "${WORKFLOW_IMAGES[@]}"; do
  # Extract the path after the registry
  target="${ACR}/$(echo $img | sed 's|^[^/]*/||')"
  echo "Pulling $img → $target"
  docker pull "$img"
  docker tag "$img" "$target"
  docker push "$target"
done
```

---

## 2. Helm Charts to Cache

```bash
# KAgent charts (from source — no public Helm repo yet)
git clone https://github.com/kagent-dev/kagent.git /tmp/kagent
# Charts are in:
#   /tmp/kagent/helm/kagent-crds/
#   /tmp/kagent/helm/kagent/

# AKS-MCP chart
git clone https://github.com/Azure/aks-mcp.git /tmp/aks-mcp
# Chart is in: /tmp/aks-mcp/chart/

# LiteLLM chart (skip if using Azure OpenAI)
git clone https://github.com/BerriAI/litellm.git /tmp/litellm
# Chart is in: /tmp/litellm/deploy/charts/litellm-helm/
```

---

## 3. Deployment Order

### Step 1: Model Backend

**Option A: Hosted vLLM + Qwen 3 (current work setup)**

Connect KAgent directly to vLLM — it speaks the OpenAI protocol natively, no LiteLLM proxy needed.

The JWT token is managed by an existing CronJob that writes to a Secret:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: vllm-qwen3
  namespace: kagent
spec:
  provider: OpenAI                         # vLLM is OpenAI-compatible
  model: qwen3                             # model name as registered in vLLM
  apiKeySecret: vllm-jwt-token             # Secret created/refreshed by CronJob
  apiKeySecretKey: token                   # key within the Secret
  openAI:
    baseUrl: http://vllm.YOUR-NAMESPACE.svc:8000/v1   # your vLLM service endpoint
```

```bash
# Verify the JWT secret exists (created by your existing CronJob)
kubectl get secret vllm-jwt-token -n kagent

# If it's in a different namespace, copy it:
kubectl get secret vllm-jwt-token -n SOURCE_NS -o yaml \
  | sed 's/namespace: SOURCE_NS/namespace: kagent/' \
  | kubectl apply -f -

# Quick test — verify vLLM responds:
kubectl run test-vllm --rm -it --image=curlimages/curl --restart=Never -n kagent -- \
  curl -s http://vllm.YOUR-NAMESPACE.svc:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(kubectl get secret vllm-jwt-token -n kagent -o jsonpath='{.data.token}' | base64 -d)" \
  -d '{"model":"qwen3","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
```

**Option B: Azure OpenAI (alternative)**

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: azure-openai-gpt4o
  namespace: kagent
spec:
  provider: AzureOpenAI
  model: gpt-4o
  apiKeySecret: azure-openai-key
  apiKeySecretKey: api-key
  azureOpenAI:
    endpoint: https://YOUR-RESOURCE.openai.azure.com
    apiVersion: "2024-10-21"
    deployment: gpt-4o
```

**Option C: LiteLLM proxy (only if you need multi-model routing or cost tracking)**

Only needed if you want to route some agents to vLLM and others to Azure OpenAI, or need per-team rate limiting. Otherwise skip — connect directly to vLLM.

### Step 2: Deploy KAgent CRDs

```bash
# From cloned kagent repo
cd /tmp/kagent

# Generate Chart.yaml
VERSION=v0.7.13 KMCP_VERSION=0.2.5 envsubst < helm/kagent-crds/Chart-template.yaml > helm/kagent-crds/Chart.yaml

# Install CRDs
helm install kagent-crds helm/kagent-crds \
  -n kagent --create-namespace
```

### Step 3: Deploy KAgent Controller + Tools

Create a values file for AKS:

```yaml
# kagent-values-aks.yaml
registry: youracr.azurecr.io   # your ACR
tag: "0.7.13"

providers:
  default: openAI
  openAI:
    provider: OpenAI
    model: "qwen3"                         # model name in your vLLM deployment
    apiKeySecretRef: vllm-jwt-token        # JWT secret refreshed by CronJob
    apiKeySecretKey: token
    baseUrl: "http://vllm.YOUR-NAMESPACE.svc:8000/v1"

tools:
  grafana-mcp:
    enabled: false
  querydoc:
    enabled: false

agents:
  k8s-agent:
    enabled: true
  helm-agent:
    enabled: true
  kgateway-agent:
    enabled: false                         # enable if using kgateway
  istio-agent:
    enabled: false
  promql-agent:
    enabled: false
  observability-agent:
    enabled: false
  argo-rollouts-agent:
    enabled: false
  cilium-policy-agent:
    enabled: false
  cilium-manager-agent:
    enabled: false
  cilium-debug-agent:
    enabled: false

database:
  type: sqlite
```

```bash
# Build dependencies
cd /tmp/kagent/helm/kagent
helm dependency build

# Install kagent
helm install kagent . \
  -n kagent \
  -f /path/to/kagent-values-aks.yaml \
  --set kmcp.image.tag=0.2.5 \
  --set tag=0.7.13

# Wait for controller
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=controller \
  -n kagent --timeout=120s
```

### Step 4: Create ModelConfig

**For vLLM + Qwen 3 (primary):**
```bash
# Verify the JWT secret exists (your CronJob should have created it)
kubectl get secret vllm-jwt-token -n kagent || echo "WARNING: JWT secret missing — check your CronJob"

kubectl apply -f - <<EOF
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: vllm-qwen3
  namespace: kagent
spec:
  provider: OpenAI
  model: qwen3
  apiKeySecret: vllm-jwt-token
  apiKeySecretKey: token
  openAI:
    baseUrl: http://vllm.YOUR-NAMESPACE.svc:8000/v1
EOF
```

**For Azure OpenAI (alternative):**
```bash
kubectl create secret generic azure-openai-key -n kagent \
  --from-literal=api-key="YOUR_KEY"

kubectl apply -f - <<EOF
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: azure-openai-gpt4o
  namespace: kagent
spec:
  provider: AzureOpenAI
  model: gpt-4o
  apiKeySecret: azure-openai-key
  apiKeySecretKey: api-key
  azureOpenAI:
    endpoint: https://YOUR-RESOURCE.openai.azure.com
    apiVersion: "2024-10-21"
    deployment: gpt-4o
EOF
```

### Step 5: Deploy AKS-MCP

```bash
# Install AKS-MCP with admin access (or scoped access per your RBAC needs)
helm install aks-mcp /tmp/aks-mcp/chart \
  --namespace aks-mcp --create-namespace \
  -f aks-mcp-values.yaml \
  --set image.repository=youracr.azurecr.io/azure/aks-mcp \
  --set image.tag=v0.0.12

# Wait for pod
kubectl wait --for=condition=ready pod \
  -l app=aks-mcp -n aks-mcp --timeout=60s
```

Register AKS-MCP as a RemoteMCPServer in kagent:

```bash
kubectl apply -f - <<EOF
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-readonly
  namespace: kagent
spec:
  url: http://aks-mcp.aks-mcp.svc:8000/mcp
  transport: streamableHTTP
EOF
```

### Step 6: Deploy SRE Agents

Update the `modelConfig` field in both agent CRDs to match your ModelConfig name:

```bash
# Change modelConfig in both agent files:
# modelConfig: litellm-qwen-14b  →  modelConfig: vllm-qwen3

# For work deployment, also uncomment the AKS-MCP tool sections:
# - aks-mcp-readonly for triage agent
# - aks-mcp-readonly AND aks-mcp-readwrite for remediation agent
```

**Files to apply:**
```bash
# From ai-platform repo
kubectl apply -f kagent/sre-triage-agent.yaml
kubectl apply -f kagent/sre-remediation-agent.yaml

# Wait for agent pods
kubectl wait --for=condition=ready pod \
  -l kagent.dev/agent=sre-triage-agent \
  -n kagent --timeout=120s
kubectl wait --for=condition=ready pod \
  -l kagent.dev/agent=sre-remediation-agent \
  -n kagent --timeout=120s
```

### Step 7: Deploy Argo Workflow Template

```bash
# From argo-workflow repo
kubectl apply -f aks-mgmt-stack/holmes-argoworkflows/kagent-sre-workflow.yaml
```

Update the workflow parameter defaults for your environment:
- `cluster`: your AKS cluster name
- `kagent_controller_url`: `http://kagent-controller.kagent.svc.cluster.local:8083`
- `gitlab_project_id`: your GitLab project ID
- `gitlab_url`: your GitLab URL
- `mattermost_webhook_url`: your Slack/Teams webhook

Ensure secrets exist in the `argo` namespace:
```bash
kubectl create secret generic gitlab-token -n argo \
  --from-literal=GITLAB_TOKEN="YOUR_TOKEN"

kubectl create secret generic mattermost-webhook -n argo \
  --from-literal=url="YOUR_WEBHOOK_URL"
```

---

## 4. Validation

```bash
# 1. KAgent controller healthy
kubectl get pods -n kagent
# Expect: controller, tools, agent pods all Running

# 2. Agents registered
curl -s http://kagent-controller.kagent.svc:8083/api/agents | jq '.[].name'
# Expect: sre-triage-agent, sre-remediation-agent, k8s-agent, helm-agent

# 3. Quick triage test
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="List all namespaces in the cluster" \
  -p event_type="HealthCheck" \
  -p namespace="default" \
  -p resource_kind="Cluster" \
  -p resource_name="health" \
  -p severity="low" \
  -p remediate="false" \
  --watch

# 4. Check GitLab issue was created
# Should see a new issue with namespace list
```

---

## 5. Homelab vs AKS — Key Differences

| Component | Homelab | AKS (Work) |
|-----------|---------|-------------|
| **Model** | Qwen 14B on RTX 3060 via KubeAI | Qwen 3 on hosted vLLM (JWT auth) |
| **Model config** | `litellm-qwen-14b` (LiteLLM proxy) | `vllm-qwen3` (direct to vLLM, no proxy) |
| **Auth** | LiteLLM API key (static) | JWT token refreshed by CronJob |
| **Image registry** | ghcr.io direct | ACR (pull + push first) |
| **AKS-MCP** | kubectl + helm only | kubectl + helm + az CLI + detectors + advisor |
| **Storage** | local-path | Azure managed disk (default SC) |
| **Namespace typo fix** | Needed for Qwen 14B | May not be needed for GPT-4o (smarter model) — keep it anyway |
| **YAML example rule** | Added to system prompt | Keep it — improves output quality regardless of model |
| **Agent CRD changes** | Change `modelConfig` field | Change `modelConfig` + uncomment AKS-MCP tool sections |
| **Networking** | NodePort + NPM | Ingress controller / Azure Front Door |

---

## 6. Files to Copy to Work

### From `ai-platform` repo

```
kagent/
├── sre-triage-agent.yaml           # Triage agent CRD (update modelConfig + AKS-MCP)
├── sre-remediation-agent.yaml      # Remediation agent CRD (update modelConfig + AKS-MCP)
├── aks-mcp-remotemcpserver.yaml    # RemoteMCPServer CRD for AKS-MCP
config/kagent/
├── kagent-values.yaml              # Helm values (adapt for AKS → kagent-values-aks.yaml)
├── kagent-modelconfig.yaml         # ModelConfig CRD (replace with Azure OpenAI version)
├── kagent-modelconfig-14b.yaml     # ModelConfig CRD (replace with Azure OpenAI version)
```

### From `argo-workflow` repo

```
aks-mgmt-stack/holmes-argoworkflows/
├── kagent-sre-workflow.yaml        # Argo WorkflowTemplate (update params for your env)
```

### Secrets to Create

| Secret | Namespace | Keys | Source | Purpose |
|--------|-----------|------|--------|---------|
| `vllm-jwt-token` | `kagent` | `token` | CronJob (existing) | JWT token for vLLM auth — auto-refreshed |
| `gitlab-token` | `argo` | `GITLAB_TOKEN` | Manual | GitLab API token for issue creation |
| `mattermost-webhook` | `argo` | `url` | Manual | Slack/Teams webhook URL (optional) |
| `azure-openai-key` | `kagent` | `api-key` | Manual (if using Azure OpenAI) | Azure OpenAI API key |

---

## 7. Checklist

```
Pre-deployment:
  [ ] Images pulled to ACR
  [ ] Helm charts cached locally / in internal repo
  [ ] vLLM endpoint reachable (or Azure OpenAI provisioned)
  [ ] JWT token Secret exists in kagent namespace (check CronJob)
  [ ] GitLab project created for triage issues
  [ ] Slack/Teams webhook configured

Deployment:
  [ ] kagent-crds Helm release installed
  [ ] kagent Helm release installed (controller + tools + built-in agents)
  [ ] ModelConfig CRD applied (vllm-qwen3 or azure-openai-gpt4o)
  [ ] AKS-MCP deployed and registered as RemoteMCPServer
  [ ] sre-triage-agent CRD applied (verify pod Running)
  [ ] sre-remediation-agent CRD applied (verify pod Running)
  [ ] kagent-sre-workflow WorkflowTemplate applied
  [ ] Secrets verified (vllm-jwt-token from CronJob, gitlab-token, mattermost-webhook)

Validation:
  [ ] KAgent controller API responds (GET /api/agents)
  [ ] Both SRE agents listed in controller
  [ ] Test triage workflow succeeds (argo submit --watch)
  [ ] GitLab issue created with analysis output
  [ ] Notification received in Slack/Teams

Next steps:
  [ ] Connect Argo Events sensor for automated alert routing
  [ ] Deploy platform agents (cert-manager-agent, external-dns-agent)
  [ ] Onboard first app team with BYOA agent
  [ ] See BYOA-AGENT-PLATFORM-PROPOSAL.md for full roadmap
```

---

## 8. Multi-Cluster Access (Worker Clusters)

KAgent runs on the **mgmt cluster** but investigates issues on **worker clusters**. This requires:

1. **AKS-MCP with Workload Identity (UAMI)** — authenticates to Azure, fetches kubeconfigs
2. **Init container** on AKS-MCP — pre-fetches credentials for all worker clusters at startup
3. **Cluster registry ConfigMap** — maps cluster names to resource groups/subscriptions
4. **Agent prompt** — tells the LLM to use `call_kubectl --context <cluster>` for all operations
5. **CronJob** — refreshes credentials every 6 hours (Azure kubeconfigs expire)

The agent uses **AKS-MCP tools** for worker clusters and **kagent-tool-server** for mgmt cluster self-diagnostics.

See **[KAGENT-MULTI-CLUSTER.md](KAGENT-MULTI-CLUSTER.md)** for the full architecture, UAMI setup, deployment manifests, and validation checklist.

---

## Related Docs

| Document | Description |
|----------|-------------|
| `KAGENT-MULTI-CLUSTER.md` | Multi-cluster architecture — UAMI, AKS-MCP init container, credential refresh |
| `BYOA-AGENT-PLATFORM-PROPOSAL.md` | Full BYOA platform vision with routing, onboarding, scaling |
| `COMPARISON-TEST-SCENARIOS.md` | Holmes vs KAgent test results (KAgent 5-0) |
| `KAGENT-PROMPT-IMPROVEMENTS.md` | Namespace anchoring + YAML example prompt fixes |
| `ai-platform/RUNBOOK.md` | Homelab deployment runbook (full step-by-step) |
| `README.md` | Workflow template documentation |
