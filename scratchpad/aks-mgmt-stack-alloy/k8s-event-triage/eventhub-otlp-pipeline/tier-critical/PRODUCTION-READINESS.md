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

**How Event Hub consumer groups actually work:** All events go to a single topic (`k8s-events`). Consumer groups are just independent read cursors — every consumer group sees every event. They don't filter. The reason we need separate consumer groups is so that multiple consumers can each read the same stream at their own pace without interfering with each other's offsets.

**Filtering happens downstream in the Argo Events Sensors**, not at the Event Hub level. Each sensor has trigger conditions that decide whether to fire its workflow based on the event payload (severity, event reason, resource kind, etc.).

```
Event Hub Topic: k8s-events
    │
    │  (every event goes to every consumer group)
    │
    ├── consumer-critical  → EventSource → Sensor (filter: severity=critical)  → Workflow → SRE Remediation Agent (cloud LLM)
    ├── consumer-warnings  → EventSource → Sensor (filter: severity=warning)   → Workflow → SRE Triage Agent (hosted LLM)
    ├── consumer-network   → EventSource → Sensor (filter: kind=NetworkPolicy)  → Workflow → Network Specialist Agent
    ├── consumer-domain    → EventSource → Sensor (filter: app-specific labels) → Workflow → Domain Specialist Agent
    └── consumer-infra     → EventSource → Sensor (filter: kind=Node)           → Workflow → SRE Read-Only Agent
```

**Alternative:** If we want actual routing at the Event Hub level, we'd need separate topics (`k8s-events-critical`, `k8s-events-warnings`, etc.) with Alloy or a relay publishing to the right topic. This adds complexity at the producer side but simplifies consumers.

- [ ] Decide: single topic + sensor filters vs multiple topics
- [ ] Define sensor filter conditions for each tier (severity, reason, resource kind, labels)
- [ ] Define which KAgent agent each tier routes to
- [ ] Create EventSource + Sensor + WorkflowTemplate per tier
- [ ] Create consumer groups in Event Hub (one per consumer, to avoid offset conflicts)

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
- [ ] Lock down MCP endpoint — ensure only authorized agents can reach it (not just people)
  - Network policy / service mesh to restrict ingress to agent pods only
  - mTLS or token-based auth so the MCP rejects requests from anything other than the triage agents
  - Audit logging on MCP access for traceability
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

## 11. Engineering Rollout — Namespace-by-Namespace Fault Injection

**Owner:** David + Team

**Strategy:** Open up one namespace at a time, assign it to a specific agent, and validate through deliberate fault injection before moving on.

### Approach

1. **One namespace, one agent** — each namespace is assigned to a dedicated agent. The team injects faults into that namespace (on any cluster in engineering) and evaluates whether the agent can correctly triage and ideally remediate the issue.
2. **Agent tuning loop** — work with each agent's context, skills, and tools to improve its performance against the injected faults. Iterate on system prompts, runbooks, and tool permissions until the agent handles the namespace's failure modes reliably.
3. **Repeat for all core agents** — once an agent passes fault injection for its namespace, move to the next agent/namespace pair. When all core agents are validated, we're in a position to release into dev clusters.

### Fault Injection Scope

- Inject faults into any cluster in the engineering environment
- Target one namespace at a time to isolate agent performance
- Fault types: CrashLoopBackOff, OOMKilled, FailedScheduling, resource exhaustion, config errors, network policies, etc.
- Success criteria: agent provides correct triage diagnosis; bonus if it can auto-remediate

### Rollout Phases

- [ ] Select first namespace + assign to first agent
- [ ] Define fault injection playbook (what faults, how to inject, expected agent response)
- [ ] Run fault injection round — evaluate agent triage accuracy
- [ ] Tune agent (prompts, tools, permissions) based on results
- [ ] Repeat for each core agent/namespace pair
- [ ] All core agents validated → release to dev clusters
- [ ] Monitor dev clusters for false positives / noise
- [ ] Tune Alloy dedup filter and rate limits
- [ ] Expand to additional namespaces gradually
- [ ] Enable warnings tier after critical is stable
- [ ] Enable infra tier last

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
