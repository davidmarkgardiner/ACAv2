# Multi-Cluster Cross-Regional Resilience Strategy
### Platform Engineering — Stakeholder Proposal
**Author:** Dave | Lead DevSecOps Engineer & Cloud Architect  
**Date:** February 2026  
**Status:** Final Position — For Stakeholder Approval

---

## 1. Executive Summary

This document proposes a **cross-regional active-passive failover architecture** using AKS clusters that already exist, are already paid for, and are already running 365 days a year.

No new infrastructure is required. No additional cluster costs are incurred. The proposal requires a one-time investment in onboarding automation and GitOps configuration — after which every team in every region has permanent, pre-provisioned failover capability as a standard feature of the platform.

The alternative — spinning up a temporary second cluster during rebuilds or failures and tearing it down afterwards — delivers a 30-day resilience window per event, costs the same or more in aggregate over a year, and leaves teams with no protection for the other 335 days. This is not a reasonable long-term position.

---

## 2. What We Already Have

Three regional clusters are already deployed, already paid for, and already running continuously:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐  │
│   │  AMERICAS       │   │  EMEA           │   │  APAC           │  │
│   │  Cluster        │   │  Cluster        │   │  Cluster        │  │
│   │                 │   │                 │   │                 │  │
│   │  US users       │   │  EU users       │   │  APAC users     │  │
│   │  (primary)      │   │  (primary)      │   │  (primary)      │  │
│   └─────────────────┘   └─────────────────┘   └─────────────────┘  │
│                                                                     │
│   All three running 365 days a year. All already paid for.         │
└─────────────────────────────────────────────────────────────────────┘
```

The only question is whether we use this infrastructure intelligently or leave resilience capacity sitting idle.

---

## 3. Proposed Architecture

Each regional cluster acts as the **primary** for its local users and as a **pre-provisioned failover target** for another region. In normal operation nothing changes — users work on their local cluster with optimal latency and data residency compliance. In a degradation, rebuild, or failure event, teams switch to their pre-configured failover cluster. The namespace, RBAC, secrets, and workload identity bindings are already there. No rebuild required.

### 3.1 Regional Topology & Failover Relationships

```
                    ┌─────────────────────┐
                    │     EMEA Cluster    │
                    │     (Primary: EU)   │
                    └────────┬────────────┘
                             │
              ┌──────────────┴──────────────┐
              │  Failover for APAC          │
              │  Failover target for AMER   │
              └─────────────────────────────┘
                    ▲                   ▲
                    │                   │
    ┌───────────────┴───┐       ┌───────┴───────────────┐
    │  AMERICAS Cluster │       │  APAC Cluster         │
    │  (Primary: US)    │       │  (Primary: APAC)      │
    └───────────────────┘       └───────────────────────┘
              │                           │
    Failover: EMEA              Failover: EMEA
    Target for EMEA             Target for AMER


  Normal Operation:     AMER users → AMER cluster
                        EMEA users → EMEA cluster
                        APAC users → APAC cluster

  APAC event:           APAC users → EMEA cluster (pre-provisioned)
  EMEA event:           EMEA users → AMER cluster (pre-provisioned)
  AMER event:           AMER users → EMEA cluster (pre-provisioned)
```

### 3.2 What "Pre-Provisioned" Means

At onboarding, every team's namespace, RBAC, Workload Identity Federation bindings, and External Secrets configuration are provisioned on their **primary cluster and their designated failover cluster** simultaneously. This is a parameter change in the existing Argo Workflows onboarding pipeline — not a new process.

```
Onboarding Request (Git PR)
        │
        ▼
Argo Workflow triggered
        │
        ├──► Primary cluster (e.g. APAC)
        │    ├── Namespace + RBAC
        │    ├── Workload Identity Federation (UAMI)
        │    └── External Secrets bindings (Key Vault)
        │
        └──► Failover cluster (e.g. EMEA)
             ├── Namespace + RBAC
             ├── Workload Identity Federation (UAMI)
             └── External Secrets bindings (Key Vault)

Both clusters share the same GitOps repo as source of truth.
Application workloads are identical on both at all times.
```

---

## 4. GitOps Synchronisation

All three clusters subscribe to the same Argo CD App-of-Apps source. Application workloads are identical across all clusters. Cluster-specific configuration is isolated via Helm values overlays scoped per cluster.

```
git-repo/
├── apps/                        # Identical across all clusters
│   ├── app-a/
│   ├── app-b/
│   └── app-c/
├── platform/                    # Shared platform tooling
│   ├── kyverno/
│   ├── istio/
│   ├── keda/
│   └── external-secrets/
└── clusters/
    ├── americas/                # Region-specific overrides
    │   ├── values.yaml
    │   └── kustomization.yaml
    ├── emea/
    │   ├── values.yaml
    │   └── kustomization.yaml
    └── apac/
        ├── values.yaml
        └── kustomization.yaml
```

Drift detection is enforced via Argo CD health checks. `OutOfSync` state triggers an immediate alert. Clusters cannot silently diverge from the source of truth.

---

## 5. Failover Process

In a rebuild or degradation event, the failover process is:

```
  EVENT (rebuild / failure / CIDR change / NAP migration)
        │
        ▼
  Is failover cluster pre-provisioned?  ──► YES (always, by design)
        │
        ▼
  DNS alias update OR kubeconfig context switch
        │
        ▼
  Teams continue work on failover cluster
  (namespace, RBAC, secrets, workload identity already in place)
        │
        ▼
  Primary cluster rebuilt / recovered at leisure
  (no time pressure, no user disruption)
        │
        ▼
  DNS alias updated back to primary
  Teams return to primary cluster
```

Compare this to the current approach:

```
  EVENT
        │
        ▼
  Spin up new cluster from scratch
        │
        ▼
  Provision namespaces, RBAC, identity, secrets
        │
        ▼
  Wait for GitOps sync to stabilise
        │
        ▼
  Smoke tests, validation
        │
        ▼
  DNS cutover
        │
        ▼
  Teams unblocked  (hours to a full day later)
        │
        ▼
  Delete old cluster after 30 days
  (back to zero resilience)
```

The current approach delivers temporary resilience at the cost of significant engineering effort, user disruption, and time pressure. This proposal delivers **permanent resilience at no additional infrastructure cost**.

---

## 6. Cost Analysis

| Approach | Infrastructure Cost | Resilience Window | Engineering Overhead |
|---|---|---|---|
| **Current (spin up on demand)** | 2x cluster cost for ~30 days per event | 30 days per rebuild only | High — full cluster standup each time |
| **Proposed (use existing clusters)** | Zero additional cost | 365 days per year, permanent | Low — one-time automation investment |

The existing three regional clusters are already funded. Making them failover targets for each other costs nothing in infrastructure. The one-time investment is updating the onboarding Argo Workflow to provision on two clusters instead of one.

There is no credible cost argument against this proposal. The current approach costs more in aggregate over a year and delivers less.

---

## 7. Addressing Anticipated Objections

### "Data residency — we can't move APAC workloads to EMEA"

This is a legitimate consideration and the answer is: **not all workloads are equal**. Stateless compute workloads — the majority of platform engineering tooling, dev/engineering tier workloads, and CI/CD pipelines — carry no data residency obligation and can fail over freely. Workloads subject to MAS, GDPR, or other regulatory data residency requirements are flagged at onboarding and assigned a compliant failover target (for example, an APAC DR region rather than EMEA). This is a policy enforcement problem, not an architecture problem, and Kyverno is already in place to enforce it.

The failover target per workload is defined at onboarding and stored in Git. It is not an ad-hoc decision made under pressure during an incident.

### "Latency — APAC to EMEA is 150-200ms"

Correct. For a **temporary failover situation** this is entirely acceptable for the vast majority of workloads. For latency-sensitive production workloads where this matters, those workloads should be evaluated for whether they belong on a shared AKS platform at all, and if so, whether a closer DR region is warranted. This is a scoping conversation, not a reason to reject the architecture.

### "Capacity — EMEA can't absorb APAC load on top of its own"

Node pools are sized with headroom. The expectation is not that EMEA absorbs 100% of APAC production traffic permanently — it absorbs a **temporary, time-limited failover** while the APAC cluster is restored. KEDA autoscaling and Node Auto Provisioner handle burst capacity. If specific workloads require guaranteed capacity reservation on the failover cluster, that is a node pool sizing decision made at onboarding, not a platform architecture problem.

### "A new standup cluster is the only reliable way to get a clean environment"

A clean environment is achieved by rebuilding one cluster while users run on the other via the pre-provisioned failover. The rebuild produces a clean cluster. Users are never disrupted. This is strictly better than the current approach in every dimension.

### "This is too complex to manage"

Managing three clusters with a shared GitOps source of truth and automated onboarding is operationally simpler than repeatedly standing up and tearing down temporary clusters on an ad-hoc basis throughout the year. The complexity is front-loaded into the automation once. Every subsequent rebuild or failure event is a non-event.

---

## 8. Implementation

### Phase 1 — Automation (Weeks 1–4)
Update the Argo Workflows onboarding pipeline to provision namespaces, RBAC, and Workload Identity Federation bindings on both primary and failover clusters. Update External Secrets Operator configuration to support cross-region Key Vault access where required.

### Phase 2 — Validation (Weeks 5–6)
Onboard a pilot team to both their primary and failover clusters. Simulate a failover event. Validate that the switch is seamless. Document the runbook.

### Phase 3 — Rollout (Weeks 7–12)
Re-onboard all existing teams to include failover cluster provisioning. Publish maintenance calendar with staggered windows per region. Decommission the practice of spinning up temporary clusters for rebuilds.

---

## 9. Summary

Three regional clusters already exist. They already run 365 days a year. They are already paid for.

This proposal uses them intelligently — making each cluster a pre-provisioned failover target for another region, with namespaces, RBAC, secrets, and workload identity bindings provisioned automatically at onboarding via the existing Argo Workflows pipeline.

The result is permanent cross-regional resilience, zero-disruption rebuilds, and no additional infrastructure cost. The alternative — temporary clusters spun up on demand — is more expensive in aggregate, more disruptive to users, and leaves the platform with no resilience capability for the majority of the year.

This is the correct architecture. The platform team's position is that this is how we proceed.

---

*Prepared by Dave | Platform Engineering | Edinburgh*  
*This document represents the Platform Engineering team's final architectural position.*