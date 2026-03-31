# Meeting Structure — What We Need To Agree

## The Ask

Before we can build anything, we need alignment on three things per workstream:

| # | What | Why |
|---|------|-----|
| 1 | **Problem statement** | What's broken or missing today? What pain are we solving? |
| 2 | **Desired state** | Where do we want to end up? What does "done" look like? |
| 3 | **Tooling** | What are we allowed to use? What do we want to use? |

## The Tooling Question

This is the key decision. For each capability we're building, do we:

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| **A** | Use existing operators + Argo Workflows | Battle-tested, community-supported, faster to deliver | Dependent on upstream projects |
| **B** | Build custom operators / APIs | Full control, tailored to our needs | Slower, more maintenance, need Go expertise |
| **C** | Hybrid | Operators for standard stuff, custom for our specific logic | Best of both, but more moving parts |

### Existing tools available to us:

| Tool | What It Does | Status |
|------|-------------|--------|
| **Argo Workflows** | DAG-based orchestration, deterministic, auditable | Available, proven |
| **Argo Events** | Event-driven triggers (K8s events, webhooks) | Available, proven |
| **Flux** | GitOps sync from Git to clusters | In use today |
| **GitLab** | Source of truth, issues, CI/CD, audit trail | In use today |
| **Azure Service Operator (ASO)** | Declarative Azure resource provisioning | Available |
| **cert-manager** | TLS certificate provisioning | Available |
| **External Secrets Operator** | Secret injection from Key Vault | Available |
| **Kyverno / Gatekeeper** | Policy enforcement | Available |
| **Istio** | Service mesh, ingress, mTLS | Available |
| **kagent** | AI agents for triage, validation, assistance | PoC running |
| **LiteLLM** | LLM proxy with token tracking | PoC running |

### What we'd need to build ourselves:

| If we go custom | What's involved |
|-----------------|-----------------|
| Custom onboarding operator | Go CRD + controller, reconciliation loops, testing, maintenance |
| Custom API gateway | REST API, auth, validation, database, frontend |
| Custom event pipeline | Replace Argo Events with custom watcher + queue |

**My recommendation:** Option A (existing operators + Argo Workflows) for the first pass. We can always build custom components later if the existing tools don't fit. Proof of concepts are already running.

## Template: Per-Meeting Output

Each meeting should end with this filled in:

```
### Area: _______________

**Problem statement:**
[What's broken or missing?]

**Desired state:**
[What does "done" look like?]

**Tools:**
- [ ] Argo Workflows
- [ ] Argo Events
- [ ] Flux (GitOps)
- [ ] ASO
- [ ] cert-manager
- [ ] ESO
- [ ] kagent
- [ ] GitLab
- [ ] Custom operator (describe: ___)
- [ ] Custom API (describe: ___)

**Next step:**
[What PoC can we build to prove this works?]
```

## What Already Exists (PoCs)

| PoC | Status | Where |
|-----|--------|-------|
| Namespace onboarding workflow | Built, tested | `application-stack/core/app-onboarding/` |
| Runtime triage (11 namespace agents) | Built, tested | `kagent-triage/worker-cluster-bundle/` |
| Multi-agent dev pipeline | Running on red cluster | `mission-control-shared/agents/` |
| LiteLLM monitoring + spend tracking | Running | `mission-control-shared/agents/LITELLM-MONITORING-SETUP.md` |

We're not starting from zero. Give me the problem statement, desired state, and tools — I'll have a PoC for the next meeting.
