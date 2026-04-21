# agentgateway — Install & Configuration Guide

## Why agentgateway, not kgateway

kgateway (kgateway.dev) is a general-purpose Kubernetes ingress controller.
agentgateway (agentgateway.dev) is purpose-built for AI agent traffic. Key differences:

| Feature | kgateway | agentgateway |
|---|---|---|
| Azure OpenAI UAMI | ❌ needs CronJob workaround | ✅ native |
| Prompt guard | ❌ | ✅ |
| Multi-pool model failover | ❌ | ✅ |
| Standard Gateway API | ✅ | ✅ |
| Timeouts, rate limiting | ✅ | ✅ |

---

## Architecture

```
Worker cluster(s)                     Management cluster
─────────────────                     ──────────────────
kagent                                agentgateway (Envoy-based)
  ModelConfig.baseUrl                   │
  = Istio VS hostname → ─── mTLS ──────►│─ /openai/v1 ─► KubeAI (local LLMs)
                                         └─ /azure/v1  ─► Azure OpenAI (UAMI)
```

- **agentgateway** runs once on the management cluster
- **kagent** on worker clusters points at agentgateway via Istio VirtualService
- Worker clusters hold no Azure credentials — agentgateway manages UAMI tokens
- Istio mTLS handles transport security (no additional TLS config needed)

---

## Files in this directory

| File | Cluster | Purpose |
|---|---|---|
| `gateway-resources.yaml` | Management | GatewayClass, Gateway, HTTPRoutes, ReferenceGrant |
| `backend-kubeai.yaml` | Management | AgentgatewayBackend for KubeAI with priority failover |
| `backend-azure-openai.yaml` | Management | AgentgatewayBackend for Azure OpenAI with UAMI |
| `ai-policy.yaml` | Management | Prompt guard, rate limiting, timeouts |
| `networkpolicy.yaml` | Management | Ingress/egress restrictions for agentgateway-system |
| `istio-authorization-policy.yaml` | Management | Restrict mTLS identities allowed to call the gateway |
| `istio-virtualservice.yaml` | Management | Cross-cluster routing from worker → management |
| `modelconfig-kubeai.yaml` | Worker | kagent ModelConfig → KubeAI via agentgateway |
| `modelconfig-azure.yaml` | Worker | kagent ModelConfig → Azure OpenAI via agentgateway |
| `FACTORY-REVIEW.md` | — | Factory quality-gate review + fixes |
| `TEST-PLAN.md` | — | Concrete kubectl/curl verification commands |

---

## Install — Management Cluster

### Step 1 — Gateway API CRDs (if not already present)

```bash
kubectl get crd gateways.gateway.networking.k8s.io 2>/dev/null \
  || kubectl apply --server-side -f \
     https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

### Step 2 — Install agentgateway

```bash
helm upgrade -i --create-namespace \
  --namespace agentgateway-system \
  --version v1.1.0 \
  agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i \
  --namespace agentgateway-system \
  --version v1.1.0 \
  agentgateway oci://cr.agentgateway.dev/charts/agentgateway

kubectl wait --for=condition=ready pod -l app=agentgateway \
  -n agentgateway-system --timeout=90s
```

### Step 3 — Gateway resources

```bash
kubectl apply -f gateway-resources.yaml
kubectl get gateway -n agentgateway-system
kubectl get httproute -n agentgateway-system
```

### Step 4 — KubeAI backend + smoke test

```bash
# Update model names first: kubectl get model -n kubeai
kubectl apply -f backend-kubeai.yaml

# Smoke test via port-forward
kubectl port-forward svc/ai-gateway -n agentgateway-system 8080:80 &
curl -s http://localhost:8080/openai/v1/models | jq '.data[].id'
# Should list your KubeAI models
```

### Step 5 — Azure OpenAI backend (UAMI)

```bash
# Update UAMI client ID and Azure OpenAI endpoint first (see backend-azure-openai.yaml)
kubectl apply -f backend-azure-openai.yaml

# Test Azure OpenAI route
curl -s http://localhost:8080/azure/v1/models | jq '.data[].id'
```

### Step 6 — AI policies (prompt guard + rate limiting)

```bash
kubectl apply -f ai-policy.yaml
kubectl get agentgatewaypolicy -n agentgateway-system
```

### Step 6b — Network segmentation (management cluster)

```bash
kubectl apply -f networkpolicy.yaml
kubectl apply -f istio-authorization-policy.yaml
kubectl apply -f istio-virtualservice.yaml

# Verify from a pod in the mesh
kubectl run -n kagent test-curl --rm -it --image=curlimages/curl -- \
  curl -s http://ai-gateway.agentgateway-system.svc.cluster.local/openai/v1/models
```

---

## Install — Worker Cluster

### Step 7 — kagent dummy secret (if not already present)

```bash
kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key="not-required" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 8 — ModelConfig (update hostname first)

```bash
# Update REPLACE_AGENTGATEWAY_HOSTNAME in both modelconfig files
kubectl apply -f modelconfig-kubeai.yaml
kubectl apply -f modelconfig-azure.yaml
kubectl get modelconfig -n kagent
```

### Step 9 — Test one agent end-to-end

```bash
kubectl port-forward svc/kagent-controller -n kagent 8083:8083 &

# Test KubeAI path
curl -s -X POST "http://localhost:8083/api/a2a/kagent/k8s-agent/" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":"1","method":"message/send",
    "params":{"message":{"role":"user","parts":[{"kind":"text","text":"How many nodes in this cluster?"}]}}
  }' | jq '{answer: .result.artifacts[0].parts[0].text, tokens: .result.metadata.kagent_usage_metadata}'

# Test Azure OpenAI path (patch agent to use azure modelconfig first)
kubectl patch agent k8s-agent -n kagent \
  --type merge \
  -p '{"spec":{"declarative":{"modelConfig":"agentgateway-azure-openai"}}}'
# Re-run the curl above
```

### Step 10 — Roll out to all agents

```bash
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"agentgateway-azure-openai"}}}'
  echo "patched $agent"
done
```

---

## Verification checks

```bash
# Management cluster
kubectl get agentgatewaybackend -n agentgateway-system
kubectl get agentgatewaypolicy -n agentgateway-system
kubectl get gateway -n agentgateway-system   # PROGRAMMED = True
kubectl get httproute -n agentgateway-system  # check parents[].conditions

# Worker cluster
kubectl get modelconfig -n kagent
kubectl get agent -n kagent -o custom-columns='NAME:.metadata.name,MODEL:.spec.declarative.modelConfig'
```

---

## Rollback

```bash
# Revert all agents to previous ModelConfig
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"default-model-config"}}}'
done
```
