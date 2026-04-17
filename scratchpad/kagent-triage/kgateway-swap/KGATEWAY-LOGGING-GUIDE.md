# kgateway + LGTM Logging — Implementation Guide

Two changes:
1. **Swap LiteLLM → kgateway** as the AI proxy between kagent and KubeAI
2. **Add log pipeline** — kagent controller + kgateway → Alloy → Loki

---

## Part 1: Swap LiteLLM for kgateway

### Why

LiteLLM was added as a compatibility shim (OpenAI API → KubeAI). kgateway is already in the stack and can proxy the same traffic with one HTTPRoute. This removes a deployment, a PostgreSQL instance, and an admin UI from the hot path.

### Architecture change

```
Before:
  kagent controller
    → http://litellm.litellm.svc.cluster.local:4000/v1
    → LiteLLM proxy + PostgreSQL
    → http://kubeai.kubeai.svc.cluster.local/openai/v1
    → KubeAI / Ollama (RTX 3060)

After:
  kagent controller
    → http://kgateway.kgateway-system.svc.cluster.local:8080/openai/v1
    → kgateway Envoy proxy (already running, no new pods)
    → http://kubeai.kubeai.svc.cluster.local/openai/v1
    → KubeAI / Ollama (RTX 3060)
```

### Step 1: Verify the kgateway service name

```bash
kubectl get svc -n kgateway-system
# Look for the Envoy listener service — likely 'kgateway' or 'kgateway-proxy'
# Note the ClusterIP and port (should be 8080)
```

If the service name differs from `kgateway`, update it in:
- `config/kgateway/ai-proxy-route.yaml` (the backendRef comment)
- `config/kagent/modelconfig-kgateway.yaml` (both ModelConfig baseUrls)

### Step 2: Verify the ReferenceGrant exists

```bash
kubectl get referencegrant -n kubeai
# Expected: allow-gw-to-kubeai
# If missing, apply the commented block at the bottom of ai-proxy-route.yaml
```

### Step 3: Apply the kgateway route

```bash
# This patches the existing gateway to add an internal listener, then adds
# an HTTPRoute that proxies /openai/v1 → KubeAI
kubectl apply -f ai-platform/config/kgateway/ai-proxy-route.yaml

# Verify the HTTPRoute is accepted
kubectl get httproute kubeai-ai-route -n kgateway-system
# STATUS column should show: Accepted
```

### Step 4: Test the route before switching kagent

```bash
# Port-forward the kgateway service
kubectl port-forward svc/kgateway -n kgateway-system 8080:8080

# In another terminal — test the OpenAI-compatible endpoint
curl -s http://localhost:8080/openai/v1/models \
  -H "Authorization: Bearer not-needed" | jq '.data[].id'

# Expected: ["qwen2.5-3b", "qwen2.5-14b"] (or similar from KubeAI)

# Test a completion
curl -s http://localhost:8080/openai/v1/chat/completions \
  -H "Authorization: Bearer not-needed" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-3b",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 50
  }' | jq '.choices[0].message.content'
```

### Step 5: Apply the new ModelConfig

```bash
kubectl apply -f ai-platform/config/kagent/modelconfig-kgateway.yaml

# Verify
kubectl get modelconfig -n kagent
# Should show: kgateway-qwen, kgateway-qwen-14b alongside the old litellm-* ones
```

### Step 6: Switch agents to the new ModelConfig

**One agent at a time** (test before rolling out to all):

```bash
# Patch one agent first
kubectl patch agent sre-triage-agent -n kagent \
  --type merge \
  -p '{"spec":{"declarative":{"modelConfig":"kgateway-qwen"}}}'

# Test it with an A2A call
curl -s -X POST "http://localhost:8083/api/a2a/kagent/sre-triage-agent/" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":"kgateway-test-1",
    "method":"message/send",
    "params":{"message":{"role":"user","parts":[{
      "kind":"text",
      "text":"What nodes are in this cluster? Check with kubectl."
    }]}}
  }' | jq -r '.result.artifacts[0].parts[0].text'
```

If the response looks good, patch the remaining agents:

```bash
for agent in sre-remediation-agent k8s-agent helm-agent; do
  kubectl patch agent $agent -n kagent \
    --type merge \
    -p "{\"spec\":{\"declarative\":{\"modelConfig\":\"kgateway-qwen\"}}}"
done

# Verify all agents are on kgateway
kubectl get agent -n kagent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.declarative.modelConfig}{"\n"}{end}'
```

### Step 7: Decommission LiteLLM (once stable)

```bash
# Only after 24h of stable operation on kgateway
helm uninstall litellm -n litellm
kubectl delete namespace litellm

# Remove the old litellm gateway listener from gateway-resources.yaml
# (the 'litellm' listener and 'litellm-route' HTTPRoute)
```

---

## Part 2: kagent + kgateway Logging → Alloy → Loki

### Architecture

```
kagent controller pods  ──stdout──┐
                                  ├──► Alloy (pod log scrape) ──► Loki ──► Grafana
kgateway Envoy pods     ──stdout──┘

kagent controller       ──OTLP──► Alloy (otelcol receiver) ──► Loki + Tempo
(structured, optional)
```

Two logging approaches — use one or both:

| Approach | What you get | Config needed |
|----------|-------------|---------------|
| **A: Pod log scraping** (Alloy) | All stdout/stderr, any log format | Only Alloy ConfigMap |
| **B: OTLP from kagent** | Structured: agent, model, tokens, latency | Alloy ConfigMap + kagent Helm values |

Approach A is simpler and requires no code changes. Approach B gives richer, queryable fields in Grafana.

### Prerequisite: Install Loki

Check if Loki is already running:

```bash
kubectl get svc loki -n monitoring 2>/dev/null || echo "not installed"
```

If not installed:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --create-namespace \
  --set promtail.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi \
  --set loki.config.limits_config.retention_period=168h

# Verify
kubectl get pods -n monitoring -l app=loki
kubectl get svc loki -n monitoring
# Expected: loki.monitoring.svc.cluster.local:3100
```

Add Loki as a Grafana data source:

```bash
# Port-forward Grafana
kubectl port-forward svc/kube-prom-grafana -n monitoring 3000:80

# In Grafana UI: Configuration → Data Sources → Add → Loki
# URL: http://loki.monitoring.svc.cluster.local:3100
```

### Step 1: Apply the Alloy log pipeline (Approach A)

```bash
kubectl apply -f ai-platform/config/monitoring/alloy-log-pipeline.yaml
```

If Alloy is already running as a DaemonSet, check if it uses a ConfigMap or a values-mounted config:

```bash
kubectl get daemonset -n monitoring -l app.kubernetes.io/name=alloy -o yaml | grep -A5 configMap
```

If it's using a different ConfigMap name, update the `name:` field in `alloy-log-pipeline.yaml` to match, then:

```bash
kubectl rollout restart daemonset/alloy -n monitoring
# or for deployment:
kubectl rollout restart deployment/alloy -n monitoring
```

### Step 2: Enable OTLP from kagent controller (Approach B, optional but recommended)

First, expose port 4317 on the Alloy service:

```bash
kubectl patch svc alloy -n monitoring --type='json' \
  -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"otlp-grpc","port":4317,"protocol":"TCP","targetPort":4317}}]'

# Verify
kubectl get svc alloy -n monitoring
```

Then upgrade kagent with OTEL enabled:

```bash
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  --reuse-values \
  -f ai-platform/config/kagent/kagent-values-otel.yaml

# Verify the env vars are set in the controller pod
kubectl exec -n kagent deployment/kagent-controller -- env | grep OTEL
# Expected:
#   OTEL_TRACING_ENABLED=true
#   OTEL_LOGGING_ENABLED=true
#   OTEL_EXPORTER_OTLP_ENDPOINT=alloy.monitoring.svc.cluster.local:4317
```

### Step 3: Add kgateway Envoy access logs (JSON format)

For structured kgateway access logs, configure Envoy to emit JSON via a `ListenerPolicy`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: kgateway-access-logs
  namespace: kgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-platform-gw
  override:
    accessLog:
      - fileSink:
          path: /dev/stdout
          jsonFormat:
            method: "%REQ(:METHOD)%"
            path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
            response_code: "%RESPONSE_CODE%"
            duration: "%DURATION%"
            upstream_cluster: "%UPSTREAM_CLUSTER%"
            bytes_sent: "%BYTES_SENT%"
            request_id: "%REQ(X-REQUEST-ID)%"
EOF
```

> **Note:** The `ListenerPolicy` CRD name and API group may differ by kgateway version.
> Verify: `kubectl api-resources | grep kgateway` and check kgateway docs for your version.

### Step 4: Verify logs are reaching Loki

```bash
# Run an agent call to generate logs
curl -s -X POST "http://localhost:8083/api/a2a/kagent/sre-triage-agent/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"log-test","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Get cluster nodes."}]}}}'

# Check Alloy is picking up logs
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=50 | grep -E 'kagent|kgateway'

# Query Loki directly
kubectl port-forward svc/loki -n monitoring 3100:3100 &
curl -s "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={service="kagent"}' \
  --data-urlencode 'limit=10' | jq '.data.result[].values[][1]' | head -5
```

### Step 5: Grafana dashboards

In Grafana (`https://grafana.lab.danatlab.com`):

**Explore → Loki:**

```logql
# kagent controller logs (all)
{service="kagent"}

# Errors only
{service="kagent", level="error"}

# kgateway access logs for /openai/v1 calls
{service="kgateway"} |= "/openai/v1"

# 5xx responses from kgateway
{service="kgateway"} | json | response_code >= 500
```

**Suggested dashboard panels:**
- Table: recent agent invocations (`{service="kagent"} | json | line_format "{{.agent}} {{.msg}}"`)
- Rate: kgateway request rate (`rate({service="kgateway"}[5m])`)
- Stat: error rate last 1h (`{service="kagent", level="error"}`)

---

## File Summary

| File | Purpose |
|------|---------|
| `config/kgateway/ai-proxy-route.yaml` | HTTPRoute: kgateway → KubeAI at `/openai/v1` |
| `config/kagent/modelconfig-kgateway.yaml` | ModelConfig pointing kagent at kgateway |
| `config/kagent/kagent-values-otel.yaml` | OTEL logging enabled for kagent controller |
| `config/monitoring/alloy-log-pipeline.yaml` | Alloy: pod log scrape + OTLP receiver → Loki |

## Rollback

If anything breaks during the swap:

```bash
# Revert agents to LiteLLM
for agent in sre-triage-agent sre-remediation-agent k8s-agent helm-agent; do
  kubectl patch agent $agent -n kagent \
    --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"litellm-qwen"}}}'
done

# Revert kagent Helm values (remove OTEL)
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  -f ai-platform/config/kagent/kagent-values.yaml
```
