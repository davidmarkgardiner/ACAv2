<!--
Labels: observability, kagent, k8s-event-triage
Milestone: KAgent — Agent Onboarding
Assignee:
-->

# KAgent logging and observability via LGTM stack

## Context

We need to track what KAgent is doing — every triage and remediation action should be observable. We have an LGTM stack (Loki, Grafana, Tempo, Mimir) available.

## Tasks

### KAgent Logs → Loki
- [ ] Identify KAgent log output format (structured JSON or plain text)
- [ ] Configure log collection for `kagent` namespace pods
  - If using Alloy: add `kagent` to the Alloy scrape targets (NOT the event triage Alloy — use the general logging Alloy or add a separate pipeline)
  - If using Promtail/Fluent Bit: add namespace filter
- [ ] Ensure KAgent pods have structured logging enabled (JSON format preferred)
- [ ] Create Loki log query for KAgent activity:
  ```logql
  {namespace="kagent"} | json | line_format "{{.agent}} {{.action}} {{.namespace}} {{.resource}}"
  ```
- [ ] Create Grafana dashboard panel: KAgent activity log (filterable by agent, namespace, action)

### KAgent Traces → Tempo (if supported)
- [ ] Check if KAgent supports OpenTelemetry tracing
- [ ] If yes: configure OTLP exporter to Tempo endpoint
- [ ] Create trace visualization for triage → remediation flow

### KAgent Metrics
- [ ] Identify if KAgent exposes Prometheus metrics
- [ ] If yes: create ServiceMonitor for kagent namespace
- [ ] Key metrics to track:
  - Triage requests per agent per namespace
  - Triage duration (p50, p95, p99)
  - Remediation actions taken (by type)
  - Agent errors / failures

### Grafana Dashboard
- [ ] Create "KAgent Operations" dashboard:
  - Agent activity timeline (logs)
  - Triage latency histogram
  - Actions taken by type (bar chart)
  - Error rate

## Acceptance Criteria

- [ ] KAgent logs visible in Grafana via Loki
- [ ] Grafana dashboard shows agent activity
- [ ] Can trace a triage event from K8s event → workflow → agent action
