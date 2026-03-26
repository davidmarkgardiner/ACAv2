# UAMI Workload Identity Federation — Software Factory Multi-Agent Analysis

**Generated:** 2026-03-26
**Input:** Security investigation + peer review
**Agents:** Architect (Sonnet 4.6), Researcher (GPT 5.4), Security Reviewer (Opus 4.6)

---

## Agent 1: Researcher (GPT 5.4) — Existing Solutions & Industry Context

### Key Findings

1. **No Azure built-in policies exist** for restricting `FederatedIdentityCredential` issuer URLs. The custom policy approach in the doc is the industry-standard workaround.

2. **Microsoft does not consider this a design gap** — the free-text issuer field is intentional since Entra ID federates with any OIDC-compliant IdP (GitHub Actions, GitLab, AWS, on-prem K8s), not just AKS.

3. **No planned fixes** from Microsoft — no publicly announced plans for environment-aware OIDC URLs or built-in cross-environment blocking.

4. **AWS and GCP handle this better:**
   - **AWS (IRSA):** Requires explicitly creating an IAM OIDC Identity Provider resource in the target AWS Account. Dev can't assume prod roles unless the prod account admin explicitly provisions the dev cluster's OIDC provider.
   - **GCP:** Ties Workload Identity Pools to GCP Projects with explicit cross-project IAM bindings, making accidental cross-env bindings much easier to audit.

5. **No built-in Defender/Sentinel rules** for cross-environment AKS OIDC bindings. Must build custom detection with Sentinel Watchlists mapping cluster UUIDs to environments.

6. **Community patterns:** The Custom Policy + Event Grid pattern is the most accepted. Some teams use hardened Terraform modules that auto-compute the correct OIDC URL based on environment context.

---

## Agent 2: Architect (Sonnet 4.6) — Control Set Review

### Azure Policy (Layer 1): Correct, But Two-Component System

The policy is the right insertion point — operates before the resource write, applies regardless of tool/principal, can't be bypassed by Contributor. **However, it's actually a two-component system:** the policy definition AND the allowlist refresh pipeline. Both need SLAs and monitoring.

**Edge cases flagged:**
- Empty allowlist = deny ALL federation writes (fail-closed, but will be treated as an incident)
- Multi-region clusters need regional-agnostic allowlist queries
- Policy exemption process must be defined before Deny mode
- Existing FederatedIdentityCredentials must be audited before switching to Deny (blocking prerequisite)

### Kyverno (Layer 2): ConfigMap Trust Model Is the Weak Point

The policy scope is correct but effectiveness depends entirely on ConfigMap integrity. Who can write it? If GitOps-managed, how is that enforced? The ConfigMap and Azure Policy allowlists are two separate inventories that must stay in sync — UAMI provisioning should emit events that update both atomically.

### Cluster Rebuild: Event Grid Sufficient in Steady State, Not for Failure Window

Recommended: define acceptable failure window explicitly, add monitoring for the pipeline itself, consider pre-staging new OIDC URL immediately post-creation (AKS API exposes it immediately).

### Riker's Suggestions Evaluated

| Suggestion | Verdict |
|---|---|
| ASO/GitOps as Layer 0 | **Adopt — strongest structural improvement** |
| Entra audit logs | **Adopt — low cost, real blind spot** |
| Subject naming convention | Useful as v2 addition, not primary control |
| Conditional Access for Workload Identities | Monitor — not currently applicable to this risk vector |
| Custom RBAC role | **Promote to Phase 4 — it's the enabling mechanism for GitOps Layer 0** |

### Recommended Implementation Sequence

- **Phase 0:** Audit existing FICs + enable alerting (hard prerequisite)
- **Phase 1:** Azure Policy in Audit mode (2 weeks)
- **Phase 2:** Kyverno in Audit mode, harden ConfigMap RBAC
- **Phase 3:** Azure Policy to Deny mode
- **Phase 4:** Custom RBAC role migration
- **Phase 5:** GitOps as Layer 0 (target architecture)

---

## Agent 3: Security Reviewer (Opus 4.6) — Adversarial Bypass Analysis

### CRITICAL: All 4 Layers Can Be Bypassed Simultaneously

An attacker with `Owner` or `policyExemptions/write` can: create exemption → write rogue FIC → deploy pod on dev → access prod → delete evidence. **Total time: ~90 seconds.**

### Layer-by-Layer Bypass Paths

**Layer 1 (Azure Policy):**
- Policy exemption bypass (Owner can create/delete exemptions — NO ALERT configured for this)
- Cluster rebuild race condition (up to 30 min stale allowlist)
- Policy propagation delay (ARM regional caches take 5-30 min)
- Allowlist pipeline is itself an attack surface (compromise pipeline SPN = poisoned allowlist)

**Layer 2 (Kyverno):**
- **Architecturally ineffective against deliberate attackers** — the `azure.workload.identity/client-id` annotation is a convenience, not a security boundary. Any pod can call the Azure AD token endpoint directly with a projected SA token, bypassing the annotation entirely.
- Kyverno failure mode (fail-open in most prod deployments — crash Kyverno = bypass)
- Webhook configuration can be modified by cluster-admin
- System namespace exclusions exploitable

**Layer 3 (Alerting):**
- Detective only — attacker has already succeeded by the time alert fires
- No alert on `federatedIdentityCredentials/delete` (create-use-delete pattern)
- No alert on `policyExemptions/write` (silent policy bypass)
- Alert fatigue from legitimate ASO reconciliation and cluster rebuilds

**Layer 4 (RBAC):**
- RG scoping doesn't eliminate the core vulnerability — SPN still has federation write within its RG
- Human access with multi-subscription Contributor is uncontrolled
- No PIM/conditional access mentioned

### Residual Attack Paths After All Layers

| Path | Description | Severity |
|---|---|---|
| A | Owner creates policy exemption → rogue FIC → direct token exchange → 90 seconds | Critical |
| B | Pipeline SPN compromise → allowlist poisoning → legitimate-looking rogue FIC | High |
| C | Cluster rebuild timing window → stale allowlist → pre-positioned FIC | Medium |
| D | Kyverno crash → fail-open → annotated SA in excluded namespace | Medium |
| E | Insider with multi-subscription access → no controls needed | Medium |

### Priority Fixes (This Week)

| # | Fix | Effort |
|---|---|---|
| 1 | Alert on `policyExemptions/write` and `/delete` | 10 minutes |
| 2 | Alert on `federatedIdentityCredentials/delete` | 10 minutes |
| 3 | Custom role: Contributor minus `federatedIdentityCredentials/write` | Medium |
| 4 | Kyverno `failurePolicy: Fail` + HA deployment (3+ replicas) | Low |
| 5 | Reclassify Layer 2 as anti-misconfiguration, not anti-attacker | Documentation |

---

## Consolidated Recommendations

### Immediate (This Week)
1. Add alerts for `policyExemptions/write`, `policyExemptions/delete`, and `federatedIdentityCredentials/delete`
2. Audit all existing FederatedIdentityCredentials for cross-environment bindings
3. Create custom RBAC role excluding `federatedIdentityCredentials/write`
4. Set Kyverno `failurePolicy: Fail` with HA deployment

### Short Term (Phases 1-3)
5. Deploy Azure Policy in Audit → validate → Deny
6. Deploy Kyverno in Audit → validate → Enforce
7. Build allowlist refresh pipeline with its own monitoring and alerting
8. Add Entra audit log alerting alongside Activity Log

### Medium Term (Phases 4-5)
9. Migrate SPNs to custom RBAC role
10. Implement GitOps (ASO) as Layer 0 — sole write path for FederatedIdentityCredentials
11. Add subject naming convention enforcement as v2 policy condition
12. Implement Sentinel Watchlist mapping cluster UUIDs to environments

### Target Architecture
```
PR Review (GitOps Layer 0) ← humans review every binding
    ↓
Custom RBAC (Layer 4) ← only GitOps SA can write FICs
    ↓
Azure Policy (Layer 1) ← backstop: issuer must be in allowlist
    ↓
Kyverno (Layer 2) ← anti-misconfiguration: annotation validation
    ↓
Alerting (Layer 3) ← detective: catch anything that slips through
```

### What Cannot Be Fixed Without Azure Platform Changes
The root cause — ARM performs no validation that an OIDC issuer URL corresponds to a cluster in the same environment — is a platform limitation requiring Microsoft to add resource references or cross-resource policy conditions.
