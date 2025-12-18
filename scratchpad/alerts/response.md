, you've been tasked with setting up observability and alerting for this pod and the wider platform. This was a clear deliverable and a critical part of our operational maturity.
What I'm hearing is that you can deliver this, but only if all alerts go into a single shared inbox. That approach isn't sustainable — the volume of noise will mean alerts get ignored, which defeats the entire purpose of having alerting in the first place. We need targeted, actionable alerts routed to the right teams, not a dumping ground that everyone tunes out.
If there are technical blockers or constraints I'm not aware of, I'm happy to discuss them. But if the solution being proposed doesn't meet the actual requirements, we need to acknowledge that.
, given the above, are we okay to reassign this to someone who can deliver what was originally committed to? I don't want this to drift any further.

---


Here's a response:

---

 the requirements have been shared multiple times over the past year — via emails, Teams messages, and direct conversations. This isn't a new ask, and I'm surprised we're still at the point of requesting a GitLab issue.

To be clear: the ask is not to add more people to a noisy alerts group. That's the opposite of what we need. The ask is, and always has been, for actionable, targeted alerting — alerts that are routed to the right teams, tuned to reduce noise, and actually get acted upon. A single inbox that everyone ignores isn't observability, it's just checkbox compliance.

If the requirements aren't clear after a year of communication, that's a concern in itself. But to remove any ambiguity:

- Alerts must be actionable — no noise, no alert fatigue
- Alerts must be routed to the appropriate teams, not a shared dumping ground
- There needs to be clear ownership and accountability for responding to alerts
- This needs to be delivered, not discussed further

I'm happy to jump on a call if that helps, but I need to see tangible progress here. We've been going in circles for too long.

, I'd appreciate your input on how we move this forward.

---

Here's the updated Teams message:

---

**Observability & Alerting — Standup Discussion**

We've invested millions of pounds and hired 5-6 engineers to deliver observability for this platform. After 12+ months, we still have no functional alerting. Engineers only find out things are broken when they manually stumble across issues while doing other work.

**This morning's example:** I tried three clusters — two were down. No alerts. Nobody working on it. Just broken and ignored.

The impact:
- Engineering velocity takes a hit because we're wasting time discovering and diagnosing issues that should be flagged automatically
- Broken code gets packaged up and promoted through dev into production because nobody knows it's broken
- Users are reporting bugs back to us in both production and development — we should be finding these first and working on them before our users even notice. Right now, we're hearing about problems from the people we're supposed to be providing a platform to. It's unprofessional and it's damaging trust.

This is a fundamental platform priority and it's blocking us. 

---
