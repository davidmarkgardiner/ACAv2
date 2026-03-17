<!--
Labels: kagent, k8s-event-triage, tested
Milestone: KAgent — Agent Onboarding
Status: Phase 2 complete (fault injection tested)
-->

# KAgent: cert-manager namespace agent — TESTED

> Cloned from template: `13-kagent-onboarding-template.md`
> **Namespace:** `cert-manager`
> **Component:** cert-manager (X.509 certificate lifecycle for Kubernetes)
> **Tested on:** Kind cluster (kind-homelab), 2026-03-13
> **KAgent version:** v0.8.0-beta4
> **LLM:** Kimi for Coding via LiteLLM proxy

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

---

## Fault Injection Results

### Test 1: Certificate with non-existent ClusterIssuer — ✅ PASS

**Fault:** Created `Certificate/test-broken-cert` referencing `ClusterIssuer/nonexistent-issuer`
**Trigger:** Manual A2A call (cert-manager emits Normal events, not Warning — see Gotcha below)

**Agent correctly:**
- Inspected the cluster with kubectl tools (not guessing)
- Found the failing Certificate and its CertificateRequest
- Identified root cause: `IssuerNotFound` — ClusterIssuer `nonexistent-issuer` doesn't exist
- Discovered all 4 working ClusterIssuers: `danat-local-ca-issuer`, `letsencrypt-prod`, `letsencrypt-staging`, `selfsigned-issuer`
- Provided 3 remediation options with exact kubectl patch commands
- Assessed risk as "Low — test certificate with no existing TLS secrets"

### Test 2: Certificate with non-existent Issuer — ✅ PASS

**Fault:** Created `Certificate/test-missing-issuer` referencing `Issuer/does-not-exist`
**Trigger:** Same A2A call (both certs diagnosed in one pass)

**Agent correctly:**
- Distinguished between `ClusterIssuer` (cluster-scoped) and `Issuer` (namespace-scoped) references
- Found no Issuer resources in the cert-manager namespace
- Provided specific fix: either create the missing Issuer or switch to a working ClusterIssuer

### Test 3: Invalid private key algorithm — ❌ NOT TESTABLE

**Fault:** Tried `spec.privateKey.algorithm: INVALID_ALGO`
**Result:** Rejected by admission webhook before any K8s event — cert-manager validates on create.
**Learning:** Webhook validation catches this before it becomes an event. Agent would only see this if webhook was down.

### Test 4: Duration < renewBefore — ❌ NOT TESTABLE

**Fault:** Tried `duration: 1h, renewBefore: 2h`
**Result:** Rejected by admission webhook.
**Learning:** Same as above — webhook catches misconfiguration at admission time.

---

## Quality Assessment

| Criteria | Result |
|----------|--------|
| Correct resource identified | ✅ Found both failing certs |
| Used cluster inspection tools | ✅ kubectl get certificates, describe certificaterequest, get clusterissuer |
| Root cause found | ✅ IssuerNotFound for both, different scoping (Issuer vs ClusterIssuer) |
| Remediation actionable | ✅ Exact kubectl patch commands provided |
| Risk assessment | ✅ "Low — test certificates" |
| Verification steps | ✅ kubectl wait + get commands |

**Overall: EXCELLENT** — The agent's output is production-quality SRE triage.

---

## Gotchas Discovered

### 1. cert-manager emits `type: Normal` events, not `type: Warning`
The k8s-warning-events EventSource only watches `type=Warning`. cert-manager errors come through as `type=Normal` with reasons like `IssuerNotFound`.

**Impact:** Auto-sensor won't trigger. Must use either:
- Direct A2A call from a custom EventSource watching Normal events with error reasons
- CronWorkflow for periodic cert health scans
- Alloy log scraping (the AKS approach)

### 2. Admission webhook blocks many misconfigurations before events fire
Invalid algorithm, impossible duration/renewBefore — all caught at admission. The agent can only diagnose these if the webhook is down.

### 3. cert-manager CRD chain is deep
Certificate → CertificateRequest → Order → Challenge. Agent needs to traverse the full chain to find root cause. Our agent handled this well for CertificateRequest but deeper chains (ACME) need more testing.

---

## Remaining Tests (Phase 2 incomplete)

| # | Fault | Status | Notes |
|---|-------|--------|-------|
| 1 | Invalid issuer ref | ✅ Done | Both ClusterIssuer and Issuer tested |
| 2 | Webhook CrashLoop | ⬜ TODO | Set webhook image to bad tag |
| 3 | cainjector OOM | ⬜ TODO | Set memory limit to 32Mi |
| 4 | ACME challenge stuck | ⬜ TODO | Create cert for invalid domain |
| 5 | Webhook scale-to-0 | ⬜ TODO | kubectl scale --replicas=0 |

---

## Phase Tracking

- [x] **Phase 1**: Research cert-manager, create agent YAML, smoke test
- [~] **Phase 2**: Fault injection — 2/5 scenarios tested, 2 not testable (webhook blocks)
- [ ] **Phase 3**: SRE review session, prompt engineering fixes, re-test
- [ ] **Phase 4**: Wire into triage pipeline (fix Normal events gap), document, sign-off

---

## Files

| File | Path | Description |
|------|------|-------------|
| Agent CR | `kagent-triage/cert-manager-agent.yaml` | kagent Agent for cert-manager |
| Sensor | `kagent-triage/cert-manager-sensor.yaml` | Argo Sensor (needs Normal events fix) |
| Fault injection | `kagent-triage/cert-manager-fault-injection.yaml` | Test certificates |
| Test results | `kagent-triage/TEST-RESULTS-2026-03-13.md` | Full output with agent responses |
