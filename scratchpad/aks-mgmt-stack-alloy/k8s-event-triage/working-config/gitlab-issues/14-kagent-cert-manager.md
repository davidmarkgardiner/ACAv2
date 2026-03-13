<!--
Labels: kagent, k8s-event-triage
Milestone: KAgent — Agent Onboarding
Assignee:
-->

# KAgent: cert-manager namespace agent

> Cloned from template: `13-kagent-onboarding-template.md`
> **Namespace:** `cert-manager`
> **Component:** cert-manager (X.509 certificate lifecycle for Kubernetes)

---

## Component Overview

cert-manager automates TLS certificate provisioning and renewal using ACME (Let's Encrypt), Vault, or self-signed issuers. Key resources:
- **Deployments**: `cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`
- **CRDs**: `Certificate`, `CertificateRequest`, `Issuer`, `ClusterIssuer`, `Order`, `Challenge`
- **Dependencies**: DNS resolution (for ACME challenges), cloud API access (for DNS01 solvers), webhook TLS

## Common Failure Modes

| Failure | K8s Events/Symptoms | Remediation |
|---------|---------------------|-------------|
| ACME challenge timeout | `Challenge` stuck in `pending`, `Order` failed | Check DNS propagation, solver config, firewall rules |
| Webhook TLS expired | `cert-manager-webhook` pod CrashLoop, admission webhook failures | Restart cainjector, check webhook cert secret |
| ClusterIssuer misconfigured | `CertificateRequest` denied, `Issuer not found` | Check ClusterIssuer status, verify secret references |
| Rate limited by Let's Encrypt | `Order` failed with 429 | Wait, check duplicate certificate requests |
| DNS01 solver auth failure | `Challenge` failed, cloud API error | Check cloud credential secret, IAM permissions |
| cainjector OOM | `cainjector` OOMKilled | Increase memory limits, check CRD count |

## Fault Injection Test Scenarios

| # | Fault | Injection Method | Expected Agent Response |
|---|-------|-----------------|------------------------|
| 1 | Webhook CrashLoop | Set webhook image to bad tag | Identify ImagePullBackOff, suggest correct image |
| 2 | Certificate renewal failure | Create cert with invalid issuer ref | Identify issuer not found, suggest correct ClusterIssuer |
| 3 | cainjector OOM | Set memory limit to 32Mi | Identify OOMKilled, suggest memory increase |
| 4 | ACME challenge stuck | Create cert for invalid domain | Identify challenge failure, check solver config |
| 5 | Webhook admission failure | Scale webhook to 0 | Identify webhook unavailable, suggest scaling back |

## Tasks

Follow all phases from the template (`13-kagent-onboarding-template.md`):

- [ ] **Phase 1**: Research cert-manager, create agent YAML, smoke test
- [ ] **Phase 2**: Run all 5 fault injection scenarios, record results
- [ ] **Phase 3**: SRE review session, prompt engineering fixes, re-test
- [ ] **Phase 4**: Wire into triage pipeline, document, sign-off
