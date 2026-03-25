# Teams Response: Cost Estimate & Savings Potential

**Subject / Context:** Replying to stakeholders asking for an exact dollar figure on savings.

---

Hi Team,

It's a difficult one to put an exact dollar figure on right out of the gate. 

To give you an accurate number, we first need to sit down and run the baseline PromQL queries across a few of our clusters to understand exactly what our current wastage looks like (the delta between requested resources and actual usage). 

Keep in mind that the financial impact isn't just limited to wasted compute (CPU/Memory). We also have to factor in:
* **Logging Costs:** Crashlooping apps and scheduling failures generate massive amounts of log ingestion (which costs us in Loki / Azure Monitor).
* **SRE Time:** The manual effort and time spent by our SREs troubleshooting issues caused by these "noisy neighbors."

Ultimately, because we are proposing a visibility/gamification model rather than strictly enforcing hard limits, the actual realized savings will come down to how quickly the application teams act on the reports to resolve their side of the issues. 

Because of that human element, it’s hard to give an exact guaranteed figure today. However, given our scale (50 clusters, ~6,000 deployments), the ballpark potential savings across compute, logging, and SRE time is considerable. I'd recommend we run a 2-week baseline on a single non-prod cluster to get a concrete starting number.

Let me know if you’d like to review the baseline queries we plan to run!
