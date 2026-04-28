# GitLab Issue Body — copy/paste

Title: `[Platform] Integrate managed LGTM (Loki/Grafana/Tempo/Mimir) into K8s event triage pipeline`

Labels: `platform`, `observability`, `lgtm`, `triage`, `design-review`

---

## Background

We have access to a managed LGTM service via Alloy. We do not have direct API
access to Mimir / Loki / Grafana / Tempo — Alloy is our only integration handle.

We need to extend the existing K8s event triage pipeline
(`aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline`) so that
**Prometheus and Loki alerts firing inside the managed stack** are routed
through the same Event Hub → Argo Events → KAgent → Mattermost flow we already
operate for K8s events.

## Goals

1. Push application metrics, pod logs, K8s events, and OTLP traces from our
   clusters into the managed Mimir / Loki / Tempo via Alloy.
2. Provision Grafana dashboards as code (or via UI export to repo if platform
   doesn't support GitOps).
3. Manage alert rules (PromQL + LogQL) via GitOps in our application repo,
   synced to the managed Mimir/Loki Ruler API by Alloy.
4. Bridge fired alerts back into our triage system via Event Hub Kafka, so
   AI-driven triage runs over alerts the same way it runs over K8s events
   today.

## Proposed design

Full design lives in `aks-mgmt-stack/k8s-event-triage/managed-lgtm-integration/README.md`
(branch: `main-clean`). High-level:

```
Cluster → Alloy → Managed Mimir/Loki/Tempo
                        │
            (rules synced via mimir.rules.kubernetes /
             loki.rules.kubernetes from PrometheusRule
             + LokiRule CRDs in this repo)
                        │
              Managed AlertManager fires
                        │
                webhook → Alloy receiver
                        │
            otelcol.exporter.kafka → Event Hub
                        │
       Argo Events Kafka EventSource (new consumer group)
                        │
        Sensor → WorkflowTemplate alert-triage
                        │
              KAgent A2A → Mattermost / GitLab
```

The new code/YAML proposal:

| File | Purpose |
|------|---------|
| `managed-lgtm-integration/README.md` | Design doc — read this first |
| `managed-lgtm-integration/OPEN-QUESTIONS.md` | Q1–Q10 for platform team — needs answers before we build |
| `managed-lgtm-integration/alloy-snippets/00-common-labels.alloy` | Label conventions across signals |
| `managed-lgtm-integration/alloy-snippets/01-metrics-to-mimir.alloy` | ServiceMonitor/PodMonitor scrape → remote_write |
| `managed-lgtm-integration/alloy-snippets/02-logs-to-loki.alloy` | Pod logs + k8s events → Loki |
| `managed-lgtm-integration/alloy-snippets/03-traces-to-tempo.alloy` | OTLP receiver → Tempo |
| `managed-lgtm-integration/alloy-snippets/04-rule-sync.alloy` | PrometheusRule + LokiRule CRDs → managed Ruler |
| `managed-lgtm-integration/alloy-snippets/05-alertmanager-webhook-bridge.alloy` | AM webhook → Kafka producer |
| `managed-lgtm-integration/alerting/01-prometheusrules-platform.yaml` | Example metric alerts |
| `managed-lgtm-integration/alerting/02-lokirules-platform.yaml` | Example log alerts |
| `managed-lgtm-integration/alerts/workflow-template-alerts.yaml` | Argo WorkflowTemplate that triages alerts |
| `managed-lgtm-integration/agents/README.md` | Agent-specific anomaly detection rationale (kagent + agentgateway) |
| `managed-lgtm-integration/agents/03-agent-anomaly-rules.yaml` | Recording rules + z-score / cohort alerts for agent anomalies |
| `managed-lgtm-integration/agents/04-triage-prompt-enrichment.md` | Enrich KAgent triage prompt with managed-LGTM query context |
| `managed-lgtm-integration/dashboards/QUERIES.md` | Curated PromQL/LogQL recipes |

## Open questions for platform team

These block implementation. Each is detailed in `OPEN-QUESTIONS.md`:

- **Q1** Mimir push endpoint, auth, tenant ID
- **Q2** Loki push endpoint, auth, tenant ID
- **Q3** Rule provisioning model (Alloy CRD sync vs central repo PRs)
- **Q4** **THE BIG ONE**: how do alerts cross the network back to us?
- **Q5** Grafana dashboard provisioning model
- **Q6** Tempo endpoint + sampling policy
- **Q7** Cardinality / cost guardrails
- **Q8** Multi-cluster naming convention
- **Q9** Existing dashboards/alerts to inherit
- **Q10** Outage / drill plan (managed LGTM down)

## Non-goals (this issue)

- Replacing kube-prometheus-stack on the cluster — it stays for local Grafana
  + AlertManager fallback.
- Changing the existing K8s event triage pipeline — the new alert pipeline is
  a sibling, not a replacement.
- Onboarding new app teams — we pilot with `agentgateway-system` and `kagent`
  first.

## Acceptance criteria

- [ ] Q1–Q5 answered by platform team
- [ ] Alloy snippets reviewed by platform team for endpoint correctness
- [ ] Rule CRDs land in managed Mimir Ruler within 5m of `kubectl apply`
- [ ] AlertManager test alert fires → arrives in Event Hub topic `alerts`
      within 30s
- [ ] Existing triage workflow handles the alert payload end-to-end
      (KAgent analysis + Mattermost message)
- [ ] Pilot rollout on `agentgateway-system` namespace only — no cluster-wide
      activation until pilot is green for 1 week
- [ ] Runbook entry in `managed-lgtm-integration/README.md` for "managed LGTM
      is down — what now?"

## Tracking

- Design PR: (link MR here once opened)
- Pilot dashboard: (link Grafana folder here once provisioned)
- Mattermost test channel: `#triage-alerts-pilot`

/cc @platform-team @ai-platform-team

---

## How to file this in GitLab

```bash
# From the repo root, with the gitlab CLI:
glab issue create \
  --title "[Platform] Integrate managed LGTM into K8s event triage pipeline" \
  --label "platform,observability,lgtm,triage,design-review" \
  --description "$(cat aks-mgmt-stack/k8s-event-triage/managed-lgtm-integration/GITLAB-ISSUE.md | sed -n '/^## Background/,$p')" \
  --assignee @me

# Or via API if you don't have glab:
TOKEN=$(kubectl get secret gitlab-token -n argo -o jsonpath='{.data.token}' | base64 -d)
PROJECT_ID="<numeric_project_id>"

curl --request POST "https://gitlab.example.com/api/v4/projects/${PROJECT_ID}/issues" \
  --header "PRIVATE-TOKEN: ${TOKEN}" \
  --form "title=[Platform] Integrate managed LGTM into K8s event triage pipeline" \
  --form "labels=platform,observability,lgtm,triage,design-review" \
  --form "description=$(awk '/^## Background/{flag=1} flag' aks-mgmt-stack/k8s-event-triage/managed-lgtm-integration/GITLAB-ISSUE.md)"
```
