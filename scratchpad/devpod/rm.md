
**Subject: Dev Pod Migration – Critical Blocker for Engineering Productivity**

As part of the planned migration from our current Dev VM environment to the new Dev Pod platform, a significant operational issue has been identified that requires urgent attention before any transition can proceed.

Our current Dev VMs provide the tools, configurations, and elevated access necessary to carry out day-to-day engineering tasks — including cluster management, Azure infrastructure operations, and DevSecOps workflows. These environments have been tuned over time to support the complexity of our work.

The Dev Pod environment, as currently configured, does not support the administrative access levels required to connect to AKS clusters or Azure resources in any meaningful capacity. Without this access, core engineering functions — including cluster troubleshooting, deployment management, policy enforcement, and infrastructure changes — cannot be performed. In practical terms, this means the team would be unable to do their jobs.

This is not a minor inconvenience or a short-term adjustment period. The absence of appropriate access is a fundamental blocker. Until the Dev Pod platform can be configured to support the necessary permissions model — whether through managed identity integration, role-based access controls, or an approved elevated access mechanism — migrating away from the Dev VM is not viable.

**Request:** Before any migration timeline is enforced, we ask that the following be addressed:

- A clear access model for Dev Pod that supports the required Azure and AKS permissions
- Confirmation that all existing tooling can be replicated or substituted within the new environment
- A pilot period where both environments run in parallel to validate parity

We're supportive of modernising our developer environment, but the current state of Dev Pod does not meet the minimum requirements for our team to function effectively.

---

Want me to adjust the tone — more urgent, more diplomatic, or more technically detailed?