# AKS Spot Node Pool Migration - Testing Scenarios & Feedback

## Meeting Notes Summary

Three scenarios identified for spot node pool adoption:

| Scenario | Description | Toleration Requirement |
|----------|-------------|------------------------|
| 1 | New clusters (spot only from day one) | Must be in place before deployment |
| 2 | Existing clusters with policy applied | **Testing required** - upgrade behaviour unclear |
| 3 | Existing clusters rebuilt as new | Same as Scenario 1 |

---

## Scenario 1: New Clusters (Spot Only)

### Overview

New clusters are provisioned with:
- System node pool (Regular priority - **required**, cannot be spot)
- User node pool(s) (Spot priority only)

### Implications

- **No regular user node pools exist** - all user workloads must tolerate spot taint
- Teams **must** include tolerations in manifests before first deployment
- Pods without tolerations will be `Pending` immediately - no grace period

### Policy Configuration

```json
{
  "policyRule": {
    "if": {
      "allOf": [
        {
          "field": "type",
          "equals": "Microsoft.ContainerService/managedClusters/agentPools"
        },
        {
          "field": "Microsoft.ContainerService/managedClusters/agentPools/mode",
          "equals": "User"
        },
        {
          "field": "Microsoft.ContainerService/managedClusters/agentPools/scaleSetPriority",
          "notEquals": "Spot"
        }
      ]
    },
    "then": {
      "effect": "Deny"
    }
  }
}
```

### Test Cases - Scenario 1

| Test ID | Test Case | Expected Result | Actual Result | Pass/Fail |
|---------|-----------|-----------------|---------------|-----------|
| 1.1 | Create new cluster with system pool only | Allowed | | |
| 1.2 | Add regular user node pool | **Denied by policy** | | |
| 1.3 | Add spot user node pool | Allowed | | |
| 1.4 | Deploy workload without toleration | Pod Pending | | |
| 1.5 | Deploy workload with toleration | Pod Running on spot | | |
| 1.6 | System pool upgrade | Allowed (not affected by policy) | | |
| 1.7 | Spot user pool upgrade | Allowed | | |

---

## Scenario 2: Existing Clusters - Policy Applied

### Overview

Existing clusters have:
- System node pool (Regular)
- User node pool(s) (Regular - **pre-existing**)

Policy is then applied to deny new non-spot user pools.

### The Upgrade Question

**Key concern**: What happens when you try to upgrade an existing regular user node pool after the deny policy is in place?

#### Potential Outcomes

> **Hypothesis**: Azure Policy `Deny` effects evaluate resource state during Create and Update operations. Because an upgrade is a PUT operation on the Agent Pool resource, and the resource state remains "Regular" priority (matching the Deny rule), **upgrades will likely be blocked** unless the policy is scoped out or exempted.

| Behaviour | Impact | Likelihood |
|-----------|--------|------------|
| Upgrade proceeds normally | Policy only checks changed fields (unlikely for Deny) | Low |
| Upgrade blocked | Update operation rejected because final state matches Deny rule | **High** |
| Partial failure | Surge nodes blocked but base upgrade works | Possible |

### How AKS Node Pool Upgrades Work

1. **With surge (maxSurge configured)**:
   - AKS creates additional temporary nodes
   - Cordons old nodes
   - Drains workloads to new/surge nodes
   - Deletes old nodes
   - Question: Are surge nodes new agentPool resources or VMSS scaling?

2. **Without surge**:
   - Nodes upgraded one at a time
   - Cordon → Drain → Reimage → Uncordon
   - No new pool resources created

3. **Spot pool upgrades**:
   - No surge available
   - Cordon and eviction notice (no drain)
   - Different behaviour entirely

### Critical Questions for Testing

1. Does upgrading an existing regular node pool trigger the Azure Policy?
2. Are surge nodes evaluated as new agentPool resources?
3. Can you still scale an existing regular pool (add nodes) after policy is applied?
4. What error message appears if upgrade is blocked?

### Test Cases - Scenario 2

| Test ID | Test Case | Expected Result | Actual Result | Pass/Fail |
|---------|-----------|-----------------|---------------|-----------|
| 2.1 | Apply deny policy to subscription with existing regular pools | Policy applies, existing pools show non-compliant | | |
| 2.2 | Scale existing regular pool (increase node count) | **Unknown** - needs testing | | |
| 2.3 | Upgrade existing regular pool (no surge) | **Unknown** - needs testing | | |
| 2.4 | Upgrade existing regular pool (with surge) | **Unknown** - needs testing | | |
| 2.5 | Add new regular user pool after policy | Denied | | |
| 2.6 | Add new spot user pool after policy | Allowed | | |
| 2.7 | Delete existing regular pool | Allowed (policy doesn't block deletes) | | |
| 2.8 | Control plane upgrade with regular user pool | **Unknown** - needs testing | | |

### Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Upgrades blocked unexpectedly | **High** | Use Policy Exemptions (Option A) for existing non-compliant clusters |
| Teams unable to scale existing pools | **High** | Implement temporary exemptions or phased rollout (Audit -> Deny) |
| Cluster becomes unmanageable | **Critical** | Define clear exemption process owner |

> **Note**: Kyverno is not available for this process. We must rely entirely on Azure Policy for enforcement and manual scripts for validation.

### Recommended Testing Approach

```bash
# 1. Create test cluster with regular user pool
az aks create \
    --resource-group test-rg \
    --name test-cluster \
    --node-count 2

az aks nodepool add \
    --resource-group test-rg \
    --cluster-name test-cluster \
    --name userpool \
    --node-count 2 \
    --mode User

# 2. Apply deny policy to resource group
az policy assignment create \
    --name "test-deny-regular-pools" \
    --policy "<policy-definition-id>" \
    --scope "/subscriptions/<sub>/resourceGroups/test-rg"

# 3. Wait for policy to take effect (~15 mins)

# 4. Test scaling
az aks nodepool scale \
    --resource-group test-rg \
    --cluster-name test-cluster \
    --name userpool \
    --node-count 3

# 5. Test upgrade
az aks nodepool upgrade \
    --resource-group test-rg \
    --cluster-name test-cluster \
    --name userpool \
    --kubernetes-version <newer-version>

# 6. Document results
```

---

## Scenario 3: Rebuild Existing Clusters

### Overview

Existing clusters are decommissioned and rebuilt with spot-only configuration. Effectively becomes Scenario 1.

### Migration Path

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. Provision new cluster with spot user pools                  │
│                                                                 │
│  2. Teams update manifests with tolerations                     │
│                                                                 │
│  3. Deploy to new cluster                                       │
│                                                                 │
│  4. Validate functionality                                      │
│                                                                 │
│  5. Cut over traffic                                            │
│                                                                 │
│  6. Decommission old cluster                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Implications

- Clean slate - no legacy regular pools
- Requires parallel infrastructure during migration
- Higher effort but lower risk than in-place changes
- Same toleration requirements as Scenario 1

### Test Cases - Scenario 3

| Test ID | Test Case | Expected Result | Actual Result | Pass/Fail |
|---------|-----------|-----------------|---------------|-----------|
| 3.1 | Create new cluster with spot user pool | Allowed | | |
| 3.2 | Migrate workloads with tolerations | Pods schedule on spot | | |
| 3.3 | Migrate workloads without tolerations | Pods Pending | | |
| 3.4 | Policy blocks adding regular pool to new cluster | Denied | | |

---

## Policy Exemption Considerations

If Scenario 2 testing reveals upgrade issues, you may need:

### Option A: Exemption for Existing Pools

Create exemptions for clusters during transition:

```bash
az policy exemption create \
    --name "upgrade-exemption" \
    --policy-assignment "<assignment-id>" \
    --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<cluster>" \
    --exemption-category "Waiver" \
    --expires-on "2026-03-01"
```

### Option B: Phased Policy Rollout

1. **Phase 1**: Audit only (visibility)
2. **Phase 2**: Deny on new clusters only (resource group targeting)
3. **Phase 3**: Deny across all after migration complete

### Option C: Policy Condition Refinement

Add condition to only apply to new resources:

```json
{
  "if": {
    "allOf": [
      {
        "field": "type",
        "equals": "Microsoft.ContainerService/managedClusters/agentPools"
      },
      {
        "field": "Microsoft.ContainerService/managedClusters/agentPools/mode",
        "equals": "User"
      },
      {
        "field": "Microsoft.ContainerService/managedClusters/agentPools/scaleSetPriority",
        "notEquals": "Spot"
      },
      {
        "field": "tags['createdAfter']",
        "exists": "true"
      }
    ]
  },
  "then": {
    "effect": "Deny"
  }
}
```

*Note: `apiVersion` is not a reliable filter for "new" resources. Using a tag like `createdAfter` (applied by IaC pipeline) or relying on Exemptions (Option A) is recommended.*

---

## Open Questions for Stakeholders

1. **Upgrade blocking**: If testing confirms upgrades are blocked, is that acceptable or do we need exemptions?

2. **Transition period**: How long should existing clusters have before policy enforcement?

3. **Exemption process**: Who can approve exemptions for clusters that genuinely need regular pools?

4. **Hybrid support**: Should we allow a mix of spot and regular user pools for critical workloads?

5. **Monitoring**: How do we track policy compliance and exemption expiry?

---

## Next Steps

| Action | Owner | Due Date |
|--------|-------|----------|
| Execute Scenario 2 test cases | | |
| Document upgrade behaviour findings | | |
| Define exemption approval process | | |
| Confirm transition timeline per scenario | | |
| Review with stakeholders | | |

---

## Feedback Section

### Test Results

*[To be completed after testing]*

### Issues Identified

*[To be completed after testing]*

### Recommendations

*[To be completed after testing]*