# LiteLLM Monitoring Setup Guide

How to enable token tracking, spend logging, and the LiteLLM UI dashboard for any cluster running LiteLLM as a proxy for kagent.

---

## What You Get

| Feature | What It Shows |
|---------|---------------|
| **UI Dashboard** (`/ui`) | Spend graphs, token usage by model, request logs, latency, per-key breakdown |
| **Spend API** (`/spend/logs`) | Programmatic access to usage data (JSON) |
| **Prometheus Metrics** (`/metrics`) | Scrapeable metrics for Grafana dashboards and alerts |
| **Budget Controls** | Per-key token limits, daily budgets, rate limiting |

---

## Prerequisites

- LiteLLM proxy running (any deployment method — Helm, raw deployment, Docker)
- PostgreSQL database (required for spend tracking and UI dashboard)
- LiteLLM master key (for admin access)

---

## Step 1: Find Your LiteLLM Master Key

The master key is set in the LiteLLM config. To find it:

```bash
# Option A: Check the LiteLLM configmap
kubectl get configmap <litellm-configmap-name> -n <namespace> -o yaml | grep master_key

# Option B: Check the deployment env vars
kubectl get deployment <litellm-deployment> -n <namespace> -o yaml | grep -A2 LITELLM_MASTER_KEY

# Option C: Check the Helm values
helm get values <litellm-release> -n <namespace> | grep master_key
```

**On our red (Geekoms) cluster:**
```bash
kubectl --context=red get configmap litellm-config -n kagent -o yaml | grep master_key
# Result: master_key: sk-litellm-kimi-1234
```

This key is used for:
- Logging into the UI dashboard
- Calling admin API endpoints (`/spend/logs`, `/key/info`, `/model/info`)
- Creating and managing API keys

---

## Step 2: Deploy PostgreSQL

LiteLLM needs PostgreSQL to store spend logs. Without it, the UI works but shows no data.

```yaml
# litellm-postgres.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: litellm-postgres-data
  namespace: <your-litellm-namespace>
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm-postgres
  namespace: <your-litellm-namespace>
  labels:
    app: litellm-postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm-postgres
  template:
    metadata:
      labels:
        app: litellm-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_USER
              value: litellm
            - name: POSTGRES_PASSWORD
              value: <choose-a-password>
            - name: POSTGRES_DB
              value: litellm
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: litellm-postgres-data
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-postgres
  namespace: <your-litellm-namespace>
spec:
  selector:
    app: litellm-postgres
  ports:
    - port: 5432
      targetPort: 5432
```

Apply it:
```bash
kubectl apply -f litellm-postgres.yaml
kubectl wait --for=condition=Ready pod -l app=litellm-postgres -n <namespace> --timeout=120s
```

---

## Step 3: Update LiteLLM Config

Add `database_url` and `success_callback` to your LiteLLM config.

### If using a ConfigMap:

```yaml
# The key fields to add/change:
litellm_settings:
  success_callback:
    - prometheus          # Enables /metrics endpoint
general_settings:
  master_key: <your-master-key>
  database_url: postgresql://<user>:<password>@<postgres-service>.<namespace>.svc.cluster.local:5432/<db>
```

**Full example (our red cluster):**
```yaml
model_list:
  - model_name: kimi-for-coding
    litellm_params:
      model: openai/kimi-for-coding
      api_key: os.environ/KIMI_API_KEY
      api_base: https://api.kimi.com/coding/v1
litellm_settings:
  drop_params: true
  num_retries: 2
  success_callback:
    - prometheus
general_settings:
  master_key: sk-litellm-kimi-1234
  database_url: postgresql://litellm:litellm-poc-pass@litellm-postgres.kagent.svc.cluster.local:5432/litellm
```

### If using Helm values:

```yaml
# litellm-values.yaml
proxy_config:
  litellm_settings:
    success_callback:
      - prometheus
  general_settings:
    master_key: <your-key>
    database_url: postgresql://litellm:<password>@litellm-postgres.<namespace>.svc.cluster.local:5432/litellm
```

Then upgrade:
```bash
helm upgrade litellm <chart> -n <namespace> -f litellm-values.yaml
```

---

## Step 4: Increase LiteLLM Memory

LiteLLM with PostgreSQL needs more memory than the default. Without this it will OOMKill.

```bash
# Minimum 2Gi limit recommended
kubectl patch deployment <litellm-deployment> -n <namespace> --type=json \
  -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"1Gi"}
  ]'
```

---

## Step 5: Restart LiteLLM

```bash
kubectl rollout restart deployment <litellm-deployment> -n <namespace>
kubectl rollout status deployment <litellm-deployment> -n <namespace> --timeout=90s

# Verify it's running (no restarts, no OOMKill)
kubectl get pods -n <namespace> | grep litellm
```

---

## Step 6: Access the UI Dashboard

```bash
kubectl port-forward -n <namespace> svc/<litellm-service> 4000:4000
```

Open **http://localhost:4000/ui** in your browser.

**Login:** Use the master key from Step 1.

### What the UI shows:

| Tab | What You See |
|-----|-------------|
| **Dashboard** | Spend over time, requests per model, token usage graphs |
| **Models** | Registered models, provider, cost per token |
| **Usage** | Per-key token usage, spend breakdown |
| **Logs** | Every request with model, tokens, latency, status |
| **Keys** | API key management, budgets, rate limits |

---

## Step 7: Verify Everything Works

After restarting LiteLLM, make one test call to populate data:

```bash
# Direct call to LiteLLM (not through kagent)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer <your-master-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<your-model>","messages":[{"role":"user","content":"Say hello."}],"max_tokens":5}'
```

Then check:

```bash
# Spend logs
curl -s http://localhost:4000/spend/logs \
  -H "Authorization: Bearer <your-master-key>" | python3 -m json.tool

# Prometheus metrics
curl -s http://localhost:4000/metrics | grep litellm

# Health
curl -s http://localhost:4000/health/liveliness
```

---

## API Reference (Useful Endpoints)

All require `Authorization: Bearer <master-key>` header.

| Endpoint | Method | What It Returns |
|----------|--------|-----------------|
| `/ui` | GET | Web dashboard (browser) |
| `/health/liveliness` | GET | `"I'm alive!"` if healthy |
| `/spend/logs` | GET | Array of all request logs with tokens/spend |
| `/global/spend/logs?limit=N` | GET | Last N requests across all keys |
| `/key/info` | GET | Current key's spend, budget, limits |
| `/model/info` | GET | Registered models with cost info |
| `/metrics` | GET | Prometheus-format metrics |
| `/v1/chat/completions` | POST | Standard OpenAI-compatible chat endpoint |

### PromQL Queries (for Grafana)

```promql
# Total tokens by model (last 24h)
sum by (model) (increase(litellm_output_tokens_metric[24h]))

# Request count by status
sum by (status) (increase(litellm_requests_metric[1h]))

# Estimated spend
sum(increase(litellm_spend_metric[24h]))

# Latency p95
histogram_quantile(0.95, rate(litellm_request_total_latency_metric_bucket[15m]))
```

---

## Optional: Budget Controls

Set per-key budgets to prevent runaway spend:

```bash
# Create a key with a $10/day budget
curl -s http://localhost:4000/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["kimi-for-coding"],
    "max_budget": 10.0,
    "budget_duration": "1d",
    "key_alias": "dev-pipeline"
  }' | python3 -m json.tool
```

Then use the generated key instead of the master key for your agents' ModelConfig.

---

## Optional: ServiceMonitor (for kube-prometheus-stack)

If you're running kube-prometheus-stack and want Grafana dashboards:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: litellm
  namespace: <litellm-namespace>
  labels:
    release: <your-prometheus-release-name>   # e.g. kube-prom
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: litellm          # check your actual service labels
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

**Check your actual service labels first:**
```bash
kubectl get svc <litellm-service> -n <namespace> --show-labels
```

---

## Quick Reference (Red Cluster)

| Setting | Value |
|---------|-------|
| Cluster context | `red` |
| Namespace | `kagent` |
| LiteLLM service | `litellm-proxy` |
| LiteLLM port | `4000` |
| Master key | `sk-litellm-kimi-1234` |
| PostgreSQL service | `litellm-postgres` |
| PostgreSQL credentials | `litellm` / `litellm-poc-pass` |
| UI URL | `http://localhost:4000/ui` (after port-forward) |
| Model | `kimi-for-coding` |

```bash
# Access the UI
kubectl --context=red port-forward -n kagent svc/litellm-proxy 4000:4000
open http://localhost:4000/ui

# Kill when done (important — prevents accidental API calls)
pkill -f "port-forward.*litellm-proxy.*4000"
```
