Here's a reply that draws a line under it:

---


Thanks for confirming the DNS alias setup - that helps clarify the intended design.

However, we're still seeing users report delays between pushing to Snapshot and the image being pullable from Main Nexus. If it's a DNS alias, it should be immediate - so there may be a caching issue on the registry side worth investigating.

**Where we've landed:**

Our copy logic (Nexus → ACR) was built to work with the Main Nexus registry for a specific Tier 1 production use case. The current setup - where users push to Snapshot, expect DNS aliasing to make it available on Main Nexus, and then expect us to copy to ACR - isn't something our solution was designed to support.

**What we're going to do:**

- **Production (Tier 1):** Keep the copy job enabled - this is working as intended
- **Dev:** Disable the copy job - users can pull directly from Nexus

Ultimately, ensuring images are available in the correct registry for users is a registry team responsibility. We've tried to help bridge the gap, but the current design isn't something we can reliably support.

Happy to hand over any context that's useful, and of course still available for the call if needed.

Cheers,
Dave

---

Does that strike the right tone - firm but not burning bridges?