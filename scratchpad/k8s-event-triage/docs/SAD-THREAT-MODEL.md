# SAD — Threat Model (STRIDE Analysis)

STRIDE threat analysis for the K8s Event Triage Platform. Each threat includes description, likelihood, impact, existing mitigations, and verification procedure.

Reference: `kagent-triage/architecture-hybrid-triage.excalidraw` for trust boundaries.

---

## Trust Boundaries

| Boundary | Components | Transport |
|----------|-----------|-----------|
| **TB1** Worker cluster → Event Hub | Alloy → Azure Event Hub | Kafka/TLS 1.2+ (SAS auth) |
| **TB2** Event Hub → Management cluster | Event Hub → EventSource | Kafka/TLS 1.2+ (SAS auth) |
| **TB3** Workflow → KAgent | Workflow pod → KAgent controller | HTTP (in-cluster, ClusterIP) |
| **TB4** KAgent → LLM | KAgent → LiteLLM → AI service | HTTP in-cluster + HTTPS to cloud |
| **TB5** Workflow → External APIs | Workflow → GitLab, Logic App | HTTPS (token/webhook auth) |
| **TB6** Management KAgent → Worker cluster | AKS-MCP (UAMI) → Worker K8s API | HTTPS (Azure AD token) |

---

## STRIDE Analysis

### S — Spoofing

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| S1: Fake events injected into Event Hub | Attacker sends crafted events to trigger malicious triage | Low | Medium | SAS tokens with **Send-only** policy on Alloy; **Listen-only** on EventSource. No component has Manage policy. | `az eventhubs namespace authorization-rule list` — verify no Manage keys distributed |
| S2: Spoofed A2A requests to KAgent | Attacker calls KAgent A2A endpoint to trigger actions | Very Low | High | KAgent controller is **ClusterIP only** — no external network path. NetworkPolicy restricts ingress to `argo-events` namespace only. | `kubectl get svc -n kagent` — verify ClusterIP; `kubectl get networkpolicy -n kagent` |
| S3: Forged GitLab tokens | Attacker uses stolen PAT to create misleading issues | Low | Low | Token stored as K8s Secret; RBAC limits who can read secrets; token scoped to single project with `api` scope only. | `kubectl auth can-i get secrets -n argo-events --as=system:serviceaccount:default:default` — should be denied |

### T — Tampering

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| T1: Event modified in transit | MITM on Event Hub connection | Very Low | Medium | TLS 1.2+ enforced on Event Hub Kafka endpoint. Azure-managed encryption at rest. | `openssl s_client -connect <eventhub>.servicebus.windows.net:9093` — verify TLS |
| T2: Dedup cache poisoned | Attacker patches the dedup ConfigMap to suppress alerts | Low | High | ConfigMap write requires RBAC on `argo-events-sa` SA; no external access to cluster API. | `kubectl auth can-i patch configmaps -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa` |
| T3: Agent routing tampered | Routing table (jq function or ConfigMap) modified to misroute events | Low | Medium | Routing is in the WorkflowTemplate (code) or ConfigMap; changes require `kubectl apply` or GitOps PR. | Review GitOps change history; restrict write access to argo-events namespace |

### R — Repudiation

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| R1: Agent action without audit trail | KAgent takes remediation action with no record | Low | High | All A2A calls logged in KAgent controller. All workflow executions stored in Argo history. LiteLLM logs all prompts/completions. | Check Loki: `{namespace="kagent"}`, Argo UI workflow history |
| R2: GitLab issue deleted | Someone deletes auto-created triage issues | Low | Low | GitLab audit log tracks issue deletions. Issues labeled `auto-generated` for filtering. | GitLab project audit events |
| R3: Teams notification not delivered | Logic App silently fails, no record | Medium | Low | Workflow logs HTTP status code from Logic App. Logic App has Run History in Azure Portal. | Check workflow logs for `Logic App: HTTP`; Azure Portal → Logic App → Run History |

### I — Information Disclosure

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| I1: Secrets leaked to LLM | K8s secrets sent in LLM prompt | Very Low | Critical | Events contain only reason, message, pod name, namespace — no secret values. Agent prompts reference resources by name, never fetch secret content. | Review workflow template `create-conversation` step — verify no secret data in prompt |
| I2: LLM responses contain sensitive data | LLM hallucinates or recalls sensitive data | Very Low | Medium | Using private/enterprise LLM (Azure OpenAI) with no training on customer data. On-prem models (Ollama) never leave the cluster. | Verify Azure OpenAI DPA; check LiteLLM config for model endpoints |
| I3: Workflow logs expose tokens | Secrets logged in workflow pod output | Low | High | All secrets mounted as env vars from K8s Secrets, not passed as workflow parameters. Workflow scripts reference `$GITLAB_TOKEN` etc. without printing values. | Review workflow template — grep for `echo.*TOKEN` or `echo.*SECRET` |
| I4: GitLab issues contain cluster internals | Triage results expose internal architecture | Medium | Low | By design — GitLab issues contain pod names, namespace names, event messages. These are operational data, not secrets. Access controlled by GitLab project permissions. | Review GitLab project access settings |

### D — Denial of Service

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| D1: Event storm overwhelms pipeline | Massive event volume (e.g., node failure causing hundreds of pod crashes) | Medium | Medium | **3-layer dedup**: Alloy drops count>1 events + 10/s rate limit; Sensor rate limit 5/min; Script-based dedup with 24h TTL strips ReplicaSet hashes. | Inject 100 events rapidly; verify only 5 workflows created per minute |
| D2: LLM overloaded | Too many concurrent triage requests | Medium | Medium | LiteLLM per-key rate limits (`max_parallel_requests`). Argo workflow `activeDeadlineSeconds: 900`. Workflow retry limit: 1. | Check LiteLLM config for rate limits; submit 20 workflows simultaneously |
| D3: Event Hub quota exhausted | Too many events forwarded by Alloy | Low | Medium | Event Hub Standard tier has 1MB/s ingress. Alloy `stage.limit` caps at 10/s. | Monitor `otelcol_exporter_send_failed_log_records_total` metric |
| D4: GitLab API rate limited | Too many issue creation requests | Low | Low | Dedup prevents duplicate issues (same event = same issue within 24h). GitLab rate limit is 300 requests/min for PAT. | Monitor workflow logs for `GitLab HTTP: 429` |

### E — Elevation of Privilege

| Threat | Description | Likelihood | Impact | Mitigation | Verification |
|--------|-------------|------------|--------|------------|--------------|
| E1: Agent escapes namespace scope | Triage agent accesses resources outside its target namespace | Low | High | Agents use namespace-scoped RBAC (Role, not ClusterRole). Agent system prompts contain `CRITICAL: always use exact namespace "X"`. Tool server enforces namespace via API. | `kubectl get rolebindings -n kagent -o yaml` — verify no ClusterRoleBindings for agent SAs |
| E2: Remediation agent makes destructive changes | Agent deletes critical resources during remediation | Low | Critical | Triage agents are **read-only** by default. Remediation agents require explicit `remediate=true` parameter. Agent prompts include safety rules (never delete CRDs, never restart all replicas). | Review agent YAML — verify tool list is read-only for triage agents |
| E3: AKS-MCP escalation | Management cluster's UAMI gains more Azure RBAC than intended | Low | Critical | UAMI scoped to specific AKS clusters via Azure role assignments. FIC bound to specific service account + namespace. | `az role assignment list --assignee <UAMI_CLIENT_ID>` — verify scope is per-cluster, not subscription-wide |
| E4: Workflow pod escapes sandbox | Workflow script breaks out of container | Very Low | Critical | Workflow pods run as non-root. No `hostPID`, `hostNetwork`, or `privileged`. Pod security standards enforced by AKS. | `kubectl get pods -n argo-events -o jsonpath='{.items[*].spec.securityContext}'` |

---

## Risk Summary

| Risk Level | Count | Threats |
|------------|-------|---------|
| **Critical** (unmitigated) | 0 | — |
| **High** (mitigated) | 4 | S2, R1, E1, E2 |
| **Medium** (mitigated) | 8 | S1, T1, T2, T3, D1, D2, I3, E3 |
| **Low** (acceptable) | 6 | S3, R2, R3, D3, D4, I4 |

All high and critical threats have existing mitigations in place. No unmitigated high-severity risks.

---

## Appendix: Verification Commands

```bash
# Verify no external services exposed
kubectl get svc -A -o wide | grep -v ClusterIP

# Verify RBAC — agent SAs should NOT have cluster-wide write
kubectl auth can-i create pods --all-namespaces --as=system:serviceaccount:kagent:kagent-controller

# Verify network policies exist
kubectl get networkpolicies -A

# Verify secrets not readable by default SA
kubectl auth can-i get secrets -n argo-events --as=system:serviceaccount:default:default

# Verify Event Hub SAS policies
az eventhubs namespace authorization-rule list --namespace-name <EH_NS> --resource-group <RG>

# Verify UAMI scope
az role assignment list --assignee <UAMI_CLIENT_ID> --output table
```
