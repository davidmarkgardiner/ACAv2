Here's a GitLab issue structure for this:

---

## Title
Namespace Onboarding: Reduce Azure RBAC Permissions to Cluster User Role Only

## Problem Statement
Product teams are requesting namespace onboarding with minimal Azure RBAC permissions. Currently, our RBAC pipeline binds the **AKS Cluster Admin role** to users via BBS permissions and SPNs, which is overly permissive for teams that only need to deploy resources via GitOps/pipelines.

## Current State
- Pipeline automatically assigns Azure RBAC admin permissions to users/SPNs
- Managed through BBS (role/group assignments)
- All users get broad cluster-level permissions regardless of actual need

## Proposed Solution: Cluster User + K8s RBAC
**Azure Level:**
- Assign only `Azure Kubernetes Service Cluster User Role` to deployer identity
- This provides authentication only (ability to run `az aks get-credentials`)

**Kubernetes Level:**
- Use native Kubernetes RBAC (RoleBindings/ClusterRoleBindings) to grant specific permissions
- Example: Bind custom Role to deployer ServiceAccount for CRD operations in their namespace

**Benefits:**
- Least privilege access model
- Azure RBAC handles authentication, K8s RBAC handles authorization
- Teams can manage their namespace permissions without Azure-level changes

**Requirements:**
- Control plane team ticket to modify RBAC pipeline automation
- Update onboarding documentation
- ServiceAccount creation automation for deployer workloads

## Alternative Approaches

### Option A: No Azure RBAC Assignment
- Create namespace without any Azure RBAC assignments
- Deploy via UAMI-backed ServiceAccount only
- GitOps/Argo handles all deployments using cluster-internal identity

**Pros:** No Azure RBAC dependency, fully GitOps-driven  
**Cons:** No human access for troubleshooting, debugging

### Option B: Kyverno Mutation + Job Pattern
- Empty namespace created on onboarding
- Kyverno mutation webhook creates deployer Job on demand
- Job runs with UAMI-backed ServiceAccount to apply CRDs/resources

**Pros:** Automated, no Azure RBAC changes needed  
**Cons:** More complex, requires Kyverno policy development

### Option C: Argo Workflow Automation
- Argo Workflow creates resources in target namespace
- Uses dedicated ServiceAccount with scoped permissions
- Triggered via Argo Events on Git commit

**Pros:** Leverages existing GitOps platform  
**Cons:** Requires workflow development, may not satisfy "human access" requirement

## Questions & Decisions Needed

1. **Do product teams actually need human `kubectl` access?**
   - If no → Option A (no Azure RBAC) is simplest
   - If yes → Proposed Solution (Cluster User + K8s RBAC)

2. **Who manages the Kubernetes RBAC bindings?**
   - Platform team via GitOps?
   - Product teams self-service?
   - Automated via namespace onboarding?

3. **What specific CRD operations are required?**
   - Create/update/delete which CRDs?
   - Namespace-scoped or cluster-scoped resources?

4. **Control plane team capacity?**
   - Timeline for RBAC pipeline modifications?
   - Risk/impact assessment for changing existing automation?

## Recommendation
**Start with Option A** (no Azure RBAC, UAMI + ServiceAccount pattern) as it:
- Requires no control plane changes
- Aligns with GitOps-first approach
- Provides security boundary via K8s ServiceAccount
- Can be implemented immediately

If human troubleshooting access is genuinely required, implement Cluster User + K8s RBAC as a second phase.

## Action Items
- [ ] Clarify product team requirements (human access vs. automation-only)
- [ ] Document UAMI + ServiceAccount pattern for deployer workloads
- [ ] Create proof-of-concept in dev cluster
- [ ] Update onboarding runbook
- [ ] (If needed) Submit control plane ticket for RBAC pipeline changes

## Related
- Link to namespace onboarding documentation
- Link to BBS RBAC configuration
- Link to ServiceAccount/UAMI standards

---

Does this capture the situation? I've structured it to push back on changing the RBAC model unless there's a clear need for human access, since your alternatives are more aligned with GitOps best practices.