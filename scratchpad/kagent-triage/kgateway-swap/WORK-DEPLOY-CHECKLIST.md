# Work Cluster Deployment Checklist

Lift-and-shift from the homelab red cluster (KIND, KubeAI CPU models) to your work cluster.
Work through Section 1 (substitutions) before applying anything. Everything else is
copy-paste once those values are confirmed.

---

## Architecture — Cross-Cluster via Istio

**Important: the topology here is different from homelab.**

```
Worker cluster(s)                     Management cluster
─────────────────                     ──────────────────
kagent (sre-triage-agent)             kgateway
  │                                     │
  │  ModelConfig.baseUrl                │
  │  = Istio VirtualService hostname    │
  └──── Istio mesh (mTLS) ────────────► ai-gateway (Envoy)
                                         │
                                         ▼
                                       KubeAI (local LLMs)
```

Consequences:

1. **kgateway is deployed once on the management cluster only.** Worker clusters do not
   get their own kgateway installation.

2. **ModelConfig `baseUrl` must be the cross-cluster Istio address**, not
   `http://ai-gateway.kgateway-system.svc.cluster.local:8080` (that only works in-cluster).
   Use the VirtualService hostname exposed through the Istio ingress/mesh gateway.

3. **TLS is handled by Istio mTLS** — the P0 "no TLS" issue from the Factory review is
   addressed by the service mesh at the transport layer. You do not need a separate
   cert-manager setup for gateway-to-agent traffic.

4. **NetworkPolicy** on the management cluster should allow inbound from the Istio
   ingress gateway only. Istio `AuthorizationPolicy` is the right control here rather
   than raw NetworkPolicy.

5. **The ReferenceGrant** (`allow-kgateway-to-kubeai`) stays — it's still needed for
   kgateway → KubeAI routing within the management cluster.

### What the ModelConfig baseUrl should look like

```bash
# On management cluster — find the VirtualService or Istio ingress hostname for kgateway
kubectl get virtualservice -A | grep -i kgateway
kubectl get gateway -A | grep -i istio   # Istio Gateway (not kgateway Gateway)
kubectl get svc -n istio-system           # find the Istio ingress gateway LB IP
```

The `baseUrl` in `verified-modelconfig.yaml` will be something like:
```yaml
# Option A — Istio ingress gateway hostname (most common)
baseUrl: http://ai-gateway.internal.example.com/openai/v1

# Option B — Istio mesh service hostname (if worker clusters are in the same mesh)
baseUrl: http://ai-gateway.kgateway-system.svc.cluster.local:8080/openai/v1
# (this works if Istio ServiceEntry is configured on worker clusters to resolve
#  cross-cluster service names via the mesh)
```

Confirm with your platform team which hostname kagent should use.

---

## Section 1 — Values to Confirm and Substitute

### 1.0 Cross-cluster endpoint (Istio VirtualService)

This is the most important substitution. The `baseUrl` in `verified-modelconfig.yaml`
must point to kgateway as seen from the **worker cluster**, not the management cluster's
in-cluster DNS.

```bash
# On management cluster
kubectl get virtualservice -A | grep kgateway
kubectl get svc ai-gateway -n kgateway-system   # note the ClusterIP / LoadBalancer IP
```

| Setting | Homelab | Work |
|---|---|---|
| ModelConfig `baseUrl` | `http://ai-gateway.kgateway-system.svc.cluster.local:8080/openai/v1` | `http://<istio-vs-or-hostname>/openai/v1` |

File to update: `verified-modelconfig.yaml` (both ModelConfig entries)

---

### 1.1 KubeAI models

The homelab manifests reference CPU-only Ollama models (`gemma2-2b-cpu`, `llama3-tools`,
`qwen2.5-14b`, `qwen2.5-3b`). Your work cluster may have different models.

```bash
# On work cluster — list available KubeAI models
kubectl get model -n kubeai
# or
kubectl get pods -n kubeai
```

| Homelab value | Replace with |
|---|---|
| `gemma2-2b-cpu` | _____________ (fast/default model) |
| `llama3-tools` | _____________ (tool-use capable model) |
| `qwen2.5-14b` | _____________ (primary model for multi-pool) |
| `qwen2.5-3b` | _____________ (fallback model for multi-pool) |

Files to update:
- `verified-modelconfig.yaml` — `model: gemma2-2b-cpu` and `model: llama3-tools`
- `ai-backend-multipool.yaml` — both pool entries

---

### 1.2 Namespaces

Check whether `kagent`, `kubeai`, `kgateway-system`, and `monitoring` already exist
or need creating. If your work cluster uses different namespace names, do a
search-and-replace across all YAML files.

```bash
kubectl get ns | grep -E 'kagent|kubeai|kgateway|monitoring|loki|tempo'
```

| Namespace | Homelab | Work |
|---|---|---|
| AI agents | `kagent` | _____________ |
| Local LLM serving | `kubeai` | _____________ |
| API gateway | `kgateway-system` | _____________ |
| Monitoring stack | `monitoring` | _____________ |

---

### 1.3 Prometheus / kube-prometheus-stack

The PodMonitor, ServiceMonitors, and PrometheusRules use `release: kube-prom` to be
picked up by the Prometheus Operator.

```bash
# Find your Helm release name
helm list -A | grep prometheus
# Find the label selector the Prometheus CR uses
kubectl get prometheus -A -o jsonpath='{.items[*].spec.serviceMonitorSelector}'
```

| Setting | Homelab | Work |
|---|---|---|
| Helm release label | `release: kube-prom` | `release: _____________` |
| Prometheus remote_write URL | `http://kube-prom-prometheus.monitoring.svc.cluster.local:9090/api/v1/write` | `http://<release>-prometheus.<ns>.svc.cluster.local:9090/api/v1/write` |

Files to update:
- `verified-gateway-resources.yaml` — PodMonitor label
- `prometheus-monitoring.yaml` — all ServiceMonitor/PrometheusRule labels
- `token-tracking-otel.yaml` — remote_write URL

---

### 1.4 Loki and Tempo endpoints

```bash
kubectl get svc -A | grep -E 'loki|tempo'
```

| Setting | Homelab | Work |
|---|---|---|
| Loki write endpoint | `http://loki.monitoring.svc.cluster.local:3100` | _____________ |
| Tempo OTLP endpoint | `http://tempo.monitoring.svc.cluster.local:4317` | _____________ |

Files to update:
- `alloy-log-pipeline.yaml` — `loki.write` URL
- `token-tracking-otel.yaml` — Tempo exporter URL

---

### 1.5 Alloy — existing ConfigMap name

Your work cluster likely already has Alloy deployed (it ships K8s Warning events to
EventHub). You need to **merge** the new pipeline into the existing Alloy ConfigMap
rather than replacing it.

```bash
# Find existing Alloy ConfigMap
kubectl get configmap -n monitoring | grep alloy
kubectl get configmap -n monitoring alloy -o yaml | head -40
```

The new sections to add are in `alloy-log-pipeline.yaml`. Copy the blocks labelled
`# ── NEW: kagent controller logs ──` and `# ── NEW: kgateway pod logs ──` into your
existing ConfigMap, then restart Alloy:

```bash
kubectl rollout restart daemonset/alloy -n monitoring
# or
kubectl rollout restart deployment/alloy -n monitoring
```

---

### 1.6 Cluster name in system prompt

`ai-traffic-policy.yaml` injects a system message with the cluster name. Update it:

```yaml
# Line ~79 in ai-traffic-policy.yaml
content: |
  You are an SRE agent running on a Kubernetes cluster (proxmox-k8s).
  # ↑ change proxmox-k8s to your work cluster name
```

---

### 1.7 Rate limiting

Current values assume an RTX 3060 GPU running `qwen2.5-14b` (~2–3 req/sec sustained).
Adjust for your hardware:

```yaml
# ai-traffic-policy.yaml
tokenBucket:
  maxTokens: 20        # burst capacity — increase if GPU is faster
  tokensPerFill: 5     # sustained req/sec — tune to match observed throughput
  fillInterval: 1s
```

---

## Section 2 — Deploy Order

Once substitutions are done, apply in this order:

### Step 1 — Install kgateway CRDs + controller

```bash
# Check Gateway API CRDs are present first
kubectl get crd | grep gateway.networking.k8s.io

# Install kgateway
helm install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
  --version v2.2.3 \
  --namespace kgateway-system \
  --create-namespace

helm install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
  --version v2.2.3 \
  --namespace kgateway-system

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kgateway \
  -n kgateway-system --timeout=90s
```

### Step 2 — Gateway resources (basic route first, no security policy yet)

```bash
kubectl apply -f verified-gateway-resources.yaml
kubectl get gateway -n kgateway-system
kubectl get httproute -n kgateway-system
```

### Step 3 — Smoke test the route

```bash
# Port-forward and hit the models endpoint
kubectl port-forward svc/ai-gateway -n kgateway-system 8080:8080 &
curl -s http://localhost:8080/openai/v1/models | jq '.data[].id'
# Should list your KubeAI models
```

### Step 4 — Istio: expose kgateway to worker clusters

If kgateway needs to be reachable from worker clusters over the Istio mesh, create a
VirtualService on the management cluster that maps the kgateway Gateway to an Istio
service hostname. The exact manifest depends on your mesh topology — confirm with your
platform team, but the pattern is:

```yaml
# Example — only apply if needed; your platform team may already have this
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ai-gateway-vs
  namespace: kgateway-system
spec:
  hosts:
    - ai-gateway.kgateway-system.svc.cluster.local   # or external hostname
  gateways:
    - mesh
  http:
    - route:
        - destination:
            host: ai-gateway.kgateway-system.svc.cluster.local
            port:
              number: 8080
```

Verify worker cluster can reach it before proceeding:
```bash
# From a pod on the worker cluster
kubectl run test --rm -it --image=curlimages/curl -- \
  curl -s http://<kgateway-hostname>/openai/v1/models
```

### Step 4b — kagent ModelConfig + dummy secret

```bash
# Run this on the WORKER cluster(s) where kagent is installed
kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key="not-required" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f verified-modelconfig.yaml
kubectl get modelconfig -n kagent
```

### Step 5 — Test one agent end-to-end

```bash
kubectl port-forward svc/kagent-controller -n kagent 8083:8083 &

curl -s -X POST "http://localhost:8083/api/a2a/kagent/k8s-agent/" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0","id":"test","method":"message/send",
    "params":{"message":{"role":"user","parts":[{"kind":"text","text":"How many nodes in this cluster?"}]}}
  }' | jq '{
    answer: .result.artifacts[0].parts[0].text,
    tokens: .result.metadata.kagent_usage_metadata
  }'
```

If you get an answer + token counts → kgateway is working.

### Step 6 — Apply security policy (prompt guard + rate limiting)

```bash
kubectl apply -f ai-traffic-policy.yaml
kubectl get trafficpolicy -n kgateway-system
kubectl describe trafficpolicy ai-security-policy -n kgateway-system
# Check: Status.Conditions should show Accepted: True
```

### Step 7 — Multi-pool fallback (optional — only if you have 2 KubeAI models)

```bash
kubectl apply -f ai-backend-multipool.yaml
kubectl get backend -n kgateway-system
```

### Step 8 — Roll out remaining kagent agents

```bash
# Switch all agents to kgateway-kubeai ModelConfig
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"kgateway-kubeai"}}}'
  echo "patched $agent"
done

# Verify
kubectl get agent -n kagent -o custom-columns='NAME:.metadata.name,MODEL:.spec.declarative.modelConfig'
```

### Step 9 — Logging (Alloy → Loki)

Merge `alloy-log-pipeline.yaml` blocks into existing Alloy ConfigMap (see Section 1.5),
then restart Alloy and verify logs appear in Loki/Grafana.

### Step 10 — Observability (Prometheus + OTEL)

```bash
# ServiceMonitors + PrometheusRules
kubectl apply -f prometheus-monitoring.yaml

# OTEL token tracking pipeline (if Tempo is installed)
kubectl apply -f token-tracking-otel.yaml

# kagent controller OTEL export (Helm upgrade)
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  -n kagent \
  -f kagent-values-otel.yaml
```

---

## Section 3 — Verification Checks

After deployment, run these to confirm everything is wired up:

```bash
# 1. kgateway controller healthy
kubectl get pods -n kgateway-system

# 2. Gateway has an IP
kubectl get gateway -n kgateway-system
# PROGRAMMED column should be True

# 3. HTTPRoute attached
kubectl get httproute -n kgateway-system -o jsonpath='{.items[*].status.parents}'

# 4. TrafficPolicy attached
kubectl describe trafficpolicy ai-security-policy -n kgateway-system | grep -A5 Status

# 5. ModelConfig accepted
kubectl get modelconfig -n kagent kgateway-kubeai -o jsonpath='{.status.conditions}'

# 6. Envoy metrics scraping
kubectl exec -n kgateway-system deploy/ai-gateway -- \
  wget -qO- http://localhost:19000/stats/prometheus | grep -c upstream_rq
# Should return a non-zero count

# 7. kagent agents pointing at kgateway
kubectl get agent -n kagent -o custom-columns='NAME:.metadata.name,MODEL:.spec.declarative.modelConfig'
```

---

## Section 4 — Rollback

If kgateway causes issues, revert agents to the old ModelConfig:

```bash
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"default-model-config"}}}'
done
```

kgateway itself can be left running — it won't affect agents until they reference its
ModelConfig.
