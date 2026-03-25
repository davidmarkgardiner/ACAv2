<!--
Name: AKS Cluster Health & Offenders Report
Description: Template for implementing the weekly AKS resource usage and health report.
Title: "Implement Weekly AKS Cluster Health & Resource Usage Report"
Labels: ~"monitoring", ~"aks", ~"enhancement", ~"finops"
Assignees:
-->

## 📝 Description
As our shared AKS clusters continue to grow, we need better visibility into resource consumption and cluster health. This issue tracks the implementation of an automated weekly "Main Offenders" report to highlight applications and namespaces that are consuming excessive resources, experiencing high restart churn, or generating excessive Kubernetes events.

## 🎯 Problem Statement
- Hundreds of thousands of users/applications share the AKS cluster.
- Lack of proactive visibility into "noisy neighbors" or resource hogs.
- Application owners are not always aware of their pod restarts, OOMKills, or excessive CPU/Memory consumption compared to their requests.

## 💡 Proposed Solution
Implement an automated mechanism (via Grafana Reporting or an Argo `CronWorkflow`) to query our LGTM stack (Mimir/Prometheus and Loki) for the top offenders and deliver a summarized report weekly via Microsoft Teams and/or an internal web portal.

## ✅ Implementation Plan / Tasks

### Phase 1: Query Development (LGTM Stack)
- [ ] Develop PromQL query for top CPU over-consumers (usage vs. requests).
- [ ] Develop PromQL query for top Memory over-consumers / OOMKills.
- [ ] Develop PromQL query for pods with the highest restart counts over 7 days.
- [ ] Develop LogQL query for namespaces generating the most Kubernetes Warning events.

### Phase 2: Automation & Delivery (Choose One)
**Option A: Grafana Native**
- [ ] Create a dedicated "Cluster Offenders" Grafana dashboard.
- [ ] Configure Grafana Alerting or Reporting to send a weekly summary.

**Option B: Argo Workflows (Agentic Approach)**
- [ ] Create Python script to query Mimir/Loki REST APIs and format data into Markdown/HTML.
- [ ] Create Argo `CronWorkflow` to run the script weekly.
- [ ] Add step to push the generated report to an internal Git repository / static website.

### Phase 3: Notifications
- [ ] Create a Microsoft Teams Webhook for the destination channel.
- [ ] Add the webhook secret to the cluster (`teams-webhook-secret`).
- [ ] Configure the workflow/alert to POST the finalized report to the Teams channel.

## 🏁 Acceptance Criteria
- [ ] The top 10 worst performing/consuming pods/namespaces are identifiable.
- [ ] A report is automatically generated and sent to the team's channel once a week (e.g., Friday morning).
- [ ] The report contains actionable data for application owners.

## 🔗 References
- [Proposal Teams Message](WEEKLY-CLUSTER-REPORT-PROPOSAL.md)
- [Implementation Guide & Queries](CLUSTER-REPORT-IMPLEMENTATION-GUIDE.md)

/label ~"monitoring" ~"aks" ~"enhancement" ~"finops"
