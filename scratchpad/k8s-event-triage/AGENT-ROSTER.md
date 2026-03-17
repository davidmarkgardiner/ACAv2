# KAgent Agent Roster

Specialist agents for the K8s Event Triage system. Each agent handles a specific domain — events are routed to agents via the `agent-routing` ConfigMap (namespace or reason matching).

---

## Current Agents

| Agent | Mode | Purpose |
|-------|------|---------|
| `sre-triage-agent` | Read-only | General-purpose investigation and root cause analysis |
| `sre-remediation-agent` | Read-write | General-purpose auto-fix (patch, scale, restart) |

---

## Proposed Specialist Agents

### 1. Certificate Management — `cert-manager-agent`

**Owner:** Platform team

**What it looks after:**
Everything TLS — certificates, issuers, ACME challenges, and secret rotation. This agent is the first responder when any certificate-related issue hits the cluster. Certificate failures cascade fast (ingress stops serving HTTPS, mTLS breaks between services, webhooks fail validation), so this agent needs to diagnose quickly and provide actionable next steps.

**Reactive — responds to events:**
- Certificate renewal failures → check issuer config, ACME challenge status, DNS propagation
- `CrashLoopBackOff` on cert-manager pods → check resource limits, webhook connectivity, leader election
- ACME challenge stuck in `pending` → verify HTTP-01 solver ingress or DNS-01 provider credentials
- `FailedSync` on Certificate resources → check issuer reference, secret permissions, rate limits
- TLS secret missing or expired → identify which certificates depend on it, check renewal schedule

**Proactive — scheduled checks (CronWorkflow, daily):**
- Scan all Certificate resources for expiry within 14 days — flag any that cert-manager isn't renewing
- Check all Issuers/ClusterIssuers are in Ready state
- Verify ACME account registration is valid (not revoked)
- Audit TLS secrets for certificates not managed by cert-manager (manually created, risk of silent expiry)
- Check cert-manager controller logs for repeated errors that haven't triggered K8s Warning events yet
- Verify webhook certificate is valid (cert-manager's own webhook uses a self-signed cert that can expire)

**Tools needed:**
- `kubectl` (read-only): describe certificates, issuers, clusterissuers, challenges, orders, certificaterequests, secrets
- cert-manager `cmctl` or API for status checks
- DNS lookup tools for ACME DNS-01 validation

**Routes to:** namespaces `cert-manager`, `cert-utils-operator`

```json
{"cert-manager": "cert-manager-agent", "cert-utils-operator": "cert-manager-agent"}
```

---

### 2. Network — `network-agent`

**Owner:** Network/Platform team

**What it looks after:**
All network connectivity — ingress, egress, service mesh, CNI, load balancers, and network policies. When pods can't talk to each other, services return 502s, or new pods fail to get an IP, this agent investigates. Network issues are the hardest to debug manually because they span multiple layers (CNI, kube-proxy, iptables, cloud LB, DNS), so this agent needs deep knowledge of the networking stack.

**Reactive — responds to events:**
- `FailedCreatePodSandBox` → check CNI plugin health, IP address exhaustion, node network readiness
- `NetworkNotReady` → check CNI DaemonSet, node annotations, cloud networking (VNet/subnet)
- Ingress controller `CrashLoopBackOff` → check config validity, backend service health, resource limits
- `Unhealthy` on service endpoints → check pod readiness probes, network policies blocking health checks
- LoadBalancer `FailedCreate` → check cloud provider quota, subnet space, NSG rules
- Service mesh sidecar injection failures → check webhook config, namespace labels, istio-proxy resource limits

**Proactive — scheduled checks (CronWorkflow, twice daily):**
- Check all ingress resources have healthy backends (no ingress pointing to 0 ready endpoints)
- Verify NetworkPolicy coverage — flag namespaces without a default-deny policy
- Check for orphaned Services (no matching pods/endpoints)
- Verify CoreDNS is healthy and responsive (run test lookups)
- Check CNI DaemonSet is running on all nodes (no missing pods)
- Audit ingress TLS — flag any ingress using HTTP without TLS termination
- Check for port conflicts on NodePort services
- Verify cloud load balancer health probes match actual pod readiness probes

**Tools needed:**
- `kubectl` (read-only): describe ingress, services, endpoints, endpointslices, networkpolicies, pods, nodes
- Network diagnostic tools: `nslookup`, `curl`, `wget` for connectivity tests
- Istio CLI: `istioctl analyze` (if service mesh deployed)
- CNI-specific tools: `cilium status`, `calicoctl node status`

**Routes to:** namespaces `ingress-nginx`, `traefik`, `istio-system`, `cilium-system`, `calico-system`; reasons `FailedCreatePodSandBox`, `NetworkNotReady`

```json
namespace-routes: {"ingress-nginx": "network-agent", "istio-system": "network-agent", "calico-system": "network-agent", "cilium-system": "network-agent"}
reason-routes: {"FailedCreatePodSandBox": "network-agent", "NetworkNotReady": "network-agent"}
```

---

### 3. Storage — `storage-agent`

**Owner:** Platform/Infrastructure team

**What it looks after:**
Persistent storage — PVs, PVCs, CSI drivers, storage classes, volume snapshots, and the underlying storage backend (Longhorn, Azure Disk, Azure Files, Ceph). Storage issues block deployments and cause data loss, so this agent needs to understand the full chain from pod → PVC → PV → CSI driver → cloud disk.

**Reactive — responds to events:**
- `FailedMount` → check PVC status, PV binding, node affinity, fsGroup permissions, CSI driver health
- `FailedAttachVolume` → check if disk is attached to another node (common after node failure), check cloud provider limits
- `ProvisioningFailed` → check storage class exists, CSI driver is running, cloud quota not exceeded
- `VolumeResizeFailed` → check if storage class allows expansion, CSI driver supports resize
- Longhorn volume `Degraded`/`Faulted` → check replica health, node disk space, network between nodes
- `CrashLoopBackOff` on CSI driver pods → check node plugin DaemonSet, controller deployment

**Proactive — scheduled checks (CronWorkflow, daily):**
- Scan all PVCs for usage >80% capacity — flag before they hit 100% and cause pod crashes
- Check for PVCs in `Pending` state for >5 minutes (stuck provisioning)
- Verify all CSI driver DaemonSets are running on every node
- Check for orphaned PVs (Released but not reclaimed)
- Audit storage classes — flag any using `Delete` reclaim policy on production namespaces
- Check Longhorn/Ceph cluster health (degraded volumes, rebuilding replicas)
- Verify volume snapshot schedules are completing successfully
- Check for pods using `emptyDir` with large sizeLimit (risk of node disk pressure)

**Tools needed:**
- `kubectl` (read-only): describe pv, pvc, storageclass, volumeattachments, csinodes, csidrivers
- Longhorn API: `kubectl get volumes.longhorn.io`, `kubectl get replicas.longhorn.io`
- Azure CLI: disk status, IOPS metrics (if AKS)

**Routes to:** namespaces `longhorn-system`, `rook-ceph`, `azuredisk-csi`, `azurefile-csi`; reasons `FailedMount`, `FailedAttachVolume`, `ProvisioningFailed`

```json
namespace-routes: {"longhorn-system": "storage-agent", "rook-ceph": "storage-agent"}
reason-routes: {"FailedMount": "storage-agent", "FailedAttachVolume": "storage-agent", "ProvisioningFailed": "storage-agent"}
```

---

### 4. Security — `security-agent`

**Owner:** Security/Platform team

**What it looks after:**
Runtime security, policy enforcement, vulnerability management, and RBAC. This agent is the security operations centre for the cluster — it investigates policy violations, suspicious runtime behaviour, and misconfigurations that could be exploited. Unlike other agents that focus on availability, this one focuses on confidentiality and integrity.

**Reactive — responds to events:**
- `FailedCreate` with PodSecurity violation → identify which security standard was violated, suggest minimum privilege fix
- Kyverno/OPA `PolicyViolation` → explain the policy, show what the resource needs to change
- Falco runtime alert → investigate the container, check for compromise indicators, recommend containment
- `FailedMount` on secret volumes → check RBAC, service account permissions, secret existence
- Suspicious `exec`/`attach` events → check who initiated it, from where, on which pod
- Image pull failures from private registries → check imagePullSecrets, registry credentials

**Proactive — scheduled checks (CronWorkflow, daily):**
- Audit all pods running as root or with privileged containers — flag violations of Pod Security Standards
- Check for pods with `hostNetwork`, `hostPID`, `hostIPC` enabled outside kube-system
- Scan for service accounts with cluster-admin or overly broad RBAC bindings
- Verify all namespaces have appropriate Pod Security Standard labels (`restricted`, `baseline`)
- Check for secrets mounted as environment variables (less secure than volume mounts)
- Audit image sources — flag containers using images from non-whitelisted registries
- Check for pods without resource limits (potential noisy neighbour / DoS vector)
- Verify Kyverno/OPA policies are enforcing (not just audit mode) on production namespaces
- Scan for exposed services without authentication (LoadBalancer/NodePort with no auth layer)
- Check for stale ServiceAccount tokens (long-lived tokens that should be rotated)

**Tools needed:**
- `kubectl` (read-only): describe pods, serviceaccounts, roles, rolebindings, clusterroles, clusterrolebindings, policyreports, networkpolicies
- Kyverno policy report API
- Falco event stream or API
- Trivy scan results (image vulnerability reports)

**Routes to:** namespaces `falco`, `trivy-system`, `kyverno`, `opa-gatekeeper-system`, `defender`

```json
namespace-routes: {"falco": "security-agent", "kyverno": "security-agent", "trivy-system": "security-agent"}
```

---

### 5. Compliance — `compliance-agent`

**Owner:** Governance/Platform team

**What it looks after:**
Organisational standards, tagging, labelling, resource governance, and audit readiness. This agent ensures every namespace, deployment, and resource meets the organisation's standards. It's not about security threats — it's about consistency, traceability, and being able to answer "who owns this?" and "does this meet our standards?" at any time.

**Reactive — responds to events:**
- New namespace created without required labels → flag missing cost centre, team, environment tags
- Resource quota exceeded → check if team needs a quota increase or is over-provisioning
- Policy admission webhook rejection → explain what standard was missed and how to fix it

**Proactive — scheduled checks (CronWorkflow, daily + weekly report):**
- **Daily scan — label compliance:**
  - Every namespace must have: `team`, `cost-centre`, `environment`, `sla-tier` labels
  - Every deployment must have: `app`, `version`, `owner` labels
  - Flag resources missing required labels with specific remediation commands
- **Daily scan — resource governance:**
  - Every namespace must have a ResourceQuota
  - Every namespace must have a LimitRange (default resource requests/limits)
  - Every pod must have resource requests and limits set
  - Flag deployments without PodDisruptionBudgets in production namespaces
- **Daily scan — network governance:**
  - Every namespace must have a default-deny NetworkPolicy
  - Flag namespaces in production without egress restrictions
- **Weekly report — full compliance audit:**
  - Generate a per-namespace compliance scorecard (% compliant)
  - Track compliance trend over time (improving or degrading)
  - List top 10 non-compliant resources with remediation commands
  - Create GitLab issue with full audit report
- **On-demand — pre-audit preparation:**
  - Generate evidence for SOC2/ISO27001/CIS benchmarks
  - Export RBAC matrix (who can do what in which namespace)
  - Export network policy matrix (which namespaces can talk to which)

**Tools needed:**
- `kubectl` (read-only): list/describe namespaces, deployments, resourcequotas, limitranges, networkpolicies, poddisruptionbudgets, roles, rolebindings
- Policy report APIs (Kyverno, OPA)
- GitLab API for report creation

**Trigger:** Primarily CronWorkflow (not event routing). Create a `compliance-scan` WorkflowTemplate that runs daily.

---

### 6. Incident Management — `incident-agent`

**Owner:** SRE/Operations team

**What it looks after:**
The full incident lifecycle — from detection through to resolution and post-mortem. This agent doesn't investigate the technical issue itself (that's what the triage/specialist agents do). Instead, it manages the incident process: creating tickets, correlating related events, escalating to the right people, tracking SLAs, and generating timelines. Think of it as the incident commander, not the engineer.

**Reactive — responds to events (runs alongside triage, not instead of it):**
- Any critical event → check if an existing incident already covers this (dedup/correlate)
- New incident needed → create ticket in ServiceNow/Jira with severity, impact assessment, affected services
- CrashLoopBackOff lasting >15 minutes → escalate from P3 to P2, page on-call
- OOMKilled on production namespace → auto-create P1 incident, notify stakeholders via Teams
- Multiple events from same namespace within 5 minutes → correlate into single incident
- Pod recovers after incident → update ticket with resolution, calculate downtime duration

**Proactive — scheduled checks (CronWorkflow, hourly):**
- Check for open incidents with no update in >30 minutes — nudge the assigned engineer
- Check for incidents approaching SLA breach — escalate before breach, not after
- Correlate events across namespaces — detect cascading failures (e.g., database down → API 502 → frontend errors)
- Generate daily incident summary — count, MTTR, top causes, recurring issues
- Check for pods that recovered without an incident being created (silent failures)
- Weekly: generate incident trend report (are we getting better or worse?)
- Monthly: identify top 3 recurring incident types — recommend permanent fixes

**Tools needed:**
- ServiceNow/Jira API: create, update, query incidents
- PagerDuty API: create incidents, escalate
- Teams/Slack API: post to incident channels, create war rooms
- `kubectl` (read-only): for enriching incident context (pod status, events, logs)
- GitLab API: create post-mortem issues

**Integration pattern:** Runs as a parallel step in `investigate-and-report`. The workflow fans out to both the technical agent (for analysis) and the incident agent (for process management).

---

### 7. Change Management — `change-agent`

**Owner:** Release/Platform team

**What it looks after:**
Deployment health, rollout safety, and release management. This agent watches for signs that a deployment is going wrong and recommends or executes rollback. It also enforces change windows, validates that canary deployments are healthy before promoting, and provides deployment diff analysis. The goal is to catch bad deployments in minutes, not hours.

**Reactive — responds to events:**
- `ProgressDeadlineExceeded` → deployment stuck, check new ReplicaSet pod errors, compare with previous revision, recommend rollback
- `CrashLoopBackOff` within 10 minutes of deployment → correlate with rollout history, identify bad image/config change
- `FailedCreate` on ReplicaSet → check resource quota, node capacity, image pull errors
- Readiness probe failures after image change → check new container health, compare probe config between revisions
- `OOMKilled` after deployment → compare resource requests/limits between old and new revision

**Proactive — scheduled checks (CronWorkflow, every 15 minutes during business hours):**
- Check all Deployments for rollouts in progress — verify they're making progress (not stuck)
- Detect deployments with `replicas != readyReplicas` for >5 minutes — something is wrong
- Check for Helm releases in `failed` or `pending-upgrade` state
- Verify ArgoCD applications are in sync (detect drift from Git)
- Check for deployments outside change windows (if change windows are defined in labels/annotations)
- Compare current image tags against approved release tags (detect manual overrides)
- Daily: generate deployment activity report (what changed, who deployed, success rate)

**Proactive — deployment validation (triggered by CI/CD webhook):**
- New deployment detected → watch rollout for 5 minutes, check error rate, check readiness
- Canary deployment → compare canary pod metrics against stable (error rate, latency, restarts)
- If canary is unhealthy → recommend abort, provide rollback command
- If rollout completes → verify all pods healthy, no errors in first 10 minutes

**Tools needed:**
- `kubectl` (read-only): describe deployments, replicasets, rollout history, pods, events
- `kubectl` (read-write, optional): `rollout undo` for auto-rollback
- Helm CLI: `helm history`, `helm status`
- ArgoCD API: application sync status, health
- Git API: compare commits between deployment revisions

**Routes to:** reason `ProgressDeadlineExceeded`

```json
reason-routes: {"ProgressDeadlineExceeded": "change-agent"}
```

---

### 8. DNS — `dns-agent`

**Owner:** Network/Platform team

**What it looks after:**
DNS resolution — both cluster-internal (CoreDNS) and external (external-dns for public/private DNS zones). DNS failures are insidious because they affect every service but the symptoms appear as random connection timeouts, not obvious DNS errors. This agent needs to quickly distinguish between "CoreDNS is down" vs "one specific record is wrong" vs "upstream DNS is slow".

**Reactive — responds to events:**
- `CrashLoopBackOff` on CoreDNS pods → check resource limits, Corefile config, upstream resolver connectivity
- `BackOff` on external-dns pods → check provider credentials, API rate limits, zone permissions
- Pod DNS resolution failures → test from affected pod's node, check ndots config, search domains
- NXDOMAIN for internal services → check Service exists, correct namespace, headless vs ClusterIP
- DNS timeout events → check CoreDNS metrics (cache hit rate, upstream latency), node DNS config

**Proactive — scheduled checks (CronWorkflow, every 30 minutes):**
- Run DNS resolution tests for critical services from multiple nodes (detect split-brain)
- Check CoreDNS pod count matches desired (autoscaler or manual)
- Verify external-dns is syncing records (last sync time, pending changes)
- Check for DNS records pointing to stale/deleted services (orphaned records)
- Monitor CoreDNS error rate and latency (from Prometheus metrics if available)
- Verify `ndots` and `search` domain config hasn't been overridden by pods (causes slow lookups)
- Daily: audit DNS zones for records not managed by external-dns (manual records that could drift)

**Tools needed:**
- `kubectl` (read-only): describe coredns pods, configmaps, services, endpoints
- DNS tools: `nslookup`, `dig` (run from debug pods on different nodes)
- External-DNS provider API (Azure DNS, Route53, Cloudflare)

**Routes to:** namespaces `external-dns`, `kube-system` (for CoreDNS)

```json
namespace-routes: {"external-dns": "dns-agent"}
```

---

### 9. Database — `database-agent`

**Owner:** Data/Platform team

**What it looks after:**
Database workloads running in Kubernetes — PostgreSQL, MySQL, Redis, MongoDB, and their operators. Database issues need specialist knowledge because a crashing database pod isn't the same as a crashing web pod — you need to check replication state, WAL files, connection limits, and data integrity before recommending a restart. This agent understands database-specific failure modes.

**Reactive — responds to events:**
- `CrashLoopBackOff` on database pods → check OOM, disk full, corrupted data files, config errors, pg_isready/mysqladmin status
- `OOMKilled` on database pods → analyse memory usage pattern, check shared_buffers/innodb_buffer_pool, recommend right-sizing
- `FailedMount` on database PVCs → check PV status, node affinity (database PV stuck on dead node), CSI driver
- Operator events (CrunchyData, Zalando, etc.) → check operator logs, cluster status, failover state
- Backup job failures → check CronJob logs, storage credentials, destination accessibility
- Replication lag alerts → check standby status, WAL shipping, network between primary and replica

**Proactive — scheduled checks (CronWorkflow, every 6 hours):**
- Check all database StatefulSets have all replicas ready
- Verify replication is healthy (primary-standby lag within thresholds)
- Check database PVC usage — flag volumes >80% full (databases grow and can't be easily resized live)
- Verify backup jobs completed successfully in the last 24 hours
- Check connection counts against limits (near-limit = risk of connection exhaustion)
- Verify database pods have appropriate resource limits (databases should not be resource-unlimited)
- Check for database pods running on spot/preemptible nodes (bad idea)
- Weekly: audit database versions against known CVEs (flag if upgrade needed)

**Tools needed:**
- `kubectl` (read-only): describe statefulsets, pods, pvcs, events, cronjobs
- Database CLIs: `pg_isready`, `redis-cli ping`, `mongosh --eval "db.runCommand({ping:1})"`
- Operator-specific APIs: CrunchyData pgcluster status, Zalando postgresql status

**Routes to:** namespaces with database operators

```json
namespace-routes: {"postgres-operator": "database-agent", "redis": "database-agent", "mongodb": "database-agent"}
```

---

### 10. Cost & Resource Optimisation — `cost-agent`

**Owner:** FinOps/Platform team

**What it looks after:**
Resource efficiency, cost allocation, and right-sizing. This agent ensures the cluster isn't wasting money on over-provisioned resources or running workloads that nobody uses. It's not about cutting costs blindly — it's about making sure every CPU core and GB of memory is justified and allocated to the right team's budget.

**Reactive — responds to events:**
- `Evicted` → node under resource pressure, identify the greedy pod, check if limits are set
- `FailedScheduling` with "insufficient" → check if cluster needs scaling or if requests are too high
- `OOMKilled` → pod needs more memory than requested, recommend right-size based on actual usage
- Node scaling events → check if scale-up was necessary or if pods could be packed better

**Proactive — scheduled checks (CronWorkflow, daily + weekly report):**
- **Daily — right-sizing scan:**
  - Compare CPU/memory requests vs actual usage (last 7 days from metrics-server/Prometheus)
  - Flag pods requesting >2x what they actually use (over-provisioned)
  - Flag pods consistently hitting limits (under-provisioned, performance risk)
  - Generate `kubectl patch` commands to right-size each deployment
- **Daily — idle resource detection:**
  - Find deployments with 0 incoming requests for >24 hours (forgotten workloads)
  - Find PVCs that are bound but not mounted to any pod (orphaned storage)
  - Find LoadBalancer Services with no traffic (each one costs money in cloud)
  - Find namespaces with no running pods (empty namespaces with quota allocated)
- **Daily — node efficiency:**
  - Check node utilisation (CPU/memory) — flag nodes <30% utilised (over-scaled)
  - Check for unschedulable capacity due to pod affinity/anti-affinity spreading
  - Recommend node pool consolidation if multiple pools are under-utilised
- **Weekly — cost report:**
  - Per-namespace cost breakdown (CPU + memory + storage)
  - Top 10 most expensive deployments
  - Week-over-week cost trend (growing or shrinking)
  - Specific savings recommendations with estimated monthly saving
  - Create GitLab issue with full cost report

**Tools needed:**
- `kubectl` (read-only): top nodes, top pods, describe resourcequotas, limitranges, nodes
- Prometheus/metrics-server API: historical CPU/memory usage
- Cloud provider cost API: Azure Cost Management, AWS Cost Explorer
- Kubecost API (if deployed)

**Routes to:** reason `Evicted`

```json
reason-routes: {"Evicted": "cost-agent"}
```

---

### 11. Node & Infrastructure — `infra-agent`

**Owner:** Infrastructure/Platform team

**What it looks after:**
Node health, OS-level issues, container runtime, kubelet, and cloud provider infrastructure. When a node goes NotReady, the blast radius is every pod on that node. This agent needs to quickly determine if the node is recoverable (restart kubelet, clear disk space) or needs replacement (hardware failure, kernel panic), and whether workloads need manual intervention to reschedule.

**Reactive — responds to events:**
- `NodeNotReady` → check node conditions (disk/memory/PID pressure), kubelet status, cloud VM status, network connectivity
- `NodeNotSchedulable` → check if intentionally cordoned (maintenance) or unexpected, check drain status
- `SystemOOM` → identify which process the kernel OOM killer targeted, check memory pressure across pods
- `Rebooted` → check if planned (OS update) or unexpected (kernel panic, hardware), verify pods rescheduled
- `FailedScheduling` with "insufficient" → check node capacity, taint/toleration mismatches, affinity rules
- `NodeHasDiskPressure` → check disk usage, identify large files/logs, check container image cache size

**Proactive — scheduled checks (CronWorkflow, every 30 minutes):**
- Check all nodes are in Ready state — alert immediately if any are NotReady
- Check node conditions — flag any node with disk/memory/PID pressure before it goes NotReady
- Verify kubelet is responding on all nodes (check node heartbeat age)
- Check container runtime (containerd) health on all nodes
- Monitor inotify instance usage — flag nodes approaching the limit (causes pod failures)
- Check node OS/kernel version consistency — flag nodes running different versions (missed updates)
- Verify cloud provider node pool health (VMSS instances, auto-repair status)
- Check for nodes with high pod density approaching `maxPods` limit
- Daily: check node certificates aren't expiring (kubelet serving cert, client cert)
- Daily: verify node-level DaemonSets are running everywhere (kube-proxy, CNI, CSI, monitoring)

**Tools needed:**
- `kubectl` (read-only): describe nodes, get events, top nodes, get pods -o wide (to see node scheduling)
- Node debug pods or SSH for OS-level diagnostics (journalctl, dmesg, df)
- Cloud provider API: Azure VMSS instance health, AWS ASG status

**Routes to:** reasons `NodeNotReady`, `NodeNotSchedulable`, `SystemOOM`, `Rebooted`

```json
reason-routes: {"NodeNotReady": "infra-agent", "NodeNotSchedulable": "infra-agent", "SystemOOM": "infra-agent"}
```

---

### 12. Observability — `observability-agent`

**Owner:** LGTM/Observability team

**What it looks after:**
The monitoring stack itself — Prometheus, Alertmanager, Grafana, Loki, Tempo, Mimir, Alloy, and OpenTelemetry collectors. If monitoring goes down, you're flying blind. This agent ensures you always have eyes on the cluster. It's the agent that watches the watchers.

**Reactive — responds to events:**
- `CrashLoopBackOff` on Prometheus/Loki/Alloy pods → check OOM (common with high cardinality), config errors, storage issues
- `OOMKilled` on monitoring pods → check cardinality explosion (new metrics flooding in), recommend memory increase or cardinality reduction
- `FailedMount` on monitoring PVCs → check storage backend, TSDB corruption, WAL issues
- Alertmanager events → check config reload failures, notification channel errors, inhibition rule issues
- Grafana events → check datasource connectivity, dashboard provisioning errors, authentication issues

**Proactive — scheduled checks (CronWorkflow, every 15 minutes):**
- **Prometheus health:**
  - Check Prometheus is scraping targets successfully (query `up` metric, flag targets returning 0)
  - Check TSDB head series count — alert if approaching storage limits
  - Check Prometheus memory usage vs limits — OOM is the #1 monitoring failure
  - Verify Alertmanager is receiving alerts (check last alert timestamp)
  - Check for silenced alerts that have been silenced >7 days (forgotten silences)
- **Loki health:**
  - Check Loki ingestion rate — sudden drop means logs are being lost
  - Verify log streams are arriving from all expected clusters/namespaces
  - Check Loki storage (S3/GCS/local) is accessible and not full
- **Alloy/Collector health:**
  - Check all Alloy pods are running on all nodes (DaemonSet)
  - Verify pipeline is flowing — check for backpressure, dropped data
  - Check exporter connectivity (can Alloy reach Event Hub, Loki, Prometheus remote write)
- **Grafana health:**
  - Check all datasources are reachable (Prometheus, Loki, Tempo)
  - Verify Grafana is accessible (HTTP health check)
- **Daily report:**
  - Monitoring stack resource usage vs allocated
  - Data ingestion rate trends (growing? need more capacity?)
  - Failed scrape targets (persistent failures, not transient)

**Tools needed:**
- `kubectl` (read-only): describe monitoring stack pods, configmaps, services, statefulsets
- Prometheus API: `/api/v1/targets`, `/api/v1/rules`, `/api/v1/alerts`, `/api/v1/status/tsdb`
- Loki API: `/ready`, `/metrics`
- Grafana API: `/api/health`, `/api/datasources`
- Alertmanager API: `/api/v2/alerts`, `/api/v2/silences`

**Routes to:** namespaces `monitoring`, `loki`, `tempo`, `mimir`, `grafana`, `alloy`, `opentelemetry`

```json
namespace-routes: {"monitoring": "observability-agent", "loki": "observability-agent", "alloy": "observability-agent", "grafana": "observability-agent"}
```

---

## Agent Permission Tiers

| Tier | Access | Use For | Agents |
|------|--------|---------|--------|
| **Read-only** | `get`, `list`, `describe`, `logs` | Triage, investigation, compliance, cost analysis | Most agents |
| **Read-write** | Above + `patch`, `scale`, `rollout` | Auto-remediation, rollback | `sre-remediation-agent`, `change-agent` |
| **Admin** | Full cluster access | Emergency response | Reserved, manual approval only |

**Principle:** Start every agent as read-only. Only promote to read-write after the team has confidence in its recommendations.

---

## Routing Summary

### By Namespace

| Namespace | Agent |
|-----------|-------|
| `cert-manager` | `cert-manager-agent` |
| `ingress-nginx`, `istio-system`, `calico-system`, `cilium-system` | `network-agent` |
| `longhorn-system`, `rook-ceph` | `storage-agent` |
| `falco`, `kyverno`, `trivy-system` | `security-agent` |
| `external-dns` | `dns-agent` |
| `postgres-operator`, `redis`, `mongodb` | `database-agent` |
| `monitoring`, `loki`, `alloy`, `grafana` | `observability-agent` |
| Everything else | `sre-triage-agent` / `sre-remediation-agent` |

### By Reason

| Event Reason | Agent |
|-------------|-------|
| `FailedMount`, `FailedAttachVolume`, `ProvisioningFailed` | `storage-agent` |
| `FailedCreatePodSandBox`, `NetworkNotReady` | `network-agent` |
| `NodeNotReady`, `NodeNotSchedulable`, `SystemOOM` | `infra-agent` |
| `ProgressDeadlineExceeded` | `change-agent` |
| `Evicted` | `cost-agent` |
| Everything else | `sre-triage-agent` / `sre-remediation-agent` |

---

## Trigger Patterns

Not all agents are event-driven. There are three trigger patterns:

### 1. Event-Driven (Reactive)
Triggered by K8s Warning events via Event Hub → Sensor → Workflow → Agent.
Used by: all agents with routing config above.

### 2. Scheduled (Proactive)
Triggered by CronWorkflow on a schedule. The workflow calls the agent with a "scan this" prompt instead of a specific event.
Used by: `compliance-agent`, `cost-agent`, `security-agent`, `observability-agent`, `dns-agent`, `infra-agent`.

Example CronWorkflow:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: daily-compliance-scan
  namespace: argo-events
spec:
  schedule: "0 8 * * *"  # 8am daily
  workflowSpec:
    entrypoint: scan
    templates:
      - name: scan
        # Call compliance-agent with a "scan all namespaces" prompt
```

### 3. Webhook (On-Demand)
Triggered by CI/CD pipelines, chatops, or manual API calls. Used for deployment validation, on-demand audits, or manual triage.
Used by: `change-agent` (deployment webhook), `compliance-agent` (pre-audit), any agent via manual workflow submission.

---

## Rollout Plan

### Phase 1 — Foundation (Current)
- `sre-triage-agent` (read-only, all events)
- `sre-remediation-agent` (read-write, manual trigger only)

### Phase 2 — Infrastructure Specialists
- `storage-agent` — high-value, FailedMount is a common and annoying issue
- `network-agent` — sandbox/CNI errors are hard to debug manually
- `infra-agent` — NodeNotReady needs fast response

### Phase 3 — Platform Specialists
- `cert-manager-agent` — certificate expiry is a top incident cause
- `dns-agent` — DNS failures cascade across all services
- `observability-agent` — monitoring failures are blind spots

### Phase 4 — Process Agents
- `incident-agent` — ticket creation and correlation
- `change-agent` — deployment health and rollback
- `compliance-agent` — scheduled compliance scans

### Phase 5 — Optimisation
- `cost-agent` — resource right-sizing and waste detection
- `database-agent` — database-specific diagnostics
- `security-agent` — runtime security response

---

## Creating a New Agent

### 1. Define the Agent CRD

```yaml
apiVersion: kagent.dev/v1alpha1
kind: Agent
metadata:
  name: cert-manager-agent
  namespace: kagent
spec:
  systemPrompt: |
    You are a cert-manager specialist agent. You diagnose and resolve
    certificate-related issues in Kubernetes clusters.

    You have access to read-only kubectl tools. Use them to:
    - Describe certificates, issuers, and challenges
    - Check certificate status and expiry dates
    - Inspect ACME orders and challenges
    - Review cert-manager controller logs

    Report findings as: Issue / Evidence / Root Cause / Recommended Fix
  modelConfig:
    provider: openai
    model: qwen3-14b
  toolServers:
    - name: kagent-tools
      url: http://kagent-tools.kagent.svc.cluster.local:8080
```

### 2. Deploy the Agent

```bash
kubectl apply -f cert-manager-agent.yaml -n kagent

# Verify it's registered
kubectl get agents -n kagent
curl -s http://kagent-a2a.kagent.svc.cluster.local/api/agents | jq '.[].metadata.name'
```

### 3. Update the Routing ConfigMap

```bash
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"cert-manager\":\"cert-manager-agent\"}"}}'
```

### 4. Test It

```bash
# Send a test event from the cert-manager namespace
kubectl create -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-cert-routing-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-triage-critical
  arguments:
    parameters:
      - name: otlp-payload
        value: '{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"my-cluster"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"cert-manager controller crashing\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"cert-manager-abc\",\"namespace\":\"cert-manager\"},\"count\":3}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"CrashLoopBackOff"}},{"key":"obj_namespace","value":{"stringValue":"cert-manager"}}]}]}]}]}'
      - name: remediate
        value: "false"
EOF

# Check it routed to cert-manager-agent
argo get -n argo-events @latest -o json | jq '
  .status.nodes[] | select(.displayName | startswith("process-event")) | .displayName
'
```

---

## Agent Design Guidelines

1. **Start read-only.** Every agent begins as triage-only. Promote to read-write only after proving accuracy over weeks.
2. **System prompt is everything.** Include: what it specialises in, what tools to use, what format to report in, common failure modes, and what NOT to do.
3. **Namespace anchoring.** Always include `CRITICAL: use exact namespace "X"` in the workflow prompt. Smaller models hallucinate namespace names.
4. **One domain per agent.** Specialist agents with focused prompts outperform generalists. A cert-manager agent that knows about ACME, issuers, and challenges will always beat a "do everything" agent.
5. **Runbooks in the prompt.** If you have runbooks for common scenarios, include the key investigation steps in the agent's system prompt.
6. **Test independently first.** Before wiring an agent into the event pipeline, test it manually with known scenarios via direct A2A calls.
7. **Proactive checks are as valuable as reactive.** An agent that catches a certificate 14 days before expiry saves more incidents than one that diagnoses the failure after it happens.
