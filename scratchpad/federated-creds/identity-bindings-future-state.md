# Identity Bindings — Future State Assessment

**Feature:** Identity Bindings for AKS (Preview)
**Status:** Preview — not GA, not production-ready, opt-in feature flag required
**Docs:**
- Concepts: https://learn.microsoft.com/en-us/azure/aks/identity-bindings-concepts
- Setup: https://learn.microsoft.com/en-us/azure/aks/identity-bindings
**Date assessed:** 2026-03-26

---

## What Identity Bindings Is

Identity Bindings is a new AKS feature that changes how workload identity federation works at scale. Its primary purpose is to solve the **20 FIC limit per UAMI** — if a managed identity is used across more than 20 clusters, the current model runs out of FederatedIdentityCredential slots.

Instead of creating one FIC per cluster per UAMI, identity bindings allow **one shared FIC per UAMI** that works across all clusters bound to it.

```
Current model (workload identity):
  UAMI → FIC-1 (cluster-1 OIDC) + FIC-2 (cluster-2 OIDC) + ... + FIC-20 (limit)

Identity bindings model:
  UAMI → 1 shared FIC (managed by AKS) ← identity-binding-1 (cluster-1)
                                         ← identity-binding-2 (cluster-2)
                                         ← identity-binding-N (no limit)
```

---

## What Changes

| Aspect | Current (Workload Identity) | Identity Bindings |
|---|---|---|
| FIC creation | Manual — you write the issuer string | Automatic — AKS creates and manages the FIC |
| OIDC issuer URL format | `https://{region}.oic.prod-aks.azure.com/{tenant}/{cluster-uuid}/` | `https://ib.oic.prod-aks.azure.com/{MI-tenant-id}/{MI-client-id}` |
| OIDC URL stability | Changes on cluster rebuild (random UUID) | **Stable** — tied to the managed identity, not the cluster |
| FIC limit | 20 per UAMI | 1 per UAMI (shared across all bindings) |
| SA authorization | Annotation-based (`azure.workload.identity/client-id`) | Kubernetes RBAC (`ClusterRole` / `ClusterRoleBinding`) |
| Token exchange | Pod → `login.microsoftonline.com` directly | Pod → cluster-local identity binding proxy → Entra ID |
| Cross-env prevention | None (issuer is a free-text string) | **Still none** — no environment validation on binding creation |

---

## What This Solves for Us

### 1. Eliminates the cluster rebuild / allowlist refresh problem

The biggest operational pain point in our current Azure Policy approach is that the OIDC URL contains a random cluster UUID that changes on rebuild. This forces us to maintain a nightly refresh pipeline and manual trigger process.

With identity bindings, the OIDC URL is `https://ib.oic.prod-aks.azure.com/{MI-tenant-id}/{MI-client-id}` — tied to the managed identity, not the cluster. Cluster rebuilds do not change it. The allowlist becomes static per managed identity and only changes when UAMIs are created or deleted.

**Impact:** The nightly refresh pipeline becomes much simpler. No more racing to update allowlists after cluster rebuilds. No more stale allowlist windows.

### 2. Removes the free-text issuer attack vector

Today, anyone with Contributor can write any string into the issuer field of a FIC. The entire vulnerability exists because ARM accepts arbitrary strings.

With identity bindings, **AKS creates the FIC automatically**. You don't set the issuer — AKS does. The FIC is named `aks-identity-binding` and the docs explicitly say "don't modify or delete it." This removes the human-error and manual-misconfiguration vector.

The attack vector shifts from "write a bad issuer string on a FIC" to "create an identity binding between a prod UAMI and a dev cluster." This is still possible but is a more deliberate, auditable action through the AKS API rather than a simple string on a UAMI.

### 3. Stronger cluster-side authorization

The current model uses annotations on ServiceAccounts (`azure.workload.identity/client-id`). As we identified in our analysis, this is not a security boundary — pods can call the token endpoint directly.

Identity bindings use proper Kubernetes RBAC:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: use-mi-<client-id>
rules:
  - verbs: ["use-managed-identity"]
    apiGroups: ["cid.wi.aks.azure.com"]
    resources: ["<client-id>"]
```

Only service accounts explicitly granted the `use-managed-identity` verb via `ClusterRoleBinding` can use the identity. This is a real Kubernetes RBAC boundary enforced by the API server, not an annotation that can be bypassed.

### 4. Scales beyond 20 clusters per UAMI

If any of our UAMIs are used across more than 20 clusters, we'll hit the FIC limit under the current model. Identity bindings remove this constraint entirely.

---

## What This Does NOT Solve

### Cross-environment binding is still possible

The core problem remains: there is no environment-scoping on identity binding creation. A principal with the right permissions can still run:

```bash
az aks identity-binding create \
  --resource-group rg-dev \
  --cluster-name dev-cluster \
  --name "prod-uami-binding" \
  --managed-identity-resource-id "/subscriptions/.../providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-prod-payments"
```

AKS does not validate that the cluster and the UAMI are in the same environment. The `op-environment` tag is not checked. The Azure Policy allowlist approach (or an adapted version of it) is still needed.

### Required permissions are the same

Creating an identity binding requires:
- `Microsoft.ContainerService/managedClusters/identityBindings/*` (on the cluster)
- `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/*` (on the UAMI)

A Contributor with access to both resources can create a cross-environment binding. The RBAC gap is unchanged.

---

## How Our Controls Would Adapt

When identity bindings goes GA, our Azure Policy approach can be simplified:

| Current control | With identity bindings |
|---|---|
| Azure Policy checking issuer URL against per-env allowlist | Azure Policy checking identity binding resource properties (cluster + UAMI environment alignment) — or continue checking issuer, which is now stable |
| Nightly allowlist refresh pipeline (OIDC URLs change on rebuild) | **Simplified** — allowlist only changes when UAMIs are created/deleted, not on cluster rebuild |
| Manual trigger for cluster rebuilds | **No longer needed** — OIDC URL is stable across rebuilds |
| Kyverno annotation validation (dropped) | Replaced by native Kubernetes RBAC — stronger, no ConfigMap to manage |
| Activity Log alerting on FIC writes | Shift to alerting on identity binding creation (`identityBindings/write`) |

### Possible new policy approach

Instead of maintaining OIDC URL allowlists, we could write an Azure Policy that validates the identity binding resource itself — checking that the cluster's `op-environment` tag matches the UAMI's `op-environment` tag. This would be a cleaner policy because it operates on resource properties rather than opaque URL strings.

```
Identity binding create request
    |
    v
Azure Policy evaluates:
    - What is the cluster's op-environment tag? → "dev"
    - What is the UAMI's op-environment tag? → "prod"
    - Do they match? → NO → DENY
```

This needs investigation — Azure Policy's ability to cross-reference tags on two different resources in a single evaluation may be limited. But the identity binding resource contains references to both the cluster and the UAMI, which makes this potentially feasible.

---

## Migration Path

### Phase 1: Current state (now)
- Azure Policy with OIDC URL allowlists (as implemented)
- Nightly refresh pipeline
- Manual trigger for rebuilds

### Phase 2: Identity bindings preview evaluation
- Enable the `IdentityBindingPreview` feature flag on a dev subscription
- Test identity binding creation and lifecycle
- Validate that the OIDC URL is stable across cluster rebuilds
- Test Azure Policy compatibility — can we write a policy against identity binding resources?
- Assess SDK readiness (preview SDK versions required)

### Phase 3: Identity bindings GA (when available)
- Migrate from manual FIC creation to identity bindings
- Simplify or replace the allowlist refresh pipeline
- Adapt Azure Policy to validate identity binding environment alignment
- Remove Kyverno (already dropped) — replaced by native K8s RBAC
- Update alerting to monitor `identityBindings/write` events

---

## Blockers for Adoption Today

| Blocker | Impact | Status |
|---|---|---|
| Preview only — not GA | Cannot use in production | Wait for GA announcement |
| Requires `IdentityBindingPreview` feature flag | Must opt in per subscription | Acceptable for dev/test |
| Requires `aks-preview` CLI extension v18.0.0b26+ | CLI dependency | Minor |
| Requires workload identity webhook v1.6.0-alpha.1 | Alpha webhook in kube-system | Not acceptable for production |
| SDK support is beta only (.NET, Go, Java, JS, Python) | Application code changes needed | Wait for stable SDK releases |
| Not supported with API server VNet integration | May affect some clusters | Check cluster configs |
| No automatic FIC cleanup on binding deletion | Operational hygiene gap | Manual cleanup process needed |

---

## Recommendation

**Do not adopt identity bindings today.** It is in preview with alpha-level components (webhook v1.6.0-alpha.1) and beta SDK dependencies. Not suitable for production.

**Do track it for GA.** When it goes GA, it significantly simplifies our control model:
- Stable OIDC URLs eliminate the allowlist refresh complexity
- AKS-managed FICs remove the free-text issuer misconfiguration vector
- Native Kubernetes RBAC replaces annotation-based SA authorization
- The Azure Policy can potentially become a tag-comparison policy rather than URL-matching

**Keep our current Azure Policy + allowlist approach as the production control.** It works today, it's GA, and it doesn't depend on preview features. When identity bindings reaches GA with stable SDK support, evaluate migration.

---

## References

- Identity Bindings Concepts: https://learn.microsoft.com/en-us/azure/aks/identity-bindings-concepts
- Identity Bindings Setup: https://learn.microsoft.com/en-us/azure/aks/identity-bindings
- AKS Workload Identity Overview: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- Azure Workload Identity Federation: https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
