# AI Platform PoC - Deployment Runbook

## Architecture Overview

```
                           *.lab.danatlab.com (Wildcard DNS)
                                     |
                                     v
                        +------------------------+
                        |   Nginx Proxy Manager  |
                        |   192.168.6.6:81       |
                        |   Let's Encrypt SSL    |
                        |   *.lab.danatlab.com   |
                        +------------------------+
                                     |
                         NodePort 30988 (HTTP)
                                     |
                                     v
                        +------------------------+
                        |   kgateway (Envoy L7)  |
                        |   Host-based routing   |
                        +------------------------+
                           /        |        \
                          /         |         \
            ai.lab.       chat.lab.    litellm.lab.
            danatlab.com  danatlab.com danatlab.com
                |              |              |
                v              v              v
          +-----------+  +-----------+  +-----------+
          | kagent UI |  | Open      |  | LiteLLM   |
          | :8080     |  | WebUI     |  | :4000     |
          | (kagent)  |  | :80       |  | (litellm) |
          +-----------+  | (kubeai)  |  +-----------+
                |        +-----------+        |
                |                             |
                +----------+    +-------------+
                           |    |
                           v    v
                    +----------------+
                    |    KubeAI      |
                    |    :80         |
                    |    (kubeai)    |
                    +----------------+
                           |
                           v
                    +----------------+
                    | Qwen 2.5 14B   |
                    | Ollama engine  |
                    | RTX 3060 12GB  |
                    +----------------+
```

### Request Flow

```
User browser
  -> https://litellm.lab.danatlab.com/v1/chat/completions
  -> NPM (SSL termination, proxy to NodePort 30988)
  -> kgateway Envoy (host match: litellm.lab.danatlab.com)
  -> HTTPRoute -> LiteLLM service (litellm:4000)
  -> LiteLLM proxies to KubeAI (kubeai.kubeai.svc:80/openai/v1)
  -> KubeAI routes to Qwen 14B model pod (Ollama)
  -> Response flows back
```

### Agent Architecture

```
                    +-------------------+
                    |   kagent UI       |
                    | ai.lab.danatlab   |
                    +-------------------+
                            |
                    +-------------------+
                    | kagent controller |
                    | Sessions + A2A    |
                    +-------------------+
                       /    |    \
                      /     |     \
            +--------+ +--------+ +----------+
            | k8s    | | helm   | | kgateway |
            | agent  | | agent  | | agent    |
            +--------+ +--------+ +----------+
                 \        |         /
                  \       |        /
              +-------------------+
              | kagent-tools      |
              | (MCP tool server) |
              | k8s, helm, gw    |
              +-------------------+
                       |
                       v
              +-------------------+
              | LiteLLM           |
              | (LLM backend)     |
              | model: qwen2.5-14b|
              +-------------------+
                       |
                       v
              +-------------------+
              | KubeAI + Ollama   |
              | Qwen 2.5 14B     |
              | RTX 3060 (9.4GB) |
              +-------------------+
```

### Agent Capabilities

| Agent | Read Tools | Write Tools | Use Cases |
|-------|-----------|-------------|-----------|
| k8s-agent | get resources, describe, logs, events, YAML, exec | apply manifest, patch, create, delete, label, annotate | Pod troubleshooting, scaling, health checks |
| helm-agent | list releases, get release info | upgrade, uninstall, repo add/update, apply manifest | Chart upgrades, rollbacks, repo management |
| kgateway-agent | get resources, describe | apply manifest, patch | Gateway/route configuration |

## Infrastructure

### Cluster

| Node | IP | Role | Specs |
|------|----|------|-------|
| k8s-cp1 | 192.168.6.4 | Control plane | Proxmox VM |
| k8s-worker1 | 192.168.6.5 | Worker | Proxmox VM |
| k8s-worker2 | 192.168.6.6 | Worker + GPU | RTX 3060 12GB (ampere) |

- Kubernetes v1.31.14, Ubuntu 24.04, Calico CNI
- Proxmox hypervisor
- Longhorn storage (PVCs)
- NVIDIA device plugin for GPU scheduling

### Namespaces

| Namespace | Components | Pod Count |
|-----------|-----------|-----------|
| `kubeai` | KubeAI operator, Qwen 14B model pod, Open WebUI | 3 |
| `litellm` | LiteLLM proxy, PostgreSQL | 2 |
| `kgateway-system` | kgateway controller, Envoy gateway pod | 2 |
| `agentgateway-system` | agentgateway controller, agent gateway pod | 2 |
| `kagent` | controller, UI, k8s/helm/kgateway agents, MCP tools, KMCP controller | 7 |

### Helm Releases

| Release | Namespace | Chart | Version |
|---------|-----------|-------|---------|
| kubeai | kubeai | kubeai | 0.23.1 |
| litellm | litellm | litellm-helm | 1.1.0 |
| kgateway-crds | kgateway-system | kgateway-crds | 0.0.2 |
| kgateway | kgateway-system | kgateway | 0.0.2 |
| agentgateway-crds | agentgateway-system | agentgateway-crds | 0.0.2 |
| agentgateway | agentgateway-system | agentgateway | 0.0.2 |
| kagent-crds | kagent | kagent-crds | v0.7.13 |
| kagent | kagent | kagent | v0.7.13 |

### Models

| Model | Status | VRAM | Engine | Min Replicas |
|-------|--------|------|--------|-------------|
| qwen2.5-14b | Active | ~9.4GB | Ollama | 1 |
| qwen2.5-3b | Standby (scales to 0) | ~2.5GB | Ollama | 0 |

### Domain Routing

| Subdomain | Service | Backend | Protocol |
|-----------|---------|---------|----------|
| `ai.lab.danatlab.com` | kagent UI | kagent-ui.kagent:8080 | HTTPS (Let's Encrypt) |
| `chat.lab.danatlab.com` | Open WebUI | open-webui.kubeai:80 | HTTPS (Let's Encrypt) |
| `litellm.lab.danatlab.com` | LiteLLM API + Dashboard | litellm.litellm:4000 | HTTPS (Let's Encrypt) |

DNS: `*.lab.danatlab.com -> 192.168.6.6` (wildcard A record)
SSL: Let's Encrypt wildcard cert `*.lab.danatlab.com` managed by NPM

### Credentials

| What | Value | Where Used |
|------|-------|-----------|
| LiteLLM master key | `<your-litellm-master-key>` | LiteLLM API auth, kagent secrets, dashboard login |
| KubeAI API key | none required | Internal cluster traffic only |
| NPM admin | `http://192.168.6.6:81` | Reverse proxy management |

---

## Deployment Steps

### Prerequisites

- Kubernetes cluster with GPU node (RTX 3060 / ampere family)
- NVIDIA device plugin installed
- Helm 3.x
- kubectl configured
- Domain `*.lab.danatlab.com` pointing to a reverse proxy (NPM)

### Step 1: Deploy KubeAI

```bash
# Build chart dependencies (downloads open-webui subchart)
cd kubeai/charts/kubeai && helm dependency build && cd -

# Install
helm install kubeai kubeai/charts/kubeai \
  --namespace kubeai --create-namespace \
  -f kubeai/kubeai-values.yaml

# Apply models
kubectl apply -f kubeai/qwen-14b-model.yaml
kubectl apply -f kubeai/qwen-model.yaml        # 3B standby (minReplicas: 0)

# Wait for 14B model pod (downloads ~9GB model weights on first run)
kubectl wait --for=condition=ready pod -l model=qwen2.5-14b -n kubeai --timeout=900s
```

### Step 2: Deploy LiteLLM

```bash
# Build chart dependencies (downloads PostgreSQL + Redis subcharts)
cd litellm/deploy/charts/litellm-helm && helm dependency build && cd -

# Install
helm install litellm litellm/deploy/charts/litellm-helm \
  --namespace litellm --create-namespace \
  -f litellm/litellm-values.yaml

# Wait for PostgreSQL then LiteLLM
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n litellm --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=litellm -n litellm --timeout=120s
```

**Known issue:** If upgrading LiteLLM, delete the migrations Job first (immutable spec):
```bash
kubectl delete job litellm-migrations -n litellm
```

### Step 3: Deploy kgateway + agentgateway

```bash
# Gateway API CRDs (upstream)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# kgateway
helm install kgateway-crds kgateway/install/helm/kgateway-crds \
  -n kgateway-system --create-namespace

helm install kgateway kgateway/install/helm/kgateway \
  -n kgateway-system \
  --set image.registry=ghcr.io/kgateway-dev \
  --set image.tag=v2.2.0

# agentgateway
helm install agentgateway-crds kgateway/install/helm/agentgateway-crds \
  -n agentgateway-system --create-namespace

helm install agentgateway kgateway/install/helm/agentgateway \
  -n agentgateway-system \
  --set image.registry=ghcr.io/kgateway-dev \
  --set image.tag=v2.2.0 \
  --set controller.image.repository=agentgateway-controller

# Apply Gateway + HTTPRoute resources (subdomain routing)
kubectl apply -f kgateway/gateway-resources.yaml

# Verify
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kgateway -n kgateway-system --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=agentgateway -n agentgateway-system --timeout=120s
```

### Step 4: Deploy kagent

```bash
# Generate Chart.yaml from templates (required - only Chart-template.yaml exists in repo)
VERSION=v0.7.13 KMCP_VERSION=0.2.5 envsubst < kagent/helm/kagent-crds/Chart-template.yaml > kagent/helm/kagent-crds/Chart.yaml
VERSION=v0.7.13 KMCP_VERSION=0.2.5 envsubst < kagent/helm/kagent/Chart-template.yaml > kagent/helm/kagent/Chart.yaml

# Also generate for all sub-charts
for dir in kagent/helm/agents/*/  kagent/helm/tools/*/; do
  [ -f "$dir/Chart-template.yaml" ] && VERSION=v0.7.13 KMCP_VERSION=0.2.5 envsubst < "$dir/Chart-template.yaml" > "$dir/Chart.yaml"
done

# Build dependencies
cd kagent/helm/kagent-crds && helm dependency build && cd -
cd kagent/helm/kagent && helm dependency build && cd -

# Install CRDs
helm install kagent-crds kagent/helm/kagent-crds \
  -n kagent --create-namespace

# Create secrets
kubectl create secret generic kagent-openai -n kagent \
  --from-literal=OPENAI_API_KEY=<your-litellm-master-key>

kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key=<your-litellm-master-key>

# Install kagent
helm install kagent kagent/helm/kagent \
  -n kagent \
  -f kagent/kagent-values.yaml \
  --set kmcp.image.tag=0.2.5 \
  --set tag=0.7.13 \
  --set registry=ghcr.io

# Apply ModelConfig (14B via LiteLLM)
kubectl apply -f kagent/kagent-modelconfig-14b.yaml

# Wait
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n kagent --timeout=120s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=ui -n kagent --timeout=120s
```

### Step 5: Configure NPM (Nginx Proxy Manager)

1. Log into NPM at `http://192.168.6.6:81`
2. Create proxy hosts for each subdomain:

| Source | Forward To | SSL |
|--------|-----------|-----|
| `ai.lab.danatlab.com` | `192.168.6.6:30988` | `*.lab.danatlab.com` cert, Force SSL |
| `chat.lab.danatlab.com` | `192.168.6.6:30988` | `*.lab.danatlab.com` cert, Force SSL |
| `litellm.lab.danatlab.com` | `192.168.6.6:30988` | `*.lab.danatlab.com` cert, Force SSL |

NodePort 30988 is created automatically by kgateway when the Gateway resource is applied.

---

## Access URLs

| Service | URL | Notes |
|---------|-----|-------|
| kagent UI | `https://ai.lab.danatlab.com` | Agent management, chat with k8s/helm/gateway agents |
| Open WebUI | `https://chat.lab.danatlab.com` | ChatGPT-like interface for Qwen 14B |
| LiteLLM Dashboard | `https://litellm.lab.danatlab.com/ui/` | API key management, usage tracking. Key: `<your-litellm-master-key>` |
| LiteLLM API | `https://litellm.lab.danatlab.com/v1/` | OpenAI-compatible API endpoint |

### Port-forward alternatives (no domain required)

```bash
# kagent UI
kubectl -n kagent port-forward svc/kagent-ui 8080:8080
# -> http://localhost:8080

# Open WebUI
kubectl -n kubeai port-forward svc/open-webui 3000:80
# -> http://localhost:3000

# LiteLLM Dashboard
kubectl -n litellm port-forward svc/litellm 4000:4000
# -> http://localhost:4000/ui
```

---

## Validation Tests

### Quick health check

```bash
echo "=== Pod Status ==="
for ns in kubeai litellm kgateway-system agentgateway-system kagent; do
  NOT_READY=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
  TOTAL=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -v "Completed" | wc -l)
  READY=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep "Running" | awk '{print $2}' | grep -c "1/1\|2/2")
  if [ "$NOT_READY" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
    echo "  OK $ns: $READY/$TOTAL pods ready"
  else
    echo "  FAIL $ns: $NOT_READY pod(s) not ready"
  fi
done

echo ""
echo "=== Gateways ==="
kubectl get gateways -A --no-headers | while read ns name class addr prog age; do
  if [ "$prog" = "True" ]; then echo "  OK $ns/$name ($class)"; else echo "  FAIL $ns/$name"; fi
done

echo ""
echo "=== Agents ==="
kubectl get agents -n kagent --no-headers | while read name type ready accepted; do
  if [ "$ready" = "True" ]; then echo "  OK $name"; else echo "  FAIL $name"; fi
done

echo ""
echo "=== GPU ==="
MODELPOD=$(kubectl get pods -n kubeai --no-headers | grep model-qwen | awk '{print $1}' | head -1)
kubectl exec -n kubeai $MODELPOD -- nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null
```

### Test 1: Direct KubeAI inference

```bash
kubectl run --rm -it test-kubeai --image=curlimages/curl --restart=Never -n kubeai -- \
  curl -s http://kubeai.kubeai.svc:80/openai/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-14b","messages":[{"role":"user","content":"Say hello in 5 words"}],"max_tokens":20}'
```

**Expected:** JSON with `choices[0].message.content` containing a greeting.

### Test 2: LiteLLM proxy chain (KubeAI -> LiteLLM -> response)

```bash
kubectl run --rm -it test-litellm --image=curlimages/curl --restart=Never -n litellm -- \
  curl -s http://litellm.litellm.svc:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-litellm-master-key>" \
  -d '{"model":"qwen2.5-14b","messages":[{"role":"user","content":"Say hello"}],"max_tokens":20}'
```

**Expected:** Same as Test 1, routed through LiteLLM.

### Test 3: LiteLLM model list

```bash
kubectl run --rm -it test-models --image=curlimages/curl --restart=Never -n litellm -- \
  curl -s http://litellm.litellm.svc:4000/v1/models \
  -H "Authorization: Bearer <your-litellm-master-key>"
```

**Expected:** `{"data":[{"id":"qwen2.5-14b",...},{"id":"qwen2.5-3b",...}]}`

### Test 4: External domain access

```bash
# All should return HTTP 200 (or 301/307 redirect to final 200)
curl -s -k -o /dev/null -w "%{http_code}" https://ai.lab.danatlab.com/
curl -s -k -o /dev/null -w "%{http_code}" https://chat.lab.danatlab.com/
curl -s -k -o /dev/null -w "%{http_code}" https://litellm.lab.danatlab.com/ui/
curl -s -k -o /dev/null -w "%{http_code}" -H "Authorization: Bearer <your-litellm-master-key>" \
  https://litellm.lab.danatlab.com/v1/models
```

### Test 5: kagent agent A2A protocol

```bash
kubectl run --rm -it test-agent --image=curlimages/curl --restart=Never -n kagent -- \
  curl -s http://k8s-agent:8080/.well-known/agent.json
```

**Expected:** JSON with `protocolVersion`, `skills`, and `capabilities`.

---

## Troubleshooting

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| LiteLLM pod CrashLoopBackOff | PostgreSQL not ready or image tag issue | Check PG pod first. Use `image.tag: main-latest` |
| kagent images not found | Wrong registry or tag format | Use `registry: ghcr.io`, tag `0.7.13` (no v prefix) |
| kgateway images not found | Default dev registry empty | Override to `ghcr.io/kgateway-dev`, tag `v2.2.0` |
| Model pod pending | GPU not available or PVC conflict | Check `kubectl describe pod` for scheduling events |
| 503 on subdomain | Backend pod scaled to 0 or not ready | Check pod status in target namespace |
| LiteLLM helm upgrade fails | Immutable migrations Job | `kubectl delete job litellm-migrations -n litellm` |
| kagent Chart.yaml missing | Only template exists | Run `envsubst` with VERSION and KMCP_VERSION |
| Agent returns "Connection error" | LiteLLM is down (agents use it as LLM backend) | Restore LiteLLM first |

### Image Registry Gotchas

| Component | Default Registry | Working Registry | Tag Format |
|-----------|-----------------|-----------------|------------|
| kagent | `cr.kagent.dev` (broken) | `ghcr.io` | `0.7.13` (no v) |
| kgateway | `cr.kgateway.dev` (broken) | `ghcr.io/kgateway-dev` | `v2.2.0` |
| agentgateway | `ghcr.io/kgateway-dev/controller` (wrong) | `ghcr.io/kgateway-dev/agentgateway-controller` | `v2.2.0` |
| LiteLLM | `ghcr.io/berriai/litellm-database` | same | `main-latest` |
| PostgreSQL (Bitnami) | stale tags removed | same | `latest` |

---

## Teardown

Reverse order. Remove kagent first, then gateways, then LiteLLM, then KubeAI.

```bash
# kagent
kubectl delete -f kagent/kagent-modelconfig-14b.yaml
kubectl delete -f kagent/kagent-modelconfig.yaml
kubectl delete secret litellm-key kagent-openai -n kagent
helm uninstall kagent -n kagent
helm uninstall kagent-crds -n kagent
kubectl delete namespace kagent

# kgateway + agentgateway
kubectl delete -f kgateway/gateway-resources.yaml
helm uninstall agentgateway -n agentgateway-system
helm uninstall agentgateway-crds -n agentgateway-system
helm uninstall kgateway -n kgateway-system
helm uninstall kgateway-crds -n kgateway-system
kubectl delete namespace agentgateway-system kgateway-system
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# LiteLLM
helm uninstall litellm -n litellm
kubectl delete namespace litellm

# KubeAI
kubectl delete -f kubeai/qwen-14b-model.yaml
kubectl delete -f kubeai/qwen-model.yaml
helm uninstall kubeai -n kubeai
kubectl delete namespace kubeai
```

---

## Files Reference

All paths relative to `/Users/xxxgardiner/Desktop/repo/ai-platform/`:

| File | Purpose |
|------|---------|
| `kubeai/kubeai-values.yaml` | RTX 3060 resource profile, Open WebUI subchart config |
| `kubeai/qwen-14b-model.yaml` | Qwen 2.5 14B Model CR (active, minReplicas: 1) |
| `kubeai/qwen-model.yaml` | Qwen 2.5 3B Model CR (standby, minReplicas: 0) |
| `litellm/litellm-values.yaml` | Proxy config, master key, PostgreSQL, model routing for both 3B and 14B |
| `kgateway/gateway-resources.yaml` | Gateway, HTTPRoutes (subdomain routing), ReferenceGrants |
| `kagent/kagent-values.yaml` | Agent config, enabled agents, SQLite DB, ghcr.io registry |
| `kagent/kagent-modelconfig-14b.yaml` | ModelConfig pointing agents at qwen2.5-14b via LiteLLM |
| `kagent/kagent-modelconfig.yaml` | ModelConfig pointing at qwen2.5-3b (legacy) |
