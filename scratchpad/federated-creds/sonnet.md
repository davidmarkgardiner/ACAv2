# UAMI Workload Identity Federation — Cross-Environment Binding Risk
**Investigation & Proposed Controls**
_Platform Engineering — AKS Security_

---

## 1. Problem Statement

Within a shared Azure tenant, AKS clusters across environments (dev, prod) all use the same OIDC issuer domain:

```
https://{region}.oic.prod-aks.azure.com/{tenant_id}/{cluster_uuid}/
```

The `issuer` field on a `FederatedIdentityCredential` resource is a free-text string. Azure Resource Manager performs **no validation** that:
- The issuer URL belongs to a cluster in the same environment as the UAMI
- The referenced cluster even exists
- The cluster and UAMI are in the same subscription or environment tier

This means a principal with `write` permissions on a UAMI can federate it to trust OIDC tokens from **any** AKS cluster in the tenant — including clusters in a different environment — simply by supplying a different issuer URL string.

**Consequence:** A workload running on a dev cluster could be granted the ability to authenticate as a prod UAMI, and thereby access any Azure resource that UAMI has permissions on.

---

## 2. How Workload Identity Federation Works

When a pod on an AKS cluster authenticates using Workload Identity, the following chain occurs:

```
Pod on AKS cluster
    │
    │  Presents projected ServiceAccount token
    ▼
Microsoft Entra ID
    │
    │  Validates token against registered FederatedIdentityCredential
    │  Checks: issuer matches, subject matches, audience matches
    ▼
Issues access token scoped to the UAMI
    │
    ▼
Pod accesses Azure resources (Key Vault, Storage, Service Bus, etc.)
```

The `FederatedIdentityCredential` on the UAMI is the trust anchor. It contains:
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
| `{tenant_id}` | Entra ID tenant GUID | **Same for all clusters in the tenant** |
| `{uuid}` | Randomly generated per cluster | **Immutable, but changes on cluster rebuild** |

**Key finding:** There is no environment identifier in the OIDC URL. Dev and prod clusters in the same region produce structurally identical URLs. The only distinguishing element is the `{uuid}`, which is opaque and carries no environment semantics.

This means wildcard-based Azure Policy pattern matching (e.g. `*dev*`) **cannot** distinguish environments. An explicit allowlist or alternative approach is required.

---

## 4. Required Permission to Create a Federated Credential

The operation touches only the UAMI — not the AKS cluster:

```
Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write
```

**Important nuance:** `Managed Identity Contributor` does **not** include this permission. Only `Contributor`, `Owner`, or a custom role with the explicit action can create federated credentials.

The AKS cluster resource requires **no permissions** — it is not contacted, queried, or modified during federation. The issuer URL is purely a string value.

---

## 5. Current Environment — RBAC Posture

| Factor | Current State |
|---|---|
| SPN scope | Subscription-scoped `Contributor` per subscription |
| Dev/prod separation | Separate subscriptions |
| Human access | Some engineers have `Contributor` on multiple subscriptions |
| Cluster inventory | All AKS clusters tagged with `op-environment` |

**What subscription boundaries already protect:**
A SPN with `Contributor` on the dev subscription cannot write a `FederatedIdentityCredential` to a UAMI in the prod subscription — it has no RBAC there. Cross-subscription binding by SPNs is already blocked by the subscription boundary.

**What subscription boundaries do not protect:**
1. A principal (human or SPN) with `Contributor` on a subscription can federate **any** UAMI within that subscription to **any** OIDC issuer URL — including the OIDC endpoint of a cluster in a different environment
2. Humans with access to multiple subscriptions face no technical barrier to cross-environment federation
3. Within a single subscription, one team's SPN could federate another team's UAMI to the wrong cluster

---

## 6. Concrete Attack Scenario

```
Attacker (or misconfigured pipeline) with Contributor on prod subscription
    │
    ▼
az identity federated-credential create \
  --identity-name uami-prod-payments \
  --resource-group rg-prod-payments \
  --issuer "https://uksouth.oic.prod-aks.azure.com/<tenant>/<DEV-CLUSTER-UUID>/" \
  --subject "system:serviceaccount:default:attacker-sa"
    │
    ▼
ARM writes the federated credential — no validation on issuer URL
    │
    ▼
Attacker deploys pod on dev cluster using ServiceAccount "attacker-sa"
    │
    ▼
Pod authenticates to Entra ID, receives access token as uami-prod-payments
    │
    ▼
Pod now has all permissions granted to the prod UAMI
```

The dev cluster — which typically has lower access controls, more engineers, and less scrutiny — becomes a pivot point into prod identities.

---

## 7. Why Azure Policy Is the Right Primary Control

RBAC cannot solve this problem because the actor is legitimately entitled to write federated credentials on their UAMI — the issue is the *value* they write, not whether they can write it.

Azure Policy evaluates resource payloads **above** RBAC in the ARM evaluation chain. Even a `Contributor` cannot bypass a `Deny` policy:

```
Principal with Contributor
    │
    ▼
ARM receives request
    │
    ▼
Azure Policy evaluates issuer field  ◄── DENY if issuer not in allowlist
    │
(request never reaches resource write)
```

---

## 8. The Cluster Rebuild Problem

The `{uuid}` in the OIDC issuer URL is randomly generated at cluster creation time and **changes if the cluster is rebuilt**. This means:

- A static allowlist of OIDC URLs becomes stale on every cluster rebuild
- All `FederatedIdentityCredential` resources across all UAMIs that referenced the old cluster must be updated
- The policy allowlist must also be updated, or new bindings will be blocked until it is

**Mitigation:** Automate the allowlist by querying the `op-environment` tag on AKS clusters at cluster lifecycle events (create/delete) via Azure Event Grid, and updating the policy assignment parameters automatically. The tag provides the environment mapping; the OIDC URL is derived from the cluster inventory dynamically.

---

## 9. Proposed Control Set

### Layer 1 — Azure Policy: Issuer Allowlist (Primary Control)

Deny any `FederatedIdentityCredential` write where the `issuer` field does not appear in an allowlist of known OIDC URLs for clusters belonging to that subscription's environment.

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

The `allowedIssuerUrls` parameter is populated dynamically by a pipeline that:
1. Queries all AKS clusters in the subscription
2. Filters by `op-environment` tag matching the subscription's environment
3. Extracts `oidcIssuerProfile.issuerUrl` from each cluster
4. Updates the policy assignment parameters

**Trigger the pipeline on:**
- Azure Event Grid — `Microsoft.ContainerService.ManagedClusters` create/delete events
- Scheduled run (every 15 minutes as a safety net)
- Post-step in any cluster provisioning pipeline

**Rollout approach:** Deploy in `Audit` mode first, validate no existing violations, then switch to `Deny`.

### Layer 2 — Kyverno: ServiceAccount Annotation Enforcement (Defence in Depth)

On the cluster side, enforce that `azure.workload.identity/client-id` annotations on ServiceAccounts only reference UAMI client IDs from an approved list for that cluster.

This provides defence in depth — even if a rogue federated credential is created in Azure, the corresponding ServiceAccount annotation on the cluster can be blocked.

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

Approved client IDs maintained in a ConfigMap per cluster, updated via GitOps when UAMIs are provisioned.

### Layer 3 — Activity Log Alerting (Visibility)

Alert on every `federatedIdentityCredentials/write` operation across both subscriptions. This operation is infrequent enough that every instance warrants a human look.

```bash
az monitor activity-log alert create \
  --name "alert-federated-credential-write" \
  --resource-group rg-platform \
  --condition category=Administrative \
  --condition operationName=Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write \
  --action-group <action-group-id>
```

### Layer 4 — RBAC Hardening (Medium Term)

Subscription-scoped `Contributor` for SPNs is broader than necessary. The specific permission required to create federated credentials is:

```
Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write
```

Moving to resource-group-scoped RBAC for application SPNs would contain the intra-subscription cross-team risk. This is a wider platform change warranting its own initiative.

---

## 10. Control Summary

| Risk | Current State | Control | Layer |
|---|---|---|---|
| Cross-subscription binding by SPN | Already blocked | Subscription RBAC boundary | Existing |
| Cross-environment binding within subscription | Uncontrolled | Azure Policy issuer allowlist | Primary |
| Wrong UAMI annotation on ServiceAccount | Uncontrolled | Kyverno policy | Defence in depth |
| Visibility of federation changes | None | Activity log alert | Detection |
| Broad SPN RBAC scope | Subscription Contributor | RG-scoped RBAC + custom role | Medium term |

---

## 11. Open Questions / Next Steps

- [ ] Confirm `op-environment` tag values in use across all AKS clusters
- [ ] Audit existing `FederatedIdentityCredential` resources for any current cross-environment bindings before enabling deny policy
- [ ] Design Event Grid → pipeline automation for allowlist refresh on cluster rebuild
- [ ] Assess CAB requirements for Azure Policy deployment in prod subscription
- [ ] Define allowed UAMI client ID inventory process for Kyverno ConfigMap management
- [ ] Evaluate whether ASO `FederatedIdentityCredential` manifests in GitOps repo should be the single source of truth, with drift detection for out-of-band changes

---

_Document produced during platform security investigation session. Intended as context for follow-on implementation work._