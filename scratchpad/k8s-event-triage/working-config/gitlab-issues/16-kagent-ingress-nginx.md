<!--
Labels: kagent, k8s-event-triage
Milestone: KAgent — Agent Onboarding
Assignee:
-->

# KAgent: ingress-nginx namespace agent

> Cloned from template: `13-kagent-onboarding-template.md`
> **Namespace:** `ingress-nginx`
> **Component:** NGINX Ingress Controller (L7 load balancing and TLS termination)

---

## Component Overview

NGINX Ingress Controller processes Ingress resources and configures NGINX to route traffic. Key resources:
- **Deployments/DaemonSets**: `ingress-nginx-controller`
- **Service**: `ingress-nginx-controller` (LoadBalancer type, external IP)
- **ConfigMap**: `ingress-nginx-controller` (NGINX global config)
- **IngressClass**: `nginx`
- **Dependencies**: cloud load balancer, cert-manager (for TLS), DNS (for hostname resolution)

## Common Failure Modes

| Failure | K8s Events/Symptoms | Remediation |
|---------|---------------------|-------------|
| Config reload failure | `nginx: configuration is invalid`, controller logs errors | Check recent Ingress changes, validate NGINX config |
| Backend service unavailable | 502/503 errors, `upstream connect error` | Check backend pod health, service endpoints |
| TLS secret missing | `SSL certificate not found`, 495 errors | Verify TLS secret exists, check cert-manager Certificate |
| LoadBalancer pending | Service stuck in Pending, no external IP | Check cloud LB quotas, NSG rules, subnet capacity |
| OOMKilled under load | Controller OOMKilled during traffic spike | Increase memory limits, check worker_connections |
| Admission webhook failure | Ingress creation rejected | Check webhook pod health, caBundle in ValidatingWebhookConfiguration |

## Fault Injection Test Scenarios

| # | Fault | Injection Method | Expected Agent Response |
|---|-------|-----------------|------------------------|
| 1 | Controller CrashLoop | Set bad image tag | Identify ImagePullBackOff, suggest correct image |
| 2 | Config reload failure | Apply Ingress with invalid annotation | Identify config error in logs, suggest fix |
| 3 | OOMKilled | Set memory limit to 32Mi | Identify OOMKilled, suggest memory increase |
| 4 | TLS secret missing | Delete TLS secret referenced by Ingress | Identify missing secret, suggest checking cert-manager |
| 5 | Backend 502 | Scale backend deployment to 0 | Identify no endpoints, suggest checking backend pods |

## Tasks

Follow all phases from the template (`13-kagent-onboarding-template.md`):

- [ ] **Phase 1**: Research ingress-nginx, create agent YAML, smoke test
- [ ] **Phase 2**: Run all 5 fault injection scenarios, record results
- [ ] **Phase 3**: SRE review session, prompt engineering fixes, re-test
- [ ] **Phase 4**: Wire into triage pipeline, document, sign-off
