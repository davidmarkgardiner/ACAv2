
# Why Frequent Releases Matter: A Case for Modern Deployment Practices

## Introduction

I've been thinking about our release strategy and wanted to share some industry insights that might help us improve our approach. This isn't about what we're doing wrong—it's about how we can reduce risk, get faster feedback, and deliver value more effectively.

The industry has shifted significantly toward frequent, smaller releases over the past decade. This isn't just a trend—it's a response to very real problems that large, bundled releases create. Let me walk you through why this matters and what we might consider.

## The Problem with Monolithic Releases

When we bundle everything into large, infrequent releases, we inadvertently create several challenges:

**1. Increased Blast Radius**

As [Codefresh notes](https://codefresh.io/blog/infrequent-deployments-release-trains-and-lengthy-sprints/): *"When you bundle many risky features into one release, you get a bigger blast-radius."* If something goes wrong, we're troubleshooting across multiple changes simultaneously, making root cause analysis harder and rollbacks more complex.

**2. Delayed Feedback**

The [Agile Alliance points out](https://agilealliance.org/glossary/frequent-releases/) a critical issue with infrequent releases: *"It mitigates the well-known planning failure mode of discovering delays very late."* The longer we wait to release, the longer we wait to discover if something's broken—or if we've built the wrong thing entirely.

**3. Higher Risk Per Deployment**

Large releases mean high-stakes deployments. Every release becomes a major event with significant pressure and risk. As Codefresh explains: *"Releasing on-demand lowers risk. Large, complex releases increase the risk of failure."*

## The Benefits of Frequent Releases

Industry research consistently shows several advantages to smaller, more frequent releases:

### Reduced Testing Time
[Exposé Data & Analytics](https://exposedata.com.au/the-power-of-frequent-software-releases-boosting-testing-release-management-and-developer-efficiency/) found that *"smaller code changes in frequent releases mean shorter testing cycles."* Less code to validate = faster, more focused testing.

### Easier Rollbacks
When changes are small and incremental, rolling back is straightforward. We're not trying to unpick weeks or months of intertwined changes—we're reverting a specific, isolated change.

### Faster Time to Value
[Redgate's DevOps research](https://www.red-gate.com/blog/database-devops/devops-101-unlocking-the-value-of-frequent-deployments) shows that *"faster deployment enables faster value to users."* Bug fixes reach production sooner. Features deliver value sooner. Users see us being responsive.

### Better Developer Experience
[Exposé Data also notes](https://exposedata.com.au/the-power-of-frequent-software-releases-boosting-testing-release-management-and-developer-efficiency/) that *"developers get feedback faster, improved collaboration, increased motivation."* No more waiting weeks for your code to reach production. No more massive, stressful release days.

### Improved Quality Through Automation
Frequent releases force us to invest in the right things: automation, testing, monitoring. As Redgate points out, *"quality and automation must go together with release speed."* This isn't about cutting corners—it's about building the infrastructure that makes quality repeatable and reliable.

## What This Looks Like in Practice

I'm not suggesting we flip a switch overnight, but we should explore moving toward:

- **Continuous deployment of non-breaking changes** (bug fixes, minor improvements, security patches)
- **Feature flags** for larger changes that need progressive rollout
- **Automated testing and validation** that gives us confidence in smaller batches
- **Clear rollback procedures** that work with our GitOps approach
- **Release frequency measured in days or weeks, not months**

This aligns well with our GitOps-first approach using Argo and our focus on automation with Kyverno and ASO.

## The Bottom Line

The industry moved away from monolithic releases because the data showed they were higher risk, slower to deliver value, and harder to manage. As [Doc Norton puts it](https://docondev.com/blog/2025/3/10/small-deployments-big-impact): *"Smaller, incremental releases allow you to adapt more quickly."*

This isn't about being trendy—it's about risk management, operational efficiency, and delivering value faster. Given our scale (managing thousands of users globally across consolidated AKS infrastructure), reducing the blast radius of each release should be a priority.

I'd like us to discuss how we might phase this in without disrupting our current commitments. Happy to talk through concerns, share more research, or workshop what this might look like for our specific context.

## Further Reading

- [Agile Alliance - Frequent Releases](https://agilealliance.org/glossary/frequent-releases/)
- [Redgate - DevOps 101: Unlocking the Value of Frequent Deployments](https://www.red-gate.com/blog/database-devops/devops-101-unlocking-the-value-of-frequent-deployments)
- [Codefresh - The Pain of Infrequent Deployments](https://codefresh.io/blog/infrequent-deployments-release-trains-and-lengthy-sprints/)
- [Exposé Data - The Power of Frequent Software Releases](https://exposedata.com.au/the-power-of-frequent-software-releases-boosting-testing-release-management-and-developer-efficiency/)

---

