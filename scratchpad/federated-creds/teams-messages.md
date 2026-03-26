# Teams Messages — FederatedIdentityCredential Controls

Informal messages for different audiences. Pick the one that fits.

---

## Option 1: Short and punchy (for the platform/infra channel)

**Heads up -- Workload Identity Federation gap**

So after digging into this, turns out Azure does zero validation on the OIDC issuer URL when you create a FederatedIdentityCredential. Like, literally any string. You could point a prod UAMI at a dev cluster and ARM just says "yeah sure, no problem." No built-in policies, no Defender rules, nothing. Microsoft don't even consider it a gap. AWS and GCP both handle this natively -- Azure just doesn't.

The only way we can plug this is with an Azure Policy and an allowlist. We've written a script that queries all AKS clusters across the management group, groups the OIDC endpoints by `op-environment` tag, and builds a per-environment allowlist. The policy then blocks any FIC write where the issuer isn't in the list for that subscription's environment. Same env = fine, different env = denied.

Script runs nightly to keep the lists current, and we can trigger it manually if we rebuild a cluster and need the new OIDC URL added straight away.

Rolling out in Audit mode first so nothing breaks. Will switch to Deny after a couple of weeks once we're confident the lists are right.

More details in the ticket: [link]

---

## Option 2: A bit more context (for a wider engineering audience)

**FederatedIdentityCredential -- we found a gap and here's how we're fixing it**

Hey all -- quick update on something we've been investigating.

When you create a FederatedIdentityCredential on a managed identity, the OIDC issuer field is just a free-text string. ARM doesn't check that the issuer actually belongs to a cluster in the same environment. So in theory, someone (or some dodgy automation) could federate a prod UAMI to trust a dev cluster, and then a pod on dev could authenticate as that prod identity.

We looked at a few options -- Kyverno policies, custom RBAC roles, GitOps with ASO -- but the quickest and most effective fix is an Azure Policy with an environment-scoped allowlist.

Here's how it works:
- We already tag everything with `op-environment` (clusters, subs, UAMIs)
- A script queries all clusters across the management group and groups their OIDC URLs by environment
- Those lists get fed into Azure Policy as the allowed issuers per subscription
- If you try to create a FIC with a dev cluster's OIDC URL in a prod subscription, the policy blocks it

The script runs every night to pick up any changes, and we can run it manually if a cluster gets rebuilt and we need the new OIDC endpoint whitelisted.

We'll run it in Audit mode for a couple of weeks first. If you've got any FIC bindings that legitimately cross environments, shout now before we flip it to Deny.

Ticket with all the details: [link]

---

## Option 3: Very casual (for a small team chat or DM)

**Quick one on the workload identity thing**

Finished looking into the FIC cross-environment risk. Bottom line -- it's a Microsoft gap, not us. ARM literally doesn't validate the OIDC issuer URL at all. You can point any UAMI at any cluster in the tenant and it just lets you. No built-in fix, no planned fix from Microsoft.

Only option is an Azure Policy with an allowlist. We've got a script that pulls all the OIDC endpoints across the management group, sorts them by op-environment tag, and builds a per-env list. Policy checks every FIC write against the list -- same env goes through, cross-env gets blocked.

Runs nightly, can be kicked manually if we rebuild a cluster. Audit mode first, Deny mode in a couple of weeks.

Pretty straightforward in the end. Let me know if you want to walk through it.

---

## Option 4: For the security team specifically

**Update -- FederatedIdentityCredential environment isolation**

Wanted to close the loop on the workload identity investigation.

The root cause is an ARM platform limitation -- no validation on the OIDC issuer URL during FIC creation. Microsoft have confirmed this is by design (they federate with any OIDC provider, not just AKS) and there's nothing on the roadmap to change it. Worth noting AWS and GCP both have native controls for this exact scenario.

Our fix: Azure Policy with a dynamically generated allowlist. We query all AKS clusters across the management group, group OIDC issuer URLs by `op-environment` tag (dev / pre-prod / prod), and the policy denies FIC writes where the issuer doesn't match the subscription's environment.

We looked at adding Kyverno as a second layer but honestly it doesn't add meaningful value here. If the FIC can't be created at ARM, there's nothing for Kyverno to catch on the cluster side. The SA annotation it validates isn't a security boundary anyway -- pods can bypass it and call the token endpoint directly.

So the control set is:
- Azure Policy (Deny) -- primary control, blocks cross-env FIC writes
- Nightly allowlist refresh -- keeps OIDC URL lists current
- Manual trigger -- for cluster rebuilds where we can't wait for the nightly run
- Activity Log alerting -- on FIC writes, deletes, and policy exemptions

Rolling out Audit mode this week, Deny mode in ~2 weeks.

Full write-up and scripts in the ticket: [link]
