# End-to-End Workflow Demo Guide

**Complete DevOps lifecycle demonstration using dot-ai MCP tools: organizational standards, application deployment, monitoring, auto-remediation, and Day 2 operations.**

## Overview

This guide walks through a complete DevOps workflow on a local Kubernetes cluster, demonstrating how dot-ai's AI-powered tools work together to streamline the entire application lifecycle.

**What you'll learn:**
- Setting up organizational patterns and policies
- Scanning cluster capabilities for intelligent recommendations
- Deploying applications with AI-guided workflows
- Auto-diagnosing and fixing issues with AI remediation
- Performing Day 2 operations (scaling, updates)

**Time required:** ~45 minutes for full demo

## Prerequisites

### Required Infrastructure

1. **Local Kubernetes cluster** (Kind or Minikube)
   ```bash
   # Create Kind cluster
   kind create cluster --name dot-ai-demo

   # Verify cluster access
   kubectl get nodes
   ```

2. **Qdrant vector database** (via Docker Compose or container)
   ```bash
   # Check if Qdrant is running
   docker ps | grep qdrant
   ```

3. **dot-ai MCP server connected**
   - Verify connection by asking your MCP client: `"Show dot-ai status"`

### Required API Keys

- **AI Model API key** (Anthropic, OpenAI, or other supported provider)
- **Embedding provider key** (OpenAI or Google) for pattern/capability storage

See [MCP Setup Guide](mcp-setup.md) for detailed configuration.

---

## Demo Workflow

### Phase 1: Define Organizational Standards

**Goal:** Establish deployment patterns and scan cluster capabilities to enhance AI recommendations.

#### 1a. Create Deployment Patterns

Patterns encode your organization's best practices. Create two foundational patterns:

**Pattern 1: Production Web Applications**
```
User: Create a pattern for Helm-based production deployments

Agent: I'll help you create this pattern. What deployment capability does it provide?

User: Helm-based production deployments

Agent: What infrastructure types should this apply to?

User: production apps, helm charts, stateless services, web applications, microservices

Agent: Which Kubernetes resources should be suggested?

User: Deployment, Service, Ingress, HorizontalPodAutoscaler, PodDisruptionBudget, ConfigMap, Secret

Agent: Why does this combination work well together?

User: Standard Helm values structure with resource limits and high availability.
      Deployment provides declarative updates, Service enables networking,
      Ingress handles external traffic, HPA enables auto-scaling.

Agent: ✅ Pattern Created Successfully!
       Pattern ID: fbab2431-dbd5-41c2-a103-df3aa0888edf
```

**Pattern 2: Database Deployments**
```
User: Create a pattern for database persistence

Agent: [Interactive workflow...]

User: databases, SQL databases, NoSQL, persistent storage, PostgreSQL, MySQL, MongoDB

Agent: Which Kubernetes resources?

User: StatefulSet, PersistentVolumeClaim, Service, Secret, ConfigMap

Agent: ✅ Pattern Created! Triggers: databases, SQL databases, NoSQL, persistent storage...
```

#### 1b. Scan Cluster Capabilities

Capability scanning discovers what resources are available in your cluster:

```
User: Scan my cluster capabilities

Agent: Would you like to scan all cluster resources or specify a subset?

User: All resources

Agent: Starting comprehensive cluster capability scan...
       ✅ Capability scan completed! Processed 160 resources.
```

**What this enables:**
- AI recommendations now understand your cluster's actual capabilities
- Recommendations will suggest operators and CRDs specific to your environment
- Pattern matching becomes context-aware

---

### Phase 2: Deploy Applications

**Goal:** Deploy a web application using AI-guided recommendations.

#### 2a. Request Deployment

```
User: Deploy a nginx web server with 3 replicas exposed via ClusterIP service

Agent: I found 4 deployment options:

| # | Score | Description | Resources |
|---|-------|-------------|-----------|
| 1 | 98 | Standard nginx deployment | Deployment, Service |
| 2 | 95 | With ConfigMap for custom config | Deployment, Service, ConfigMap |
| 3 | 85 | With HorizontalPodAutoscaler | Deployment, Service, HPA |
| 4 | 75 | Direct ReplicaSet approach | ReplicaSet, Service |

Which solution would you like to use?

User: Solution 1

Agent: I need some configuration details:
       - Name: nginx-demo
       - Namespace: default
       - Replicas: 3
       - Container port: 80
       - Service port: 80

User: [Provides values]

Agent: Generating manifests...

       ✅ Deployment successful!
       - deployment.apps/nginx-demo created
       - service/nginx-demo created
```

#### 2b. Verify Deployment

```bash
# Check deployment status
kubectl get deployment nginx-demo -n default
# Output: nginx-demo   3/3     3            3           2m

kubectl get pods -l app=nginx -n default
# Output: 3 pods Running

kubectl get svc nginx-demo -n default
# Output: ClusterIP 10.96.24.187:80
```

---

### Phase 3: Monitor & Observe

**Goal:** Verify system health and understand current state.

```
User: Show dot-ai status

Agent: System Health: ✅ Healthy
       - Version: 0.151.0
       - Kubernetes: Connected (v1.33.1)
       - Vector DB: Connected
         - Patterns: 2 stored
         - Capabilities: 160 stored
       - AI Provider: Connected
       - Kyverno: Installed (v1.15.2)
```

---

### Phase 4: Auto-Remediation Demo

**Goal:** Demonstrate AI-powered issue diagnosis and automatic fixing.

#### 4a. Create a Broken Deployment

```bash
# Intentionally create a deployment with invalid image
kubectl create deployment broken-app --image=nginx:nonexistent-tag -n default
```

#### 4b. Diagnose with AI

```
User: Pod broken-app in default namespace is in ErrImagePull status

Agent: 🔍 Investigating...

       Investigation Steps:
       1. kubectl get pods (found ImagePullBackOff)
       2. kubectl describe pod (found image pull error)
       3. kubectl events (found "not found" error from registry)

       Root Cause Analysis:
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
       Root Cause: Invalid container image 'nginx:nonexistent-tag'
                   does not exist in Docker registry
       Confidence: 99%
       Risk Level: Low
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

       Proposed Fix:
       kubectl patch deployment broken-app -n default --type=json \
         -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:latest"}]'

       Choose execution method:
       1. Execute automatically via MCP
       2. Execute via agent (show commands)

User: 1

Agent: ✅ Remediation Successful!
       - deployment.apps/broken-app patched
       - Pod now Running with 1/1 ready
       - Validation confirmed issue resolution
```

---

### Phase 5: Day 2 Operations

**Goal:** Perform operational changes on running applications.

#### 5a. Scale Application

```
User: Scale the nginx-demo deployment to 5 replicas

Agent: Analyzing current state...

       Operation Analysis:
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
       Current: 3 replicas
       Proposed: 5 replicas
       Risk: Low
       Pattern Applied: Helm-based production deployments ✅
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

       Command: kubectl scale deployment/nginx-demo --replicas=5 -n default

       Execute changes?

User: Yes

Agent: ✅ Scale Operation Complete!
       - deployment.apps/nginx-demo scaled
       - Validation: 5/5 replicas ready (99% confidence)
```

#### 5b. Update Application Version

```
User: Update the nginx-demo deployment to use nginx:1.27-alpine image

Agent: Analyzing update...

       Operation Analysis:
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
       Current Image: nginx:1.25-alpine
       Proposed Image: nginx:1.27-alpine
       Risk: Low (minor version upgrade)
       Strategy: RollingUpdate (25% max unavailable)
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

       Command: kubectl set image deployment/nginx-demo nginx=nginx:1.27-alpine -n default

User: Execute

Agent: ✅ Update Complete!
       - deployment.apps/nginx-demo image updated
       - Rollout completed successfully
       - All 5 pods running nginx:1.27-alpine (99% confidence)
```

---

## Final State Summary

After completing the demo:

| Resource | Status | Details |
|----------|--------|---------|
| **Patterns** | 2 created | Production web apps, Database persistence |
| **Capabilities** | 160 scanned | Full cluster resource discovery |
| **nginx-demo** | Running | 5 replicas, nginx:1.27-alpine |
| **broken-app** | Fixed | Auto-remediated from ErrImagePull |

---

## Tools Used in This Demo

| Tool | Purpose | Phase |
|------|---------|-------|
| `manageOrgData` | Create patterns, policies, scan capabilities | 1 |
| `recommend` | AI-powered deployment recommendations | 2 |
| `version` | System health monitoring | 3 |
| `remediate` | Root cause analysis & auto-fix | 4 |
| `operate` | Day 2 operations (scale, update) | 5 |

---

## Quick Test Commands

Run these in your MCP client to quickly test each capability:

```text
# 1. Check system health
"Show dot-ai status"

# 2. Scan cluster capabilities
"Scan my cluster capabilities"

# 3. Create a pattern
"Create a pattern for Helm-based production deployments"

# 4. Deploy an app
"Deploy a nginx web server with 3 replicas"

# 5. Troubleshoot
"My pods in default namespace are pending"

# 6. Operate
"Scale nginx to 5 replicas"
```

---

## Current Limitations & Workarounds

| Feature | Status | Workaround |
|---------|--------|------------|
| Helm chart output | Planned (PRD #248) | Generate YAML, convert to Helm manually |
| GitOps integration | Planned (PRD #202) | Manual git commit of manifests |
| Multi-cluster | Single context | Switch kubeconfig between clusters |

---

## Cleanup

Remove demo resources when finished:

```bash
# Delete demo deployments
kubectl delete deployment nginx-demo broken-app -n default
kubectl delete service nginx-demo -n default

# Optional: Delete Kind cluster
kind delete cluster --name dot-ai-demo
```

---

## Next Steps

- **[Pattern Management Guide](pattern-management-guide.md)** - Create more sophisticated patterns
- **[Policy Management Guide](policy-management-guide.md)** - Add governance policies
- **[Capability Management Guide](mcp-capability-management-guide.md)** - Advanced capability scanning
- **[Remediation Guide](mcp-remediate-guide.md)** - Deep dive into auto-remediation
- **[Operations Guide](mcp-operate-guide.md)** - Complete Day 2 operations reference
