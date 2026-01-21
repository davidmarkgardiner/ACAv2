# Production Pipeline Deployment Guide

## Overview

This pipeline automatically triages Kubernetes warning events:

```
Event Hub → Argo Events → Holmes AI Investigation → GitLab Issue → Mattermost Notification
```

**Verified working:** 2026-01-19 on kind-argo-workflow cluster

---

## Prerequisites

1. **Argo Workflows** installed with server
2. **Argo Events** installed (controller + EventBus)
3. **HolmesGPT** deployed (or use included deployment)
4. **GitLab** project with API access
5. **Mattermost** (optional) with incoming webhook

---

## Quick Start

### Step 1: Deploy RBAC and EventBus

```bash
kubectl apply -f 00-rbac.yaml

# Wait for EventBus to be ready
kubectl get eventbus -n argo-events -w
# Wait for STATUS: Running
```

### Step 2: Create Secrets

```bash
# GitLab Personal Access Token (requires 'api' scope)
kubectl create secret generic gitlab-mcp-secret -n argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="glpat-xxxxxxxxxxxx"

# Anthropic API Key for Holmes
kubectl create secret generic holmes-secrets -n holmesgpt \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-api03-xxxxxxxxxxxx"
```

### Step 3: Deploy Holmes (if not already deployed)

```bash
kubectl apply -f 06-holmes-local-deployment.yaml

# Wait for Holmes to be ready
kubectl get pods -n holmesgpt -w
# Wait for READY: 1/1
```

### Step 4: Deploy Workflow Template

```bash
kubectl apply -f 02-workflow-template.yaml
```

### Step 5: Configure Mattermost Webhook (Optional)

```bash
kubectl create configmap rocketchat-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="http://mattermost.mattermost.svc.cluster.local:8065/hooks/your-webhook-id"
```

### Step 6: Deploy EventSource and Sensor

For **local testing** (webhook):
```bash
kubectl apply -f 03-webhook-eventsource.yaml
kubectl apply -f 04-sensor-production-test.yaml
```

For **production** (Event Hub):
```bash
# Use the production sensor from parent directory
kubectl apply -f ../03-eventsource-workload-identity.yaml
kubectl apply -f ../04-sensor-production.yaml
```

---

## Testing

### Local Test (Webhook)

```bash
# Terminal 1: Port-forward
kubectl port-forward -n argo-events svc/webhook-prod-test-svc 12000:12000

# Terminal 2: Send test event
curl -X POST http://localhost:12000/k8s-event \
  -H "Content-Type: application/json" \
  -d @test-payload-eventhub.json

# Watch workflows
kubectl get workflows -n argo-events -w
```

### Verify Results

1. **Check workflow status:**
   ```bash
   kubectl get workflows -n argo-events -l purpose=production-testing
   ```

2. **Check GitLab:** Look for new issue in your project

3. **Check Mattermost:** Look for notification in configured channel

4. **View workflow logs:**
   ```bash
   WF=$(kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp -o name | tail -1)
   kubectl logs -n argo-events $WF --all-containers
   ```

---

## Configuration Reference

### Workflow Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster-name` | Source cluster identifier | (from event) |
| `namespace` | K8s namespace | (from event) |
| `resource-name` | Pod/resource name | (from event) |
| `resource-kind` | Resource type | `Pod` |
| `event-reason` | Event reason | (from event) |
| `event-message` | Full event message | (from event) |
| `gitlab-project` | GitLab project path | `xxxmarkgardiner/mcp-test-repo` |
| `holmes-url` | Holmes API URL | `http://holmesgpt.holmesgpt.svc.cluster.local:80` |

### Holmes Configuration

The Holmes deployment uses:
- **Model:** `claude-sonnet-4-20250514` (configurable via MODEL env var)
- **Port:** 5050 (exposed as port 80 via Service)
- **Health endpoints:** `/healthz`, `/readyz`
- **API endpoint:** `/api/investigate`

### Secrets Required

| Secret | Namespace | Key | Purpose |
|--------|-----------|-----|---------|
| `gitlab-mcp-secret` | argo-events | `GITLAB_PERSONAL_ACCESS_TOKEN` | GitLab API access |
| `holmes-secrets` | holmesgpt | `ANTHROPIC_API_KEY` | AI model access |

### ConfigMaps

| ConfigMap | Namespace | Key | Purpose |
|-----------|-----------|-----|---------|
| `rocketchat-webhook-config` | argo-events | `WEBHOOK_URL` | Mattermost notifications |

---

## File Reference

| File | Purpose |
|------|---------|
| `00-rbac.yaml` | Namespace, ServiceAccount, Role, RoleBinding, EventBus |
| `01-secrets.yaml` | Secret templates (edit before use) |
| `02-workflow-template.yaml` | Main workflow: Holmes → GitLab → Mattermost |
| `03-webhook-eventsource.yaml` | Webhook EventSource for local testing |
| `04-sensor-production-test.yaml` | Sensor with Base64 payload processing |
| `05-holmes-rbac.yaml` | ClusterRole for Holmes K8s access |
| `06-holmes-local-deployment.yaml` | Complete Holmes deployment |
| `test-payload-eventhub.json` | Sample Event Hub format payload |
| `test-payload-raw.json` | Raw K8s event for reference |

---

## Troubleshooting

### Holmes returns 401 Unauthorized

**Cause:** Invalid or missing Anthropic API key

```bash
# Check secret
kubectl get secret holmes-secrets -n holmesgpt -o jsonpath='{.data.ANTHROPIC_API_KEY}' | base64 -d

# Update secret
kubectl create secret generic holmes-secrets -n holmesgpt \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-api03-xxxxx" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Holmes
kubectl rollout restart deployment/holmes -n holmesgpt
```

### Holmes model not found

**Cause:** Deprecated model ID

```bash
# Update model
kubectl set env deployment/holmes -n holmesgpt MODEL=claude-sonnet-4-20250514
```

### GitLab returns 401 Unauthorized

**Cause:** Invalid or missing GitLab PAT

```bash
# Check secret
kubectl get secret gitlab-mcp-secret -n argo-events -o jsonpath='{.data.GITLAB_PERSONAL_ACCESS_TOKEN}' | base64 -d

# Update secret
kubectl create secret generic gitlab-mcp-secret -n argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="glpat-xxxxx" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Workflow fails with RBAC error

**Cause:** Missing workflowtaskresults permission

```bash
# Check RBAC
kubectl auth can-i create workflowtaskresults --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events

# Apply RBAC fix (included in 00-rbac.yaml)
kubectl apply -f 00-rbac.yaml
```

### Mattermost notification not received

**Cause:** Webhook URL not configured or incorrect

```bash
# Check configmap
kubectl get configmap rocketchat-webhook-config -n argo-events -o yaml

# Test webhook directly
curl -X POST "http://your-mattermost:8065/hooks/xxx" \
  -H "Content-Type: application/json" \
  -d '{"text": "Test message"}'
```

---

## Production Deployment Checklist

- [ ] Argo Workflows installed and running
- [ ] Argo Events controller installed
- [ ] EventBus created and running
- [ ] GitLab PAT secret created
- [ ] Anthropic API key secret created
- [ ] Holmes deployed and healthy
- [ ] Workflow template applied
- [ ] Mattermost webhook configured (optional)
- [ ] Production EventSource connected to Event Hub
- [ ] Production Sensor deployed
- [ ] Test event processed successfully
- [ ] GitLab issue created
- [ ] Mattermost notification received
