Hi all,

Wanted to share some thoughts ahead of our next discussion on cluster lifecycle management.

We currently have three regional AKS clusters running 24/7, 365 days a year — Americas, EMEA, and APAC. They're already deployed, already funded, and already serving their respective user bases. The question we should be asking is: are we using them as well as we could be?

Right now, when we need to rebuild a cluster — whether that's a CIDR change, a NAP migration, or a scheduled uplift — we spin up a temporary second cluster, run both in parallel for ~30 days, and then tear the old one down. That means we're paying for two clusters during the transition anyway, but getting zero resilience benefit for the other 335 days of the year.

The proposal is simple: instead of spinning up temporary clusters on demand, we pre-provision every team's namespace, RBAC, and workload identity bindings on both their primary cluster and a designated failover cluster at the point of onboarding. APAC fails over to EMEA. EMEA fails over to Americas. Americas fails over to EMEA. The failover cluster is always warm, always synced via GitOps, and always ready.

When a rebuild or failure happens, teams switch context — the namespace is already there, secrets are already synced, identity bindings are already in place. No emergency standup. No user disruption. No time pressure.

The cost delta is zero. The infrastructure already exists. The one-time investment is updating our onboarding automation to provision on two clusters instead of one.

Happy to walk through the detail — I've put together a full architecture document covering the topology, GitOps sync approach, failover process, and answers to the likely questions around data residency and capacity. Will share shortly.

Dave