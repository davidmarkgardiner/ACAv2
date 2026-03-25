# Proposal: Weekly AKS Cluster Health & Resource Usage Report

**Subject:** Proposal for a Weekly AKS Cluster "Resource & Health" Newsletter

Hi Team,

As our shared AKS clusters continue to grow with hundreds of thousands of users and applications, keeping track of resource consumption and cluster health is becoming increasingly challenging. 

To improve visibility and encourage best practices, I'd like to propose we implement an automated **Weekly Cluster Health & Resource Usage Report** (sent via email or Teams). This report would highlight the "main offenders" and outliers in our clusters so we can proactively flag issues and encourage application owners to optimize their workloads.

**Proposed Metrics to Include:**
* **Top Resource Consumers:** Namespaces or applications consuming the most CPU/Memory (especially those significantly exceeding their requests).
* **High Churn / Instability:** Pods with the highest restart counts or crash loops.
* **Noisiest Neighbors:** Applications generating the highest volume of Kubernetes events (e.g., scheduling failures, probe failures).

**The Goal:**
By shining a light on these metrics weekly, we can:
1. Gamify optimization and gently nudge teams to fix application-side issues.
2. Reduce wasted resources and control our AKS costs.
3. Improve overall cluster stability by addressing noisy neighbors.

Let me know your thoughts on this! If we agree this is valuable, we can look into automating this using Prometheus/Grafana reports or a scheduled Argo Workflow.

Best,
[Your Name]
