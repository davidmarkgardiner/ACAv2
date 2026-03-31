# SAD — Logging, Monitoring, Authentication & LLM Governance

Supplementary SAD section for the K8s Event Triage Platform. Covers the four operational pillars required for production sign-off. Read alongside the main SAD (`working-config/gitlab-issues/26-sad-architecture-document.md`).

---

## 1. Logging Architecture

### 1.1 Log Sources

| Component | Namespace | Log Format | Destination | Retention |
|-----------|-----------|------------|-------------|-----------|
| KAgent controller | `kagent` | JSON (structured) | Loki | 30d hot / 90d cold |
| KAgent agent pods | `kagent` | JSON (structured) | Loki | 30d hot / 90d cold |
| Argo Workflow pods | `argo-events` | Plain text (script output) | Loki | 30d hot / 90d cold |
| Argo Events controller | `argo-events` | JSON | Loki | 30d hot / 90d cold |
| LiteLLM proxy | `kagent` or `litellm` | JSON | Loki + database | 30d hot / 90d cold |
| Alloy | `monitoring` | JSON | Loki | 14d |
| EventBus (NATS) | `argo-events` | Plain text | Loki | 14d |

### 1.2 What Is Logged

| Data | Logged | Notes |
|------|--------|-------|
| K8s event text (reason, message) | Yes | Core diagnostic input |
| Pod names, namespace names | Yes | Required for triage |
| Agent A2A requests/responses | Yes | Via KAgent controller logs |
| LLM prompts and completions | Yes (LiteLLM) | Enable `LITELLM_LOG=True` or database logging |
| Token counts per request | Yes (LiteLLM) | Via `/spend/logs` API and Prometheus metrics |
| Workflow step outcomes | Yes (Argo) | Stored in workflow status + pod logs |
| GitLab issue URLs | Yes | Logged in workflow output |
| Teams/notification delivery status | Yes | HTTP status codes logged in workflow |

### 1.3 What Is NOT Logged

| Data | Why |
|------|-----|
| K8s Secrets content | Never sent to LLM; not in event payloads |
| Azure SAS tokens | Mounted as secrets, not logged |
| GitLab personal access tokens | Env var from secret, not in log output |
| Logic App webhook URLs | Env var from secret, not in log output |
| LiteLLM API keys | Masked in LiteLLM logs by default |

### 1.4 Log Collection Method

Logs are collected by the existing LGTM stack. KAgent and Argo Events namespaces must be included in the Loki collection scope.

**If using Grafana Alloy for log collection:**
```yaml
# Add kagent and argo-events to Alloy's log scrape targets
loki.source.kubernetes "pod_logs" {
  targets = discovery.kubernetes.pods.targets
  forward_to = [loki.write.default.receiver]
}
```

**If using Promtail:**
```yaml
# Ensure namespace filter includes kagent and argo-events
scrapeConfigs:
  - job_name: kagent
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [kagent, argo-events]
```

### 1.5 Key LogQL Queries

```logql
# KAgent agent activity (all agents)
{namespace="kagent"} | json | line_format "{{.level}} {{.msg}}"

# Specific agent triage output
{namespace="kagent", pod=~"kube-system-agent.*"}

# Argo workflow step logs (triage results)
{namespace="argo-events"} |= "KAgent" |= "CRITICAL"

# LiteLLM request logs (token usage)
{namespace="kagent", container="litellm"} | json | line_format "model={{.model}} tokens={{.usage.total_tokens}}"

# Failed notifications
{namespace="argo-events"} |= "Logic App" |= "error"
```

---

## 2. Authentication & Authorization

### 2.1 RBAC Matrix

#### Management Cluster

| Service Account | Namespace | Role/ClusterRole | Resources | Verbs | Purpose |
|----------------|-----------|-----------------|-----------|-------|---------|
| `argo-events-sa` | `argo-events` | Role: `sensor-workflow-creator` | workflows, workflowtemplates | create, get, list, watch | Sensor triggers workflows |
| `argo-events-sa` | `argo-events` | Role: `workflow-executor` | workflowtaskresults | create, patch, get, list, watch | Workflow pod step execution |
| `argo-events-sa` | `argo-events` | ClusterRole: `argo-events-triage-role` | pods, pods/log, events | get, list, watch | Read-only diagnostics |
| `aks-mcp` | `aks-mcp` | ClusterRole: `aks-mcp-admin` | pods, deployments, services, etc. | all verbs | Cross-cluster kubectl (management only) |
| `argo-events-sa` | `argo-events` | ClusterRole: `argo-memoize-configmaps` | configmaps | create, update | Dedup cache (ConfigMap-based) |

#### Worker Cluster

| Service Account | Namespace | Role/ClusterRole | Resources | Verbs | Purpose |
|----------------|-----------|-----------------|-----------|-------|---------|
| `argo-events-sa` | `argo-events` | Role: `sensor-workflow-creator` | workflows, workflowtemplates | create, get, list, watch | Sensor triggers workflows |
| `argo-events-sa` | `argo-events` | Role: `workflow-executor` | workflowtaskresults | create, patch, get, list, watch | Workflow pod step execution |
| kagent tool-server SA | `kagent` | ClusterRole (read-only) | pods, pods/log, events, deployments, services | get, list, watch | Local K8s diagnostics |

### 2.2 Identity & Authentication

| Component | Auth Method | Identity Source | Scope |
|-----------|------------|-----------------|-------|
| KAgent (management) | AKS-MCP + UAMI | User Assigned Managed Identity | Cross-cluster kubectl to worker clusters |
| KAgent (worker) | kagent-tool-server | K8s ServiceAccount token | Local cluster only |
| Alloy → Event Hub | SASL/PLAIN | SAS token (Send-only policy) | Event Hub topic write |
| EventSource → Event Hub | SASL/PLAIN | SAS token (Listen-only policy) | Event Hub topic read |
| Workflow → GitLab | PRIVATE-TOKEN header | K8s Secret `gitlab-token` | GitLab API issue creation |
| Workflow → Logic App | Webhook URL with SAS | K8s Secret `logic-app-webhook-secret` | Logic App HTTP trigger |
| Workflow → LiteLLM | API key | K8s Secret `litellm-key` | LLM proxy (ClusterIP) |

### 2.3 Secrets Inventory

| Secret Name | Namespace | Keys | Rotation | Source |
|-------------|-----------|------|----------|--------|
| `eventhub-credentials` | `argo-events` | `username`, `connection-string` | ESO 1h refresh / manual | Azure Key Vault |
| `gitlab-token` | `argo-events` | `GITLAB_TOKEN`, `url`, `project-id` | Manual (PAT expiry) | Azure Key Vault |
| `logic-app-webhook-secret` | `argo-events` | `url` | Regenerate via `listCallbackUrl` | Azure Portal |
| `litellm-key` | `kagent` | `api-key` | Per provider policy | Azure Key Vault |
| `telegram-bot-secret` | `argo-events` | `token` | Manual | Azure Key Vault |
| `eventhub-tls-ca` | `argo-events` | `ca.pem` | Azure-managed (public CA) | `openssl s_client` extraction |

### 2.4 Network Security

All pipeline components are **ClusterIP only** — no external ingress.

| Source | Destination | Protocol | Port | Policy |
|--------|-------------|----------|------|--------|
| Sensor pod | Argo API | HTTPS | 443 | Allow (workflow creation) |
| Workflow pod | KAgent controller | HTTP | 8083 | Allow (A2A protocol) |
| KAgent agent | LiteLLM proxy | HTTP | 4000 | Allow (LLM calls) |
| LiteLLM proxy | Azure OpenAI / on-prem | HTTPS | 443 | Allow (egress to LLM) |
| Workflow pod | GitLab API | HTTPS | 443 | Allow (issue creation) |
| Workflow pod | Logic App | HTTPS | 443 | Allow (Teams notification) |
| Workflow pod | K8s API | HTTPS | 443 | Allow (dedup ConfigMap) |
| Alloy | Event Hub | Kafka/TLS | 9093 | Allow (event forwarding) |
| All other | All other | * | * | **Deny** (NetworkPolicy default-deny) |

---

## 3. Monitoring & Alerting

### 3.1 Prometheus Metrics by Component

#### Argo Workflows
| Metric | Type | Description |
|--------|------|-------------|
| `argo_workflows_count` | Gauge | Active workflows by status |
| `argo_workflows_pods_count` | Gauge | Workflow pods by phase |
| `argo_workflow_status_phase` | Gauge | Workflow outcome (Succeeded/Failed/Error) |

#### Argo Events
| Metric | Type | Description |
|--------|------|-------------|
| `argo_events_event_processing_duration_milliseconds` | Histogram | Event processing latency |
| `argo_events_events_sent_total` | Counter | Events forwarded by sensor |
| `argo_events_events_processing_failed_total` | Counter | Processing failures |

#### LiteLLM (requires enabling `/metrics` endpoint)
| Metric | Type | Description |
|--------|------|-------------|
| `litellm_requests_total` | Counter | Total requests by model, status |
| `litellm_tokens_total` | Counter | Input/output tokens by model |
| `litellm_request_duration_seconds` | Histogram | Request latency |
| `litellm_errors_total` | Counter | Failures by model, error type |
| `litellm_spend_total` | Counter | Estimated cost (paid models) |

#### Alloy
| Metric | Type | Description |
|--------|------|-------------|
| `loki_source_kubernetes_events_entries_total` | Counter | Events received from K8s API |
| `otelcol_exporter_sent_log_records_total` | Counter | Events exported to Event Hub |
| `otelcol_exporter_send_failed_log_records_total` | Counter | Failed exports |

### 3.2 Critical Alerts (PrometheusRule)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kagent-triage-alerts
  labels:
    release: kube-prom  # Match your Prometheus label selector
spec:
  groups:
    - name: kagent-triage
      rules:
        # Workflow failure rate > 20%
        - alert: KAgentTriageHighFailureRate
          expr: |
            sum(rate(argo_workflow_status_phase{phase="Failed",workflowtemplate=~"kagent-triage|k8s-triage-critical"}[15m]))
            / sum(rate(argo_workflow_status_phase{workflowtemplate=~"kagent-triage|k8s-triage-critical"}[15m]))
            > 0.2
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "KAgent triage workflow failure rate > 20%"

        # LiteLLM error rate > 10%
        - alert: LiteLLMHighErrorRate
          expr: |
            sum(rate(litellm_errors_total[15m]))
            / sum(rate(litellm_requests_total[15m]))
            > 0.1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "LiteLLM error rate > 10%"

        # LiteLLM p95 latency > 30s
        - alert: LiteLLMHighLatency
          expr: histogram_quantile(0.95, rate(litellm_request_duration_seconds_bucket[15m])) > 30
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "LiteLLM p95 latency > 30s (model may be overloaded)"

        # Anomalous token usage (> 100k tokens/hour)
        - alert: LiteLLMAnomalousTokenUsage
          expr: sum(rate(litellm_tokens_total[1h])) * 3600 > 100000
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Anomalous LLM token usage — potential loop or prompt injection"

        # Alloy export failures
        - alert: AlloyExportFailures
          expr: rate(otelcol_exporter_send_failed_log_records_total[5m]) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Alloy failing to export events to Event Hub"

        # EventBus (NATS) not ready
        - alert: EventBusNotReady
          expr: kube_statefulset_status_replicas_ready{statefulset=~"eventbus-default-stan.*"} < 3
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Argo Events NATS EventBus < 3 replicas ready"
```

### 3.3 Grafana Dashboards

| Dashboard | Panels | Data Source |
|-----------|--------|-------------|
| **Pipeline Health** | Event flow rate, workflow outcomes (success/fail/error), triage latency p50/p95, notification delivery rate | Prometheus |
| **KAgent Operations** | Agent activity timeline, triage count by agent, duration histogram, error rate by agent | Loki + Prometheus |
| **LLM Usage** | Token consumption by model (input/output), request latency p50/p95/p99, error rate, estimated cost, top consumers | Prometheus |
| **Alloy Health** | Events forwarded/failed, Kafka export rate, Event Hub lag | Prometheus |

---

## 4. LLM Token Tracking & Cost Controls

### 4.1 Enabling LiteLLM Metrics

Add to LiteLLM Helm values (`ai-platform/config/litellm/litellm-values.yaml`):

```yaml
env:
  - name: LITELLM_LOG
    value: "True"
  - name: STORE_MODEL_IN_DB
    value: "True"

# Enable Prometheus metrics
extraArgs:
  - "--telemetry"
  - "prometheus"

service:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "4000"
    prometheus.io/path: "/metrics"
```

Create a ServiceMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: litellm
  namespace: kagent
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

### 4.2 Cost Controls

| Control | Configuration | Threshold |
|---------|---------------|-----------|
| Per-key rate limit | LiteLLM `max_parallel_requests` per key | 10 concurrent |
| Per-model token budget | LiteLLM `max_budget` per model (daily) | Configurable per model |
| Budget alerts | PrometheusRule on `litellm_spend_total` | 70%, 90%, 100% |
| Anomaly detection | PrometheusRule on `litellm_tokens_total` rate | > 100k tokens/hour |

### 4.3 Data Privacy — What Reaches the LLM

| Data Sent | Example | Sensitive? |
|-----------|---------|-----------|
| K8s event reason | `CrashLoopBackOff` | No |
| K8s event message | `back-off restarting failed container` | No |
| Pod name | `coredns-5dd5756b68-m2jk` | No |
| Namespace | `kube-system` | No |
| Resource kind | `Pod`, `Deployment` | No |

**NOT sent to LLM:**
- Secret values, tokens, API keys
- ConfigMap data content
- Environment variable values
- Azure subscription IDs or resource IDs
- User identities or email addresses

### 4.4 Azure OpenAI Compliance (if applicable)

| Requirement | Status |
|-------------|--------|
| Data residency | Azure OpenAI processes data in the selected region |
| Data Processing Agreement (DPA) | Covered by Microsoft DPA |
| Data retention by Azure OpenAI | No training on customer data; 30-day abuse monitoring log |
| Private endpoint | Recommended for production (avoids public internet) |

---

## Appendix: Related Documents

| Document | Location |
|----------|----------|
| Main SAD (architecture) | `working-config/gitlab-issues/26-sad-architecture-document.md` |
| Threat Model | `kagent-triage/docs/SAD-THREAT-MODEL.md` |
| Compliance Checklist | `kagent-triage/docs/SAD-COMPLIANCE-CHECKLIST.md` |
| Implementation Tasks | `kagent-triage/docs/IMPLEMENTATION-TASKS.md` |
| Architecture Diagram | `kagent-triage/architecture-hybrid-triage.excalidraw` |
