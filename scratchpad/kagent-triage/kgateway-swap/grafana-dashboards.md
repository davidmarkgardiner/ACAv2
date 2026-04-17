# Grafana Dashboards & LogQL/PromQL Reference
#
# After deploying all manifests, use these queries in Grafana
# (https://grafana.lab.danatlab.com) to build dashboards.
#
# Data sources needed:
#   - Prometheus (kube-prom)  — already configured
#   - Loki                    — add: http://loki.monitoring.svc.cluster.local:3100
#   - Tempo                   — add: http://tempo.monitoring.svc.cluster.local:3100
# ---

## ── PROMETHEUS QUERIES (Dashboards & Alerts) ─────────────────────────────────

### Request rate — AI gateway
```promql
# Requests per second to KubeAI via kgateway
sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"kubeai.*"}[5m]))
```

### Error rate — AI gateway
```promql
# 5xx rate as % of total
(
  sum(rate(envoy_cluster_upstream_rq_5xx{envoy_cluster_name=~"kubeai.*"}[5m]))
  /
  sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"kubeai.*"}[5m]))
) * 100
```

### Latency p50/p95/p99
```promql
# p95 response time from kgateway to KubeAI (milliseconds)
histogram_quantile(0.95,
  sum(rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"kubeai.*"}[5m])) by (le)
)
```

### Token counts (from OTEL span metrics via spanmetrics connector)
```promql
# Total input tokens per minute, by model
sum by (gen_ai_request_model) (
  increase(ai_gateway_traces_spanmetrics_calls_total[1m])
)

# Output token rate (useful for cost estimation)
# Note: label name is sanitised from gen_ai.usage.output_tokens → gen_ai_usage_output_tokens
sum by (gen_ai_request_model) (
  rate(ai_gateway_traces_spanmetrics_calls_total[5m])
)
```

### Model fallback detection
```promql
# Rate of requests hitting the 3B fallback model
rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~".*qwen.*3b.*"}[5m])

# Rate of 14B errors (which trigger the fallback)
rate(envoy_cluster_upstream_rq_5xx{envoy_cluster_name=~".*qwen.*14b.*"}[5m])
```

### Rate limiting — requests being dropped
```promql
sum(rate(envoy_http_local_rate_limit_enabled[5m]))
```

### GPU memory pressure (KubeAI)
```promql
# % of memory limit used by KubeAI pods
(
  container_memory_working_set_bytes{namespace="kubeai"}
  /
  container_spec_memory_limit_bytes{namespace="kubeai"}
) * 100
```

### kagent agent request rate
```promql
# Requests per agent per minute
sum by (agent) (rate(kagent_agent_requests_total[1m]))
```

---

## ── LOKI QUERIES (Log Explorer) ──────────────────────────────────────────────

### All kagent controller logs
```logql
{service="kagent"}
```

### kagent errors only
```logql
{service="kagent", level="error"}
```

### kagent logs for a specific agent
```logql
{service="kagent"} | json | agent="sre-triage-agent"
```

### kgateway access logs — all AI requests
```logql
{service="kgateway"} |= "/openai/v1"
```

### kgateway — slow requests (>10s)
```logql
{service="kgateway"} | json | duration_ms > 10000
```

### kgateway — failed requests (4xx/5xx)
```logql
{service="kgateway"} | json | status >= 400
```

### kgateway — model fallback events (14B errors)
```logql
{service="kgateway"} | json | upstream_cluster=~".*14b.*" | status >= 500
```

### Prompt guard blocks (requests rejected by security policy)
```logql
{service="kgateway"} |= "Request blocked"
```

### Rate limit hits
```logql
{service="kgateway"} |= "rate_limited" or {service="kgateway"} | json | response_flags=~".*RL.*"
```

---

## ── TEMPO — TRACE QUERIES ────────────────────────────────────────────────────

In Grafana → Explore → Tempo:

### Find slow agent calls (>5s)
```
{ .gen_ai.request.model = "qwen2.5-14b" && duration > 5s }
```

### Trace with token counts
```
{ .gen_ai.usage.input_tokens > 0 }
```
Click any trace → expand spans → look for `ai.tokens.prompt` and `gen_ai.usage.*` attributes.

### Correlate trace → logs
From any Tempo trace, click "Logs for this span" → jumps to Loki with the trace_id filter.

---

## ── SUGGESTED DASHBOARD PANELS ─────────────────────────────────────────────

### AI Platform Overview dashboard

| Panel | Type | Query |
|-------|------|-------|
| Request rate | Timeseries | `sum(rate(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"kubeai.*"}[5m]))` |
| Error rate % | Gauge | `(sum(rate(5xx)) / sum(rate(total))) * 100` |
| p95 latency | Gauge | histogram_quantile query above |
| Active model (14B vs 3B) | Stat | compare 14B vs 3B cluster rates |
| Rate limit hits | Stat | `sum(rate(envoy_http_local_rate_limit_enabled[5m]))` |
| GPU memory | Gauge | container memory % query |
| Prompt guard blocks | Timeseries | Loki metric: `sum(rate({service="kgateway"} \|= "Request blocked" [5m]))` |
| Token usage / agent | Bar chart | spanmetrics token query grouped by agent |
| Recent errors | Logs panel | `{service="kagent", level="error"}` |
| kgateway access log | Logs panel | `{service="kgateway"} \|= "/openai/v1"` |

### Import a pre-built Envoy dashboard
Grafana dashboard ID **11022** (Envoy Proxy) — works with kgateway Envoy metrics:
```
Grafana → Dashboards → Import → Enter ID: 11022 → Select kube-prom datasource
```
