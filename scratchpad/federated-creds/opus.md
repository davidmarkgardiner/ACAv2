# UAMI Workload Identity Federation — Cross-Environment Binding Risk

**Consolidated Security Design Document**
_Platform Engineering — AKS Security_

**Sources:** Original investigation (Sonnet 4.6), Peer review (Riker), Layered model review (Codex), Multi-agent adversarial analysis (Factory: GPT 5.4, Sonnet 4.6, Opus 4.6)
**Date:** 2026-03-26

---

## 1. Problem Statement

Within a shared Azure tenant, AKS clusters across environments (dev, prod) all use the same OIDC issuer domain:

```
https://{region}.oic.prod-aks.azure.com/{tenant_id}/{cluster_uuid}/
```

The `issuer` field on a `FederatedIdentityCredential` (FIC) is a free-text string. Azure Resource Manager performs **no validation** that:
- The issuer URL belongs to a cluster in the same environment as the UAMI
- The referenced cluster even exists
- The cluster and UAMI are in the same subscription or environment tier

**Consequence:** A workload on a dev cluster could authenticate as a prod UAMI and access any Azure resource that UAMI has permissions on.

**Root cause:** This is an ARM platform limitation. Microsoft does not consider it a design gap — the free-text issuer field is intentional since Entra ID federates with any OIDC-compliant IdP (GitHub Actions, GitLab, AWS, on-prem K8s), not just AKS. There are no publicly announced plans for environment-aware OIDC URLs or built-in cross-environment blocking.

**Cloud comparison — AWS and GCP both have native guardrails for this scenario. Azure does not.**

- **AWS (IRSA / EKS Pod Identity):** To federate a Kubernetes service account to an IAM role, you must first create an `IAM OIDC Identity Provider` resource in the target AWS account. This is a deliberate, account-scoped trust establishment — a dev cluster's OIDC provider does not exist in the prod account unless an admin explicitly creates it. The trust boundary is structural, not a free-text string.
  - Reference: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
  - Reference: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html

- **GCP (Workload Identity Federation):** GCP uses `Workload Identity Pools` scoped to a GCP Project. Cross-project federation requires explicit IAM bindings on the target project's pool. The trust relationship is a first-class resource with explicit scope — not an opaque string on a managed identity.
  - Reference: https://cloud.google.com/iam/docs/workload-identity-federation
  - Reference: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity

- **Azure (Workload Identity Federation):** The `issuer` field on a `FederatedIdentityCredential` is a free-text string. ARM performs no validation. There are no built-in Azure policies, no Defender for Cloud rules, and no Sentinel detections for cross-environment bindings. No planned fixes from Microsoft.
  - Reference: https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
  - Reference: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview

**Note:** The AWS and GCP comparisons should be independently verified against current documentation before citing in formal stakeholder communications. The references above are the relevant documentation pages.

---

## 2. How Workload Identity Federation Works

```
Pod on AKS cluster
    |  Presents projected ServiceAccount token
    v
Microsoft Entra ID
    |  Validates token against registered FederatedIdentityCredential
    |  Checks: issuer matches, subject matches, audience matches
    v
Issues access token scoped to the UAMI
    |
    v
Pod accesses Azure resources (Key Vault, Storage, Service Bus, etc.)
```

The `FederatedIdentityCredential` on the UAMI is the trust anchor:
- `issuer` — the AKS cluster OIDC endpoint URL
- `subject` — the Kubernetes ServiceAccount (`system:serviceaccount:<namespace>:<name>`)
- `audiences` — always `api://AzureADTokenExchange`

---

## 3. OIDC Issuer URL Structure

```
https://{region}.oic.prod-aks.azure.com/{tenant_id}/{uuid}/
```

| Segment | Value | Notes |
|---|---|---|
| `{region}` | Azure region of the cluster | e.g. `uksouth`, `eastus` |
| `{tenant_id}` | Entra ID tenant GUID | Same for all clusters in the tenant |
| `{uuid}` | Randomly generated per cluster | Immutable, but changes on cluster rebuild |

There is no environment identifier in the OIDC URL. Wildcard-based Azure Policy pattern matching (e.g. `*dev*`) **cannot** distinguish environments. An explicit allowlist is required.

---

## 4. Required Permission

The operation touches only the UAMI — not the AKS cluster:

```
Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write
```

`Managed Identity Contributor` does **not** include this permission. Only `Contributor`, `Owner`, or a custom role with the explicit action can create federated credentials. The AKS cluster requires **no permissions** — it is not contacted during federation.

---

## 5. Current RBAC Posture

| Factor | Current State |
|---|---|
| SPN scope | Subscription-scoped `Contributor` per subscription |
| Dev/prod separation | Separate subscriptions |
| Human access | Some engineers have `Contributor` on multiple subscriptions |
| Cluster inventory | All AKS clusters tagged with `op-environment` |

**What subscription boundaries protect:** A SPN with `Contributor` on dev cannot write a FIC to a UAMI in prod — blocked by subscription RBAC.

**What subscription boundaries do NOT protect:**
1. A principal within a subscription can federate any UAMI in that subscription to any OIDC issuer URL — including clusters in different environments
2. Humans with access to multiple subscriptions face no technical barrier to cross-environment federation
3. Within a single subscription, one team's SPN could federate another team's UAMI to the wrong cluster

---

## 6. Concrete Attack Scenario

```
Attacker (or misconfigured pipeline) with Contributor on prod subscription
    |
    v
az identity federated-credential create \
  --identity-name uami-prod-payments \
  --resource-group rg-prod-payments \
  --issuer "https://uksouth.oic.prod-aks.azure.com/<tenant>/<DEV-CLUSTER-UUID>/" \
  --subject "system:serviceaccount:default:attacker-sa"
    |
    v
ARM writes the federated credential — no validation on issuer URL
    |
    v
Attacker deploys pod on dev cluster using ServiceAccount "attacker-sa"
    |
    v
Pod authenticates to Entra ID, receives access token as uami-prod-payments
    |
    v
Pod now has all permissions granted to the prod UAMI
```

---

## 7. Target Architecture — Five-Layer Defence Model

```
Layer 0: GitOps + ASO    <-- PR review on every binding (preventive)
    |
Layer 1: Custom RBAC     <-- Only GitOps SA can write FICs (preventive)
    |
Layer 2: Azure Policy    <-- Issuer must be in allowlist (preventive backstop)
    |
Layer 3: Kyverno         <-- Anti-misconfiguration: annotation validation
    |
Layer 4: Alerting + Reconciliation  <-- Catch anything that slips through (detective)
```

### Layer 0 — GitOps + ASO: Authoritative Write Path

Make `FederatedIdentityCredential` creation flow through reviewed manifests in git, reconciled by Azure Service Operator (ASO).

**Benefits:**
- Every federation binding gets PR review and approval
- Git history becomes the audit trail
- Out-of-band changes become detectable drift
- Human error moves earlier in the process, before ARM writes happen

This is the highest-value control because it changes who can write and how writes occur.

**Requirements:**
- Define a break-glass process for emergency changes
- Emergency changes must still be back-ported to git within a defined SLA

### Layer 1 — Custom RBAC Role: Narrow Write Permissions

Create a custom role that excludes:
- `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write`
- `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete`

Assign the restricted role to normal application SPNs. Grant the write capability only to the GitOps identity or tightly scoped automation identity. This is the enabling mechanism for Layer 0.

### Layer 2 — Azure Policy: Issuer Allowlist (Preventive Backstop)

Deny any `FederatedIdentityCredential` write where the `issuer` field does not appear in an environment-scoped allowlist.

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials"
      },
      {
        "not": {
          "field": "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/issuer",
          "in": "[parameters('allowedIssuerUrls')]"
        }
      }
    ]
  },
  "then": {
    "effect": "Deny"
  }
}
```

**Allowlist refresh pipeline:**
1. Queries all AKS clusters in the subscription
2. Filters by `op-environment` tag matching the subscription's environment
3. Extracts `oidcIssuerProfile.issuerUrl` from each cluster
4. Updates the policy assignment parameters

**Trigger on:**
- Azure Event Grid — `Microsoft.ContainerService.ManagedClusters` create/delete events
- Scheduled run (every 15 minutes as a safety net)
- Post-step in any cluster provisioning pipeline

**Edge cases to handle:**
- Empty allowlist = deny ALL federation writes (fail-closed — will be treated as an incident)
- Multi-region clusters need regional-agnostic allowlist queries
- Policy exemption process must be defined before Deny mode
- Existing FICs must be audited before switching to Deny (blocking prerequisite)
- Policy propagation delay: ARM regional caches take 5-30 min
- The allowlist pipeline itself is an attack surface — compromise of the pipeline SPN = poisoned allowlist

**Rollout:** Deploy in `Audit` mode first, validate no existing violations, then switch to `Deny`.

### Layer 3 — Kyverno: ServiceAccount Annotation Enforcement

On the cluster side, enforce that `azure.workload.identity/client-id` annotations on ServiceAccounts only reference approved UAMI client IDs.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-workload-identity-client-id
spec:
  validationFailureAction: Enforce
  rules:
    - name: validate-uami-client-id
      match:
        any:
          - resources:
              kinds: [ServiceAccount]
      validate:
        message: "UAMI client-id must belong to an approved identity for this cluster"
        deny:
          conditions:
            any:
              - key: "{{ request.object.metadata.annotations.\"azure.workload.identity/client-id\" || '' }}"
                operator: NotIn
                value: "{{ allowedClientIds }}"
```

**Important limitation:** This layer is **anti-misconfiguration, not anti-attacker**. The `azure.workload.identity/client-id` annotation is a convenience label — any pod can call the Azure AD token endpoint directly with a projected SA token, bypassing the annotation entirely. Kyverno does not prevent direct token exchange.

**Hardening requirements:**
- Set `failurePolicy: Fail` (not the common fail-open default)
- Deploy Kyverno in HA (3+ replicas) — crashing Kyverno = bypass
- Restrict who can modify the webhook configuration (cluster-admin can disable it)
- Lock down the ConfigMap via RBAC — its integrity determines Kyverno's effectiveness
- Keep the ConfigMap and Azure Policy allowlists in sync; UAMI provisioning should emit events that update both atomically

### Layer 4 — Alerting, Detection & Reconciliation

**Dual-source alerting (both are required — they are separate telemetry pipelines):**

1. **ARM Activity Log** — alert on every `federatedIdentityCredentials/write` AND `federatedIdentityCredentials/delete`
2. **Entra ID Audit Log** — alert on `AuditLogs | where OperationName == "Update application – Certificates and secrets management"`

**Additional critical alerts:**
- `policyExemptions/write` and `policyExemptions/delete` — a policy exemption silently bypasses the Azure Policy layer
- Allowlist pipeline failures — if the pipeline stops running, new legitimate bindings will be blocked and stale entries won't be removed

**Periodic reconciliation:**
Run a scheduled job that compares actual `FederatedIdentityCredential` resources against:
- The GitOps source of truth
- The current issuer allowlist
- Expected subject naming patterns
- Known cluster-to-environment mappings (Sentinel Watchlist)

---

## 8. The Cluster Rebuild Problem

The `{uuid}` in the OIDC issuer URL changes on cluster rebuild. This means:
- The allowlist becomes stale
- All FICs referencing the old cluster must be updated
- New bindings will be blocked until the allowlist is refreshed

**Mitigation:** Event Grid automation (as described in Layer 2).

**Failure window:** Define an acceptable failure window explicitly. The AKS API exposes the OIDC URL immediately post-creation — consider pre-staging the new URL. Add monitoring for the pipeline itself, not just the policy.

---

## 9. Adversarial Bypass Analysis

### All Layers Can Be Bypassed Simultaneously

An attacker with `Owner` or `policyExemptions/write` can: create exemption, write rogue FIC, deploy pod on dev, access prod, delete evidence. **Total time: ~90 seconds.**

### Residual Attack Paths After All Layers

| Path | Description | Severity |
|---|---|---|
| A | Owner creates policy exemption then rogue FIC then direct token exchange | Critical |
| B | Pipeline SPN compromise leads to allowlist poisoning then legitimate-looking rogue FIC | High |
| C | Cluster rebuild timing window with stale allowlist and pre-positioned FIC | Medium |
| D | Kyverno crash leads to fail-open and annotated SA in excluded namespace | Medium |
| E | Insider with multi-subscription Contributor — no controls needed | Medium |

### What Cannot Be Fixed Without Azure Platform Changes

The root cause — ARM performs no validation that an OIDC issuer URL corresponds to a cluster in the same environment — is a platform limitation requiring Microsoft to add resource references or cross-resource policy conditions.

---

## 10. Implementation Roadmap

### Phase 0 — Immediate (This Week)

| # | Action | Effort |
|---|---|---|
| 1 | Alert on `policyExemptions/write` and `policyExemptions/delete` | 10 min |
| 2 | Alert on `federatedIdentityCredentials/delete` (create-use-delete attack pattern) | 10 min |
| 3 | Alert on `federatedIdentityCredentials/write` via Activity Log | Low |
| 4 | Add Entra audit log alerting alongside Activity Log | Low |
| 5 | Audit ALL existing FederatedIdentityCredentials for cross-environment bindings | Medium |
| 6 | Create periodic inventory report of existing FICs | Medium |
| 7 | Define and document subject naming conventions | Low |

### Phase 1 — Azure Policy Audit Mode (2 weeks)

- Build allowlist refresh pipeline with its own monitoring and alerting
- Deploy Azure Policy in `Audit` mode
- Validate no existing violations
- Define policy exemption process

### Phase 2 — Kyverno Audit Mode

- Deploy Kyverno policy in `Audit` mode
- Harden ConfigMap RBAC
- Set `failurePolicy: Fail` with HA deployment (3+ replicas)
- Validate approved UAMI client ID inventory

### Phase 3 — Enforce

- Switch Azure Policy to `Deny` mode
- Switch Kyverno to `Enforce` mode
- Implement reconciliation job to detect out-of-band changes

### Phase 4 — Custom RBAC Role

- Create custom role: `Contributor` minus `federatedIdentityCredentials/write` and `/delete`
- Migrate application SPNs to custom role
- Grant write permission only to designated automation identity

### Phase 5 — GitOps as Layer 0 (Target State)

- Implement ASO as the sole write path for FederatedIdentityCredentials
- All changes via PR review and approval
- Drift detection for out-of-band changes
- Define break-glass process for emergencies
- Implement Sentinel Watchlist mapping cluster UUIDs to environments

---

## 11. Control Summary

| Risk | Current State | Control | Layer | Phase |
|---|---|---|---|---|
| Cross-subscription binding by SPN | Already blocked | Subscription RBAC boundary | Existing | - |
| Cross-environment binding within subscription | Uncontrolled | Azure Policy issuer allowlist | 2 | 1-3 |
| Wrong UAMI annotation on ServiceAccount | Uncontrolled | Kyverno policy | 3 | 2-3 |
| Visibility of federation changes | None | Dual-source alerting + reconciliation | 4 | 0 |
| Broad SPN RBAC scope | Subscription Contributor | Custom RBAC role | 1 | 4 |
| Unreviewed FIC creation | Uncontrolled | GitOps + ASO | 0 | 5 |
| Policy exemption bypass | No alerting | Alert on exemption writes/deletes | 4 | 0 |
| Allowlist pipeline failure | N/A | Pipeline monitoring + scheduled fallback | 2 | 1 |

---

## 12. Alternative Approaches Considered

### System-Assigned Identities Where Possible

For workloads where the UAMI isn't shared across multiple resources, system-assigned MIs are tied to the resource lifecycle and can't be federated arbitrarily. Audit which UAMIs are single-use and migrate them. Good parallel cleanup effort.

### Separate Entra Tenants

Place dev and prod in separate tenants so federation boundaries are enforced structurally. Strongest isolation model, but high operational overhead. Reserve for regulated or hard-separation compliance environments.

### Conditional Access for Workload Identities

GA for some scenarios. Can apply condition-based policies to managed identity token issuance. Worth monitoring but not currently applicable to this specific risk vector.

---

## 13. Open Questions

- [ ] Confirm `op-environment` tag values in use across all AKS clusters
- [ ] What is the break-glass path if allowlist automation fails during a legitimate cluster rebuild?
- [ ] Which non-GitOps tools currently write FederatedIdentityCredentials (Terraform, Pulumi, Crossplane, custom pipelines)?
- [ ] Which identities truly require UAMI reuse, and which can move to system-assigned?
- [ ] Is tenant-level separation necessary for compliance, or can the layered model satisfy control requirements?
- [ ] Assess CAB requirements for Azure Policy deployment in prod subscription
- [ ] How will drift be detected and remediated if someone makes a valid-but-unauthorized direct change?
- [ ] Define acceptable failure window for cluster rebuild allowlist refresh

---

_Consolidated from multi-agent security analysis. Intended as the authoritative reference for implementation._
