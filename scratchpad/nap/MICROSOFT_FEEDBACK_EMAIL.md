# Email to Microsoft: NAP Default NodePools and Azure Linux Support

## Subject Line
NAP Default NodePools - Request for Azure Linux Default Option and Ubuntu Certificate Injection Support

---

## Email Body

Dear Microsoft Azure Kubernetes Service Team,

We are currently implementing Node Auto-Provisioning (NAP) across our AKS clusters and have identified a critical compatibility issue with our certificate injection tooling that requires your attention.

### Current Issue

When enabling NAP with `--node-provisioning-mode Auto`, Azure automatically creates two default NodePools:
1. **"default"** - General purpose NodePool
2. **"system-surge"** - System workload surge NodePool

**Problem**: Both default NodePools use **Ubuntu2204** as the default `imageFamily`, which is incompatible with our enterprise certificate injection tool. Our certificate injection solution is currently only compatible with **Azure Linux** nodes, causing cluster initialization to fail immediately after creation.

### Current Workaround

We have identified a working solution using the Azure CLI flag:

```bash
az aks create \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools None
```

This prevents the automatic creation of Ubuntu-based default NodePools, allowing us to deploy custom Azure Linux-based NodePools via GitOps immediately after cluster creation.

**Workflow**:
1. Create cluster with `--node-provisioning-default-pools None`
2. Deploy custom Azure Linux NodePools via GitOps/Flux
3. Cluster operates normally with certificate injection working correctly

### Feature Requests

We request the following enhancements to improve NAP functionality for enterprise environments:

#### 1. **Per-Cluster/Environment Default NodePool Image Family Configuration**

**Request**: Add a configuration option to specify the default `imageFamily` for automatically created NodePools.

**Proposed Implementation**:
```bash
# CLI Option
az aks create \
  --node-provisioning-mode Auto \
  --node-provisioning-default-pools Auto \
  --node-provisioning-default-image-family AzureLinux
```

**ASO/ARM Template Option**:
```yaml
nodeProvisioningProfile:
  mode: Auto
  defaultNodePools: Auto
  defaultImageFamily: AzureLinux  # or Ubuntu2204
```

**Benefits**:
- Allows clusters to start with appropriate OS for their environment
- Eliminates manual NodePool recreation workflow
- Reduces cluster creation time and complexity
- Supports enterprise requirements for specific OS distributions

**Use Cases**:
- Production environments requiring Azure Linux for security/compliance
- Development environments using Ubuntu for developer familiarity
- Multi-tenant platforms with different OS requirements per environment
- Enterprises with certificate injection tools tied to specific OS distributions

#### 2. **Ubuntu Certificate Injection Compatibility**

**Request**: We need guidance or tooling updates to enable our certificate injection solution to work on Ubuntu nodes.

**Context**:
- Our current certificate injection tool works seamlessly with Azure Linux nodes
- Ubuntu nodes fail certificate injection, preventing system pods from starting
- This blocks us from using the default NAP experience

**Questions**:
1. Are there known differences in certificate handling between Ubuntu2204 and Azure Linux in AKS?
2. Are there specific paths, permissions, or system configurations required for certificate injection on Ubuntu nodes?
3. Does Microsoft have recommended practices or tooling for enterprise certificate injection on Ubuntu AKS nodes?
4. Are there plans to standardize certificate injection mechanisms across Ubuntu and Azure Linux?

**Impact**:
- Enables us to use default NAP configuration
- Removes dependency on Azure Linux-specific workarounds
- Improves cluster creation automation
- Better aligns with standard AKS deployment patterns

### Why This Matters

**Scale**: We are deploying NAP across multiple production AKS clusters supporting critical enterprise workloads.

**Certificate Injection Requirement**: Enterprise security policy mandates custom CA certificate injection for:
- Internal PKI infrastructure
- Corporate proxy certificates
- Compliance and audit requirements
- Zero-trust security architecture

**GitOps Complexity**: Current workaround requires:
1. Creating cluster with no default NodePools
2. Deploying custom NodePools via GitOps within minutes
3. Careful orchestration to prevent NAP failures (NAP requires at least one NodePool)
4. Additional monitoring to ensure NodePools deploy successfully

### Current Architecture

**Cluster Configuration** (Azure Service Operator):
```yaml
apiVersion: containerservice.azure.com/v1api20240402preview
kind: ManagedCluster
spec:
  nodeProvisioningProfile:
    mode: Auto
    defaultNodePools: None  # Current workaround
  agentPoolProfiles:
    - name: systempool
      mode: System
      count: 1
      osType: Linux
      osSKU: AzureLinux  # Works with certificate injection
```

**Custom NodePools** (Deployed via GitOps):
- `system-pool` - Azure Linux, system workloads
- `default` - Azure Linux, general workloads (overrides default Ubuntu pool)
- `system-surge` - Azure Linux, surge capacity (overrides default Ubuntu pool)

### Requested Timeline

We would appreciate feedback on:
1. **Short-term** (0-3 months): Guidance on Ubuntu certificate injection compatibility
2. **Medium-term** (3-6 months): Consideration of `defaultImageFamily` configuration option
3. **Long-term** (6-12 months): Standardized certificate injection support across all AKS OS distributions

### Technical Environment

- **API Version**: `containerservice.azure.com/v1api20240402preview`
- **Kubernetes Version**: 1.32
- **Azure CLI**: 2.73.0
- **Deployment Method**: Azure Service Operator (ASO) v2 + Flux GitOps
- **Network**: Azure CNI Overlay + Cilium
- **Scale**: Multiple production clusters, 50+ namespaces per cluster
- **OS Requirement**: Azure Linux (due to certificate injection compatibility)

### Additional Context

**Why Azure Linux?**
- Microsoft-optimized for AKS
- Works with our certificate injection tooling
- Security-hardened distribution
- Faster updates and patches

**Why We Need Ubuntu Option?**
- Developer familiarity
- Some application dependencies expect Ubuntu
- Third-party tool compatibility
- Migration path from existing Ubuntu-based clusters

### Our Commitment

We are committed to:
- Testing and providing feedback on any beta/preview features
- Documenting our certificate injection approach for the community
- Contributing to AKS best practices and documentation
- Participating in customer advisory boards or feedback programs

### Contact Information

**Primary Contact**: [Your Name]
- Email: [Your Email]
- Company: [Your Company]
- Role: [Your Role]

**Technical Contact**: [Technical Lead Name]
- Email: [Tech Email]

### Documentation References

We have documented our workaround and findings:
- Cluster configuration with `defaultNodePools: None`
- Custom Azure Linux NodePool definitions
- GitOps deployment workflow
- Certificate injection architecture

We are happy to share these with the AKS team if helpful.

---

## Summary

**Current Workaround**: Use `--node-provisioning-default-pools None` and deploy custom Azure Linux NodePools via GitOps

**Feature Request 1**: Per-cluster configuration for default NodePool `imageFamily` (AzureLinux or Ubuntu2204)

**Feature Request 2**: Guidance/tooling for certificate injection on Ubuntu nodes in AKS

**Impact**: Affects cluster creation automation, GitOps complexity, and enterprise security compliance

**Timeline**: Short-term guidance needed; medium-term feature consideration appreciated

---

We appreciate the excellent work the AKS team has done with Node Auto-Provisioning. NAP represents a significant improvement in cluster management, and these enhancements would make it even more powerful for enterprise environments.

Thank you for considering our feedback. We look forward to your response and are happy to provide additional details or participate in discussions.

Best regards,

[Your Name]
[Your Title]
[Your Company]
[Your Email]
[Your Phone]

---

## Attachments (Optional)

Consider attaching:
1. **Architecture Diagram**: Showing current certificate injection flow
2. **NodePool Configurations**: Your custom Azure Linux NodePool definitions
3. **GitOps Workflow**: Diagram showing cluster creation and NodePool deployment sequence
4. **Certificate Injection Tool Details**: Technical specifications (if shareable)

---

## Follow-up Actions

After sending:
1. **Track Response**: Create ticket/case number for tracking
2. **Escalation Path**: Identify Microsoft TAM or account team for escalation if needed
3. **Community Engagement**: Consider posting sanitized version to AKS GitHub discussions
4. **Internal Documentation**: Update runbooks with any Microsoft guidance received

---

## Alternative: GitHub Issue Template

If Microsoft prefers GitHub issues for feature requests:

**Repository**: https://github.com/Azure/AKS/issues

**Template**:
```markdown
**Describe the feature request**
Add configuration option for default NAP NodePool imageFamily

**Describe the solution you'd like**
Add `--node-provisioning-default-image-family` CLI flag and corresponding ARM/ASO property

**Describe alternatives you've considered**
Current workaround: `--node-provisioning-default-pools None` + manual NodePool deployment

**Additional context**
Enterprise certificate injection tool requires Azure Linux, default Ubuntu NodePools fail

**Impact**
- Affects cluster creation automation
- Increases GitOps complexity
- Blocks default NAP experience for enterprises with OS-specific tooling
```

---

## Microsoft Support Channels

**Azure Support**: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade
**AKS GitHub**: https://github.com/Azure/AKS/issues
**AKS Feedback**: https://feedback.azure.com/d365community/forum/aabe212a-f724-ec11-b6e6-000d3a4f0da0
**Microsoft Q&A**: https://learn.microsoft.com/en-us/answers/tags/200/azure-kubernetes-service
