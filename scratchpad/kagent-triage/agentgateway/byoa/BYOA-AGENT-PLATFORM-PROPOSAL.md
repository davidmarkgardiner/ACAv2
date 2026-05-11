# BYOA Agent Platform — Proposal

**Bring Your Own Agent: Self-service incident triage for shared AKS clusters**

> Status: Proposal / RFC
> Date: 2026-02-17
> Author: David Gardiner
> Validated: Holmes vs KAgent comparison (5 scenarios, KAgent 5-0)

---

## Problem

We run shared AKS clusters with ~1000 namespaces globally. Today, alert triage is either manual or handled by a single monolithic agent (HolmesGPT) that has no team-specific context. Every alert gets the same generic investigation regardless of whether it's a PostgreSQL replication issue, a cert-manager renewal failure, or a team's custom application crash.

**Pain points:**
- Platform alerts (cert-manager, external-dns, ingress) need platform-specific runbooks
- App team alerts need team-specific domain knowledge (their services, dependencies, escalation paths)
- One-size-fits-all triage produces generic recommendations that teams ignore
- No self-service — every runbook change requires platform team intervention

---

## Proposal

Use **KAgent** (Kubernetes-native AI agent framework) to provide a **two-tier triage architecture**:

1. **Platform agents** — owned by the platform team, handle cross-cutting infrastructure concerns
2. **Team agents (BYOA)** — owned by app teams, handle team-specific application issues

Alerts route to the correct agent based on namespace annotations and alert type.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     Alert Sources                               │
│  Prometheus AlertManager  ·  Argo Events  ·  K8s Event Exporter │
└──────────────────────────┬─────────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   Argo Events Sensor   │
              │   (routing logic)      │
              └─────────┬──────────────┘
                        │
          ┌─────────────┼──────────────────────┐
          │             │                      │
          ▼             ▼                      ▼
   ┌─────────────┐  ┌──────────┐     ┌────────────────┐
   │  PLATFORM   │  │  PLATFORM│     │   APP TEAM     │
   │  AGENTS     │  │  AGENTS  │     │   BYOA AGENT   │
   │             │  │          │     │                │
   │ cert-manager│  │ external │     │ Team-specific  │
   │ ingress     │  │ -dns     │     │ runbooks,      │
   │ node-health │  │ flux/argo│     │ tools, model   │
   │ storage     │  │ cd       │     │                │
   └──────┬──────┘  └────┬─────┘     └───────┬────────┘
          │               │                   │
          ▼               ▼                   ▼
   ┌──────────────────────────────────────────────────┐
   │              Reporting Pipeline                    │
   │  GitLab Issues  ·  Slack/Teams  ·  PagerDuty      │
   └──────────────────────────────────────────────────┘
```

---

## Routing Mechanism

### Namespace Annotations

App teams register their agent by annotating their namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments-prod
  labels:
    team: payments
    environment: production
  annotations:
    triage.platform.com/agent: payments-triage-agent
    triage.platform.com/agent-namespace: kagent
```

### Routing Rules (priority order)

| Priority | Condition | Routes to |
|----------|-----------|-----------|
| 1 | Alert type matches platform agent (cert-manager, external-dns, node) | Platform agent |
| 2 | Namespace has `triage.platform.com/agent` annotation | Team's BYOA agent |
| 3 | Namespace has `team` label → lookup agent by convention (`{team}-triage-agent`) | Team's agent (convention-based) |
| 4 | No annotation, no label match | Platform generic `sre-triage-agent` (fallback) |

### Platform Alert Types (always routed to platform agents)

| Alert / Event Pattern | Platform Agent |
|-----------------------|----------------|
| Certificate expiry, ACME failures, Issuer errors | `cert-manager-agent` |
| DNS record sync failures, zone errors | `external-dns-agent` |
| Ingress controller errors, TLS termination | `ingress-agent` |
| Node NotReady, resource pressure, OOM system | `node-health-agent` |
| PVC pending, storage class errors | `storage-agent` |
| Flux/ArgoCD reconciliation failures | `gitops-agent` |

---

## BYOA Contract

### What teams provide

An Agent CRD with their domain knowledge:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: payments-triage-agent
  namespace: kagent
  labels:
    platform.com/team: payments
    platform.com/type: triage
spec:
  description: Payments team triage agent
  type: Declarative
  declarative:
    systemMessage: |
      You are the Payments team triage agent.

      ## Your namespaces
      - payments-prod
      - payments-staging
      - payments-dev

      ## Team services
      - payment-api: Go service, connects to PostgreSQL + Redis + Stripe API
      - payment-worker: Background job processor, reads from SQS
      - payment-gateway: Nginx ingress, TLS terminated

      ## Runbooks
      ### PostgreSQL connection failures
      1. Check pod logs for "connection refused" or "too many connections"
      2. Verify PostgreSQL pod health in database namespace
      3. Check connection pool settings (max 20 per pod)
      4. Escalate to DBA team if replication lag > 30s

      ### Stripe webhook failures
      1. Check payment-api logs for 4xx/5xx from Stripe
      2. Verify webhook endpoint is reachable (k8s_check_service_connectivity)
      3. Check DLQ depth in SQS

      ## Escalation
      - Slack: #payments-incidents
      - PagerDuty: payments-oncall
      - Never expose card numbers or PII in triage output

      ## Output format
      Follow the standard Issue/Evidence/Root Cause/Fix format.
      Always use the EXACT namespace provided. Copy it character-for-character.
      When recommending resource creation, include ready-to-use YAML.

    modelConfig: litellm-qwen-14b    # platform-provided model
    tools:
      - type: McpServer
        mcpServer:
          name: kagent-tool-server
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            # Read-only tools (triage agents)
            - k8s_get_resources
            - k8s_describe_resource
            - k8s_get_pod_logs
            - k8s_get_events
            - k8s_get_resource_yaml
            - k8s_check_service_connectivity
            - k8s_execute_command
            - helm_list_releases
            - helm_get_release
  a2aConfig:
    skills:
      - id: payments-triage
        name: Payments Triage
        description: Investigate issues in payments namespaces
        tags: [payments, triage]
```

### What the platform provides

| Component | Description |
|-----------|-------------|
| **KAgent controller** | Central controller managing all agents |
| **kagent-tool-server** | MCP tool server with k8s + helm tools |
| **LLM endpoint** | Shared model pool via KubeAI/LiteLLM (Qwen 14B default, teams can upgrade) |
| **Argo Events pipeline** | EventSource + Sensor + routing WorkflowTemplate |
| **Reporting pipeline** | GitLab issue creation, Slack/Teams notifications |
| **Agent CRD template** | Starter template teams copy and customize |
| **Onboarding automation** | Kyverno policy validates Agent CRDs on apply |

---

## Scaling Considerations

### Model Capacity

| Scale | Approach |
|-------|----------|
| **Homelab / PoC** | Single Qwen 14B on GPU (current setup) |
| **10-50 teams** | KubeAI with 2-3 GPU replicas, queue-based routing |
| **100+ teams** | Azure OpenAI / cloud LLM backend via LiteLLM, per-team rate limits |
| **1000 NS** | Cloud LLM required. Estimated ~500 alerts/day across all NS, each taking ~1min LLM time. Budget ~$50-200/day on GPT-4o-mini or equivalent. |

### RBAC Scoping

Current state: kagent-tool-server has cluster-wide read access. For production:

| Option | Pros | Cons |
|--------|------|------|
| **A. Namespace-scoped ServiceAccounts** | True isolation per team | Need one tool-server per team (operational overhead) |
| **B. OPA/Kyverno admission control** | Single tool-server, policy-enforced | Complexity in policy rules |
| **C. Agent-level namespace allowlist** | Simple — agent system prompt lists allowed namespaces | Soft enforcement only (LLM could ignore it) |
| **D. Hybrid: C for triage, A for remediation** | Triage is read-only (low risk), remediation gets strict RBAC | Good balance of security and simplicity |

**Recommendation**: Start with **Option C** (namespace allowlist in system prompt) for the PoC. Move to **Option D** for production — remediation agents get namespace-scoped ServiceAccounts, triage agents use the shared tool-server with prompt-based scoping.

### Agent Discovery

| Approach | Description |
|----------|-------------|
| **Namespace annotation** (recommended) | `triage.platform.com/agent: team-x-agent` — simple, GitOps-friendly |
| **ConfigMap registry** | Central ConfigMap mapping namespaces → agents — easier to audit |
| **CRD label selector** | Sensor queries KAgent CRDs by team label — dynamic but complex |

---

## Onboarding Flow

```
1. Team creates Agent CRD YAML (from template)
   ↓
2. Team adds system prompt with their runbooks
   ↓
3. Team submits PR to GitOps repo
   ↓
4. Kyverno policy validates:
   - Required labels (platform.com/team, platform.com/type)
   - System prompt includes namespace list
   - Tools are from approved list (no write tools for triage)
   - ModelConfig uses platform-provided model
   ↓
5. PR merged → Flux/ArgoCD deploys Agent CRD
   ↓
6. Team annotates their namespaces:
   kubectl annotate ns payments-prod triage.platform.com/agent=payments-triage-agent
   ↓
7. Next alert in payments-prod → routed to payments-triage-agent
```

---

## Platform Agents — Initial Set

### cert-manager-agent

```
System prompt focus:
- Certificate expiry timeline (warn at 30d, critical at 7d)
- ACME challenge failures (HTTP-01 vs DNS-01 debugging)
- ClusterIssuer vs Issuer health
- Tools: k8s_describe_resource, k8s_get_events, k8s_get_resources
```

### external-dns-agent

```
System prompt focus:
- DNS record sync status (TXT ownership records)
- Zone delegation issues
- Provider-specific errors (Azure DNS, Route53, Cloudflare)
- Tools: k8s_get_resources, k8s_describe_resource, k8s_get_pod_logs
```

### ingress-agent

```
System prompt focus:
- Ingress controller pod health and logs
- TLS certificate binding (cert-manager integration)
- Backend service health checks
- 502/503/504 gateway error patterns
- Tools: k8s_describe_resource, k8s_get_pod_logs, k8s_check_service_connectivity
```

### node-health-agent

```
System prompt focus:
- Node conditions (Ready, MemoryPressure, DiskPressure, PIDPressure)
- Allocatable vs allocated resources
- Taint/toleration mismatches causing unschedulable pods
- AKS node pool scaling recommendations
- Tools: k8s_get_resources, k8s_describe_resource, k8s_get_events
```

---

## Comparison with Current Approach

| Dimension | Holmes (current) | BYOA Agent Platform (proposed) |
|-----------|-----------------|-------------------------------|
| Agent per team | No — one agent for everything | Yes — team-specific agents with domain knowledge |
| Runbook management | Platform team manages all runbooks in Holmes config | Teams manage their own runbooks as Agent CRDs in Git |
| Routing | All alerts → same agent | Namespace annotations route to correct agent |
| Tool scoping | All tools loaded every call | Per-agent tool selection (token-efficient) |
| Self-service | No — requires platform team changes | Yes — teams PR their Agent CRD |
| Helm/gateway tools | No — kubectl only via AKS-MCP | Yes — native helm, kgateway, connectivity tools |
| Remediation | Same agent does triage + fix (risky) | Separate triage (readonly) and remediation (readwrite) agents |
| Escalation | Manual | Agent-to-agent via A2A protocol |
| Scale | Single LLM call per alert | Distributed agents, pooled model capacity |

---

## PoC Scope

To validate the concept with the team:

1. **Platform agents**: Deploy `cert-manager-agent` and `external-dns-agent`
2. **BYOA example**: One app team deploys their own agent with custom runbooks
3. **Routing sensor**: Argo Events sensor that reads namespace annotations and dispatches
4. **Reporting**: GitLab issues + Slack notifications (existing pipeline)
5. **Metrics**: Compare triage quality, time-to-resolution, and team satisfaction vs Holmes

**Estimated effort**: 2-3 days for PoC (agents + sensor + routing workflow)

---

## Open Questions

1. **Model choice for production**: Qwen 14B (self-hosted, free) vs Azure OpenAI (paid, faster, more reliable at scale)?
2. **Remediation policy**: Which teams get auto-remediation agents? What approval gate?
3. **Agent versioning**: How do teams test agent changes before production? Staging agent CRD?
4. **Cost allocation**: If using cloud LLM, how to charge-back per team?
5. **Audit trail**: How to track which agent took which action? (KAgent has session history, but need central logging)
6. **Multi-cluster**: One KAgent controller per cluster, or central controller with multi-cluster tool access?

---

## Next Steps

- [ ] Present proposal to platform team
- [ ] Gather feedback on BYOA contract and onboarding flow
- [ ] Decide on model strategy (self-hosted vs cloud)
- [ ] Build PoC with 2 platform agents + 1 BYOA team agent
- [ ] Demo to app teams and collect interest
