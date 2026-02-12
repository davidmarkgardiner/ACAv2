 Our current setup isn't really working for us — it's all or nothing, so we're either drowning in email noise or flying blind. Neither is ideal.

What we actually need is quite simple: targeted alerts on the core components of our three flagship clusters, triggered on commits to main, so we know immediately if something is broken. No manual dashboard checks, no sifting through hundreds of emails every morning.


---

Appreciate the honest update on alerting. I do want to flag a concern though.

If our current observability offering is essentially "watch the Grafana dashboards and look for things going red", that's not really observability in any meaningful sense — it's manual monitoring, and it doesn't scale. Engineers shouldn't need to sit in front of dashboards to find out if a commit has broken something. That's exactly the problem alerting exists to solve.

More broadly, this is something we need to get right internally before we can credibly roll it out to the wider shared AKS platform. If we can't deliver automated alerting to our own pod, it raises a fair question about whether the current approach is going to work for the hundreds of teams we're expected to support.

I think it's worth stepping back and reviewing our observability strategy with that lens.

---



If our current observability offering is essentially "watch the Grafana dashboards and look for things going red", that's not really observability in any meaningful sense — it's manual monitoring, and it doesn't scale. Engineers shouldn't need to sit in front of dashboards to find out if a commit has broken something. That's exactly the problem alerting exists to solve.

To be frank, alerting is a solved problem. DevOps teams across the industry deliver targeted, automated alerts as standard practice — it's one of the most fundamental capabilities in any observability stack. With a dedicated Grafana expert embedded in the pod, the expectation would be that this is something we can absolutely deliver. The fact that we can't, even for our own team, is a gap we need to understand and close.

More broadly, this is something we need to get right internally before we can credibly roll it out to the wider shared AKS platform. If we can't deliver automated alerting to our own pod, it raises a fair question about whether the current approach is going to work for the hundreds of teams we're expected to support.

I think it's worth stepping back and reviewing our observability strategy with that lens. Happy to contribute to that conversation — let's get something scheduled.

---
Hi team,

Appreciate the honest update on alerting. I do want to flag a serious concern though.

If our current observability offering is essentially "watch the Grafana dashboards and look for things going red", that's not really observability in any meaningful sense — it's manual monitoring, and it doesn't scale. Engineers shouldn't need to sit in front of dashboards to find out if a commit has broken something. That's exactly the problem alerting exists to solve.

To be frank, alerting is a solved problem. DevOps teams across the industry deliver targeted, automated alerts as standard practice — it's one of the most fundamental capabilities in any observability stack. With a dedicated Grafana expert embedded in the pod, the expectation would be that this is something we can absolutely deliver. The fact that we can't, even for our own team, is a gap we need to understand and close.

We also need to acknowledge the investment that's been made here. We've assigned multiple engineers to this over the past year. Despite that commitment, we still can't deliver basic alerting to our own pod. That points to a clear accountability problem — outcomes are expected when resources are allocated, and those outcomes have not materialised. We can't keep investing time and people into this without seeing results.

More broadly, this is something we need to get right internally before we can credibly roll it out to the wider shared AKS platform. If after a year of dedicated effort we can't deliver automated alerting to our own team, it raises serious questions about whether the current approach and ownership model is going to work for the hundreds of teams we're expected to support.

I think we need to step back and have a frank review of our observability strategy, what's been blocking progress, and how we ensure delivery going forward. Let's get something scheduled.