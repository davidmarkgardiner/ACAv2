<!--
Labels: observability, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
Depends on: #6
-->

# Set up monitoring, health checks, and Azure Monitor alerts

## Context

The pipeline needs observability to detect failures quickly. See `PRODUCTION-PLAN.md` Section 4.

## Tasks

### Kubernetes Monitoring
- [ ] Create PrometheusRule for pod readiness (EventSource, Sensor, EventBus, Ollama)
- [ ] Create PrometheusRule for workflow failure rate (< 90% success in 15min window)
- [ ] Create PrometheusRule for workflow duration p95 (> 120s)
- [ ] Add health check script to repo (see PRODUCTION-PLAN.md Section 4.2)

### Azure Monitor
- [ ] Configure alert: Event Hub `IncomingMessages < 1` over 30min (Alloy stopped)
- [ ] Configure alert: Event Hub `ActiveConnections == 0` (EventSource disconnected)
- [ ] Configure alert: Event Hub consumer lag > 1000 messages

### Alloy Metrics
- [ ] Verify Alloy exposes metrics at `:12345/metrics`
- [ ] Add Grafana dashboard for Alloy pipeline metrics
- [ ] Track `otelcol_exporter_send_failed_log_records_total` — alert if non-zero

### Grafana Dashboard
- [ ] Create dashboard: pipeline health (EventBus, EventSource, Sensor, Ollama pod status)
- [ ] Create dashboard: workflow outcomes (success/fail rate, duration histogram)
- [ ] Create dashboard: Event Hub lag and throughput

## Acceptance Criteria

- [ ] Alerts fire within 5 minutes of component failure
- [ ] Grafana dashboard shows pipeline health at a glance
- [ ] Health check script runs clean on a healthy pipeline
