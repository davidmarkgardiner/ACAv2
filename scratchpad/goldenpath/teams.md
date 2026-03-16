
The idea is to make application onboarding repeatable, so when we rebuild clusters, apps just come back on their own. There are already a couple of teams in the org doing golden path onboarding and the first step is to go and talk to them, understand what they're doing, and see where we can collaborate or build on top of it.

My thinking on how we approach this is a tiered model rather than trying to force one-size-fits-all:

🥇 Tier 1 — Full GitOps: App onboarded via Flux, wrapped in HELM/ KRO, everything declared in Git. Survives a cluster rebuild automatically. This is the target state.

🥈 Tier 2 — Partial GitOps: App registered via Flux, external components mapped in via YAML. Not perfect but recoverable and a realistic stepping stone for a lot of teams.

🥉 Tier 3 — AKS Backup: Manifests restored post-rebuild. Valid fallback but operationally heavier — more of a bridge than a destination.

The other idea I had was a community template repo — a central place where component patterns live and teams can compose what they need. We set the standards, the community contributes the patterns. Worth discussing.

We can't force everyone onto GitOps and I don't think we should try — but we can make the trade-offs obvious and let teams make the call.

Next steps as I see it: go talk to the golden path teams, understand the landscape, then start shaping our approach. We'll need to carve out some time, raise tickets, and assign a couple of engineers to own this.
