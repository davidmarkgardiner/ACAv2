<!--
Labels: kagent, k8s-event-triage
Milestone: KAgent — Agent Onboarding
Assignee:
-->

# KAgent: external-dns namespace agent

> Cloned from template: `13-kagent-onboarding-template.md`
> **Namespace:** `external-dns`
> **Component:** ExternalDNS (automatic DNS record management from K8s resources)

---

## Component Overview

ExternalDNS watches Kubernetes Ingress/Service resources and creates corresponding DNS records in Azure DNS, Route53, or other providers. Key resources:
- **Deployment**: `external-dns`
- **Dependencies**: Cloud DNS API access (Azure DNS, Managed Identity / Service Principal), Ingress controller
- **Config**: Typically via args/env vars on the deployment, references cloud credential secrets

## Common Failure Modes

| Failure | K8s Events/Symptoms | Remediation |
|---------|---------------------|-------------|
| Cloud auth failure | `failed to list DNS zones`, 403/401 errors in logs | Check Managed Identity binding, credential secret |
| DNS zone not found | `zone not found` errors | Verify zone name in args, check Azure DNS resource exists |
| Rate limited by DNS provider | 429 errors, records not updating | Increase `--interval`, check for tight reconcile loops |
| Stale DNS records | Records pointing to old IPs | Check `--policy` (upsert-only vs sync), verify source filter |
| TXT registry conflict | `registry conflict` errors | Check TXT ownership records, clean orphaned records |
| RBAC missing | Can't watch Ingress/Service resources | Check ClusterRole bindings |

## Fault Injection Test Scenarios

| # | Fault | Injection Method | Expected Agent Response |
|---|-------|-----------------|------------------------|
| 1 | CrashLoopBackOff | Set bad image tag | Identify ImagePullBackOff, suggest correct image |
| 2 | Auth failure | Revoke/corrupt credential secret | Identify auth error in logs, suggest checking credentials |
| 3 | OOMKilled | Set memory limit to 16Mi | Identify OOMKilled, suggest memory increase |
| 4 | DNS zone misconfigured | Change zone filter to nonexistent zone | Identify zone not found, suggest correct zone name |
| 5 | Missing RBAC | Delete ClusterRoleBinding | Identify permission denied, suggest recreating binding |

## Tasks

Follow all phases from the template (`13-kagent-onboarding-template.md`):

- [ ] **Phase 1**: Research external-dns, create agent YAML, smoke test
- [ ] **Phase 2**: Run all 5 fault injection scenarios, record results
- [ ] **Phase 3**: SRE review session, prompt engineering fixes, re-test
- [ ] **Phase 4**: Wire into triage pipeline, document, sign-off
