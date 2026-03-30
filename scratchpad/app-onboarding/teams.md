# Teams Message: Meeting Structure Request

**Copy-paste into Teams:**

---

Hi Team,

Can we get some structure to these meetings? I think we'd make a lot more progress if we agreed on a few things upfront for each piece of work.

For each area we're looking at, I'd like us to define:

1. **Problem statement** — What problem are we trying to solve? What's broken or missing today?
2. **Desired state** — Where do we want to end up? What does "done" look like?
3. **Tooling decision** — What tools are we using to get there? Do we use existing operators and workflows (Argo, Flux, ASO, cert-manager, etc.) or do we build our own operators/APIs?

Once we agree on those three things, I can start building proof of concepts. I've already got several running on real clusters — the triage system, the onboarding workflow, the multi-agent pipeline — so we're not starting from scratch.

The tooling question is important: are we happy using Argo Workflows for orchestration, GitLab for audit/GitOps, and the existing operator ecosystem (cert-manager, ESO, ASO, Kyverno)? Or is there a preference to build custom operators or APIs? Either way is fine — I just need to know before I build.

If we can get alignment on problem + desired state + tools for even one area, I'll have a PoC ready for the next meeting.

David

---
# Teams Message: Platform Automation — Next Steps

**Copy-paste into Teams:**

---

Hi Team,

Following on from our discussion, I want to propose a more structured approach so we can make real progress.

**The approach:** We combine the best of both worlds — deterministic, structured Argo Workflows for guaranteed results (onboarding, provisioning, compliance) with AI agents in the loop where they add value (triage, validation, template creation, observability).

**What I need from the team for each phase:** Give me the **problem statement**, the **desired state**, and the **allowed tools**. With those three things, I can work out a solution and build a PoC. Let's be direct about what we want to achieve rather than having open-ended discussions that don't end with running code.

**The PoCs already exist.** The multi-agent pipeline, the triage system with namespace-specific agents, the onboarding workflow template — these are running on real clusters, tested end-to-end. We're not starting from zero.

**The blocker:** Everything depends on the management cluster, which is blocked on IP availability in the target VNet. We've requested this multiple times. Nothing rolls through environments without it. This needs to be unblocked first.

**Proposed meeting structure — one phase per meeting:**

| Meeting | Focus | What We Need To Agree |
|---------|-------|----------------------|
| **1** | Management cluster | Unblock IP allocation. What components, what environment, what access? |
| **2** | Namespace onboarding | Replace Go program with Argo Workflows. Get a hello-world app through end-to-end. RBAC from day one. |
| **3** | Runtime triage | K8s events → agent diagnosis → GitLab + Teams. Which namespaces first? Engineers first, then SRE. |
| **4** | App onboarding + defaults | PDBs, certs, Istio, security contexts — start basic, add incrementally. |
| **5** | External Azure resources | ASO for workload identity, Key Vault, databases. Comes after local K8s operators. |
| **6** | RBAC + Azure RBAC | Namespace RBAC + Azure role assignments via ASO. Drift detection. |
| **7** | Autonomous remediation | Allowlist-based safe actions. Logging, monitoring, progressive trust. |

Each meeting: review problem statement, agree desired state, confirm tools, create tickets. One phase at a time.

Full proposal with architecture diagrams, problem statements, and tooling breakdown is in the repo — happy to share.

David
