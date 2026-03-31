# Implementation Tasks — Monitoring, Logging & Hardening

Handoff document for another agent or engineer to execute. Each task is independently executable unless dependencies are noted.

**Stack context:** Grafana LGTM (Loki, Grafana, Tempo, Mimir), Prometheus (`kube-prom` release), kagent v0.7+, LiteLLM, Argo Workflows + Events.

---

## Task 1: LiteLLM Prometheus Metrics (HIGH)

**Goal:** Expose LiteLLM metrics to Prometheus so we can track token usage, latency, and errors.

**Steps:**
1. Edit `ai-platform/config/litellm/litellm-values.yaml`:
   - Add env `LITELLM_LOG=True`
   - Enable Prometheus metrics endpoint (`/metrics` on port 4000)
2. Create `kagent-triage/monitoring/litellm-servicemonitor.yaml`:
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
3. Apply and verify: `curl <litellm-pod-ip>:4000/metrics | grep litellm_`
4. Check Prometheus targets page — LiteLLM should appear as UP

**Depends on:** LiteLLM deployed
**Verification:** `litellm_requests_total` metric visible in Prometheus

---

## Task 2: LiteLLM Grafana Dashboard (HIGH)

**Goal:** Dashboard showing token consumption, latency, errors, and cost by model.

**Steps:**
1. Create `kagent-triage/monitoring/litellm-dashboard.json` — Grafana dashboard JSON with panels:
   - Token consumption over time (input vs output, by model) — `sum by (model) (rate(litellm_tokens_total[5m]))`
   - Request latency p50/p95/p99 — `histogram_quantile(0.95, rate(litellm_request_duration_seconds_bucket[5m]))`
   - Request volume by model — `sum by (model) (rate(litellm_requests_total[5m]))`
   - Error rate — `sum(rate(litellm_errors_total[5m])) / sum(rate(litellm_requests_total[5m]))`
   - Estimated cost (if paid models) — `sum(litellm_spend_total)`
2. Deploy as ConfigMap with label `grafana_dashboard: "1"` (Grafana sidecar auto-import)
3. Verify in Grafana

**Depends on:** Task 1 (metrics available)
**Verification:** Dashboard loads in Grafana with live data

---

## Task 3: LiteLLM Cost Alerts (HIGH)

**Goal:** Alert on anomalous token usage, high error rate, and budget thresholds.

**Steps:**
1. Create `kagent-triage/monitoring/litellm-alerts.yaml` — PrometheusRule with:
   - `LiteLLMHighErrorRate`: error rate > 10% for 10min
   - `LiteLLMHighLatency`: p95 > 30s for 10min
   - `LiteLLMAnomalousTokenUsage`: > 100k tokens/hour for 5min
   - `LiteLLMBudget70`: spend > 70% of daily budget
   - `LiteLLMBudget90`: spend > 90% of daily budget
   - `LiteLLMPodNotReady`: LiteLLM pod not ready > 2min
2. Set label `release: kube-prom` on PrometheusRule
3. Apply and verify: `kubectl get prometheusrules -A | grep litellm`
4. Test: generate load against LiteLLM, verify alerts fire in AlertManager

**Depends on:** Task 1 (metrics available)
**Verification:** Alerts visible in AlertManager; fire on threshold breach

---

## Task 4: KAgent Log Collection (HIGH)

**Goal:** KAgent pod logs collected by Loki and queryable in Grafana.

**Steps:**
1. Verify KAgent pods output structured JSON logs:
   ```bash
   kubectl logs -n kagent -l app=kagent-controller --tail=5
   ```
2. Ensure the LGTM stack's log collector (Alloy or Promtail) is scraping the `kagent` namespace
   - If Alloy: verify `kagent` is in the namespace list for pod log collection
   - If Promtail: verify `kagent` is in `scrapeConfigs` namespace filter
3. Test in Grafana Explore → Loki:
   ```logql
   {namespace="kagent"}
   ```
4. Create saved LogQL queries:
   - All agent activity: `{namespace="kagent"} | json`
   - Specific agent: `{namespace="kagent", pod=~"kube-system-agent.*"}`
   - Errors only: `{namespace="kagent"} |= "error" or |= "Error"`

**Depends on:** LGTM stack deployed, kagent deployed
**Verification:** `{namespace="kagent"}` returns results in Grafana Explore

---

## Task 5: KAgent Grafana Dashboard (MEDIUM)

**Goal:** Dashboard showing agent activity, triage latency, and error rates.

**Steps:**
1. Create `kagent-triage/monitoring/kagent-dashboard.json` — Grafana dashboard with panels:
   - Agent activity timeline (Loki logs, table view) — `{namespace="kagent"} | json | line_format "{{.ts}} {{.agent}} {{.level}} {{.msg}}"`
   - Triage count by agent (bar chart) — count log lines per pod label
   - Error rate by agent — filter on `level="error"`
   - Pod restarts — `kube_pod_container_status_restarts_total{namespace="kagent"}`
2. Deploy as ConfigMap with Grafana sidecar label
3. Verify in Grafana

**Depends on:** Task 4 (logs in Loki)
**Verification:** Dashboard loads with log-based panels populated

---

## Task 6: KAgent Prometheus Metrics (MEDIUM)

**Goal:** Determine if kagent-controller exposes Prometheus metrics; if yes, scrape them.

**Steps:**
1. Check if kagent-controller has a `/metrics` endpoint:
   ```bash
   kubectl port-forward -n kagent svc/kagent-controller 8083:8083
   curl http://localhost:8083/metrics
   ```
2. If yes:
   - Create `kagent-triage/monitoring/kagent-servicemonitor.yaml`
   - Set label `release: kube-prom`
   - Apply and verify in Prometheus targets
3. If no: skip — rely on Loki logs for KAgent observability (Task 4/5)

**Depends on:** kagent deployed
**Verification:** Either ServiceMonitor scraping metrics, or documented that kagent does not expose metrics

---

## Task 7: Network Policies (MEDIUM)

**Goal:** Enforce network isolation on kagent, argo-events, and litellm namespaces.

**Steps:**
1. Create `kagent-triage/monitoring/network-policies.yaml` with:

   **kagent namespace:**
   - Default deny all ingress/egress
   - Allow ingress from `argo-events` (A2A calls from workflow pods)
   - Allow egress to K8s API (port 443)
   - Allow egress to LiteLLM service (port 4000)
   - Allow egress to kube-dns (port 53)

   **argo-events namespace:**
   - Default deny all ingress/egress
   - Allow egress to K8s API (port 443)
   - Allow egress to kagent (port 8083, A2A)
   - Allow egress to GitLab (port 443)
   - Allow egress to Logic App (port 443)
   - Allow egress to kube-dns (port 53)
   - Allow ingress from EventBus pods (NATS, same namespace)

   **litellm namespace (if separate):**
   - Default deny all ingress/egress
   - Allow ingress from kagent (LLM requests)
   - Allow egress to Azure OpenAI / on-prem LLM endpoint (port 443)
   - Allow egress to kube-dns (port 53)

2. Apply and test: verify workflows still complete end-to-end
3. Test negative: verify that unauthorized cross-namespace traffic is blocked

**Depends on:** CNI supports NetworkPolicy (Cilium, Calico, Azure NPM)
**Verification:** `kubectl get networkpolicies -A`; workflows still succeed; unauthorized traffic blocked

---

## Task 8: Pipeline Health Dashboard (MEDIUM)

**Goal:** Unified dashboard showing the entire triage pipeline health at a glance.

**Steps:**
1. Create `kagent-triage/monitoring/pipeline-health-dashboard.json` with panels:
   - **Event flow rate** — Alloy events forwarded (`otelcol_exporter_sent_log_records_total`)
   - **Workflow outcomes** — success/fail/error pie chart (`argo_workflow_status_phase`)
   - **Triage latency p95** — workflow duration histogram
   - **Active workflows** — current in-flight (`argo_workflows_count{status="Running"}`)
   - **Notification delivery** — GitLab + Logic App success rate (from Loki logs)
   - **Dedup hit rate** — count of "DUPLICATE" vs "NEW" in workflow logs (Loki)
   - **EventBus health** — NATS replica count
2. Deploy as ConfigMap with Grafana sidecar label
3. Verify in Grafana

**Depends on:** Prometheus scraping Argo + Alloy metrics
**Verification:** Dashboard loads; all panels have data

---

## Task 9: Argo Workflow Log Collection (LOW)

**Goal:** Workflow pod logs in Loki for debugging failed triage runs.

**Steps:**
1. Verify LGTM log collector scrapes `argo-events` namespace (same check as Task 4)
2. Test in Grafana Explore:
   ```logql
   {namespace="argo-events"} |= "CRITICAL"
   ```
3. Create saved queries:
   - Failed workflows: `{namespace="argo-events"} |= "error" |= "exit code"`
   - Triage results: `{namespace="argo-events"} |= "Done:"`
   - Dedup decisions: `{namespace="argo-events"} |= "DUPLICATE" or |= "NEW:"`

**Depends on:** LGTM stack scraping `argo-events` namespace
**Verification:** Workflow logs visible in Grafana

---

## Task 10: Secret Rotation Runbook (LOW)

**Goal:** Document how to rotate every secret in the pipeline.

**Steps:**
1. Create `kagent-triage/docs/SECRET-ROTATION-RUNBOOK.md` with procedures for:

   | Secret | Rotation Method |
   |--------|----------------|
   | Event Hub SAS | Regenerate in Azure Portal → update Key Vault → ESO syncs in 1h |
   | GitLab PAT | Generate new PAT in GitLab → update Key Vault → ESO syncs |
   | Logic App webhook URL | Regenerate via `listCallbackUrl` → update K8s secret |
   | LiteLLM API key | Rotate in provider (Azure OpenAI / API key) → update Key Vault → ESO syncs |
   | Telegram bot token | Regenerate via BotFather → update Key Vault → ESO syncs |

2. Include emergency manual rotation (bypass ESO):
   ```bash
   kubectl create secret generic <name> --from-literal=key=<value> -n <ns> --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Include verification steps for each rotation

**Depends on:** Nothing
**Verification:** Follow each procedure end-to-end on a test secret

---

## Summary

| # | Task | Priority | Depends On | Estimated Effort |
|---|------|----------|------------|-----------------|
| 1 | LiteLLM Prometheus Metrics | HIGH | LiteLLM deployed | 1-2h |
| 2 | LiteLLM Grafana Dashboard | HIGH | Task 1 | 2-3h |
| 3 | LiteLLM Cost Alerts | HIGH | Task 1 | 1-2h |
| 4 | KAgent Log Collection | HIGH | LGTM stack | 1h |
| 5 | KAgent Grafana Dashboard | MEDIUM | Task 4 | 2-3h |
| 6 | KAgent Prometheus Metrics | MEDIUM | kagent deployed | 30min |
| 7 | Network Policies | MEDIUM | CNI support | 2-3h |
| 8 | Pipeline Health Dashboard | MEDIUM | Prometheus | 2-3h |
| 9 | Argo Workflow Log Collection | LOW | LGTM stack | 30min |
| 10 | Secret Rotation Runbook | LOW | Nothing | 1-2h |
