# AI Platform - Use Cases & Capabilities

## What This Is

An AI-powered SRE assistant deployed on a management cluster that gives engineers a conversational interface to investigate, triage, and remediate issues across Kubernetes environments. Instead of switching between terminals, dashboards, and runbooks, SRE talks to an agent that has direct access to cluster tooling.

## Proven Capabilities (PoC)

These have been tested and validated on the current deployment:

| Capability | What It Does | Proven |
|-----------|-------------|--------|
| Cluster health check | Agent queries all namespaces, finds unhealthy pods, reports issues | Yes |
| Pod log analysis | Agent pulls logs from specific pods and interprets error messages | Yes |
| Event correlation | Agent reads k8s events and connects them to root causes | Yes |
| Helm release inspection | Agent lists releases, checks status, identifies failed upgrades | Yes |
| Autonomous remediation | Agent patches resources to fix issues (e.g., scaling a StatefulSet back up) | Yes |
| Multi-tool reasoning | Agent chains multiple k8s queries together to build a diagnosis | Yes |
| A2A protocol | Agents expose a standard API for programmatic interaction | Yes |

---

## SRE Triage Use Cases

### 1. Incident First Response

**Scenario:** PagerDuty fires at 3am. SRE opens the kagent UI on their phone.

**Conversation:**
> "The payments service in prod is returning 500s. What's going on?"

**Agent actions:**
- Gets pods in the payments namespace, finds CrashLoopBackOff
- Pulls logs from the crashing pod, identifies OOMKilled
- Checks resource limits vs actual usage
- Reports: "The payments-api pod is being OOMKilled. Current memory limit is 512Mi but the pod was using 498Mi before crash. Recent deployment changed the batch size config which increased memory usage. Recommend increasing memory limit to 1Gi."

**Value:** Cuts mean-time-to-diagnose from 15-30 minutes of manual kubectl commands down to a single question.

### 2. Deployment Rollback Assistance

**Scenario:** A helm upgrade broke something in pre-prod.

**Conversation:**
> "The last helm upgrade of user-service in pre-prod seems broken. What changed and can you roll it back?"

**Agent actions:**
- Runs `helm_get_release` to see current vs previous revision
- Compares values between revisions
- Checks pod status and identifies the failure
- Reports the diff and offers to run `helm_upgrade` to the previous revision

**Value:** SRE doesn't need to remember helm rollback syntax or which revision was stable. The agent handles the investigation and execution.

### 3. Cross-Namespace Dependency Tracing

**Scenario:** An app is failing but the root cause is in a different namespace.

**Conversation:**
> "The frontend in dev is showing connection timeouts. Trace the dependency chain."

**Agent actions:**
- Checks frontend pods (Running, but logs show connection refused to backend-api:8080)
- Checks backend-api pods (Running, but logs show connection refused to postgres:5432)
- Checks postgres pods (CrashLoopBackOff - PVC full)
- Reports the full chain: frontend -> backend-api -> postgres (disk full)

**Value:** Follows the dependency chain across namespaces automatically, something that takes SRE multiple rounds of manual investigation.

### 4. Certificate and Secret Expiry Checks

**Scenario:** Proactive check before things break.

**Conversation:**
> "Check all TLS secrets across the prod cluster and flag anything expiring in the next 30 days."

**Agent actions:**
- Lists all secrets of type `kubernetes.io/tls` across namespaces
- Decodes and checks certificate expiry dates
- Reports a table of certs with their expiry status

**Value:** Prevents outages from expired certificates, a common cause of production incidents.

### 5. Resource Right-Sizing Analysis

**Scenario:** Cost optimization review.

**Conversation:**
> "Which deployments in the dev cluster are over-provisioned? Show me anything requesting more than 2x what it's actually using."

**Agent actions:**
- Gets resource requests/limits for all deployments
- Compares against actual usage from metrics
- Flags deployments where requests significantly exceed actual consumption
- Suggests right-sized values

**Value:** Helps optimize cluster costs without manual spreadsheet analysis.

---

## Multi-Cluster / Multi-Environment Use Cases

### 6. Environment Drift Detection

**Scenario:** Something works in dev but fails in pre-prod.

**Conversation:**
> "Compare the auth-service deployment between dev and pre-prod. What's different?"

**Agent actions (with multi-cluster access):**
- Gets deployment YAML from both clusters
- Diffs image tags, env vars, resource limits, configmaps
- Reports: "Image tag differs (dev: v2.3.1, pre-prod: v2.2.8). Environment variable AUTH_TIMEOUT is 30s in dev but 10s in pre-prod. ConfigMap auth-config has 3 additional keys in dev."

**Value:** Instantly identifies environment drift that would otherwise require manual YAML comparison across clusters.

### 7. Promotion Readiness Check

**Scenario:** Before promoting from pre-prod to prod.

**Conversation:**
> "Is the order-service in pre-prod ready for prod promotion? Check health, recent restarts, and any pending issues."

**Agent actions:**
- Checks pod health, restart count, uptime
- Reviews recent events for warnings
- Checks HPA scaling behaviour
- Verifies all dependencies are healthy
- Reports a promotion readiness summary

**Value:** Standardises the pre-promotion checklist that currently lives in someone's head or a wiki page.

### 8. Incident Correlation Across Environments

**Scenario:** The same issue is hitting multiple environments.

**Conversation:**
> "We're seeing intermittent 503s on the API gateway in both pre-prod and prod. Is there a common cause?"

**Agent actions:**
- Checks gateway pods and logs in both environments
- Identifies a common pattern (e.g., DNS resolution failures)
- Traces to a shared dependency (e.g., CoreDNS hitting resource limits)
- Reports the common root cause

**Value:** Correlates incidents across environments that would typically be investigated separately by different on-call engineers.

---

## Auto-Triage & Automation Use Cases

### 9. Automated Incident Classification

**Scenario:** Alert fires, agent auto-triages before SRE even looks.

**Flow:**
1. Alert webhook triggers agent via A2A API
2. Agent investigates automatically
3. Agent classifies severity: P1 (data loss risk), P2 (degraded), P3 (cosmetic), P4 (self-healing)
4. Agent posts findings to Slack/Teams with recommended actions
5. SRE reviews the pre-built diagnosis instead of starting from scratch

**Value:** Every alert arrives with context. SRE spends time fixing, not investigating.

### 10. Runbook Execution

**Scenario:** Known issues with documented fix procedures.

**Flow:**
1. Agent detects a known pattern (e.g., Kafka consumer lag > threshold)
2. Matches against a library of known issues and runbooks
3. Executes the runbook steps: check consumer group, verify broker connectivity, restart consumer pods if needed
4. Reports what it did and the result

**Value:** Codifies tribal knowledge into executable runbooks. New SREs get the same quality of response as senior engineers.

### 11. Scheduled Health Sweeps

**Scenario:** Daily cluster hygiene.

**Flow:**
1. Cron triggers agent every morning at 8am
2. Agent runs a comprehensive health check across all environments
3. Reports: pods not ready, failed jobs, PVC usage > 80%, certificates expiring soon, helm releases in failed state, nodes with high resource pressure
4. Posts summary to team channel

**Value:** Catches issues before they become incidents. Replaces manual morning checks.

### 12. Post-Incident Analysis

**Scenario:** After an incident is resolved, build the timeline.

**Conversation:**
> "Build a post-incident timeline for the outage on the payments service between 14:00 and 15:30 today."

**Agent actions:**
- Pulls events, pod status changes, and deployment events in the time window
- Correlates with helm releases and config changes
- Builds a chronological timeline of what changed and when
- Identifies the triggering change

**Value:** Automates the tedious part of post-incident reviews.

---

## Network & Gateway Use Cases

### 13. Ingress/Route Troubleshooting

**Scenario:** Traffic not reaching the right backend.

**Conversation:**
> "Requests to api.example.com/v2 are returning 404 but /v1 works fine. Check the gateway routing."

**Agent actions (kgateway-agent):**
- Lists HTTPRoutes and their path match rules
- Identifies that /v2 has no matching route or the route points to a non-existent service
- Checks if the backend service and pods exist
- Reports the misconfiguration and offers to apply a fix

**Value:** Gateway routing issues are notoriously hard to debug. The agent understands the Gateway API resource model.

### 14. Network Policy Audit

**Scenario:** Security review of network segmentation.

**Conversation:**
> "Which pods in the prod namespace can communicate with the database namespace? Are there any unintended paths?"

**Agent actions:**
- Lists NetworkPolicies in both namespaces
- Maps allowed ingress/egress rules
- Identifies pods that match policy selectors
- Flags any overly permissive rules (e.g., allow-all)

**Value:** Network policy auditing is complex and error-prone when done manually.

---

## Platform & Helm Use Cases

### 15. Chart Version Inventory

**Scenario:** Compliance check across environments.

**Conversation:**
> "List all helm releases across dev, pre-prod, and prod. Flag anything where the chart version differs between environments."

**Agent actions (helm-agent):**
- Lists releases in each cluster
- Compares chart versions and app versions
- Reports a matrix showing version alignment
- Flags drift

**Value:** Ensures environment parity for compliance and reduces "works on my cluster" issues.

### 16. Failed Job Investigation

**Scenario:** A CronJob is silently failing.

**Conversation:**
> "The nightly-backup CronJob in prod hasn't succeeded in 3 days. What's happening?"

**Agent actions:**
- Gets CronJob status and recent Job history
- Finds failed Jobs and pulls their pod logs
- Identifies the error (e.g., S3 bucket permission denied)
- Reports the root cause and when it started failing

**Value:** CronJob failures are often invisible until the thing they're supposed to do hasn't happened. The agent surfaces these proactively.

---

## Architecture: Management Cluster Deployment

```
                    +---------------------------+
                    |    Management Cluster      |
                    |                           |
                    |  +-------+  +---------+  |
                    |  |kagent |  |LiteLLM  |  |
                    |  |  UI   |  |  proxy  |  |
                    |  +-------+  +---------+  |
                    |       |          |        |
                    |  +----+----+-----+---+   |
                    |  |k8s-agent|helm-agt |   |
                    |  |gw-agent |         |   |
                    |  +---------+---------+   |
                    +---------------------------+
                       /       |        \
                      /        |         \
            +--------+   +----------+   +------+
            |  Dev   |   | Pre-Prod |   | Prod |
            |Cluster |   | Cluster  |   |Cluster|
            +--------+   +----------+   +------+
```

### Multi-Cluster Access Pattern

Each agent gets a kubeconfig with contexts for each environment cluster. The agent selects the right context based on the user's question. RBAC on each cluster controls what the agent can read and write per environment:

| Environment | Read Access | Write Access |
|------------|------------|-------------|
| Dev | Full | Full (patch, scale, delete) |
| Pre-Prod | Full | Limited (scale, restart pods) |
| Prod | Full | Read-only (investigate only, no changes without approval) |

This ensures the agent can investigate freely everywhere but can only auto-remediate in lower environments. Prod changes require human approval.

---

## What's Needed to Get There

| Capability | Current State | What's Needed |
|-----------|--------------|---------------|
| Single-cluster investigation | Working | Nothing - ready now |
| Single-cluster remediation | Working (14B model) | Larger model improves reliability |
| Multi-cluster access | Not yet | kubeconfig with multiple contexts, RBAC per cluster |
| Alert-triggered auto-triage | Not yet | Webhook endpoint, integration with alerting (PagerDuty/Alertmanager) |
| Slack/Teams integration | Not yet | Bot integration, agent API bridge |
| Scheduled health sweeps | Not yet | CronJob calling agent A2A API |
| Custom runbook library | Not yet | Knowledge base integration or fine-tuned prompts |
| Audit logging | Partial (LiteLLM tracks API usage) | Full audit trail of agent actions per user |

## Model Sizing Recommendations

| Model Size | Best For | Trade-offs |
|-----------|---------|-----------|
| 3B (Qwen 2.5) | Basic queries, pod status checks | Fast but halluccinates details, can't chain complex reasoning |
| 14B (Qwen 2.5) | Investigation + simple remediation | Good balance, fits on RTX 3060, handles multi-step tool use |
| 32B-70B | Complex multi-cluster reasoning, auto-triage | Needs A100/H100, significantly better tool use accuracy |
| Cloud API (Claude/GPT-4) | Maximum capability, complex runbooks | Requires network egress, cost per query, data governance considerations |

The platform supports swapping models without changing agent config - just update the ModelConfig CRD and agents restart with the new model.
