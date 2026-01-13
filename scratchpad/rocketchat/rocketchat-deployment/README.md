# RocketChat + HolmesGPT Deployment Bundle

Complete deployment package for AI-powered Kubernetes triage with:
- **Manual Triage**: RocketChat `@triage` command for on-demand investigation
- **Auto-Remediation**: Fluent Bit → Event Hub → Argo pipeline for automated response

## Architecture Overview

### Two Trigger Paths, One Workflow

```
+======================== AUTOMATED PATH =========================+
|                                                                  |
|  K8s Events → Fluent Bit → Event Hub → EventSource → Sensor     |
|                                                                  |
+==================================================================+
                                                      |
                                                      v
                                        +-------------------------+
                                        | multi-cluster-triage    |
                                        | WorkflowTemplate        |
                                        |   - Holmes Analysis     |
                                        |   - GitLab Issue        |
                                        |   - RocketChat Notify   |
                                        +-------------------------+
                                                      ^
                                                      |
+========================== MANUAL PATH ==========================+
|                                                                  |
|  User @triage → RocketChat Webhook → EventSource → Sensor       |
|                                                                  |
+==================================================================+
```

### Detailed Flow

```
AUTOMATED (Fluent Bit → Event Hub):
+------------------+     +------------------+     +------------------+
| Kubernetes       |     | Azure Event Hub  |     | Argo Events      |
| Warning Events   |---->| (Kafka protocol) |---->| EventSource      |
| (via Fluent Bit) |     | (SAS token auth) |     | (AMQP consumer)  |
+------------------+     +------------------+     +--------+---------+
                                                          |
                                                          v
MANUAL (RocketChat):                              +------------------+
+------------------+     +------------------+     | Sensor           |
| User: @triage    |---->| Webhook          |---->| (rate limited)   |
| ns/pod reason    |     | EventSource      |     +--------+---------+
+------------------+     +------------------+              |
                                                          v
                                              +-----------------------+
                                              | Triage Workflow       |
                                              |   1. Holmes Analyze   |
                                              |   2. GitLab Issue     |
                                              |   3. RocketChat Notify|
                                              +-----------------------+
```

## Files Overview

```
rocketchat-deployment/
├── README.md                           # This file
├── ROCKETCHAT-SETUP.md                 # Quick RocketChat setup guide
├── MANUAL-TRIAGE-SETUP.md              # @triage command setup
│
├── rocketchat/                         # RocketChat + MongoDB
│   ├── mongodb-standalone.yaml
│   └── rocketchat-standalone.yaml
│
├── holmesgpt/                          # AI Investigation Engine
│   └── holmesgpt-standalone.yaml       # Deployment + RBAC + ConfigMaps
│
├── workflows/                          # Argo Workflows
│   ├── manual-triage-integration.yaml  # EventSource + Sensor for @triage
│   └── workflow-multi-cluster-triage.yaml  # Main triage workflow
│
├── auto-remediation/                   # AUTOMATED PIPELINE
│   ├── README.md                       # Auto-remediation setup guide
│   ├── 01-fluent-bit-config.yaml       # K8s events → Kafka output
│   ├── 02-fluent-bit-deployment.yaml   # Deployment + RBAC
│   ├── 03-eventhub-config.yaml         # Event Hub connection config
│   ├── 04-eventsource-eventhub.yaml    # Event Hub consumer
│   ├── 05-sensor-auto-triage.yaml      # Auto-trigger with rate limiting
│   └── 06-keyvault-integration.yaml    # Key Vault → K8s secrets sync
│
├── istio/                              # Istio Service Mesh
│   ├── gateway.yaml                    # Istio Gateway (HTTPS)
│   ├── certificate.yaml                # cert-manager Certificate
│   └── rocketchat-virtualservice.yaml  # VirtualService + DestinationRule
│
└── secrets/
    └── secrets-template.yaml           # All required secrets (TEMPLATE)
```

## Deployment Order

### Step 1: Prerequisites

Ensure these are already deployed:
- AKS cluster with Managed Istio enabled
- Argo Workflows (`helm install argo-workflows argo/argo-workflows -n argo --create-namespace`)
- Argo Events + EventBus
- cert-manager (for HTTPS)

```bash
# Check Istio revision
kubectl get pods -n aks-istio-system -l app=istiod -o jsonpath='{.items[0].metadata.labels.istio\.io/rev}'
# Output: asm-1-27 (use this in namespace labels)
```

### Step 2: Create Namespaces

```bash
# RocketChat namespace - CRITICAL: correct Istio labels
kubectl create namespace rocketchat
kubectl label namespace rocketchat istio.io/rev=asm-1-27  # Use YOUR revision

# HolmesGPT namespace
kubectl create namespace holmesgpt

# Ensure argo-events exists
kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -
```

**IMPORTANT**: Do NOT add `istio-injection=enabled` - AKS Managed Istio uses revision-based injection only.

### Step 3: Deploy Secrets

```bash
# HolmesGPT - LLM API keys (choose one)
kubectl create secret generic holmes-secrets -n holmesgpt \
  --from-literal=OPENAI_API_KEY="sk-your-key" \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-your-key"

# GitLab token for issue creation
kubectl create secret generic gitlab-mcp-secret -n argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="glpat-xxxxx"

# RocketChat webhook config (update after creating webhook in RocketChat)
kubectl create configmap rocketchat-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="http://rocketchat.rocketchat.svc.cluster.local:3000/hooks/PLACEHOLDER/PLACEHOLDER"

# Azure Storage for Argo artifacts (or use S3/MinIO)
kubectl create secret generic azure-storage-secret -n argo-events \
  --from-literal=account-key="your-storage-key"
```

### Step 4: Deploy HolmesGPT

```bash
kubectl apply -f holmesgpt/holmesgpt-standalone.yaml

# Verify
kubectl get pods -n holmesgpt
kubectl logs -n holmesgpt deployment/holmes --tail=20
```

### Step 5: Deploy RocketChat + MongoDB

```bash
kubectl apply -f rocketchat/mongodb-standalone.yaml
kubectl apply -f rocketchat/rocketchat-standalone.yaml

# Wait for pods (should show 2/2 for Istio sidecar)
kubectl get pods -n rocketchat -w

# If pods show 1/1, fix Istio injection:
kubectl label namespace rocketchat istio-injection-  # Remove if exists
kubectl rollout restart deployment/mongodb deployment/rocketchat -n rocketchat
```

### Step 6: Deploy Istio Routing

Edit files in `istio/` folder first:
- `gateway.yaml`: Set your domain
- `certificate.yaml`: Set your domain
- `rocketchat-virtualservice.yaml`: Set your domain and gateway reference

```bash
# Deploy Gateway (in aks-istio-ingress namespace)
kubectl apply -f istio/gateway.yaml

# Deploy Certificate (in aks-istio-ingress namespace)
kubectl apply -f istio/certificate.yaml

# Check certificate status
kubectl get certificate -n aks-istio-ingress

# Deploy VirtualService
kubectl apply -f istio/rocketchat-virtualservice.yaml
```

**cert-manager HTTP-01 Challenge**: If certificate stays "Pending", add ACME route:
```bash
# Find solver service
kubectl get svc -n aks-istio-ingress -l acme.cert-manager.io/http01-solver=true

# Add to VirtualService (before catch-all route):
# - match:
#     - uri:
#         prefix: /.well-known/acme-challenge/
#   route:
#     - destination:
#         host: cm-acme-http-solver-XXXXX.aks-istio-ingress.svc.cluster.local
#         port:
#           number: 8089
```

### Step 7: Configure RocketChat Webhooks

Access RocketChat:
```bash
kubectl port-forward -n rocketchat svc/rocketchat 3000:3000
# Open http://localhost:3000
```

1. **Create Admin Account** and complete setup wizard

2. **Create Incoming Webhook** (for Holmes responses):
   - Administration > Integrations > + New > Incoming WebHook
   - Name: `Holmes Bot`
   - Post to Channel: `#general`
   - Post as: `rocket.cat`
   - Save and **copy the Webhook URL**

3. **Update ConfigMap with real webhook URL**:
   ```bash
   kubectl patch configmap rocketchat-webhook-config -n argo-events --type merge \
     -p '{"data":{"WEBHOOK_URL":"http://rocketchat.rocketchat.svc.cluster.local:3000/hooks/YOUR_ID/YOUR_TOKEN"}}'
   ```

4. **Create Outgoing Webhook** (for @triage command):
   - Administration > Integrations > + New > Outgoing WebHook
   - Name: `Manual Triage`
   - Event Trigger: Message Sent
   - Channel: `#general` (or `all_public_channels`)
   - Trigger Words: `@triage`
   - URLs: `http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage`
   - Script Enabled: No

### Step 8: Deploy Workflows

```bash
# Deploy EventSource + Sensor for @triage
kubectl apply -f workflows/manual-triage-integration.yaml

# Deploy main triage WorkflowTemplate
kubectl apply -f workflows/workflow-multi-cluster-triage.yaml

# Verify
kubectl get eventsource,sensor -n argo-events
```

## Testing

### Test @triage Command

In RocketChat #general:
```
@triage default/test-pod CrashLoopBackOff
```

Expected:
1. "Triage Started..." message
2. "Triage Complete" with GitLab issue link

### Manual API Test

```bash
# Test EventSource directly
kubectl run test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST "http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage" \
  -H "Content-Type: application/json" \
  -d '{"text":"@triage default/nginx CrashLoopBackOff","user_name":"test","channel_name":"general"}'
```

### Test Holmes API

```bash
kubectl run test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST "http://holmesgpt.holmesgpt.svc.cluster.local:80/api/investigate" \
  -H "Content-Type: application/json" \
  -d '{"source":"test","title":"Test","description":"List pods","context":{}}'
```

## Verification Commands

```bash
# Check all pods
kubectl get pods -n rocketchat    # Should show 2/2 (with Istio sidecar)
kubectl get pods -n holmesgpt
kubectl get pods -n argo-events

# Check Argo Events components
kubectl get eventsource,sensor -n argo-events

# Check workflows
kubectl get workflows -n argo-events

# Check Istio resources
kubectl get gateway -n aks-istio-ingress
kubectl get virtualservice -n rocketchat
kubectl get certificate -n aks-istio-ingress

# Check external access
curl -s -o /dev/null -w "%{http_code}" https://YOUR_DOMAIN/
```

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Pod shows 1/1 not 2/2 | Missing Istio sidecar | Remove `istio-injection=enabled` label, keep only `istio.io/rev=asm-1-27` |
| 503 errors | Backend missing sidecar | Fix Istio injection, restart pods |
| Certificate stuck Pending | ACME challenge not routed | Add `.well-known/acme-challenge` route to VirtualService |
| No triage response | Webhook URL wrong | Update ConfigMap with correct incoming webhook URL |
| "exit code 127" in workflow | HEREDOC parsing error | Use `jq` for JSON building, avoid complex HEREDOCs |

## HolmesGPT Configuration Reference

Key config in `holmesgpt-standalone.yaml`:

```yaml
# Toolsets - enable/disable investigation tools
holmes-toolsets:
  kubernetes/core: true   # Pod/deployment inspection
  kubernetes/logs: true   # Log analysis
  robusta: false          # Robusta integration
  internet: true          # Web searches
  prometheus/metrics: false

# Runbooks - custom investigation guides
holmes-runbooks:
  dns-troubleshooting.yaml  # DNS/CoreDNS issues
  aks-troubleshooting.yaml  # AKS-specific issues

# API Keys - set in secrets
OPENAI_API_KEY: required for GPT models
ANTHROPIC_API_KEY: required for Claude models
```

## Auto-Remediation Pipeline (Optional)

For fully automated triage of K8s Warning events:

```bash
# See auto-remediation/README.md for full setup

# Quick start:
# 1. Set up Azure Event Hub (namespace + hub + consumer group)
# 2. Store connection string in Key Vault
# 3. Configure Key Vault sync (External Secrets or CSI Driver)
# 4. Deploy Fluent Bit + EventSource + Sensor

cd auto-remediation
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml
kubectl apply -f 03-eventhub-config.yaml  # Edit first!
kubectl apply -f 04-eventsource-eventhub.yaml
kubectl apply -f 05-sensor-auto-triage.yaml
```

**Authentication**: Fluent Bit doesn't support Workload Identity for Kafka. Uses SASL_PLAIN with connection string from Key Vault.

## Related Workflows

Other workflows you might need:

| Workflow | Location | Purpose |
|----------|----------|---------|
| GitLab Issue Creator | `application-stack/apps/holmesgpt/workflow-gitlab-issue-creator.yaml` | Standalone GitLab issue creation |
| Critical Infra Sensor | `application-stack/apps/holmesgpt/gitlab-issue-automation/critical-infra-sensor.yaml` | Auto-triage for critical events |
| Fluent Bit Production | `application-stack/apps/holmesgpt/multi-cluster/fluent-bit-production/` | Event Hub integration |
| AKS Production | `application-stack/apps/holmesgpt/multi-cluster/aks-production/` | Full production setup |

## Authentication Summary

| Component | Method | Secret Source |
|-----------|--------|---------------|
| HolmesGPT | OpenAI/Anthropic API Key | K8s Secret |
| GitLab | Personal Access Token | K8s Secret |
| Fluent Bit → Event Hub | SASL_PLAIN (connection string) | Key Vault |
| EventSource → Event Hub | Shared Access Key | Key Vault |
| RocketChat Webhook | Internal cluster URL | ConfigMap |
