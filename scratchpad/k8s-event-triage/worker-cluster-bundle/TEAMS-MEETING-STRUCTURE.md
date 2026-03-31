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
