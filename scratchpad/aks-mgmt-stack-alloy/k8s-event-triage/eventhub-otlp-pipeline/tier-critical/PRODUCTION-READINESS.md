# Production Readiness - K8s Event Triage

Outstanding items to get from working prototype to production. Needs team involvement.

## Status: What Works Today

- Alloy collects K8s events on workload cluster → Event Hub (OTLP JSON)
- Argo Events consumes from Event Hub → triggers workflows
- Workflow parses OTLP, filters by severity, fans out per event
- KAgent A2A analysis (triage + remediation modes)
- GitLab issue creation (personal repo)
- Mattermost notifications
- Tested end-to-end on proxmox-k8s and AKS

---

## 1. Alerting Pipeline — AlertManager vs Event Hub

**Owner:** LGTM crew + David

**Decision needed:** How do monitoring namespace alerts reach the triage system?

- **Option A:** Prometheus → AlertManager webhook → Argo Events EventSource (already proven in `prometheus-alerting/` pipeline)
- **Option B:** Prometheus → AlertManager → Event Hub (via alertmanager config or webhook relay)
- **Option C:** Alloy picks up K8s events from monitoring namespace directly (current approach, but these are K8s events not Prometheus alerts)

**Question:** Are we triaging K8s Warning events (what Alloy sends), Prometheus alerts (what AlertManager fires), or both? They're different data — K8s events are `CrashLoopBackOff`, `OOMKilled` etc; Prometheus alerts are `KubePodCrashLooping`, `KubeMemoryOvercommit` etc. May want both pipelines.

- [ ] Meet with LGTM crew to agree on alerting flow
- [ ] Decide if AlertManager alerts also go through Event Hub or stay as direct webhooks
- [ ] Document the agreed pipeline

---

## 2. Event Routing — Consumer Groups & EventSources

**Owner:** David

Different event types trigger different EventSources via separate consumer groups. Each routes to a different workflow/agent.

```
Event Hub Topic: k8s-events
    │
    ├── consumer-critical  → Sensor → Workflow → SRE Remediation Agent (cloud LLM)
    ├── consumer-warnings  → Sensor → Workflow → SRE Triage Agent (hosted LLM)
    ├── consumer-network   → Sensor → Workflow → Network Specialist Agent
    ├── consumer-domain    → Sensor → Workflow → Domain Specialist Agent
    └── consumer-infra     → Sensor → Workflow → SRE Read-Only Agent
```

- [ ] Define the full list of consumer groups and what events each handles
- [ ] Define which KAgent agent each tier routes to
- [ ] Create EventSource + Sensor + WorkflowTemplate per tier
- [ ] Create consumer groups in Event Hub

---

## 3. Agent Architecture — KAgent Routing

**Owner:** David + AI Platform team

KAgent controller routes to different agents. Each agent has different permissions and connects to a different LLM backend.

```
KAgent Controller
    │
    ├── sre-triage-agent        (read-only, k8s tools)       → Hosted VLLM
    ├── sre-remediation-agent   (read-write, k8s tools)      → Cloud VLLM
    ├── network-specialist      (read-only, network tools)    → Cloud VLLM
    ├── domain-specialist       (read-only, app-specific)     → Cloud VLLM
    └── sre-admin-agent         (admin, full access)          → Cloud VLLM
```

- [ ] Define the agent roster — name, permissions, tools, LLM backend
- [ ] Create KAgent agent CRDs for each
- [ ] Decide permission boundaries (which agents get write access)
- [ ] Test each agent independently before wiring into the pipeline

---

## 4. LLM Backend Strategy — Two Clouds

**Owner:** David + AI Platform team

Two VLLM backends available. Need to decide which agents connect to which.

| Backend | Location | Speed | Cost | Best For |
|---------|----------|-------|------|----------|
| Cloud VLLM | Cloud provider | Fast | Higher | Critical events, remediation |
| Hosted VLLM | On-prem / hosted | Slower | Lower | Warnings, best-effort triage |

- [ ] Confirm both backends are accessible from KAgent
- [ ] Assign agents to backends based on SLA requirements
- [ ] Test failover — what happens when one backend is down?
- [ ] Document the backend mapping

---

## 5. AKS-MCP Deployment — Central vs Per-Cluster

**Owner:** David + Platform team

**Current state:** AKS-MCP hosted on the management cluster. Agents use `call_kubectl` tool to investigate workload clusters.

**Options:**

| Approach | Pros | Cons |
|----------|------|------|
| **Central MCP on mgmt cluster** | Simple, one deployment | Single point of failure, cross-cluster auth needed |
| **MCP per workload cluster** | Self-contained, agents talk to local cluster | More deployments, more UAMI config |
| **Hybrid** | Critical clusters get local MCP, others use central | Best of both, more complex |

**Key question:** Can KAgent and the MCP agents live on the same cluster as the workloads?

**Self-healing problem:** If the management cluster goes down, the triage system can't fix itself. Options:
- Deploy a minimal triage agent on each workload cluster as a fallback
- Use a secondary management cluster (active-passive)
- Accept the risk — management cluster issues are handled manually

- [ ] Decide central vs per-cluster MCP deployment
- [ ] If per-cluster: plan UAMI config for each cluster
- [ ] Address the self-healing gap (mgmt cluster down scenario)
- [ ] Document the deployment topology

---

## 6. UAMI — Managed Identity for Central MCP

**Owner:** Platform team

If going with a central MCP, the MCP service needs User Assigned Managed Identity (UAMI) to authenticate to each workload cluster's API server.

- [ ] Create UAMI for the MCP service
- [ ] Assign RBAC on each target AKS cluster
- [ ] Configure workload identity federation
- [ ] Test cross-cluster `kubectl` access via UAMI

---

## 7. GitLab — Strategic Location

**Owner:** David + Team Lead

**Current state:** Issues created in David's personal GitLab project (`68265584`).

**Decision needed:** Where should auto-generated triage issues go?

- [ ] Decide: dedicated project? Existing ops repo? Per-team repos?
- [ ] Set up the GitLab project with appropriate access
- [ ] Configure labels, boards, and templates for triage issues
- [ ] Update `gitlab-project-id` in workflow parameters
- [ ] Ensure the GitLab token has the right scope (API, create issues)

---

## 8. Teams Integration — Replace Mattermost

**Owner:**  David

**Current state:** Mattermost incoming webhook. Need to swap for Microsoft Teams.

- [ ] Work with Ben to understand Teams integration options (incoming webhook, Power Automate, Graph API)
- [ ] Decide on Teams channel structure (one channel? per-severity? per-cluster?)
- [ ] Get a Teams webhook URL or connector set up
- [ ] Update the workflow's Mattermost payload format to Teams Adaptive Cards
- [ ] Test end-to-end with Teams

**Note:** Teams webhook payload format differs from Mattermost. The `jq` payload construction in the workflow will need updating — Teams uses Adaptive Cards JSON, not Mattermost attachment format.

---

## 9. Runbooks

**Owner:** Team

Agents are only as good as the context they have. Need runbooks for common scenarios.

- [ ] Define runbook format/template
- [ ] Create runbooks for critical events:
  - CrashLoopBackOff — common causes, investigation steps, fixes
  - OOMKilled — memory analysis, right-sizing, leak detection
  - FailedScheduling — node capacity, taints, affinity
  - FailedMount / FailedAttachVolume — PV/PVC troubleshooting
  - NodeNotReady — node health checks
- [ ] Decide where runbooks live (Git repo? Wiki? Injected into agent prompts?)
- [ ] Wire runbooks into KAgent agent system prompts or tool context

---

## 10. KAgent vs Holmes — Final Decision

**Owner:** David + AI Platform team

**Current state:** Both exist, KAgent winning 5-0 in comparison tests. But need a formal decision.

| Factor | KAgent | Holmes |
|--------|--------|--------|
| K8s tool quality | Native tools, no shell quoting issues | call_kubectl via subshell, fragile |
| Speed | ~55s triage | ~120s triage |
| Accuracy | Correct diagnosis consistently | Confused by subshell context |
| A2A protocol | Supported | Not supported |
| Maintenance | Active development | Stable but less active |

- [ ] Present comparison results to the team
- [ ] Make formal decision: KAgent, Holmes, or keep both
- [ ] If KAgent: decommission Holmes deployment plan
- [ ] If both: document when to use which

---

## 11. Engineering Rollout

**Owner:** David

Turn it on for real and flush out bugs.

- [ ] Start with one non-critical AKS cluster
- [ ] Critical tier only (Phase 1)
- [ ] Monitor for false positives / noise
- [ ] Tune the Alloy dedup filter and rate limits
- [ ] Add more namespaces gradually
- [ ] Enable warnings tier (Phase 2) after critical is stable
- [ ] Enable infra tier (Phase 3) last

---

## Priority Order

| Priority | Item | Blocker? |
|----------|------|----------|
| 1 | Alerting pipeline decision (AlertManager vs Event Hub) | Blocks full architecture |
| 2 | Teams integration (swap Mattermost) | Blocks team visibility |
| 3 | GitLab strategic location | Blocks issue tracking |
| 4 | KAgent vs Holmes decision | Blocks agent deployment |
| 5 | UAMI for central MCP | Blocks cross-cluster access |
| 6 | Agent roster + LLM backend mapping | Blocks multi-agent routing |
| 7 | Runbooks | Improves quality, not a blocker |
| 8 | Engineering rollout | After 1-6 are resolved |
| 9 | Self-healing / resilience design | Can iterate after initial rollout |
