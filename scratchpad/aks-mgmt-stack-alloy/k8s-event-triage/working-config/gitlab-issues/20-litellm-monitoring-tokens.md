<!--
Labels: observability, llm, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# LiteLLM monitoring — token usage, latency, and cost tracking

## Context

LiteLLM is the proxy layer routing LLM requests to models (Ollama/qwen, OpenAI, etc.). We need to track token consumption, latency, and cost to manage spend and detect anomalies.

## Tasks

### LiteLLM Built-in Monitoring
- [ ] Enable LiteLLM's built-in usage tracking (`LITELLM_LOG=True` or database logging)
- [ ] Configure LiteLLM to log to a database (Postgres or SQLite) for usage queries
- [ ] Set up LiteLLM's `/spend/logs` API endpoint for usage reporting
- [ ] Configure per-model and per-key spend limits if needed

### Prometheus Metrics
- [ ] Enable LiteLLM Prometheus metrics endpoint (`/metrics`)
- [ ] Create ServiceMonitor for LiteLLM namespace
- [ ] Key metrics:
  - `litellm_requests_total` — total requests by model, status
  - `litellm_tokens_total` — input/output tokens by model
  - `litellm_request_duration_seconds` — latency histogram
  - `litellm_errors_total` — failures by model, error type
  - `litellm_spend_total` — estimated cost (if using paid models)

### Grafana Dashboard
- [ ] Create "LLM Usage" dashboard:
  - Token consumption over time (input vs output, by model)
  - Request latency (p50, p95, p99)
  - Request volume by model
  - Error rate
  - Estimated cost (if applicable)
  - Top consumers (by API key or workflow)

### Alerting
- [ ] Alert: token usage > X per hour (anomaly detection — potential prompt injection or loop)
- [ ] Alert: error rate > 10% in 15min window
- [ ] Alert: p95 latency > 30s (model overloaded)
- [ ] Alert: LiteLLM pod not ready for > 2 minutes

### Cost Controls
- [ ] Set per-key rate limits in LiteLLM config
- [ ] Set per-model token budget (daily/monthly)
- [ ] Configure alerts when approaching budget thresholds (70%, 90%, 100%)

## Acceptance Criteria

- [ ] Token usage visible in Grafana
- [ ] Can answer: "How many tokens did we use this week, by model?"
- [ ] Alerts fire on anomalous usage
- [ ] Budget controls prevent runaway spend
