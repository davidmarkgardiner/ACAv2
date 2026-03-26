# Codex Review: Federated Identity Credential Controls

## Summary

The current direction is broadly correct: this is not an RBAC-only problem, because the risk comes from a principal with legitimate write access creating the wrong `FederatedIdentityCredential` value. The strongest design is a layered model where direct writes are narrowed as much as possible, policy blocks invalid bindings, and detection plus reconciliation catch drift.

The main improvement is to promote GitOps and ASO from an open question into the primary control plane. Policy should be a backstop, not the only line of defense.

## Recommended Direction

Use a five-layer model:

### Layer 0: Authoritative write path via GitOps + ASO

Make `FederatedIdentityCredential` creation flow through reviewed manifests in git, reconciled by ASO or an equivalent controller.

Benefits:

- Every federation binding gets PR review and approval.
- Git history becomes the audit trail.
- Out-of-band changes become detectable drift.
- Human error moves earlier in the process, before ARM writes happen.

This is the highest-value control because it changes who can write and how writes occur.

### Layer 1: Narrow direct write permissions

Create a custom RBAC role that excludes:

- `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write`
- `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete`

Then:

- Assign the restricted role to normal application service principals.
- Grant the write capability only to the GitOps identity or tightly scoped automation identity.

This is lower complexity than tenant separation and materially reduces blast radius.

### Layer 2: Preventive policy enforcement

Keep the Azure Policy + Kyverno combination, but tighten the validation model:

- Enforce issuer allowlists.
- Enforce subject format and naming conventions.
- Validate environment alignment between cluster, namespace, service account, and target identity.
- Treat cluster rebuild automation as part of the control, not an afterthought.

If the `subject` is always predictable, use that to your advantage. A structured naming convention makes invalid cross-environment bindings easier to detect and block.

### Layer 3: Detection and alerting across both control planes

Do not rely on only one audit source.

Alert on:

- ARM Activity Log events for federated credential writes
- Entra ID audit logs for application credential and federation-related changes

Reason:

- These are separate telemetry pipelines.
- Retention, routing, and operational visibility may differ.
- One source can catch activity the other misses or delays.

### Layer 4: Reconciliation and periodic audit

Run a scheduled reconciliation job that compares actual `FederatedIdentityCredential` resources against:

- the GitOps source of truth
- the current issuer allowlist
- expected subject patterns

This closes the gap on drift and failed automation.

## Potential Solutions

### Option A: GitOps as the single write path

Description:
Only the GitOps controller or deployment automation can create or modify federated credentials.

Pros:

- Strongest preventive control
- Best auditability
- Simplest mental model for ownership

Cons:

- Requires operating discipline
- Emergency changes need a defined break-glass path

Recommendation:
Preferred end state.

### Option B: Custom RBAC role replacing broad Contributor access

Description:
Remove federated credential write access from general-purpose identities and grant it only to dedicated automation.

Pros:

- High impact
- Lower implementation cost than full platform redesign
- Works well with existing deployments

Cons:

- Does not by itself validate values
- Still needs policy and detection layers

Recommendation:
Implement early, even before full GitOps adoption.

### Option C: Policy-first enforcement with Azure Policy + Kyverno

Description:
Keep existing writer permissions but block invalid issuers, subjects, or environment mappings.

Pros:

- Fastest to introduce
- Good backstop control
- Helps during transition

Cons:

- Still allows attempted bad writes up to admission time
- Can become brittle if cluster metadata and allowlists drift

Recommendation:
Keep, but do not treat this as the primary long-term answer.

### Option D: Reduce UAMI usage with system-assigned identities where possible

Description:
Audit user-assigned managed identities and migrate single-purpose cases to system-assigned identities.

Pros:

- Shrinks the attack surface
- Reduces reuse across environments
- Simplifies ownership

Cons:

- Not viable for every workload
- Requires migration work

Recommendation:
Good parallel cleanup effort.

### Option E: Separate Entra tenants for strict environment isolation

Description:
Place dev and prod in separate tenants so federation boundaries are enforced structurally.

Pros:

- Strongest isolation model
- Minimizes shared trust assumptions

Cons:

- High operational overhead
- Expensive in process and platform complexity

Recommendation:
Reserve for regulated or hard-separation environments.

### Option F: Conditional Access for workload identities

Description:
Investigate whether Conditional Access can add meaningful restrictions around workload identity token issuance or federation trust.

Pros:

- Platform-level control
- Independent of ARM policy logic

Cons:

- Capability may be limited by scenario
- Not a substitute for write-path control

Recommendation:
Treat as a possible enhancement, not a primary mitigation.

## Improvements to the Existing Design

The document should be strengthened in these areas:

1. Elevate ASO and GitOps into a named control layer instead of leaving them as an open question.
2. Add Entra ID audit log monitoring alongside ARM Activity Log monitoring.
3. Define a formal `subject` naming convention and validate it consistently.
4. Add periodic reconciliation to detect drift, not just block new bad writes.
5. Define a break-glass process for cluster rebuild or allowlist automation failure.
6. Identify every tool that can write federated credentials, including Terraform, Pulumi, Crossplane, and custom pipelines.
7. Explicitly document which automation updates issuer allowlists after cluster rebuilds and how failure is detected.

## Suggested Phased Plan

### Phase 1: Immediate

- Add dual-source alerting for ARM Activity Log and Entra audit logs.
- Create a periodic inventory report of existing federated credentials.
- Define and document subject naming conventions.

### Phase 2: Near term

- Introduce a custom RBAC role that removes federated credential write access from general application identities.
- Tighten Azure Policy and Kyverno validation rules around issuer and subject matching.
- Implement reconciliation to detect out-of-band changes.

### Phase 3: Target state

- Move federated credential management to GitOps + ASO as the standard write path.
- Limit direct writes to narrowly scoped automation identities.
- Keep policy and detection layers as defense in depth.

## Open Questions

- What is the break-glass path if allowlist automation fails during a legitimate cluster rebuild?
- Which non-GitOps tools currently write federated credentials?
- How will drift be detected and remediated if someone makes a valid-but-unauthorized direct change?
- Which identities truly require UAMI reuse, and which can move to system-assigned identities?
- Is tenant-level separation necessary for compliance, or can the layered model satisfy control requirements?

## Final Recommendation

If the goal is strong practical risk reduction without excessive platform upheaval, the best sequence is:

1. remove federated credential write access from broad roles
2. enforce issuer and subject policy
3. add dual-source alerting and reconciliation
4. move to GitOps + ASO as the authoritative path

That combination addresses both accidental misconfiguration and malicious use of otherwise legitimate permissions, while preserving an incremental rollout path.
