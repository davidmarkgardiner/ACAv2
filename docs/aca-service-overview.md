# Azure Container Apps as a Service - Overview

## Where We Are Now

The current approach is **shift-left / self-service** - teams are deploying Azure Container Apps themselves, essentially being handed ARM templates and left to configure their own parameters. This works for teams with Azure expertise, but it creates several gaps:

- **No enforced security baseline** - SSL/TLS configuration, Key Vault integration, managed identity, and network isolation are left to each team to figure out
- **No storage guidance** - no standard pattern for persistent storage, volume mounts, or Azure Files integration
- **No standardisation** - every team's deployment looks different, making support and troubleshooting harder
- **No central visibility** - the platform team has no consolidated view of what's deployed, resource usage, or costs across teams
- **No audit trail** - who deployed what, when, and with what configuration isn't tracked centrally
- **Knowledge barrier** - teams without Azure infrastructure experience struggle or make mistakes

## What's Already Been Done

We've already prototyped a set of **modular Bicep templates** that bake in organisational best practices. These aren't just raw ARM templates - they encode the security, networking, and monitoring decisions so teams don't have to:

| Module | What It Handles |
|--------|----------------|
| **Container App** | Image config, CPU/memory, autoscaling rules, ingress with TLS enforced, managed identity, liveness/readiness/startup health probes |
| **Environment** | Managed environment with Log Analytics integration, optional VNet, internal load balancer |
| **Networking** | VNet with dedicated subnet, NSG rules, Container Apps delegation |
| **Security** | Key Vault with RBAC authorisation, soft delete, purge protection |
| **Monitoring** | Log Analytics workspace for centralised logging and metrics |

We've also drafted a **full PRD** covering payload schema, lifecycle operations (create, update, delete, scale), non-functional requirements (security, performance, reliability), and the target architecture.

## Where We're Going

The desired end state is **ACA as a Managed Service** - similar to how we handle AKS namespace onboarding through the dev cloud portal today. The concept:

1. **Team submits a simple request** - app name, container image, resource requirements, environment (dev/staging/prod)
2. **Platform handles everything else** - networking, security, SSL, monitoring, scaling, Key Vault, managed identity
3. **Automation deploys it** - an event-driven pipeline (Argo Events + Argo Workflows) takes the request, runs the Bicep templates, verifies the deployment, and returns the app URL
4. **Teams get self-service with guardrails** - they can deploy in minutes without needing Azure infrastructure knowledge, but everything meets our security and operational standards

### Key Benefits

- **Self-service onboarding in under 15 minutes** - no tickets, no waiting for the infra team
- **Security by default** - TLS, Key Vault, managed identity, VNet isolation, RBAC all built in
- **Full audit trail** - every deployment tracked with who, what, when
- **Cost visibility** - tagging and tracking per team and application
- **Consistent deployments** - every app gets the same baseline regardless of the team's Azure expertise

### What's Needed to Get There

- **Resources** - engineering time to build the automation layer (Argo workflows, API, portal integration)
- **Decision on portal** - integrate into existing dev cloud portal or standalone UI
- **Azure AD integration** - for RBAC and team-based access control
- **Agreement on scope** - MVP could be create/delete with a basic web form, then iterate

## Summary

| | Current State | Target State |
|--|--------------|-------------|
| **Deployment** | Teams self-serve with raw templates | Automated via portal/API |
| **Security** | Team's responsibility | Baked in by default |
| **Visibility** | None centrally | Full dashboard and audit trail |
| **Time to deploy** | Hours/days (depending on team skill) | Minutes |
| **Azure knowledge needed** | Significant | Minimal to none |
| **Standardisation** | Inconsistent | Enforced through templates |

---

*Next step: Discuss resourcing with xxx to determine capacity for implementation.*
