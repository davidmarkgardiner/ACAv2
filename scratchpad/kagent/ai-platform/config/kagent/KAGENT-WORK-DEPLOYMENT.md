# KAgent - Work Deployment (Behind APIM)

> **Scenario**: Models live behind Azure API Management (APIM). We have an API base URL, a model name, and pass a JWT token as the API key.

---

## What Gets Deployed (Default Images)

| Image | Tag | Deployed By Default? | Can Disable? | Purpose |
|-------|-----|---------------------|--------------|---------|
| `ghcr.io/kagent-dev/kagent/controller` | `0.7.13` | Yes | No (core) | Reconciles Agent CRDs, manages agent pods |
| `ghcr.io/kagent-dev/kagent/app` | `0.7.13` | Yes (x10 pods!) | Yes, per agent | One pod per enabled agent. **Default enables 10 agents** |
| `ghcr.io/kagent-dev/kagent/tools` | `0.0.13` | Yes | Yes (`kagent-tools.enabled: false`) | Built-in MCP tool server (k8s, helm, prometheus) |
| `ghcr.io/kagent-dev/kagent/ui` | `0.7.13` | Yes | No (no toggle in values) | Web UI for managing agents |
| `ghcr.io/kagent-dev/kmcp/controller` | `0.2.5` | Yes | Yes (`kmcp.enabled: false`) | KMCP controller for MCP server connections |
| `ghcr.io/kagent-dev/doc2vec/mcp` | `1.1.14` | Yes | Yes (`tools.querydoc.enabled: false`) | Doc search MCP tool |

### Default Agents (each spawns a `kagent/app` pod)

All 10 are enabled by default:
- k8s-agent, kgateway-agent, istio-agent, promql-agent, observability-agent
- argo-rollouts-agent, helm-agent, cilium-policy-agent, cilium-manager-agent, cilium-debug-agent

**You probably only need 2-3 of these.** Disable the rest to save resources.

---

## Step 1: Install CRDs

```bash
helm install kagent-crds \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --namespace kagent \
  --create-namespace
```

## Step 2: Create the JWT Secret

```bash
# Replace with your actual JWT token
kubectl create secret generic kagent-apim-key \
  --namespace kagent \
  --from-literal=api-key="eyJhbGciOiJSUzI1NiIs..."
```

## Step 3: Create Helm Values

```yaml
# kagent-work-values.yaml
tag: "0.7.13"
registry: "ghcr.io"

# ---------------------------------------------------------------------------
# Provider: Use OpenAI provider pointed at your APIM endpoint
# APIM exposes an OpenAI-compatible API, so we use provider: OpenAI
# with a custom baseUrl. The JWT token goes in the api-key secret.
# ---------------------------------------------------------------------------
providers:
  default: openAI
  openAI:
    provider: OpenAI
    model: "YOUR_MODEL_NAME"            # e.g. "gpt-4o", "gpt-4-turbo" — whatever APIM routes
    apiKeySecretRef: kagent-apim-key    # Secret created in Step 2
    apiKeySecretKey: api-key

# ---------------------------------------------------------------------------
# Disable agents you don't need (each one spawns a pod)
# ---------------------------------------------------------------------------
agents:
  k8s-agent:
    enabled: true
  helm-agent:
    enabled: true
  # Disable everything else
  kgateway-agent:
    enabled: false
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

# ---------------------------------------------------------------------------
# Disable tools you don't need
# ---------------------------------------------------------------------------
tools:
  grafana-mcp:
    enabled: false
  querydoc:
    enabled: false

# SQLite is fine unless you need persistence across restarts
database:
  type: sqlite
```

## Step 4: Install KAgent

```bash
helm install kagent \
  oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --values kagent-work-values.yaml
```

## Step 5: Apply ModelConfig CRD (Points at APIM)

The Helm `providers` block creates a default ModelConfig, but if you need to be explicit
about the base URL (which you do for APIM), apply this after install:

```yaml
# kagent-apim-modelconfig.yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: apim-llm
  namespace: kagent
spec:
  provider: OpenAI
  model: "YOUR_MODEL_NAME"                # Must match what APIM expects in the request body
  apiKeySecret: kagent-apim-key           # Secret with your JWT token
  apiKeySecretKey: api-key
  openAI:
    baseUrl: "https://YOUR_APIM_GATEWAY.azure-api.net/openai/v1"   # Your APIM base URL
    # temperature: "0.7"                  # Optional
    # maxTokens: 4096                     # Optional
  # If APIM uses a corporate CA certificate:
  # tls:
  #   caCertSecretRef: corporate-ca
  #   caCertSecretKey: ca.crt
```

```bash
kubectl apply -f kagent-apim-modelconfig.yaml
```

## Step 6: Verify

```bash
# Check all pods are running
kubectl get pods -n kagent

# Expected (with values above):
# kagent-controller-xxx     1/1  Running   (controller)
# kagent-kmcp-xxx           1/1  Running   (KMCP controller)
# kagent-tools-xxx          1/1  Running   (MCP tool server)
# kagent-ui-xxx             1/1  Running   (Web UI)
# k8s-agent-xxx             1/1  Running   (agent pod)
# helm-agent-xxx            1/1  Running   (agent pod)

# Check ModelConfig was created
kubectl get modelconfigs -n kagent

# Port-forward the UI
kubectl port-forward svc/kagent-ui -n kagent 8080:8080
# Open http://localhost:8080
```

---

## How the JWT/APIM Auth Works

KAgent uses the `apiKeySecret` value as a Bearer token in the `Authorization` header
when calling the OpenAI-compatible API. The flow is:

```
KAgent Agent Pod
    │
    │  POST https://YOUR_APIM_GATEWAY.azure-api.net/openai/v1/chat/completions
    │  Authorization: Bearer <JWT from secret>
    │  Content-Type: application/json
    │  {"model": "YOUR_MODEL_NAME", "messages": [...]}
    │
    ▼
Azure APIM
    │  Validates JWT
    │  Routes to backend Azure OpenAI instance
    ▼
Azure OpenAI
    │  Returns completion
    ▼
KAgent Agent Pod
```

---

## Values You Need to Replace

| Placeholder | What to put |
|------------|-------------|
| `YOUR_MODEL_NAME` | The model name APIM expects (e.g. `gpt-4o`, `gpt-4-turbo`) |
| `YOUR_APIM_GATEWAY.azure-api.net` | Your APIM gateway hostname |
| `eyJhbGciOiJSUzI1NiIs...` | Your actual JWT token |

---

## Istio VirtualService — Expose the UI

The KAgent UI service runs on port 8080. Create a VirtualService to expose it
through your Istio ingress gateway:

```yaml
# kagent-virtualservice.yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: kagent-ui
  namespace: kagent
spec:
  hosts:
    - "kagent.YOUR_DOMAIN.com"           # Replace with your hostname
  gateways:
    - istio-system/YOUR_GATEWAY_NAME     # Replace with your Istio Gateway name
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: kagent-ui.kagent.svc.cluster.local
            port:
              number: 8080
```

```bash
kubectl apply -f kagent-virtualservice.yaml
```

> **Note**: The UI talks to the controller API internally. No separate VirtualService
> is needed for the controller — it's only called from within the cluster.

---

## Argo Workflows → KAgent (In-Cluster Service Call)

Argo Workflows call KAgent's A2A endpoint via the **in-cluster service DNS**.
No external ingress or VirtualService needed — it's pod-to-pod traffic.

```
┌──────────────────┐                        ┌──────────────────────┐
│  Argo Workflow    │  HTTP (in-cluster)     │  KAgent Controller   │
│  (namespace: argo)│───────────────────────▶│  (namespace: kagent) │
│                   │                        │  port: 8083          │
└──────────────────┘                        └──────────────────────┘
```

### Service URL

```
http://kagent-controller.kagent.svc.cluster.local:8083
```

This is already the pattern from the existing `kagent-sre-workflow.yaml`:

```yaml
# Workflow parameter — no ingress needed
- name: kagent_controller_url
  value: "http://kagent-controller.kagent.svc.cluster.local:8083"
```

### A2A Endpoint (what workflows call)

```
POST http://kagent-controller.kagent.svc.cluster.local:8083/api/a2a/kagent/{agent-name}/
```

> **Trailing slash is required** — without it you get a redirect/404.

### If Argo Workflows is in the same namespace as KAgent

You can shorten the URL to just the service name:

```
http://kagent-controller:8083/api/a2a/kagent/{agent-name}/
```

But using the full FQDN (`kagent-controller.kagent.svc.cluster.local:8083`) is safer
and works regardless of which namespace the workflow runs in.

---

## Pod Count Summary (with these values)

| Component | Pods | Image |
|-----------|------|-------|
| kagent-controller | 1 | `kagent/controller` |
| kagent-kmcp | 1 | `kmcp/controller` |
| kagent-tools | 1 | `kagent/tools` |
| kagent-ui | 1 | `kagent/ui` |
| k8s-agent | 1 | `kagent/app` |
| helm-agent | 1 | `kagent/app` |
| **Total** | **6 pods** | vs 14+ with all defaults |
