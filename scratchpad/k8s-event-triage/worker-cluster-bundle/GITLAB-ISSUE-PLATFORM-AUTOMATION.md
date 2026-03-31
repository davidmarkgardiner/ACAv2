<!--
Name: AKS Platform Automation — Onboarding & Runtime Triage
Description: High-level design proposal for two platform automation capabilities
Title: "AKS Platform Automation — Onboarding & Runtime Triage Design"
Labels: ~"architecture" ~"platform" ~"kagent" ~"argo-workflows" ~"proposal"
Assignees: David Gardiner
-->

## Description

High-level design for two platform automation capabilities sharing a management cluster per environment:

1. **Onboarding Automation** — Deterministic provisioning of namespaces, apps, RBAC, and Azure resources
2. **Runtime Triage** — AI-driven, event-triggered K8s issue diagnosis and notification

Both consume kagent (Kubernetes-native AI agent framework) but for different purposes. Both share the same management cluster infrastructure.

Full proposal document: `PLATFORM-PROPOSAL.md`

## Problem Statements

### Onboarding
- Namespace creation is manual, inconsistent, and lacks guardrails
- No standard application deployment path across teams
- Azure resource provisioning (workload identity, role assignments) is manual and error-prone
- External resources (Key Vault, databases) require manual tickets and days of lead time
- RBAC applied ad-hoc with no audit trail or drift detection

### Runtime Triage
- K8s Warning events go unnoticed until users report issues
- CrashLoopBackOff, OOMKilled, ImagePullBackOff require manual investigation every time
- No automated first-pass diagnosis — on-call starts from scratch
- No audit trail of what was investigated and what was found

## Desired State (Phases)

- [ ] **Phase 1:** Management cluster setup — Argo Workflows, Argo Events, kagent, LiteLLM, ASO, LGTM monitoring stack
- [ ] **Phase 2:** Namespace onboarding — self-service creation with quotas, network policies, labels, audit trail
- [ ] **Phase 3:** Runtime triage on worker clusters — event-driven K8s Warning → per-namespace agent diagnosis → GitLab + Teams
- [ ] **Phase 4:** Application onboarding — three input modes (payload/manifest/Helm), workload identity via ASO, post-deploy validation via kagent
- [ ] **Phase 5:** External resource onboarding — Key Vault access, databases, storage accounts via ASO templates
- [ ] **Phase 6:** RBAC layer — namespace-scoped RBAC from onboarding payload, Azure RBAC via ASO, drift detection
- [ ] **Phase 7:** Full observability — Grafana dashboards for LLM usage + pipeline health, alerting, cost attribution per team

## Tooling

| Tool | Purpose |
|------|---------|
| Argo Workflows | Orchestration engine for both projects |
| Argo Events | Event-driven triggers — K8s events (triage), webhooks (onboarding) |
| kagent | AI agents — triage diagnosis + post-deploy validation |
| LiteLLM + PostgreSQL | LLM proxy, token tracking, spend dashboard |
| Azure Service Operator (ASO) | Declarative Azure resource provisioning |
| External Secrets Operator | Secret injection from Key Vault |
| kube-prometheus-stack | Monitoring, alerting, Grafana dashboards |
| Alloy → Loki | Log aggregation |
| Kyverno / Gatekeeper | Policy enforcement on created resources |
| GitLab | Audit trail, issue tracking, GitOps |

## Architecture Diagrams

| Diagram | File |
|---------|------|
| Onboarding system | `application-stack/core/app-onboarding/architecture.excalidraw` |
| Hybrid triage | `kagent-triage/architecture-hybrid-triage.excalidraw` |

## Acceptance Criteria

- [ ] Problem statements agreed with stakeholders
- [ ] Desired state phases reviewed and prioritised
- [ ] Tooling approved (or alternatives identified)
- [ ] Management cluster requirements documented
- [ ] Phase 1 implementation plan with estimated effort
- [ ] Security, monitoring, and logging requirements captured

## Related

- #23 — Migrate kagent to worker clusters (hybrid model)
- #24 — RBAC lockdown on management cluster
- #25 — Kagent workload protection
- #26 — SAD architecture document

/label ~"architecture" ~"platform" ~"kagent" ~"argo-workflows" ~"proposal"
