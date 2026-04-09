# UAG Agent Deployment Options for AKS

## Context

We're deploying Stonebranch Universal Agent (UAG) on our AKS worker clusters. The Universal Controller (UC) and OMS are managed by the Stonebranch team. Our responsibility is deploying and managing the agents only.

This document outlines three deployment patterns. We need the Stonebranch team's input on which best fits their job design and our security requirements.

---

## Option 1: Shared Agent Pool (Centralised)

A single set of agents in a dedicated namespace, serving the entire cluster.

```
┌──────────────────────────────────────────────┐
│  AKS Cluster                                 │
│                                              │
│  namespace: stonebranch                      │
│  ├── uag-agent (replica 1)                   │
│  ├── uag-agent (replica 2)                   │
│  └── uag-agent (replica 3)                   │
│       │                                      │
│       │  ClusterRole: access all namespaces  │
│       │                                      │
│  namespace: team-alpha   ──── accessible ────│
│  namespace: team-beta    ──── accessible ────│
│  namespace: team-gamma   ──── accessible ────│
│  ... (hundreds)                              │
└──────────────────────────────────────────────┘

Agents registered as: AKS-WORKER1-001, AKS-WORKER1-002, AKS-WORKER1-003
OMS connections: 3
```

**How it works:**
- Platform team deploys 2-5 agents in a dedicated namespace
- Agents have cluster-wide access via ClusterRoleBinding
- Controller dispatches jobs to any available agent
- Agent executes against whichever namespace the job targets

**Pros:**
- Simplest to deploy and manage
- Lowest resource footprint (3 agents × 256Mi = 768Mi total)
- Fewest OMS connections
- Standard Stonebranch reference architecture
- Easy to scale (adjust replica count)

**Cons:**
- Any agent can access any namespace (broad blast radius)
- Compromised job definition could affect unrelated teams
- Single ServiceAccount with cluster-wide permissions
- No namespace-level audit boundary

**Best for:**
- Single team or platform team controls all job definitions
- Non-regulated environments
- Getting started quickly

**Questions for Stonebranch team:**
1. Is this your standard deployment recommendation?
2. How do you scope jobs to specific namespaces in the Controller?
3. Can Controller RBAC prevent a user from targeting namespaces they shouldn't access?

---

## Option 2: Agent Pool Per Trust Boundary

Separate agent groups for different security zones. Not one-per-namespace — grouped by trust boundary (e.g. production vs non-production, or by business unit).

```
┌──────────────────────────────────────────────────────┐
│  AKS Cluster                                         │
│                                                      │
│  namespace: stonebranch-platform                     │
│  ├── uag-platform-001     ← Role: platform NSes     │
│  └── uag-platform-002                               │
│       │                                              │
│       ├── namespace: monitoring    ── accessible     │
│       ├── namespace: ingress       ── accessible     │
│       └── namespace: cert-manager  ── accessible     │
│                                                      │
│  namespace: stonebranch-apps                         │
│  ├── uag-apps-001         ← Role: app NSes only     │
│  └── uag-apps-002                                   │
│       │                                              │
│       ├── namespace: team-alpha    ── accessible     │
│       ├── namespace: team-beta     ── accessible     │
│       └── namespace: team-gamma    ── accessible     │
│                                                      │
│  namespace: team-delta (no agent)  ── not accessible │
└──────────────────────────────────────────────────────┘

Agent groups: 2 (platform + apps)
OMS connections: 4
```

**How it works:**
- Platform team creates 2-4 agent pools, one per trust boundary
- Each pool has its own ServiceAccount with RBAC scoped to specific namespaces
- Controller routes jobs to the correct agent pool
- NetworkPolicies restrict agent egress to their allowed namespaces

**Pros:**
- Reduced blast radius (pool can only access its assigned namespaces)
- Still manageable (2-4 pools, not hundreds)
- Moderate resource cost
- Clear security boundaries without per-namespace overhead

**Cons:**
- More complex than shared pool
- Need to maintain namespace-to-pool mapping
- New namespaces need to be assigned to a pool
- Multiple agent groups to register in Controller

**Best for:**
- Multi-tenant clusters with distinct trust boundaries
- Separation between platform infrastructure and application workloads
- Environments with moderate compliance requirements

**Questions for Stonebranch team:**
1. Does the Controller support agent cluster groups that restrict which jobs run where?
2. Can you map job definitions to specific agent groups?
3. How do you handle a new namespace being added to a trust boundary — is re-registration needed?

---

## Option 3: One Agent Per Namespace (Self-Service)

Each namespace that needs Stonebranch gets its own agent, deployed automatically when the namespace opts in.

```
┌──────────────────────────────────────────────────────┐
│  AKS Cluster                                         │
│                                                      │
│  namespace: team-alpha                               │
│    annotation: stonebranch.com/agent-enabled: "true" │
│  ├── app-pods...                                     │
│  └── uag-agent  ← Role scoped to team-alpha ONLY    │
│       agent name: team-alpha-agent                   │
│                                                      │
│  namespace: team-beta                                │
│    annotation: stonebranch.com/agent-enabled: "true" │
│  ├── app-pods...                                     │
│  └── uag-agent  ← Role scoped to team-beta ONLY     │
│       agent name: team-beta-agent                    │
│                                                      │
│  namespace: team-gamma (no annotation = no agent)    │
│  ├── app-pods...                                     │
│                                                      │
└──────────────────────────────────────────────────────┘

Agents: 1 per opted-in namespace
OMS connections: 1 per opted-in namespace
```

**How it works:**
- App teams add annotation to their namespace to opt in
- Platform automation (Kyverno / Argo Workflows / GitOps) deploys an agent
- Each agent has a namespace-scoped ServiceAccount (Role, not ClusterRole)
- Each agent's NetworkPolicy only allows egress to OMS
- Agent name matches namespace name for clear Controller mapping

**Pros:**
- Strongest isolation (agent can only access its own namespace)
- Clear audit trail (agent name = namespace name)
- Self-service for app teams (annotation to opt in)
- Smallest blast radius
- Meets strict compliance requirements

**Cons:**
- Highest resource cost (100 namespaces × 128Mi = 12.8Gi memory)
- Most OMS connections (one per namespace — check OMS capacity)
- Most agents to register and manage in Controller
- Each agent needs a unique job definition in Controller (or templated)
- Agent sits idle most of the time in low-activity namespaces

**Best for:**
- Strict multi-tenancy with compliance requirements
- App teams defining their own jobs
- Regulated environments (PCI, SOX, HIPAA)

**Questions for Stonebranch team:**
1. Is there a practical limit on OMS connections? (e.g. 100+ agents to one OMS)
2. Can job definitions be templated to target agents by naming pattern? (e.g. `*-agent`)
3. Does the Controller handle agent auto-discovery, or does each need manual registration?
4. What's the licensing model — per agent, per Controller, or per connection?

---

## Comparison Summary

| Factor | Option 1: Shared | Option 2: Per Boundary | Option 3: Per Namespace |
|--------|-----------------|----------------------|------------------------|
| Agents | 2-5 total | 2-5 per boundary | 1 per namespace |
| OMS connections | 2-5 | 4-10 | 1 per opted-in NS |
| Isolation | None (cluster-wide) | Trust boundary | Namespace-level |
| Blast radius | Entire cluster | Group of namespaces | Single namespace |
| Resource cost (100 NS) | ~768Mi | ~2Gi | ~12.8Gi |
| Management complexity | Low | Medium | Medium-High |
| Onboarding a new NS | Nothing | Assign to pool | Annotation + auto-deploy |
| Compliance fit | Dev/test | Most production | Regulated |
| Matches Stonebranch ref arch | Yes | Partially | No (custom pattern) |

---

## What We Need From the Stonebranch Team

1. **Job ownership model** — who defines and triggers jobs? Your team only, or do our app teams self-serve?
2. **Controller RBAC** — can you restrict which namespaces/targets a user or job can access?
3. **Agent capacity** — any limits on agents per OMS, or licensing considerations?
4. **Agent auto-discovery** — do agents self-register, or do you manually add each one?
5. **Your recommendation** — given a cluster with hundreds of namespaces, what's your standard guidance?
6. **Job-to-agent routing** — how do you map a job to a specific agent or agent group?

Based on answers, we'll align on one of these options or a hybrid approach.

---

## Our Current POC

We've tested the agent deployment locally and confirmed:
- Agent connects to OMS over TLS 1.2 (auto-negotiated, self-signed certs)
- Agent needs only two config values: OMS address + agent name
- No persistent storage required
- Image: `stonebranch/universal-agent:8.0.0.0-debian` (~600MB)
- Resources: 50-100m CPU, 128-256Mi memory per agent
- Cross-namespace connectivity verified

We have deployment scripts ready for all three options.
