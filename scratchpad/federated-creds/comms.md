# FederatedIdentityCredential Cross-Environment Binding Controls -- Communications

---

## 1. GitLab Ticket

**Title:** `[Security] Compensating controls for Microsoft platform gap in FederatedIdentityCredential validation`

**Priority:** High

**Labels:** `security`, `platform`, `aks`, `workload-identity`, `microsoft-gap`

### Summary

Azure Resource Manager performs no validation on the OIDC issuer URL when creating a FederatedIdentityCredential. This is a Microsoft platform limitation -- not a misconfiguration on our side. ARM treats the issuer as a free-text string with no cross-reference to actual AKS cluster resources, allowing a principal to federate a production UAMI to trust a dev cluster's OIDC endpoint. This creates a lateral movement path from lower environments into production. Microsoft has no planned fix. AWS and GCP both handle the equivalent scenario with native guardrails. We are building compensating controls using Azure Policy, Kyverno, and a nightly refresh pipeline to enforce the environment boundary integrity that the platform should provide.

### Background

Workload identity federation on AKS works by creating a FederatedIdentityCredential (FIC) on a UAMI that trusts an OIDC issuer URL and a specific subject (namespace/service-account). When a pod presents a projected service account token, Azure AD validates the token against the issuer URL and, if it matches the FIC configuration, issues an access token for the UAMI.

The critical design gap is that the `issuer` field on a FIC is a free-text string. ARM does not validate that the issuer URL belongs to a cluster in the same environment, subscription, or even the same tenant. Any principal with Contributor RBAC on the UAMI's resource group can set the issuer to any URL, including the OIDC endpoint of a cluster in a different environment.

**Attack scenario:**

1. An engineer (or automation) with Contributor access creates or modifies a FIC on a prod UAMI.
2. They set the issuer to the OIDC endpoint of a dev AKS cluster.
3. They set the subject to a service account they control on the dev cluster.
4. A pod on the dev cluster running under that service account can now obtain tokens for the prod UAMI.
5. The pod accesses prod resources (Key Vault secrets, databases, storage accounts) using the prod identity.

Microsoft does not consider this a design gap and has no planned fixes. AWS (IAM OIDC provider + condition keys) and GCP (Workload Identity Federation with attribute conditions) handle this better natively.

### Current Risk

The following scenarios are uncontrolled today:

- **Within-subscription cross-environment binding:** A principal with Contributor on a subscription containing both dev and prod UAMIs can federate a prod UAMI to trust a dev cluster. This is the primary risk.
- **Human cross-subscription access:** Users with Contributor across multiple subscriptions (e.g., platform engineers) can manually create cross-environment FIC bindings across subscription boundaries.
- **SPN cross-subscription binding** is already mitigated by subscription-scoped RBAC boundaries for service principals.

### Proposed Controls

**1. Azure Policy (preventive, platform-level)**

- Query all AKS clusters across the management group, grouped by their `op-environment` tag (dev, pre-prod, prod).
- Build per-environment allowlists of valid OIDC issuer URLs.
- Deploy an Azure Policy that denies `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials` write operations where the issuer URL is not in the allowlist for the subscription's `op-environment`.
- All AKS clusters, subscriptions, and UAMIs are already tagged with `op-environment`.

**2. Kyverno (preventive, cluster-level)**

- On each AKS cluster, deploy a Kyverno ClusterPolicy that validates ServiceAccount annotations.
- The policy checks that `azure.workload.identity/client-id` annotations on ServiceAccounts only reference UAMI client-ids from the same `op-environment`.
- Approved client-id lists are maintained in a ConfigMap per cluster, sourced from the nightly refresh pipeline.

**3. Nightly refresh pipeline (operational)**

- A scheduled pipeline runs nightly across the management group.
- It enumerates all AKS clusters and their OIDC issuer URLs, groups them by `op-environment` tag, and regenerates the allowlists.
- Outputs are consumed by both the Azure Policy definitions and the Kyverno ConfigMaps.
- The pipeline can be triggered manually (e.g., after a cluster rebuild or new cluster provisioning).

### Implementation Plan

| Phase | Week | Activities |
|-------|------|------------|
| 1 -- Inventory and audit | Week 1 | Enumerate all AKS clusters, OIDC endpoints, and UAMIs across the management group. Identify any existing cross-environment FIC bindings. Build initial allowlists. |
| 2 -- Audit mode | Week 2 | Deploy Azure Policy in Audit mode. Deploy Kyverno policy in Audit mode. Monitor compliance dashboard for violations. Notify teams of any flagged bindings. |
| 3 -- Pipeline and testing | Week 3 | Deploy nightly refresh pipeline. Validate allowlist accuracy. Test policy enforcement in a sandbox environment. Remediate any legitimate cross-environment bindings found in audit. |
| 4 -- Deny mode | Week 4 | Switch Azure Policy to Deny mode. Switch Kyverno policy to Enforce mode. Monitor for blocked operations. Provide support channel for exceptions. |

### Acceptance Criteria

- [ ] All AKS clusters across the management group are inventoried with their OIDC issuer URLs and `op-environment` tags.
- [ ] Azure Policy is deployed and actively denying cross-environment FIC writes in all subscriptions under the management group.
- [ ] Kyverno ClusterPolicy is deployed on all AKS clusters, enforcing SA annotation validation against approved UAMI client-id lists.
- [ ] Nightly refresh pipeline runs successfully, regenerating allowlists and updating both Azure Policy parameters and Kyverno ConfigMaps.
- [ ] Manual trigger for the refresh pipeline is documented and tested.
- [ ] No existing cross-environment FIC bindings remain (or any exceptions are documented and approved).
- [ ] Audit logs confirm that cross-environment FIC creation attempts are denied.
- [ ] Runbook exists for handling exceptions, onboarding new clusters, and troubleshooting denied operations.

---

## 2. Teams Message

**Channel:** #platform-engineering / #security

---

**FederatedIdentityCredential cross-environment binding -- plugging a Microsoft platform gap**

We have identified a gap in how Azure handles workload identity federation on AKS. This is a **Microsoft platform limitation, not a misconfiguration on our side**.

**The gap:** When you create a FederatedIdentityCredential on a UAMI, the OIDC issuer field is a free-text string. Azure Resource Manager performs zero validation that the issuer URL belongs to a cluster in the same environment, subscription, or even the same tenant. There are no built-in policies, no Defender rules, and no planned fixes from Microsoft. AWS and GCP both handle the equivalent scenario with native guardrails -- Azure does not.

**The risk:** A dev cluster could be federated to a prod managed identity, giving dev workloads access to prod resources (Key Vault, Storage, Service Bus, etc.). This can happen through misconfiguration or deliberate abuse.

**What we're building to compensate:**

- **Azure Policy** -- per-environment allowlists of valid OIDC issuer URLs, derived from `op-environment` tags. Cross-environment FIC writes will be denied.
- **Kyverno policies** -- cluster-side validation that ServiceAccount annotations only reference approved managed identities for that environment.
- A **nightly pipeline** -- keeps allowlists current across the management group. Can be triggered manually after cluster rebuilds.

**What this means for you:**
- For the next 2 weeks, policies will run in **audit mode only** -- nothing will be blocked, but violations will be flagged.
- After that, policies move to **deny mode**. Any cross-environment FIC bindings will be blocked.
- If you have a legitimate need for cross-environment federation, raise it now so we can handle it before enforcement begins.

Full details and implementation plan: [GitLab ticket link]

Questions or concerns -- drop them in this thread.

---

## 3. Email

**Subject:** Action Required -- Plugging a Microsoft Platform Gap in Workload Identity Federation

**To:** Security Team, Platform Engineering Lead

**CC:** Engineering Managers, Cloud Architecture Team

---

Hello,

I am writing to flag a security gap in the Azure platform's handling of workload identity federation, and to outline the controls we are building to compensate. This is not a misconfiguration on our side -- it is a limitation in how Azure Resource Manager validates FederatedIdentityCredential resources.

**Executive Summary**

Azure Resource Manager performs no validation on the OIDC issuer URL when a FederatedIdentityCredential (FIC) is created on a User-Assigned Managed Identity (UAMI). The issuer field is a free-text string -- ARM does not check that it belongs to a cluster in the same environment, subscription, or even tenant. This means a principal with Contributor RBAC can federate a production UAMI to trust a dev cluster, allowing dev workloads to authenticate as prod identities and access prod resources.

Microsoft does not consider this a design gap and has no announced plans to address it. There are no built-in Azure policies, no Defender for Cloud rules, and no Sentinel detections for this scenario. For context, both AWS and GCP handle the equivalent risk with stronger native guardrails:

- **AWS (IRSA):** Requires explicitly provisioning an IAM OIDC Identity Provider in the target account. A dev cluster cannot assume prod roles unless the prod account admin explicitly trusts it.
- **GCP:** Workload Identity Pools are tied to GCP Projects with explicit cross-project IAM bindings, making accidental cross-environment federation far harder.

Azure provides none of these safeguards. We are building the controls that the platform should provide.

**Risk Description**

The FIC resource binds a UAMI to an OIDC issuer URL and a Kubernetes service account subject. Because ARM treats the issuer as an opaque string with no cross-reference to actual AKS cluster resources, any Contributor can point a prod UAMI at a dev cluster's OIDC endpoint. A pod on that dev cluster can then obtain access tokens for the prod identity and reach production resources -- Key Vault secrets, databases, storage accounts, and anything else the UAMI has access to.

This can occur through misconfiguration (human error, bad automation) or deliberate abuse. Either way, the result is a lateral movement path from a lower environment into production.

**Proposed Solution**

We are building three compensating controls using infrastructure we already have in place (`op-environment` tags are already set on all AKS clusters, subscriptions, and UAMIs):

1. **Azure Policy** -- Per-environment allowlists of valid OIDC issuer URLs, derived from AKS cluster inventory grouped by `op-environment` tag. Policy denies FIC writes where the issuer URL does not belong to a cluster in the same environment as the subscription. Deployed at management group scope.

2. **Kyverno ClusterPolicy** -- On each AKS cluster, validates that ServiceAccount workload identity annotations only reference UAMI client-ids approved for that cluster's environment. Catches misconfiguration at the Kubernetes layer.

3. **Nightly refresh pipeline** -- Automated regeneration of allowlists across the management group. Runs nightly and can be triggered manually for ad-hoc events such as cluster rebuilds.

**Rollout Timeline**

- **Week 1:** Inventory all clusters, OIDC endpoints, and existing FIC bindings across the management group. Identify and flag any current cross-environment bindings.
- **Week 2:** Deploy policies in Audit mode. Monitor and report violations. No blocking.
- **Week 3:** Deploy nightly refresh pipeline. Validate allowlists. Remediate any flagged bindings.
- **Week 4:** Switch to Deny mode. Full enforcement active.

**What We Need**

- **Security team:** Review and approve the proposed controls and rollout plan. Consider whether this gap warrants a formal risk entry or discussion with Microsoft.
- **Platform engineering:** Confirm `op-environment` tag coverage is complete across all AKS clusters and UAMIs.
- **Engineering managers:** Communicate to your teams that audit-mode alerts may appear over the next two weeks, and that any legitimate cross-environment federation needs must be raised before Week 4.

**Next Steps**

The full implementation plan is documented in the GitLab ticket: [link]. We will begin the inventory phase this week. Please review and share any concerns or questions by [date].

I would also recommend we raise this gap formally with our Microsoft account team, both to confirm there is no planned fix and to register it as customer feedback.

Best regards,
[Your name]
[Your role]
