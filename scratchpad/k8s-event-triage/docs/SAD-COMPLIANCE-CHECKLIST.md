# SAD — Compliance & Sign-Off Checklist

Go/no-go checklist for stakeholders. Every item must be checked before the kagent triage platform is approved for production.

---

## 1. Audit Trail

- [ ] Every K8s Warning event that triggers a workflow is logged (Argo workflow history)
- [ ] Every KAgent A2A call is logged with request/response (KAgent controller logs → Loki)
- [ ] Every LLM call is logged with model, tokens, duration (LiteLLM logs → Loki/database)
- [ ] Every GitLab issue creation is logged with issue URL and HTTP status
- [ ] Every Teams notification is logged with HTTP status (Logic App Run History + workflow logs)
- [ ] Dedup decisions are logged ("DUPLICATE: skipped" or "NEW: recorded")
- [ ] Workflow execution history retained for minimum 30 days (Argo TTL + Loki retention)

## 2. Data Classification

| Data Category | Classification | Where It Flows | Stored Where |
|--------------|---------------|----------------|--------------|
| K8s event metadata (reason, message, pod name) | Internal | Worker → Event Hub → Management → LLM → GitLab/Teams | Argo logs, GitLab issues, Loki |
| LLM prompts (event context) | Internal | KAgent → LiteLLM → Azure OpenAI / on-prem | LiteLLM logs, Loki |
| LLM completions (diagnosis) | Internal | LLM → KAgent → GitLab issue + Teams card | GitLab issues, Teams messages, Loki |
| Azure SAS tokens | Confidential | K8s Secret → Alloy/EventSource env var | K8s etcd (encrypted at rest) |
| GitLab PAT | Confidential | K8s Secret → workflow pod env var | K8s etcd (encrypted at rest) |
| Logic App webhook URL | Confidential | K8s Secret → workflow pod env var | K8s etcd (encrypted at rest) |

- [ ] No confidential data is sent to the LLM
- [ ] No confidential data appears in workflow logs
- [ ] No confidential data is stored in GitLab issues

## 3. Secrets Management

- [ ] All secrets stored as K8s Secrets (not ConfigMaps, not in code)
- [ ] External Secrets Operator configured for Azure Key Vault sync (1h refresh)
- [ ] Secret rotation procedure documented (`docs/SECRET-ROTATION-RUNBOOK.md`)
- [ ] No secrets committed to Git (detect-secrets baseline in CI)
- [ ] SAS tokens follow least-privilege: Send-only (Alloy), Listen-only (EventSource)
- [ ] LiteLLM API key scoped to specific models (no admin access)
- [ ] GitLab PAT scoped to single project with `api` scope only

## 4. RBAC & Access Control

- [ ] All service accounts follow principle of least privilege
- [ ] Triage agents are **read-only** (no write verbs on k8s resources)
- [ ] Remediation agents require explicit `remediate=true` parameter
- [ ] No agent has ClusterRole with wildcard (`*`) verbs
- [ ] AKS-MCP UAMI is scoped to specific worker clusters (not subscription-wide)
- [ ] RBAC matrix documented and matches deployed state (`docs/SAD-LOGGING-MONITORING-AUTH.md` Section 2)
- [ ] Regular RBAC audit: `kubectl auth can-i` checks automated

## 5. Network Security

- [ ] All pipeline components are ClusterIP only (no external LoadBalancer/Ingress)
- [ ] NetworkPolicies enforce default-deny on `kagent`, `argo-events` namespaces
- [ ] Egress restricted: only known endpoints (Event Hub, GitLab, Logic App, LLM, K8s API)
- [ ] Event Hub connection uses TLS 1.2+
- [ ] No public endpoints for KAgent A2A protocol

## 6. LLM Data Privacy

- [ ] Only K8s event metadata sent to LLM (reason, message, pod name, namespace)
- [ ] No secrets, tokens, or config values in LLM prompts
- [ ] If Azure OpenAI: Data Processing Agreement (DPA) in place
- [ ] If Azure OpenAI: Customer data not used for model training
- [ ] If on-prem LLM: Data never leaves the cluster network
- [ ] LLM response truncated to 4000 chars before external notification (Teams)

## 7. Monitoring & Alerting

- [ ] Prometheus ServiceMonitors deployed for: Argo Workflows, Argo Events, LiteLLM, Alloy
- [ ] PrometheusRules deployed for critical alerts (failure rate, LLM errors, token anomalies)
- [ ] Grafana dashboards deployed: Pipeline Health, KAgent Ops, LLM Usage, Alloy Health
- [ ] KAgent logs visible in Grafana via Loki
- [ ] LLM token usage visible in Grafana
- [ ] Alert routing configured (AlertManager → notification channel)
- [ ] Health check script available for pipeline readiness verification

## 8. LLM Cost Controls

- [ ] Per-key rate limits configured in LiteLLM
- [ ] Per-model token budgets set (daily/monthly)
- [ ] Budget alerts configured: 70%, 90%, 100% thresholds
- [ ] Anomalous token usage alert configured (> 100k tokens/hour)
- [ ] Can answer: "How many tokens did we use this week, by model?"

## 9. Change Management

- [ ] All pipeline manifests stored in Git
- [ ] Changes require PR review before merge
- [ ] GitOps deployment (Flux or manual `kubectl apply` from repo)
- [ ] No `kubectl edit` or `kubectl patch` outside of emergency procedures
- [ ] Emergency change procedure documented

## 10. Incident Response

- [ ] Agent malfunction procedure: how to disable a sensor/agent without affecting others
- [ ] LLM outage procedure: workflow degrades gracefully (skips analysis, still creates GitLab + notification)
- [ ] Event Hub outage: management cluster triage stops; worker cluster local triage continues
- [ ] Runaway alert storm: dedup handles it; manual override: delete dedup ConfigMap or scale sensor to 0
- [ ] Escalation path documented

## 11. Data Retention

| Data | Retention | Location |
|------|-----------|----------|
| Argo workflow history | 30 days (TTL) | K8s (etcd) |
| Workflow pod logs | 30 days | Loki |
| KAgent logs | 30 days hot / 90 days cold | Loki |
| LiteLLM logs | 30 days | Loki / database |
| GitLab issues | Indefinite | GitLab |
| Teams messages | Per Teams retention policy | Microsoft 365 |
| Event Hub messages | 24 hours (default) | Azure Event Hub |
| Dedup ConfigMap | 24 hours per key (TTL) | K8s (etcd) |

- [ ] Retention policy reviewed with data governance team
- [ ] No PII in any retained data

---

## Sign-Off

| Role | Name | Date | Approved |
|------|------|------|----------|
| Platform Engineer | | | [ ] |
| Security Reviewer | | | [ ] |
| Data Governance | | | [ ] |
| Service Owner | | | [ ] |
