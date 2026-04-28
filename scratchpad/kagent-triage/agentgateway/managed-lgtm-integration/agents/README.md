# Agent Observability — kagent + agentgateway in managed LGTM

Companion to the parent `README.md`. Covers how the AI agent stack
(`kagent` workers + `agentgateway` proxy) is observed through the managed
LGTM, and what makes "agent anomaly" different from regular K8s workload
anomaly.

---

## What we already get for free from the parent design

| Signal | Source | Component | Lands in |
|--------|--------|-----------|----------|
| agentgateway envoy stats | PodMonitor in `ai-platform/agentgateway/monitoring.yaml` | `prometheus.operator.podmonitors` (snippet 01) | Mimir |
| agentgateway gen_ai token counters | same PodMonitor | same | Mimir |
| kagent controller request counters | ServiceMonitor in `ai-platform/agentgateway/monitoring.yaml` | `prometheus.operator.servicemonitors` (snippet 01) | Mimir |
| Pod logs (both namespaces) | kubelet | `loki.source.kubernetes` (snippet 02) | Loki |
| OTLP traces (if Helm `tracing.enabled=true`) | apps push OTLP | `otelcol.receiver.otlp` (snippet 03) | Tempo |
| Existing token-burn alert | mirrored in `../alerting/01-prometheusrules-platform.yaml` | `mimir.rules.kubernetes` (snippet 04) | Mimir Ruler → AM |

So *exposure* is covered. This file adds the **anomaly detection** layer on
top — alerts that catch behaviour the existing static-threshold alerts miss.

---

## Why agents need different alert thinking

A regular workload alert is shaped like *"latency > 1s for 5m"*. That works
poorly for agents because:

1. **Token usage is bursty by design.** A long planning task legitimately
   uses 50× more tokens than a quick triage. Static thresholds either fire
   constantly or miss real runaway loops.
2. **Latency is multi-modal.** A 60-second response is normal for deep
   reasoning, anomalous for a quick lookup. Single p95 threshold misses both.
3. **Failure modes are *semantic*.** A model can return a 200 OK with a
   useless answer ("I cannot help with that") that no HTTP-status-based
   alert catches.
4. **Loops are silent.** An agent calling the same tool 100 times still
   reports "success" — only the rate of identical calls reveals the loop.
5. **Cross-agent baselines matter.** One agent hot while others idle is the
   real anomaly signal, not absolute throughput.

The recipes in `03-agent-anomaly-rules.yaml` use **recording rules to
establish baselines** and **stddev / ratio tests to flag outliers** instead
of static thresholds wherever possible.

---

## What "anomalous agent behaviour" looks like

| Pattern | How we detect | Severity |
|---------|---------------|----------|
| Runaway token loop | tokens-per-minute > 5σ above rolling 1h baseline | warning → critical |
| Cost spike | $/agent/hour > 3× same-hour-yesterday baseline | warning |
| Tool-call loop | same `tool_name` called > 50×/min from one agent | warning |
| Hallucination signal | response length > 99th percentile of last 24h | info |
| Sudden cohort failure | agent error rate > 3× cohort median | critical |
| Latency outlier | p99/p50 ratio > 10 (long tail explosion) | warning |
| Silent failure | request rate > 0 AND success rate ≈ 0 for 15m | critical |
| Backend flap | upstream reset rate > 0.1/s sustained | warning |
| Model drift | output length distribution shifts by > 2σ over 24h | info |
| Auth/Quota anomaly | 429/403 rate from agentgateway > 5× baseline | warning |
| Cross-cluster fanout | one cluster suddenly dominates total traffic | info |

---

## Recording rules — the foundation

Anomaly alerts only work if you have a **baseline series** to compare against.
Recording rules pre-compute those baselines so alert evaluation stays fast.

The parent `monitoring.yaml` already has one recording rule
(`agentgateway:tokens_per_minute:rate1m`). `03-agent-anomaly-rules.yaml`
adds the rolling-baseline siblings:

```
agentgateway:tokens_per_minute:baseline_1h_avg   # 1h trailing average
agentgateway:tokens_per_minute:baseline_1h_stddev # 1h trailing stddev
agentgateway:tokens_per_minute:zscore             # current vs baseline
kagent:request_rate:baseline_1h_avg
kagent:error_rate:cohort_median
kagent:tool_calls:rate1m
kagent:response_length:p99_24h
```

Once those exist, anomaly alerts become trivial PromQL like
`agentgateway:tokens_per_minute:zscore > 5`.

---

## Triage payload enrichment

When an agent anomaly alert fires and goes through the Event Hub bridge,
the existing `alerts/workflow-template-alerts.yaml` workflow needs slightly
more context to give KAgent a useful prompt. Specifically, agent alerts
benefit from:

- The triggering query/session ID (if logged)
- Token counts for the past 5 / 30 / 60m
- Tool call distribution for the past 1h
- Concurrent agent activity (is the whole stack stressed or just this one?)

The workflow can fetch these via PromQL/LogQL queries against managed
Mimir/Loki *as part of triage*, not as part of the alert payload.
That keeps the alert payload small and the triage context rich.

See `04-triage-prompt-enrichment.md` for the prompt-engineering pattern.

---

## File index (this subdirectory)

```
agents/
├── README.md                          ← this file
├── 03-agent-anomaly-rules.yaml        ← recording + anomaly PrometheusRules + LokiRules
└── 04-triage-prompt-enrichment.md     ← how the triage workflow fetches context
```

Combine with the parent directory for the full picture:
- `../alloy-snippets/01-metrics-to-mimir.alloy` already discovers the
  agentgateway PodMonitor + kagent ServiceMonitor — no extra config needed
- `../alerting/01-prometheusrules-platform.yaml` has the static
  token-budget alert (kept; complements the anomaly rules here)
- `../dashboards/QUERIES.md` has the agentgateway/kagent query library

---

## Open questions specific to agent monitoring

Add these to the platform-team conversation:

- **Q11** Is there a session ID label we can put on every gen_ai metric so
  we can group anomalies by user/session, not just by agent?
- **Q12** Does the platform team allow recording rules in their Mimir, or do
  we have to evaluate baselines client-side in Alloy?
- **Q13** Cardinality budget for `gen_ai_request_model` × `agent` × `cluster`
  — how many concurrent agents can we run before we hit limits?
- **Q14** Tempo retention for traces — agent traces are huge (full LLM
  request body) but invaluable for "why did the agent loop?" debugging.
