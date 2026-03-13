# Session Summary — 2026-03-13

## 1. Workflow Pod Debug Guide

Created `DEBUG-WORKFLOW-PODS.md` — step-by-step troubleshooting for the immediate blocker: workflows are being created by the sensor but pods aren't running.

**Most likely cause:** The Argo workflow controller (in `argo` namespace) isn't configured to watch the `argo-events` namespace.

**Start here at work:**
```bash
kubectl get configmap workflow-controller-configmap -n argo -o yaml
```

**File:** [`working-config/DEBUG-WORKFLOW-PODS.md`](./DEBUG-WORKFLOW-PODS.md)

---

## 2. GitLab Issues (22 tickets)

Created `working-config/gitlab-issues/` with 22 ready-to-copy issues. Each file has labels, milestones, dependencies, and acceptance criteria in the frontmatter.

**Index:** [`working-config/gitlab-issues/README.md`](./gitlab-issues/README.md)

| Category | Tickets | Key Items |
|----------|---------|-----------|
| Fix & Stabilise | #1-2 | Debug pod creation, clean old configs |
| Production Hardening | #3-12 | Controller namespace, EventBus HA, Ollama/LLM, WorkflowTemplate v2, secrets, Alloy expansion, monitoring, smoke tests, private registry |
| KAgent Onboarding | #13-16 | Reusable template + instances for cert-manager, external-dns, ingress-nginx |
| Observability | #19-20 | KAgent logs → Loki/LGTM, LiteLLM token/cost monitoring |
| Architecture Decisions | #18, #21 | Human-in-the-loop approval, hybrid cluster model |
| Security & Compliance | #22 | SAD documentation |
| Go-Live | #17 | Full go/no-go checklist |

### KAgent Onboarding Template

Ticket #13 is a **reusable template** for onboarding a KAgent agent to any namespace. The process:

1. **Research** the component (failure modes, resources, dependencies)
2. **Create** agent YAML with namespace-anchored system prompt
3. **Fault inject** (CrashLoop, OOM, ImagePull, misconfig, dependency failure)
4. **SRE review** — real human works with the agent, identifies gaps
5. **Fine-tune** — update prompts based on SRE feedback
6. **Re-test** — verify fixes, no regressions
7. **Integrate** — wire into triage pipeline, sign off

Tickets #14-16 are pre-filled instances of this template for cert-manager, external-dns, and ingress-nginx.

---

## 3. Design Decisions (Open)

Three architectural questions raised during the session. Each has a dedicated ticket with options, trade-offs, and a decision needed.

### Human-in-the-Loop Approval

**Question:** How do engineers approve remediation actions before agents execute them?

**Options:**
- **A — Teams Adaptive Cards:** Workflow posts card with Approve/Reject buttons → webhook triggers remediation
- **B — Allow-list:** Define what agents can auto-execute (restart, scale up) vs what's manual-only (delete, RBAC changes)
- **C — Hybrid (recommended):** Tier 1 auto, Tier 2 approval, Tier 3 manual-only

**File:** [`gitlab-issues/18-human-in-the-loop-approval.md`](./gitlab-issues/18-human-in-the-loop-approval.md)

### Hybrid Management/Worker Cluster Model

**Question:** Should we move the AI stack (KAgent, LiteLLM, Ollama) to worker clusters for self-healing, keeping management cluster for critical cluster-level issues only?

**Trade-offs:** Faster self-healing and lower Event Hub cost vs more complexity and resource overhead per cluster.

**File:** [`gitlab-issues/21-hybrid-architecture-exploration.md`](./gitlab-issues/21-hybrid-architecture-exploration.md)

### SAD — Security, Authentication, and Compliance

**Question:** How do we document the security posture for stakeholders?

**Covers:** Event Hub SAS token lockdown, KAgent namespace-scoped RBAC, LiteLLM API key management, network security (NetworkPolicies, no external ingress), and a STRIDE threat model.

**File:** [`gitlab-issues/22-sad-security-compliance.md`](./gitlab-issues/22-sad-security-compliance.md)

---

## Related Documents

| Document | Purpose |
|----------|---------|
| [`PRODUCTION-PLAN.md`](./PRODUCTION-PLAN.md) | Full deployment plan (Phases 0-6), scaling, monitoring, rollback |
| [`GOTCHAS.md`](./GOTCHAS.md) | 13 lessons learned from PoC deployment |
| [`HANDOVER.md`](./HANDOVER.md) | Handover documentation |
| [`IMAGES.md`](./IMAGES.md) | Container image inventory |
| [`PRIVATE-REGISTRY.md`](./PRIVATE-REGISTRY.md) | Private ACR mirroring guide |
