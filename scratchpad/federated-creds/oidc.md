# OIDC Federated Identity Credential — Issuer Validation Gap

## Summary

Azure Resource Manager accepts any arbitrary URL string as the `issuer` field on a
`FederatedIdentityCredential` resource. There is no platform-level validation, no
built-in Azure Policy, and no Defender for Cloud rule that restricts or inspects
what issuer value is written. This creates a misconfiguration risk in multi-cluster
environments where a dev or staging cluster's OIDC issuer could be bound to a
production UAMI without any native guardrail preventing it.

---

## Findings

### Azure — Gap Confirmed

- The ARM schema for `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials`
  defines `issuer` as a plain string with no enumerated values, no pattern constraint,
  and no reference to a trusted issuer registry.
- At write time, ARM performs no content validation on the issuer value beyond:
  - Field must be present
  - Must be 600 characters or fewer
  - Leading/trailing whitespace is blocked (enforced at token exchange, not at write time)
- A misconfigured or malicious issuer is created successfully without error. The failure
  is silent and only surfaces at token exchange time.
- Microsoft's own documentation explicitly notes:
  > *"If you accidentally add the incorrect external workload information in the subject
  > setting, the federated identity credential is created successfully without error."*
- **No built-in Azure Policy** exists that inspects or restricts the `issuer` field value.
- **No Defender for Cloud recommendation** covers cross-environment OIDC bindings.
- **No Sentinel analytic rule** is documented for detecting anomalous FIC issuer values.
- Microsoft's considerations documentation does reference Azure Policy for this resource
  type, but the only documented example is a **blanket deny** on all FIC creation —
  there is no Microsoft-provided pattern for issuer-scoped allowlist enforcement.
- There is no public Microsoft roadmap item to address this gap at the platform level.

---

### AWS — Gap Closed (Structurally)

- OIDC trust in AWS is governed by **IAM OIDC Identity Provider** resources, which are
  explicit, account-scoped objects that must be deliberately provisioned.
- A dev cluster's OIDC issuer **does not exist** in a prod account unless an administrator
  explicitly registers it there — trust is a first-class resource, not a string field.
- Cross-account OIDC federation (e.g. IRSA across accounts) requires an admin to:
  1. Obtain the cluster's OIDC issuer URL from the source account.
  2. Explicitly create a matching IAM OIDC Provider resource in the target account.
  3. Author a trust policy referencing that provider by ARN.
- This structural requirement means cross-environment binding is an intentional, auditable
  act rather than a misconfiguration risk.
- AWS has additionally introduced **identity-provider controls** for recognised shared OIDC
  providers (e.g. GitHub Actions, Terraform Cloud), requiring explicit claim evaluation in
  trust policies — role creation fails if these controls are absent.
- **Verdict:** Platform-level structural control. Cross-environment trust requires deliberate
  provisioning in the target account.

---

### GCP — Gap Partially Closed (Project-Scoped, with Caveats)

- GCP Workload Identity Federation is governed by **Workload Identity Pools**, which are
  project-scoped resources. Each pool is tied to a specific GCP project, and cross-project
  access requires explicit IAM bindings.
- GCP's best practices documentation recommends using a **dedicated project** for WIF
  configuration to centralise control and enforce consistent attribute conditions.
- GCP supports **Organisation Policy constraints** to deny creation of new workload identity
  pool providers by default, with explicit exceptions for trusted projects.
- **Important caveat:** GCP's own documentation warns about an **identity sameness** risk —
  if multiple clusters share a workload identity pool (because they belong to the same GCP
  project), IAM treats their workloads as the same principal. GCP's mitigation for this
  is architectural guidance (place clusters in separate projects), not a platform guardrail.
- GCP also acknowledges that for shared OIDC providers (e.g. GitHub, Terraform Cloud),
  checking the issuer URL alone is insufficient — attribute conditions must be configured
  to verify tenant or organisation membership.
- **Verdict:** Stronger than Azure by virtue of project-scoped pool resources and org
  policy support, but not free of analogous risks. Mitigations rely on correct architecture
  and configuration rather than pure platform enforcement.

---

## Comparison Table

| Cloud | Mechanism | Issuer Validated at Write Time | Native Guardrail Against Cross-Env Binding | Notes |
|---|---|---|---|---|
| **AWS** | IAM OIDC Identity Provider (account-scoped resource) | Yes — provider must be explicitly provisioned | ✅ Structural | Dev issuer cannot be used in prod without admin act in prod account |
| **GCP** | Workload Identity Pool (project-scoped resource) | Partial — pool is scoped to project | ✅ Architectural + Org Policy | Identity sameness risk within a project; attribute conditions recommended for shared IdPs |
| **Azure** | FederatedIdentityCredential `issuer` string field | ❌ No | ❌ None native | Blanket deny via custom Azure Policy is possible but no issuer-scoped control exists |

---

## Implications for AKS Multi-Cluster Environments

In a platform with many AKS clusters across dev, staging, and production environments:

- Each AKS cluster exposes its own OIDC issuer URL (e.g.
  `https://oidc.prod.eastus.azure.com/<uuid>`).
- UAMIs bound to production workloads could be misconfigured — or deliberately tampered
  with — to trust a dev cluster's issuer, allowing dev workloads to impersonate prod identities.
- ARM will accept this configuration without warning.
- The error only surfaces at runtime when a token exchange is attempted, by which point
  the misconfiguration may already be exploitable.
- At scale (hundreds of UAMIs, dozens of clusters), manual review of issuer values is
  not operationally viable.

This is the gap that Kyverno policy-based issuer allowlisting addresses at the GitOps
layer, enforcing the control that the Azure platform does not provide natively.

---

## References

| Source | URL |
|---|---|
| Azure Workload Identity Federation | https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation |
| Azure FIC Considerations & Restrictions | https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-considerations |
| Azure AKS Workload Identity Overview | https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview |
| ARM Template Reference — FederatedIdentityCredentials | https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/userassignedidentities/federatedidentitycredentials |
| AWS IAM OIDC Identity Provider | https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html |
| AWS Identity-Provider Controls (Shared IdPs) | https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc_secure-by-default.html |
| AWS Trust Policy Best Practices | https://aws.amazon.com/blogs/security/how-to-use-trust-policies-with-iam-roles/ |
| GCP Workload Identity Federation | https://cloud.google.com/iam/docs/workload-identity-federation |
| GCP WIF Best Practices | https://cloud.google.com/iam/docs/best-practices-for-using-workload-identity-federation |
| GCP GKE Workload Identity (Identity Sameness Warning) | https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity |