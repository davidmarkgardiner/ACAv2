# KAgent Namespace Triage — Test Results

**Date:** 2026-03-13
**Cluster:** kind-homelab (Kind, single node, always-on mini PC)
**KAgent Version:** v0.8.0-beta4
**LLM:** Kimi for Coding via LiteLLM proxy
**Tested by:** Scotty (orchestrator) + MC specialist agents (Sonnet)

---

## Infrastructure Deployed

| Component | Status | Namespace | Notes |
|-----------|--------|-----------|-------|
| kagent controller | ✅ Running | kagent | v0.8.0-beta4 |
| kagent UI | ✅ Running | kagent | Exposed at https://kagent.xxx |
| LiteLLM proxy | ✅ Running | kagent | Routing to Kimi API |
| test-ns-agent | ✅ Ready | kagent | General test namespace diagnostics |
| cert-manager-agent | ✅ Ready | kagent | TLS certificate lifecycle specialist |
| kagent-triage WorkflowTemplate | ✅ Deployed | argo-events | Routes events → agents via A2A |
| kagent-triage-test-ns Sensor | ✅ Deployed | argo-events | Filters Warning events from test-ns |
| kagent-triage-cert-manager Sensor | ✅ Deployed | argo-events | Filters events from cert-manager |
| k8s-warning-events EventSource | ✅ Running | argo-events | Pre-existing, cluster-wide |

---

## Test 1: test-ns — CrashLoopBackOff (auto-triggered via sensor)

**Fault injected:** `busybox` pod with `exit 1` command → CrashLoopBackOff

**Trigger:** K8s Warning event → EventSource → Sensor → Argo Workflow → test-ns-agent

**Result: ✅ PASS**

Agent correctly diagnosed:
- Identified container "crash" running `exit 1`
- Found exit code 1 with 3 restarts
- Identified CrashLoopBackOff status
- Provided structured diagnostic report with remediation steps

**Workflow:** `kagent-triage-test-ns-zt2wb` — Succeeded
**Response time:** ~30s from event to diagnosis

### Agent Output (excerpt)
```
## Diagnostic Report: CrashLoopBackOff on crashloop-test-pod

### Event Summary
A BackOff event was triggered on Pod `crashloop-test-pod` in namespace `test-ns`.
The container named "crash" is repeatedly failing and being restarted.

### Initial Findings
- Name: crashloop-test-pod
- Container: crash (busybox:latest)
- Status: CrashLoopBackOff
- Restart Count: 3
- Exit Code: 1 (Error)
```

**Workflows triggered on test-ns:**
| Workflow | Status | Duration |
|----------|--------|----------|
| kagent-triage-test-ns-zmg66 | ✅ Succeeded | ~30s |
| kagent-triage-test-ns-zt2wb | ✅ Succeeded | ~30s |
| kagent-triage-test-ns-zlfq7 | ✅ Succeeded | ~30s |
| kagent-triage-test-ns-z2r7k | ❌ Failed | ~20s |
| kagent-triage-test-ns-zvkcb | ✅ Succeeded | ~30s |

**Success rate:** 4/5 (80%) — one failure likely due to rate limiting or transient LLM timeout.

---

## Test 2: cert-manager — IssuerNotFound (manual A2A invocation)

**Faults injected:**
1. `Certificate/test-broken-cert` — references non-existent `ClusterIssuer/nonexistent-issuer`
2. `Certificate/test-missing-issuer` — references non-existent `Issuer/does-not-exist`

**Trigger:** Manual A2A call to cert-manager-agent via `POST /api/a2a/kagent/cert-manager-agent/`

**Result: ✅ PASS — Excellent quality**

Agent correctly:
- Used kubectl tools to inspect the cluster (not just guessing from the prompt)
- Found both failing certificates and their CertificateRequest objects
- Identified the exact error: `IssuerNotFound` for both
- Discovered all 4 working ClusterIssuers: `danat-local-ca-issuer`, `letsencrypt-prod`, `letsencrypt-staging`, `selfsigned-issuer`
- Provided 3 remediation options with exact kubectl commands

### Agent Output (full)
```
## 🔍 Issue
Both certificates (test-broken-cert and test-missing-issuer) are failing with
IssuerNotFound errors because they reference non-existent issuers.

## 📋 Affected Resources
| Resource | Namespace | Issue |
|----------|-----------|-------|
| Certificate/test-broken-cert | cert-manager | References ClusterIssuer `nonexistent-issuer` (does not exist) |
| Certificate/test-missing-issuer | cert-manager | References Issuer `does-not-exist` (does not exist) |

## 🔬 Root Cause

**test-broken-cert:**
- Certificate references `ClusterIssuer` named `nonexistent-issuer`
- The cluster has 4 working ClusterIssuers: danat-local-ca-issuer, letsencrypt-prod,
  letsencrypt-staging, selfsigned-issuer
- Event confirms: "Referenced ClusterIssuer not found"

**test-missing-issuer:**
- Certificate references `Issuer` named `does-not-exist`
- No Issuer resources exist in the cert-manager namespace
- Event confirms: "Referenced Issuer not found"

## 🛠️ Remediation

### Option 1: Update Certificates to Use Existing ClusterIssuers (Recommended)
kubectl patch certificate test-broken-cert -n cert-manager \
  --type='merge' -p='{"spec":{"issuerRef":{"name":"selfsigned-issuer","kind":"ClusterIssuer"}}}'

kubectl patch certificate test-missing-issuer -n cert-manager \
  --type='merge' -p='{"spec":{"issuerRef":{"name":"selfsigned-issuer","kind":"ClusterIssuer"}}}'

### Option 2: Create the Missing Issuers
(Provided full YAML for both ClusterIssuer and Issuer)

### Option 3: Delete the Test Certificates
kubectl delete certificate test-broken-cert test-missing-issuer -n cert-manager

## ⚠️ Risk Level
Low — test certificates with no existing TLS secrets.

## ✅ Verification
kubectl get certificate -n cert-manager
kubectl wait --for=condition=Ready certificate/test-broken-cert -n cert-manager --timeout=60s
```

---

## Known Issues / Gaps

### 1. cert-manager events are `type: Normal`, not `type: Warning`
The k8s-warning-events EventSource only watches `type=Warning`. cert-manager emits errors as `type=Normal` with reasons like `IssuerNotFound`. This means the sensor won't auto-trigger for cert-manager errors.

**Fix needed:** Either:
- Create a separate EventSource for cert-manager that watches Normal events with error-related reasons
- Or configure cert-manager to emit Warning events (upstream feature request)

### 2. LLM provider — Kimi quota usage
Running workflows auto-triggered by events burns Kimi API quota. Each workflow uses ~13K tokens.
**Recommendation:** Switch to local Qwen model on Proxmox KubeAI (free) or add rate limiting to sensors.

### 3. One workflow failure in test-ns batch
1 of 5 auto-triggered workflows failed. Likely transient LLM timeout or rate limit. Need to check workflow logs for the specific failure.

---

## Files

| File | Description |
|------|-------------|
| `cert-manager-agent.yaml` | kagent Agent CR — cert-manager specialist |
| `cert-manager-sensor.yaml` | Argo Sensor — routes cert-manager events |
| `cert-manager-fault-injection.yaml` | Fault injection manifests |
| `test-ns-agent.yaml` | kagent Agent CR — test-ns diagnostics |
| `test-ns-sensor.yaml` | Argo Sensor — routes test-ns events |
| `test-ns-test-error.yaml` | Fault injection for test-ns |
| `02-workflow-kagent-triage.yaml` | Argo WorkflowTemplate — the triage workflow |
| `04-ingress-kagent-ui.yaml` | Traefik IngressRoute for kagent UI |

---

## Next Steps

1. **Fix cert-manager sensor** — handle `Normal` type events with error reasons
2. **Run remaining fault scenarios** from gitlab-issues/14 (webhook CrashLoop, cainjector OOM, ACME challenge stuck)
3. **Switch LLM to local Qwen** on Proxmox to save Kimi quota
4. **Add external-dns and ingress-nginx agents** (gitlab-issues #15, #16)
5. **Cross-reference with working-config** at `aks-mgmt-stack/k8s-event-triage/working-config/` for AKS alignment
