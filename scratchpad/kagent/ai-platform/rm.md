# AI Platform PoC — Deployment Guide

**KubeAI + LiteLLM + kgateway + kagent on Kubernetes**

| | |
|---|---|
| **Version** | 1.0 — PoC |
| **Date** | February 2026 |
| **Author** | Dave — Lead DevSecOps / Cloud Architect |
| **Target** | Homelab Kubernetes Cluster |

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Deployment Order](#3-deployment-order)
4. [Step 1: Deploy KubeAI (Inference Backend)](#4-step-1-deploy-kubeai-inference-backend)
5. [Step 2: Deploy LiteLLM Proxy (AI Gateway)](#5-step-2-deploy-litellm-proxy-ai-gateway)
6. [Step 3: Deploy kgateway + agentgateway (Ingress + MCP Routing)](#6-step-3-deploy-kgateway--agentgateway-ingress--mcp-routing)
7. [Step 4: Deploy kagent (Agent Runtime)](#7-step-4-deploy-kagent-agent-runtime)
8. [Full Stack Smoke Test](#8-full-stack-smoke-test)
9. [Namespace and Service Map](#9-namespace-and-service-map)
10. [Troubleshooting](#10-troubleshooting)
11. [Next Steps After PoC](#11-next-steps-after-poc)
12. [References](#12-references)

---

## 1. Overview

This guide deploys a complete AI-as-a-Service stack on a homelab Kubernetes cluster. The stack provides self-hosted LLM inference, an AI gateway for routing and cost tracking, an agent gateway for MCP server connectivity, and a Kubernetes-native AI agent framework.

### 1.1 Architecture

| Layer | Component | Role |
|-------|-----------|------|
| Inference | KubeAI + vLLM | Model operator managing vLLM pods, scale-from-zero, prefix-aware load balancing, OpenAI-compatible API |
| AI Gateway | LiteLLM Proxy | Model routing, API key management, token/spend tracking, rate limiting, fallbacks across providers |
| Agent Gateway | kgateway + agentgateway | K8s Gateway API ingress, MCP server routing, A2A protocol support, traffic policies |
| Agent Runtime | kagent | Kubernetes-native AI agents as CRDs, built-in MCP tools for K8s/Helm/Argo/Prometheus/Istio, web UI and CLI |

### 1.2 Traffic Flow

```
Client/Agent Request
       │
       ▼
kgateway (Gateway API ingress, TLS, L7 routing, TrafficPolicy)
       │
       ├──▶ /v1/chat/*  ──▶ LiteLLM Proxy ──▶ KubeAI (vLLM pods)
       │                     (token tracking,    (model operator,
       │                      API keys,           autoscaling,
       │                      rate limits)         GPU scheduling)
       │
       ├──▶ /mcp/*     ──▶ agentgateway ──▶ MCP Server pods
       │                    (tool routing,     (Streamable HTTP)
       │                     aggregation)
       │
       └──▶ /kagent/*  ──▶ kagent UI + Engine
                            (agent CRDs,
                             MCP tools)
```

### 1.3 What You Get

- Self-hosted LLM inference with automatic scaling and KV-cache-aware load balancing
- OpenAI-compatible API endpoint fronted by LiteLLM for multi-model routing
- Kubernetes Gateway API based ingress replacing traditional ingress controllers
- MCP server routing with protocol-aware gateway for tool/function providers
- AI agents running as Kubernetes CRDs with built-in tools for cluster operations
- Web UI for agent management, plus CLI and REPL for direct interaction

---

## 2. Prerequisites

### 2.1 Cluster Requirements

| Requirement | Details |
|-------------|---------|
| Kubernetes | v1.28+ (K3s, kubeadm, or managed). K3s recommended for homelab. |
| GPU (optional for PoC) | NVIDIA GPU with drivers + nvidia-device-plugin. For CPU-only PoC, use Ollama engine with smaller models. |
| Storage | 50GB+ available. PVC-capable StorageClass (local-path for K3s works fine). |
| Memory | 16GB+ RAM recommended. 7B models need ~8GB VRAM (GPU) or ~8GB RAM (CPU/Ollama). |
| Network | Outbound internet for pulling images and model weights from HuggingFace. |

### 2.2 CLI Tools Required

| Tool | Install | Purpose |
|------|---------|---------|
| kubectl | `curl -LO https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl` | Kubernetes CLI |
| helm | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` | Package manager |
| kagent CLI | See https://kagent.dev/docs for latest binary | Agent management |

### 2.3 API Keys

For the PoC you need at least one LLM provider API key. kagent uses this to power agents, and LiteLLM can route to it as an external provider alongside your self-hosted models.

| Provider | Get Key From | Env Var |
|----------|-------------|---------|
| OpenAI | platform.openai.com | `OPENAI_API_KEY` |
| Anthropic | console.anthropic.com | `ANTHROPIC_API_KEY` |
| HuggingFace | huggingface.co/settings/tokens (for gated models) | `HF_TOKEN` |

> **Note:** For a fully self-hosted PoC with no external API calls, you can skip cloud provider keys and use only KubeAI-hosted models. kagent can be pointed at KubeAI via LiteLLM using a custom ModelConfig.

---

## 3. Deployment Order

Deploy components in this order. Each layer builds on the previous:

| Step | Component | Why This Order | Namespace |
|------|-----------|---------------|-----------|
| 1 | KubeAI | Inference backend must exist before gateway can route to it | `kubeai` |
| 2 | LiteLLM Proxy | AI gateway needs a backend to proxy to | `litellm` |
| 3 | kgateway + agentgateway | Ingress layer routes external traffic to LiteLLM and MCP servers | `kgateway-system` |
| 4 | kagent | Agent runtime consumes all lower layers | `kagent` |

---

## 4. Step 1: Deploy KubeAI (Inference Backend)

KubeAI is a Kubernetes operator that manages vLLM and Ollama servers via a Model CRD. It provides an OpenAI-compatible API, scale-from-zero, prefix-aware load balancing, and a pre-configured model catalogue.

### 4.1 Install KubeAI

```bash
# Add the KubeAI Helm repo
helm repo add kubeai https://www.kubeai.org
helm repo update

# Install KubeAI operator
helm install kubeai kubeai/kubeai \
  --namespace kubeai \
  --create-namespace \
  --wait --timeout 10m
```

### 4.2 Deploy Models

Create a values file for your models. This example includes both a GPU model (if available) and a CPU-only model for testing:

```yaml
# kubeai-models.yaml
catalog:
  # ── CPU model (works on any cluster, good for PoC) ──
  deepseek-r1-1.5b-cpu:
    enabled: true
    features: [TextGeneration]
    url: 'ollama://deepseek-r1:1.5b'
    engine: OLlama
    minReplicas: 1        # Always running
    resourceProfile: 'cpu:1'

  # ── GPU model (requires NVIDIA GPU + device plugin) ──
  # Uncomment if you have a GPU available:
  # llama-3.1-8b-instruct:
  #   enabled: true
  #   features: [TextGeneration]
  #   url: hf://neuralmagic/Meta-Llama-3.1-8B-Instruct-FP8
  #   engine: VLLM
  #   args:
  #     - --max-model-len=16384
  #     - --gpu-memory-utilization=0.9
  #     - --disable-log-requests
  #   resourceProfile: nvidia-gpu-l4:1
  #   minReplicas: 0       # Scale from zero

  # ── Embeddings model (for RAG use cases) ──
  nomic-embed-text-cpu:
    enabled: true
    features: [TextEmbedding]
    url: 'ollama://nomic-embed-text'
    engine: OLlama
    minReplicas: 0
    resourceProfile: 'cpu:1'
```

```bash
# Install models
helm install kubeai-models kubeai/models \
  -f kubeai-models.yaml \
  --namespace kubeai
```

### 4.3 Verify

```bash
# Check models are registered
kubectl get models -n kubeai

# Watch pods spin up (deepseek should start immediately)
kubectl get pods -n kubeai -w

# Test the OpenAI-compatible API
kubectl port-forward svc/kubeai -n kubeai 8000:80 &

curl http://localhost:8000/openai/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-r1-1.5b-cpu",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

> ⚠️ **If using gated HuggingFace models**, create a secret first: `kubectl create secret generic hf-token --from-literal=token=$HF_TOKEN -n kubeai`

> **Note:** KubeAI exposes its API at `http://kubeai.kubeai.svc.cluster.local/openai/v1` inside the cluster. LiteLLM will use this as a backend.

---

## 5. Step 2: Deploy LiteLLM Proxy (AI Gateway)

LiteLLM sits in front of KubeAI (and optionally external providers like OpenAI/Anthropic) providing a unified API with token tracking, API key management, rate limiting, and spend controls.

### 5.1 Create Namespace and Secrets

```bash
kubectl create namespace litellm

# Create secret for API keys (add whichever you need)
kubectl create secret generic litellm-api-keys \
  --namespace litellm \
  --from-literal=OPENAI_API_KEY=${OPENAI_API_KEY:-not-set} \
  --from-literal=ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-not-set}
```

### 5.2 Create LiteLLM Config

This is the core configuration. It tells LiteLLM where to route model requests:

```yaml
# litellm-values.yaml
replicaCount: 1

masterkey: "<your-litellm-master-key>"    # Change this!

environmentSecrets:
  - litellm-api-keys

proxy_config:
  model_list:
    # ── Self-hosted models via KubeAI ──
    - model_name: deepseek-r1
      litellm_params:
        model: openai/deepseek-r1-1.5b-cpu
        api_base: http://kubeai.kubeai.svc.cluster.local/openai/v1
        api_key: ignored-by-kubeai

    # ── External providers (optional) ──
    - model_name: gpt-4o
      litellm_params:
        model: openai/gpt-4o
        api_key: os.environ/OPENAI_API_KEY

    - model_name: claude-sonnet
      litellm_params:
        model: anthropic/claude-sonnet-4-20250514
        api_key: os.environ/ANTHROPIC_API_KEY

  litellm_settings:
    drop_params: true
    set_verbose: false

  general_settings:
    master_key: <your-litellm-master-key>
```

### 5.3 Install via Helm

```bash
# Clone the LiteLLM repo for the Helm chart
git clone https://github.com/BerriAI/litellm.git /tmp/litellm

# Install
helm install litellm /tmp/litellm/deploy/charts/litellm-helm \
  --namespace litellm \
  -f litellm-values.yaml \
  --wait --timeout 5m
```

> **Note:** The LiteLLM Helm chart is marked as BETA. An alternative community chart is available at artifacthub.io/packages/helm/unique/litellm if the upstream chart has issues.

### 5.4 Verify

```bash
# Check pod is running
kubectl get pods -n litellm

# Port-forward to test
kubectl port-forward svc/litellm-litellm-helm -n litellm 4000:4000 &

# List available models
curl http://localhost:4000/v1/models \
  -H 'Authorization: Bearer <your-litellm-master-key>'

# Test a completion (routes to KubeAI)
curl http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <your-litellm-master-key>' \
  -d '{
    "model": "deepseek-r1",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}]
  }'
```

> **Note:** LiteLLM is now available at `http://litellm-litellm-helm.litellm.svc.cluster.local:4000` inside the cluster.

---

## 6. Step 3: Deploy kgateway + agentgateway (Ingress + MCP Routing)

kgateway is a CNCF implementation of the Kubernetes Gateway API built on Envoy. The agentgateway extension adds MCP protocol-aware routing for AI tool servers and A2A (agent-to-agent) communication.

### 6.1 Install Gateway API CRDs

```bash
# Install Kubernetes Gateway API CRDs (v1.4.0)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### 6.2 Install kgateway with agentgateway

```bash
# Install kgateway CRDs
helm install kgateway-crds \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version v2.2.0-main \
  --namespace kgateway-system \
  --create-namespace

# Install kgateway control plane (includes agentgateway)
helm install kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version v2.2.0-main \
  --namespace kgateway-system \
  --set controller.image.pullPolicy=Always
```

### 6.3 Install agentgateway (dedicated chart)

```bash
# Install agentgateway CRDs
helm install agentgateway-crds \
  oci://ghcr.io/kgateway-dev/charts/agentgateway-crds \
  --version v2.2.0-main \
  --namespace agentgateway-system \
  --create-namespace

# Install agentgateway
helm install agentgateway \
  oci://ghcr.io/kgateway-dev/charts/agentgateway \
  --version v2.2.0-main \
  --namespace agentgateway-system \
  --set controller.image.pullPolicy=Always
```

### 6.4 Create Gateway Resources

Create an HTTP Gateway for standard ingress traffic and an agentgateway Gateway for MCP/A2A traffic:

```yaml
# gateway.yaml
---
# Standard HTTP Gateway (kgateway / Envoy)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-platform-gw
  namespace: kgateway-system
spec:
  gatewayClassName: kgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 8080
      allowedRoutes:
        namespaces:
          from: All
---
# Agent Gateway (MCP + A2A routing)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agent-gw
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 8081
      allowedRoutes:
        namespaces:
          from: All
```

```bash
kubectl apply -f gateway.yaml
```

### 6.5 Create HTTPRoute for LiteLLM

Route traffic from the kgateway to LiteLLM:

```yaml
# litellm-route.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: litellm-route
  namespace: litellm
spec:
  parentRefs:
    - name: ai-platform-gw
      namespace: kgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
      backendRefs:
        - name: litellm-litellm-helm
          port: 4000
```

```bash
kubectl apply -f litellm-route.yaml
```

### 6.6 Verify

```bash
# Check gateways are accepted
kubectl get gateways -A

# Check gateway classes
kubectl get gatewayclass

# Check kgateway pods
kubectl get pods -n kgateway-system

# Check agentgateway pods
kubectl get pods -n agentgateway-system

# Check routes
kubectl get httproutes -A
```

---

## 7. Step 4: Deploy kagent (Agent Runtime)

kagent is a Kubernetes-native framework for building AI agents. Agents, tools, and LLM configs are all managed as CRDs. It ships with pre-built agents for Kubernetes, Helm, Istio, Argo, and Prometheus operations.

### 7.1 Install kagent CRDs

```bash
helm install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent \
  --create-namespace
```

### 7.2 Install kagent

Choose your provider. For a fully self-hosted PoC using KubeAI via LiteLLM, use the custom model config. For cloud providers, set the API key directly:

```bash
# Option A: Using an external provider (e.g. Anthropic)
helm install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --set providers.default=anthropic \
  --set providers.anthropic.apiKey=$ANTHROPIC_API_KEY

# Option B: Using OpenAI
helm install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --set providers.openai.apiKey=$OPENAI_API_KEY

# Option C: Point at LiteLLM (routes to KubeAI)
# Install with defaults first, then apply custom ModelConfig
helm install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --set providers.openai.apiKey=<your-litellm-master-key>
```

### 7.3 Custom ModelConfig for LiteLLM/KubeAI

If you chose Option C, create a ModelConfig that points kagent at LiteLLM (which routes to KubeAI):

```yaml
# kagent-litellm-modelconfig.yaml
apiVersion: kagent.dev/v1alpha1
kind: ModelConfig
metadata:
  name: litellm-deepseek
  namespace: kagent
spec:
  model: deepseek-r1
  apiType: OpenAI
  baseUrl: http://litellm-litellm-helm.litellm.svc.cluster.local:4000/v1
  apiKeySecretRef:
    name: litellm-key
    key: api-key
```

```bash
# Create the API key secret
kubectl create secret generic litellm-key \
  --namespace kagent \
  --from-literal=api-key=<your-litellm-master-key>

# Apply the ModelConfig
kubectl apply -f kagent-litellm-modelconfig.yaml
```

### 7.4 Access kagent UI

```bash
# Port-forward the kagent UI
kubectl port-forward svc/kagent-ui -n kagent 8080:8080

# Open browser to http://localhost:8080
```

The UI presents pre-configured agents including Helm Agent, Kubernetes Agent, Istio Agent, and an Observability Agent. Each comes with relevant MCP tool servers pre-wired.

### 7.5 Test via CLI

```bash
# List available agents
kagent get agents

# Invoke an agent
kagent invoke \
  --agent helm-agent \
  -t "What Helm charts are installed in my cluster?"

# Interactive REPL mode
kagent invoke --agent k8s-agent
```

### 7.6 Verify Full Stack Integration

```bash
# Check all kagent resources
kubectl get agents,modelconfigs,toolservers -n kagent

# Verify agent engine pods
kubectl get pods -n kagent

# Expected pods:
#   kagent-controller-xxx    (CRD controller)
#   kagent-engine-xxx        (agent runtime / ADK)
#   kagent-ui-xxx            (web UI)
```

---

## 8. Full Stack Smoke Test

After deploying all components, run through this checklist to verify end-to-end functionality:

| # | Test | Command | Expected |
|---|------|---------|----------|
| 1 | KubeAI model pods running | `kubectl get pods -n kubeai` | At least 1 model pod Running |
| 2 | KubeAI direct inference | `curl kubeai:80/openai/v1/models` | Model list returned |
| 3 | LiteLLM proxy healthy | `curl litellm:4000/health` | 200 OK |
| 4 | LiteLLM routes to KubeAI | `curl litellm:4000/v1/chat/completions` | Completion response |
| 5 | kgateway Gateway accepted | `kubectl get gateways -A` | STATUS: Accepted |
| 6 | HTTPRoute attached | `kubectl get httproutes -A` | Route shows parent |
| 7 | kagent agents listed | `kubectl get agents -n kagent` | Pre-built agents listed |
| 8 | kagent agent invocation | `kagent invoke --agent helm-agent` | Agent responds with Helm data |

---

## 9. Namespace and Service Map

Quick reference for all deployed services and their in-cluster DNS names:

| Namespace | Service | In-Cluster URL | Port |
|-----------|---------|---------------|------|
| `kubeai` | kubeai | `kubeai.kubeai.svc:80` | 80 |
| `litellm` | litellm-litellm-helm | `litellm-litellm-helm.litellm.svc:4000` | 4000 |
| `kgateway-system` | kgateway | `kgateway.kgateway-system.svc` | 9977 |
| `agentgateway-system` | agentgateway | `agentgateway.agentgateway-system.svc` | 8081 |
| `kagent` | kagent-ui | `kagent-ui.kagent.svc:8080` | 8080 |
| `kagent` | kagent-controller | `kagent-controller.kagent.svc` | 8443 |

---

## 10. Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| KubeAI model pod stuck Pending | Insufficient GPU/CPU resources or no matching resource profile | Check `kubectl describe pod`. Use `cpu:1` profile for CPU-only. Check nvidia device plugin is installed for GPU. |
| LiteLLM returns 401 | Wrong master key in Authorization header | Check masterkey value. Retrieve from secret: `kubectl get secret -n litellm -o jsonpath`. |
| LiteLLM returns model not found | KubeAI model name mismatch in config | Run `kubectl get models -n kubeai` and match exact name in litellm config `model_list`. |
| kgateway Gateway not Accepted | GatewayClass not found or CRDs missing | Ensure Gateway API CRDs v1.4.0 installed. Check `kubectl get gatewayclass`. |
| kagent agent returns errors | ModelConfig pointing to wrong endpoint or bad API key | Check ModelConfig `baseUrl` matches LiteLLM service. Verify key secret exists. |
| Pods pulling images slowly | Large container images (vLLM ~5GB, model weights 4-16GB) | Expected on first pull. Consider pre-pulling images or using a local registry. |
| OOM kills on model pods | Model too large for available RAM/VRAM | Use smaller models (1.5B-3B for CPU). Set `--gpu-memory-utilization=0.85` for GPU. Check resource limits. |

---

## 11. Next Steps After PoC

Once the PoC is validated, consider the following for production readiness:

- Add TLS termination on kgateway using cert-manager and Let's Encrypt or self-signed certs.
- Deploy PostgreSQL for LiteLLM to enable persistent API key management and spend tracking across restarts.
- Add Redis for LiteLLM request buffering and caching under high load.
- Create custom kagent Agents with domain-specific system prompts and tool permissions tailored to your teams.
- Deploy custom MCP servers behind agentgateway for internal tools (JIRA, ServiceNow, internal APIs).
- Implement Kyverno policies for multi-tenant isolation, rate limit enforcement, and labelling standards.
- Set up Prometheus + Grafana dashboards consuming vLLM metrics (queue depth, TTFT, GPU cache utilisation).
- Configure KEDA scalers for KubeAI model pods based on request queue depth.
- Build GitOps onboarding via Argo Workflows with an AIServiceConsumer CRD pattern.
- Evaluate Solo.io Enterprise for production-grade kagent and agentgateway support.

---

## 12. References

| Component | Documentation |
|-----------|--------------|
| KubeAI | https://www.kubeai.org — https://github.com/substratusai/kubeai |
| LiteLLM | https://docs.litellm.ai — https://github.com/BerriAI/litellm |
| kgateway | https://kgateway.dev — https://github.com/kgateway-dev/kgateway |
| agentgateway | https://kgateway.dev/docs/agentgateway |
| kagent | https://kagent.dev — https://github.com/kagent-dev/kagent |
| K8s Gateway API | https://gateway-api.sigs.k8s.io |
| vLLM | https://docs.vllm.ai |