# SAD — Logging, Monitoring & LLM Token Governance

How the kagent triage platform is observed using the Grafana LGTM stack.

---

## 1. Logging (Loki)

All component logs are collected into Loki via the existing LGTM stack.

### What Goes to Loki

| Component | Namespace | What's Logged |
|-----------|-----------|---------------|
| KAgent controller + agents | `kagent` | Agent A2A requests, triage results, tool calls, errors |
| Argo Workflow pods | `argo-events` | Workflow step output: dedup decisions, KAgent responses, notification delivery status |
| LiteLLM proxy | `kagent` | Model calls, token counts, latency, errors |
| Argo Events controller | `argo-events` | Event processing, sensor triggers |

### Key Queries

```logql
# KAgent agent activity
{namespace="kagent"} | json

# Workflow triage results
{namespace="argo-events"} |= "Done:"

# LLM calls (model + tokens)
{namespace="kagent", container="litellm"} | json

# Dedup decisions
{namespace="argo-events"} |= "DUPLICATE" or |= "NEW:"

# Errors across the pipeline
{namespace=~"kagent|argo-events"} |= "error" or |= "Error" or |= "failed"
```

### What Is NOT Logged

Secrets, tokens, API keys, webhook URLs — all mounted as env vars from K8s Secrets, never printed in log output.

---

## 2. Monitoring (Prometheus + Grafana)

### Metrics by Component

**Argo Workflows**
- `argo_workflows_count` — active workflows by status
- `argo_workflow_status_phase` — outcome (Succeeded/Failed/Error)

**Argo Events**
- `argo_events_events_sent_total` — events processed by sensors
- `argo_events_events_processing_failed_total` — failures

**LiteLLM**
- `litellm_requests_total` — requests by model and status
- `litellm_tokens_total` — input/output tokens by model
- `litellm_request_duration_seconds` — latency histogram
- `litellm_errors_total` — failures by model

**Alloy (management cluster only)**
- `otelcol_exporter_sent_log_records_total` — events forwarded to Event Hub
- `otelcol_exporter_send_failed_log_records_total` — failed exports

### Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kagent-triage-alerts
  labels:
    release: kube-prom
spec:
  groups:
    - name: kagent-triage
      rules:
        - alert: KAgentTriageHighFailureRate
          expr: |
            sum(rate(argo_workflow_status_phase{phase="Failed"}[15m]))
            / sum(rate(argo_workflow_status_phase[15m])) > 0.2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Triage workflow failure rate > 20%"

        - alert: LiteLLMHighErrorRate
          expr: |
            sum(rate(litellm_errors_total[15m]))
            / sum(rate(litellm_requests_total[15m])) > 0.1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "LiteLLM error rate > 10%"

        - alert: LiteLLMHighLatency
          expr: histogram_quantile(0.95, rate(litellm_request_duration_seconds_bucket[15m])) > 30
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "LLM p95 latency > 30s"

        - alert: LiteLLMAnomalousTokenUsage
          expr: sum(rate(litellm_tokens_total[1h])) * 3600 > 100000
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Anomalous LLM token usage (> 100k/hour) — possible loop or prompt injection"
```

### Grafana Dashboards

| Dashboard | Key Panels |
|-----------|------------|
| **Pipeline Health** | Event flow rate, workflow success/fail, triage latency p95, dedup hit rate |
| **LLM Usage** | Tokens by model (input/output), latency p50/p95/p99, error rate, estimated cost |

---

## 3. LLM Token Governance

### Enabling LiteLLM Metrics

Add to LiteLLM Helm values:

```yaml
env:
  - name: LITELLM_LOG
    value: "True"
extraArgs:
  - "--telemetry"
  - "prometheus"
```

Create ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: litellm
  labels:
    release: kube-prom
spec:
  selector:
    matchLabels:
      app: litellm
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

### Cost Controls

| Control | How |
|---------|-----|
| Per-key rate limit | LiteLLM `max_parallel_requests` per API key |
| Per-model token budget | LiteLLM `max_budget` (daily) |
| Budget alerts | PrometheusRule at 70%, 90%, 100% of budget |
| Anomaly detection | Alert if > 100k tokens/hour sustained |

### Answering "How many tokens did we use?"

```promql
# Total tokens this week, by model
sum by (model) (increase(litellm_tokens_total[7d]))

# Input vs output tokens today
sum by (model, type) (increase(litellm_tokens_total[24h]))

# Estimated cost today (if using paid models)
sum(increase(litellm_spend_total[24h]))
```

### Data Privacy

| Data | Sent to LLM? |
|------|--------------|
| Event reason (`CrashLoopBackOff`) | Yes |
| Event message (`back-off restarting`) | Yes |
| Pod name, namespace | Yes |
| Secrets, tokens, API keys | **Never** |
| ConfigMap/Secret content | **Never** |

If using Azure OpenAI: customer data is not used for model training. Data processed in the selected Azure region.
