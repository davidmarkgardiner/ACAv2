# kgateway — Verified Install Guide
# Tested on: red cluster (KIND, 1 node, homelab-control-plane, K8s v1.32.2)
# Date: 2026-04-17

## What was verified working

| Component | Status | Notes |
|-----------|--------|-------|
| kgateway install (v2.2.3) | ✅ | OCI chart from cr.kgateway.dev |
| GatewayClass + Gateway | ✅ | ai-gateway, LoadBalancer, 172.18.255.201 |
| HTTPRoute → KubeAI | ✅ | /openai/v1 proxied to kubeai.kubeai:80 |
| Models list via kgateway | ✅ | gemma2-2b-cpu, llama3-tools |
| Completion via kgateway | ✅ | Token counts in response |
| kagent ModelConfig | ✅ | kgateway-kubeai, Accepted |
| kagent → kgateway → KubeAI A2A | ✅ | k8s-agent: 4333 tokens, answer correct |
| TrafficPolicy (timeouts) | ✅ | 120s for model cold-start |
| PodMonitor (Envoy :19000) | ✅ | Prometheus scrape configured |

---

## Install (from scratch)

### 1. Install kgateway

```bash
# Gateway API CRDs must already exist (verify: kubectl get crd | grep gateway.networking.k8s.io)

helm install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version v2.2.3 \
  --namespace kgateway-system \
  --create-namespace

helm install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version v2.2.3 \
  --namespace kgateway-system

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kgateway \
  -n kgateway-system --timeout=60s
```

### 2. Apply Gateway resources

```bash
kubectl apply -f verified-gateway-resources.yaml
```

### 3. Create dummy API key secret (required by ModelConfig CRD)

```bash
kubectl create secret generic litellm-key -n kagent --from-literal=api-key="not-required"
```

### 4. Apply ModelConfig

```bash
kubectl apply -f verified-modelconfig.yaml
```

### 5. Switch agents to kgateway

```bash
# One agent first to validate
kubectl patch agent k8s-agent -n kagent \
  --type merge \
  -p '{"spec":{"declarative":{"modelConfig":"kgateway-kubeai"}}}'

# Test (port-forward the controller first)
kubectl port-forward svc/kagent-controller -n kagent 8083:8083 &
curl -s -X POST "http://localhost:8083/api/a2a/kagent/k8s-agent/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"test","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"How many nodes?"}]}}}'  \
  | jq '{answer: .result.artifacts[0].parts[0].text, tokens: .result.metadata.kagent_usage_metadata}'

# Roll out to all agents once validated
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent $agent -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"kgateway-kubeai"}}}'
done
```

---

## Token counts

Token counts are available in TWO places:

### 1. A2A response (per-call)
```bash
curl ... | jq '.result.metadata.kagent_usage_metadata'
# {
#   "candidatesTokenCount": 4,
#   "promptTokenCount": 4329,
#   "totalTokenCount": 4333
# }
```

### 2. KubeAI /metrics (aggregate, Prometheus)
```bash
kubectl port-forward svc/kubeai -n kubeai 8080:80 &
curl -s http://localhost:8080/metrics | grep -E 'token|request'
```

### 3. Envoy stats (kgateway bytes_sent/received as proxy for token volume)
```bash
kubectl exec -n kgateway-system deploy/ai-gateway -- \
  wget -qO- http://localhost:19000/stats/prometheus | grep -E 'upstream_rq|bytes'
```

---

## Actual cluster facts (red cluster)

- **KubeAI models**: `gemma2-2b-cpu`, `llama3-tools` (CPU-only, Ollama backend)
- **kgateway service**: `ai-gateway.kgateway-system.svc.cluster.local:8080`
- **Envoy metrics port**: `19000` (admin interface, /stats/prometheus)
- **kgateway version**: v2.2.3
- **ModelConfig name**: `kgateway-kubeai`

---

## KubeAI cold-start behaviour

Models scale to 0 replicas when idle. First request after idle takes ~60-90s (Ollama model load).
The `TrafficPolicy` sets 120s timeout to handle this. Subsequent requests are fast (<5s).

Monitor scaling:
```bash
kubectl get pods -n kubeai -w
```
