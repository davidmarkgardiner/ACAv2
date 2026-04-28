# Managed LGTM Integration — Design Proposal

**Status:** DRAFT — for review by platform team
**Owner:** David Gardiner
**Date:** 2026-04-28
**Context:** We have access to a managed LGTM (Loki, Grafana, Tempo, Mimir) service via Alloy. We do **not** have direct API access to Mimir / Loki / Grafana / Tempo. Alloy is the only ingress/egress point we control.

---

## Problem statement

Our existing K8s event triage pipeline (`../eventhub-otlp-pipeline`) consumes events from Azure Event Hub and routes them through Argo Events → KAgent → Mattermost. We want to extend that pipeline to also be **driven by Prometheus / Loki alerts** that fire inside the managed LGTM stack — without requiring API access to Mimir or Loki themselves.

The four questions we need to answer:

1. **Push** — How do we get the right metrics, logs, and traces *into* the managed Mimir/Loki/Tempo endpoints when Alloy is our only handle?
2. **Visualise** — How do we query that data back out (build dashboards, search logs)?
3. **Alert** — How do we configure alert rules on metrics and log patterns when we don't own the Mimir/Loki Ruler API?
4. **Triage loop** — How do we pipe those fired alerts back into our triage system (Argo Events / Event Hub / Kafka)?

This document proposes a design for each, lists the example YAML in this directory, and captures open questions for the platform team in `OPEN-QUESTIONS.md`.

---

## Architecture proposal

```
                                                                                    ┌────────────────────┐
                                                                                    │ Managed LGTM       │
  Worker / Mgmt cluster                                                             │ (platform team)    │
 ┌───────────────────────────────────────────────────────────────────────┐          │                    │
 │                                                                       │          │  ┌──────────────┐  │
 │   ┌─────────────────────────┐    metrics (remote_write)               │          │  │   Mimir      │  │
 │   │ kube-prometheus-stack   │──┐                                      │          │  │   (TSDB)     │  │
 │   │ (PrometheusRule CRDs)   │  │                                      │          │  └──────┬───────┘  │
 │   └─────────────────────────┘  │                                      │          │         │ Ruler   │
 │   ┌─────────────────────────┐  │                                      │          │         ▼         │
 │   │ pod logs                │──┤                                      │          │  ┌──────────────┐  │
 │   │ k8s events              │──┤                                      │          │  │ AlertManager │  │
 │   └─────────────────────────┘  │                                      │          │  │  (managed)   │  │
 │   ┌─────────────────────────┐  │       ┌─────────────────────────┐   │  HTTPS   │  └──────┬───────┘  │
 │   │ OTLP traces (apps)      │──┼──────▶│  Alloy (in-cluster)     │───┼─────────▶│         │ webhook  │
 │   └─────────────────────────┘  │       │                         │   │          │         │          │
 │   ┌─────────────────────────┐  │       │  prometheus.remote_write│   │          │  ┌──────▼───────┐  │
 │   │ LokiRule CRDs           │──┘       │  loki.write             │   │          │  │   Loki       │  │
 │   │ PrometheusRule CRDs     │──────────▶  mimir.rules.kubernetes │   │          │  │   (logs)     │  │
 │   └─────────────────────────┘          │  loki.rules.kubernetes  │   │          │  └──────────────┘  │
 │                                        │  otelcol.exporter.otlp  │   │          │  ┌──────────────┐  │
 │   ┌─────────────────────────┐          │  prometheus.receive_http│◀──┼──────────│──│   Tempo      │  │
 │   │ Alert webhook bridge    │◀─────────┤                         │   │          │  │   (traces)   │  │
 │   │ (Alloy → Kafka)         │          └─────────────────────────┘   │          │  └──────────────┘  │
 │   └────────────┬────────────┘                                        │          │  ┌──────────────┐  │
 │                │                                                     │          │  │   Grafana    │  │
 │                │  otelcol.exporter.kafka (otlp_json)                 │          │  │  (dashboards)│  │
 │                ▼                                                     │          │  └──────────────┘  │
 │       ┌────────────────────┐                                         │          └────────────────────┘
 │       │ Azure Event Hub    │
 │       │ topic: alerts      │  ◀── (existing) k8s-events topic also lives here
 │       └─────────┬──────────┘
 │                 │
 │       ┌─────────▼──────────┐
 │       │ Argo Events        │
 │       │ Kafka EventSource  │     (re-uses ../eventhub-otlp-pipeline)
 │       │  → Sensor          │
 │       │  → KAgent A2A      │
 │       │  → Mattermost      │
 │       └────────────────────┘
 └───────────────────────────────────────────────────────────────────────┘
```

The key insight: **Alloy is bidirectional**. It can push *to* the managed stack (metrics/logs/traces/rules) and also receive callbacks *from* it (AlertManager webhook → `prometheus.receive_http` or a custom HTTP receiver) and republish to Kafka — closing the loop without needing Mimir/Loki API access.

---

## 1. Push the right data into managed LGTM

We control the Alloy config, so we use it as our single egress point.

| Signal | Alloy components | Endpoint type | Example |
|--------|------------------|---------------|---------|
| Metrics | `prometheus.operator.podmonitors`, `prometheus.operator.servicemonitors`, `prometheus.scrape` → `prometheus.remote_write` | Mimir `/api/v1/push` | `alloy-snippets/01-metrics-to-mimir.alloy` |
| Logs (pods) | `loki.source.kubernetes` → `loki.process` → `loki.write` | Loki `/loki/api/v1/push` | `alloy-snippets/02-logs-to-loki.alloy` |
| Logs (events) | `loki.source.kubernetes_events` → `loki.write` | Loki `/loki/api/v1/push` | `alloy-snippets/02-logs-to-loki.alloy` |
| Traces | `otelcol.receiver.otlp` → `otelcol.processor.batch` → `otelcol.exporter.otlp` | Tempo OTLP gRPC :4317 | `alloy-snippets/03-traces-to-tempo.alloy` |

The dashboards/datasources work *because* Alloy populates the managed backends with consistent labels (`cluster`, `environment`, `namespace`, `service`). Rule of thumb: every signal must carry `cluster=<name>` so cross-signal correlation in Grafana works.

See `alloy-snippets/00-common-labels.alloy` for the label conventions we propose.

---

## 2. Visualise — dashboards & log search

Two paths depending on what the platform team gives us:

**Path A — Use the managed Grafana UI directly**
- Platform team registers Mimir / Loki / Tempo as datasources in their Grafana
- We build dashboards in the UI, export JSON, store in Git for versioning
- Folder per team / per service for RBAC scoping
- We commit the JSON to `dashboards/` here so it's reviewable

**Path B — Provision dashboards from our cluster**
- If managed Grafana supports the [sidecar pattern](https://github.com/grafana/helm-charts/tree/main/charts/grafana#sidecar-for-dashboards) or the Grafana Operator's `GrafanaDashboard` CRD across clusters
- We label a `ConfigMap grafana_dashboard=1` and let the sidecar pull it
- Cleaner GitOps story, but depends on platform support — see `OPEN-QUESTIONS.md`

**Examples shipped here:**
- `dashboards/agentgateway-token-budget.json` — re-implements the PromQL recipes in `ai-platform/agentgateway/monitoring.yaml` against managed Mimir
- `dashboards/k8s-event-triage-pipeline.json` — pipeline health (Argo Events lag, sensor errors, workflow success rate)

For log search we don't need anything pre-built — engineers use Grafana Explore against the Loki datasource. We document the standard `LogQL` queries in `dashboards/QUERIES.md`.

---

## 3. Alerting on logs and metrics

Without Mimir/Loki API access, the only sustainable way to manage alert rules is **GitOps via Alloy's rule-sync components**. Alloy has two components designed exactly for this:

- `mimir.rules.kubernetes` — watches `PrometheusRule` CRs in the cluster and pushes them to the Mimir Ruler API on our behalf, using a token Alloy holds
- `loki.rules.kubernetes` — same idea for `LokiRule` CRs against the Loki Ruler API

This means:
1. We write `PrometheusRule` and `LokiRule` YAML in this repo (just like `prometheus-alerting/02-custom-alerting-rules.yaml`)
2. We `kubectl apply` them to a labelled namespace
3. Alloy syncs them up to the managed Ruler, which evaluates them and routes to the managed AlertManager

Examples:
- `alerting/01-prometheusrules-platform.yaml` — metric alerts (5xx rate, latency, token burn, OOM, restart loops)
- `alerting/02-lokirules-platform.yaml` — log alerts (error patterns, panic strings, security events)
- `alloy-snippets/04-rule-sync.alloy` — the Alloy snippet that wires CRDs → managed Ruler

**Open question:** Does the platform team grant us a Ruler API token, or do they want us to PR rules into a central repo they own? See `OPEN-QUESTIONS.md` Q3.

---

## 4. Loop fired alerts back into the triage system

The managed AlertManager fires; we want those firings to land in our existing Event Hub topic so the existing `eventhub-otlp-pipeline` pulls them in just like K8s events.

**Proposed bridge: Alloy as AlertManager webhook receiver → Kafka producer.**

```
Managed AlertManager
   │  webhook_configs:
   │    url: https://<our-public-endpoint>/alerts
   ▼
Alloy `prometheus.receive_http` (custom AM webhook handler)
   │
   ▼  convert to OTLP log envelope (single record per alert)
otelcol.processor.batch
   │
   ▼
otelcol.exporter.kafka  → Event Hub topic: alerts
   │
   ▼
Existing Argo Events Kafka EventSource (new consumer group: consumer-alerts)
   │
   ▼
Sensor → Workflow (parse-otlp same jq pattern) → KAgent A2A → Mattermost / GitLab
```

Why Alloy and not a bespoke service:
- We already operate Alloy — no new component to deploy
- Same OTLP envelope shape as the existing K8s-events pipeline → existing `parse-otlp` jq step works with minor field changes
- Same Kafka auth path, same Event Hub topic family → no new Azure resources, no new RBAC

Example: `alloy-snippets/05-alertmanager-webhook-bridge.alloy`

**Triage workflow reuse:** the existing `eventhub-otlp-pipeline` workflow template gets a sibling — `alerts/workflow-template-alerts.yaml` — that swaps the K8s-event-specific jq filter for an alert-specific one (alertname / severity / instance / runbook_url).

**Network path:** AlertManager lives in the managed network. Two options to reach Alloy in our cluster:
1. Expose Alloy via an ingress (TLS + token auth)
2. Have the platform team forward to a queue endpoint we own (Event Hub direct? Service Bus? webhook URL?)

See `OPEN-QUESTIONS.md` Q4 — this is the biggest unknown.

---

## File index

```
managed-lgtm-integration/
├── README.md                                      ← this file
├── OPEN-QUESTIONS.md                              ← unresolved items for platform team
├── GITLAB-ISSUE.md                                ← pre-formatted ticket body
│
├── alloy-snippets/
│   ├── 00-common-labels.alloy                     ← label conventions
│   ├── 01-metrics-to-mimir.alloy                  ← scrape + remote_write
│   ├── 02-logs-to-loki.alloy                      ← pod logs + k8s events → Loki
│   ├── 03-traces-to-tempo.alloy                   ← OTLP receiver → Tempo
│   ├── 04-rule-sync.alloy                         ← CRD sync to managed Rulers
│   └── 05-alertmanager-webhook-bridge.alloy       ← AM webhook → Kafka
│
├── alerting/
│   ├── 01-prometheusrules-platform.yaml           ← example metric alerts
│   └── 02-lokirules-platform.yaml                 ← example log alerts
│
├── alerts/
│   └── workflow-template-alerts.yaml              ← Argo Workflow that triages alerts
│
├── agents/                                        ← agent-specific anomaly detection
│   ├── README.md                                  ←   why agents need different alerting
│   ├── 03-agent-anomaly-rules.yaml                ←   recording rules + z-score / cohort alerts
│   └── 04-triage-prompt-enrichment.md             ←   enrich KAgent prompt with LGTM context
│
└── dashboards/
    ├── QUERIES.md                                 ← curated PromQL/LogQL queries
    ├── agentgateway-token-budget.json             ← Grafana dashboard
    └── k8s-event-triage-pipeline.json             ← Grafana dashboard
```

---

## Next steps

1. Walk this design through with the platform team using the questions in `OPEN-QUESTIONS.md`
2. Convert this directory into a GitLab issue using `GITLAB-ISSUE.md` so progress is tracked publicly
3. Once Q1–Q5 in `OPEN-QUESTIONS.md` are answered, fork this design into the platform-team-confirmed implementation under `managed-lgtm-integration/CONFIRMED/`
4. Pilot on **one** namespace before any cluster-wide rollout — re-uses the same phased pattern from `eventhub-otlp-pipeline/PHASED-ROLLOUT.md`
