# AKS Management Cluster Stack Deployment

Deploy a complete management cluster stack on AKS that receives events from local kind cluster, using token-optimized HolmesGPT with **Gemini** (recommended) or Anthropic Claude.

## What It Does

1. **Collects K8s Warning events** from source clusters via Fluent Bit
2. **Routes events** through Azure Event Hub to AKS management cluster
3. **Triggers AI-powered investigation** using HolmesGPT (Gemini/Claude)
4. **Creates GitLab issues** with detailed analysis and copy-paste commands
5. **Sends Mattermost notifications** with quick commands and fix recommendations

## Architecture

```
Local Kind Cluster                    AKS Management Cluster
+-------------------+                  +--------------------------------+
| K8s Events        |                  |  Argo Events                   |
|      |            |                  |  +-------------+               |
| Fluent Bit -------+---> Event Hub -->|  | EventSource |               |
|                   |                  |  +------+------+               |
+-------------------+                  |         |                      |
                                       |  +------v------+               |
                                       |  |   Sensor    |               |
                                       |  +------+------+               |
                                       |         |                      |
                                       |  +------v----------------+     |
                                       |  | multi-cluster-triage  |     |
                                       |  | Workflow               |     |
                                       |  +----+----------+-------+     |
                                       |       |          |             |
                                       |  +----v----+ +---v-------+     |
                                       |  | Holmes  | | GitLab    |     |
                                       |  | +Claude | | Issues    |     |
                                       |  +----+----+ +-----------+     |
                                       |       |                        |
                                       |  +----v--------+               |
                                       |  | Mattermost  |               |
                                       |  +-------------+               |
                                       +--------------------------------+
```

## Prerequisites

- Azure CLI logged in
- kubectl configured
- Helm installed
- Kind cluster running (for local testing)

## Quick Start

### Phase 0: ASO Credentials (if not configured)

```bash
# Check current ASO status
cd 00-aso-setup
./04-verify-aso.sh

# If credentials are empty, create a new Service Principal
./01-create-service-principal.sh

# Configure ASO with the credentials
./02-configure-aso-credentials.sh <CLIENT_ID> <CLIENT_SECRET> [TENANT_ID]

# Create ResourceGroup
kubectl apply -f 03-resource-group.yaml
```

### Phase 1: Create Azure Event Hub

```bash
# Set variables
RESOURCE_GROUP="at39473-weu-dev-public"
EVENTHUB_NS="k8s-events-hub-$RANDOM"
LOCATION="westeurope"

# Create Event Hub namespace
az eventhubs namespace create \
  --name $EVENTHUB_NS \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard

# Create Event Hub (topic)
az eventhubs eventhub create \
  --name kube-events \
  --namespace-name $EVENTHUB_NS \
  --resource-group $RESOURCE_GROUP \
  --partition-count 2

# Create consumer group for Argo Events
az eventhubs eventhub consumer-group create \
  --name argo-events \
  --eventhub-name kube-events \
  --namespace-name $EVENTHUB_NS \
  --resource-group $RESOURCE_GROUP

# Get connection string
az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NS \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv
```

### Phase 2: Deploy to AKS Management Cluster

```bash
# Switch to AKS context
kubectl config use-context <your-aks-context>

# 1. Create namespaces
kubectl apply -f 01-namespaces/namespaces.yaml

# 2. Create secrets (interactive)
cd 02-secrets
chmod +x create-secrets.sh
./create-secrets.sh

# 3. Deploy Argo Workflows
cd ../03-core-stack
chmod +x *.sh
./01-deploy-argo-workflows.sh

# 4. Deploy Argo Events
./02-deploy-argo-events.sh
kubectl apply -f 03-argo-events-rbac.yaml

# 5. Deploy HolmesGPT (token-optimized)
kubectl apply -f ../04-holmesgpt/holmesgpt-token-optimized.yaml

# 6. Deploy Workflow Template
kubectl apply -f ../05-workflow/workflow-multi-cluster-triage-optimized.yaml

# 7. Deploy Mattermost
cd ../06-mattermost
chmod +x deploy-mattermost.sh
./deploy-mattermost.sh

# 8. Configure Mattermost webhook (see below)

# 9. Deploy Event Hub EventSource and Sensor
# FIRST: Update Event Hub FQDN in 01-eventsource-eventhub.yaml
kubectl apply -f ../07-event-flow/01-eventsource-eventhub.yaml
kubectl apply -f ../07-event-flow/02-sensor-production.yaml
```

### Phase 3: Configure Mattermost Webhook

```bash
# Port-forward to Mattermost
kubectl port-forward -n mattermost svc/mattermost 8065:8065

# 1. Open http://localhost:8065
# 2. Create admin account and team
# 3. Go to: Menu > Integrations > Incoming Webhooks > Add
# 4. Select channel, save, copy webhook URL

# Update the ConfigMap with your webhook URL
kubectl edit configmap mattermost-webhook-config -n argo-events
# Replace REPLACE_WITH_HOOK_ID with your actual hook ID
```

### Phase 4: Deploy Fluent Bit on Kind Cluster

```bash
# Switch to Kind context
kubectl config use-context kind-argo-workflow

# Set environment variables
export EVENTHUB_NAMESPACE="your-eventhub-namespace"
export EVENTHUB_CONNECTION_STRING="Endpoint=sb://..."
export CLUSTER_NAME="kind-local"

# Deploy
cd ../08-kind-setup
chmod +x deploy-fluent-bit.sh
./deploy-fluent-bit.sh
```

## Testing

### Generate Test Event (on Kind cluster)

```bash
# Create a pod with invalid image to generate Warning events
kubectl run test-crash --image=invalid-image-xyz --restart=Never

# Watch for events
kubectl get events -w
```

### Verify Event Flow

```bash
# 1. Check Fluent Bit logs (Kind cluster)
kubectl logs -n monitoring -l app=fluent-bit -f

# 2. Check EventSource logs (AKS cluster)
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events -f

# 3. Watch for workflows (AKS cluster)
kubectl get workflows -n argo-events -w

# 4. Check Mattermost for notifications
```

## Configuration Reference

### AI Model Configuration (HolmesGPT)

**Gemini (Recommended - cheaper):**
```bash
kubectl patch deployment holmes -n holmesgpt --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env/2/value", "value": "gemini/gemini-2.0-flash"},
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "GOOGLE_API_KEY", "valueFrom": {"secretKeyRef": {"name": "holmes-secrets", "key": "GOOGLE_API_KEY"}}}}
]'
```

**Claude (Higher quality, more expensive):**
```bash
kubectl patch deployment holmes -n holmesgpt --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env/2/value", "value": "claude-sonnet-4-20250514"}
]'
```

### Token Optimization Settings

| File | Setting | Value | Purpose |
|------|---------|-------|---------|
| `04-holmesgpt/holmesgpt-token-optimized.yaml` | `max_steps` | `10` | Limit investigation depth |
| `05-workflow/workflow-multi-cluster-triage-optimized.yaml` | `include_tool_call_results` | `false` | Don't include raw tool output |

### Secrets Required

| Secret | Namespace | Keys |
|--------|-----------|------|
| `eventhub-listener-secret` | argo-events | sharedAccessKeyName, sharedAccessKey |
| `holmes-secrets` | holmesgpt | GOOGLE_API_KEY (or ANTHROPIC_API_KEY) |
| `gitlab-mcp-secret` | argo-events | GITLAB_PERSONAL_ACCESS_TOKEN |
| `postgresql-secret` | mattermost | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB |
| `eventhub-sas-secret` | monitoring (kind) | connectionString |

### Create Secrets Commands

```bash
# Event Hub (AKS - argo-events namespace)
kubectl create secret generic eventhub-listener-secret -n argo-events \
  --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \
  --from-literal=sharedAccessKey="YOUR_SAS_KEY"

# HolmesGPT with Gemini (AKS - holmesgpt namespace)
kubectl create secret generic holmes-secrets -n holmesgpt \
  --from-literal=GOOGLE_API_KEY="YOUR_GEMINI_API_KEY" \
  --from-literal=ANTHROPIC_API_KEY="" \
  --from-literal=OPENAI_API_KEY=""

# GitLab (AKS - argo-events namespace)
kubectl create secret generic gitlab-mcp-secret -n argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="YOUR_GITLAB_PAT"

# Event Hub (Source cluster - monitoring namespace)
kubectl create secret generic eventhub-sas-secret -n monitoring \
  --from-literal=connectionString="Endpoint=sb://YOUR_NS.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=..."
```

### ConfigMaps Required

| ConfigMap | Namespace | Keys |
|-----------|-----------|------|
| `mattermost-webhook-config` | argo-events | WEBHOOK_URL |
| `eventhub-config` | monitoring (kind) | EVENTHUB_NAMESPACE, EVENTHUB_NAME, EVENTHUB_FQDN |

## Directory Structure

```
aks-mgmt-stack/
+-- 00-aso-setup/           # ASO credential setup
|   +-- 01-create-service-principal.sh
|   +-- 02-configure-aso-credentials.sh
|   +-- 03-resource-group.yaml
|   +-- 04-verify-aso.sh
+-- 01-namespaces/          # Namespace definitions
|   +-- namespaces.yaml
+-- 02-secrets/             # Secret templates
|   +-- secrets-template.yaml
|   +-- create-secrets.sh
+-- 03-core-stack/          # Argo deployment
|   +-- 01-deploy-argo-workflows.sh
|   +-- 02-deploy-argo-events.sh
|   +-- 03-argo-events-rbac.yaml
+-- 04-holmesgpt/           # Holmes (token-optimized)
|   +-- holmesgpt-token-optimized.yaml
+-- 05-workflow/            # Workflow template
|   +-- workflow-multi-cluster-triage-optimized.yaml
+-- 06-mattermost/          # Mattermost deployment
|   +-- 01-postgresql.yaml
|   +-- 02-mattermost.yaml
|   +-- 03-mattermost-webhook-config.yaml
|   +-- deploy-mattermost.sh
+-- 07-event-flow/          # EventSource & Sensor
|   +-- 01-eventsource-eventhub.yaml
|   +-- 02-sensor-production.yaml
+-- 08-kind-setup/          # Fluent Bit for Kind
|   +-- 01-fluent-bit-config.yaml
|   +-- 02-fluent-bit-deployment.yaml
|   +-- deploy-fluent-bit.sh
+-- README.md               # This file
```

## Output Formats

### GitLab Issue Format

Each issue includes:

```markdown
## Issue Summary

| Field | Value |
|-------|-------|
| **Cluster** | `cluster-name` |
| **Namespace** | `namespace` |
| **Resource** | `Pod/pod-name` |
| **Event** | `OOMKilled` |
| **Timestamp** | 2026-01-22 19:13:41 UTC |
| **Workflow** | triage-xyz |

## Event Message
\`\`\`
Container exceeded memory limit and was OOMKilled
\`\`\`

## AI Analysis
[Detailed investigation from HolmesGPT including root cause and findings]

## Quick Commands
\`\`\`bash
kubectl config use-context cluster-name
kubectl get pod pod-name -n namespace -o wide
kubectl describe pod pod-name -n namespace | tail -30
kubectl logs pod-name -n namespace --tail=100
\`\`\`

## Recommended Actions
[AI-generated fix steps]
```

### Mattermost Notification Format

Each notification shows 4 colored sections:

| Section | Color | Content |
|---------|-------|---------|
| **AI Analysis** | 🟢 Green | Summary of the issue and root cause |
| **Quick Commands** | 🟠 Orange | Copy-paste kubectl commands |
| **Recommended Fix** | 🟣 Purple | AI-generated remediation steps |
| **GitLab Issue** | 🔵 Blue | Link to full details |

### GitLab Assignee Configuration

To auto-assign issues to yourself:

```bash
# Get your GitLab user ID
glab api "users?username=YOUR_USERNAME" | jq '.[0].id'

# Update in workflow template (line ~248)
ASSIGNEE_ID="YOUR_USER_ID"
```

## Testing Strategy

### Recommended Approach: Manual First, Then Fluent Bit

**Important**: Always test with manual workflow submission first. If the manual test works, the Fluent Bit event flow will work too - they use the exact same payload structure.

```
Manual Test                          Fluent Bit Event Flow
┌─────────────────┐                 ┌─────────────────────────────┐
│ kubectl create  │                 │ K8s Event → Fluent Bit      │
│ -f workflow.yaml│                 │     → Event Hub → Sensor    │
└────────┬────────┘                 └──────────────┬──────────────┘
         │                                         │
         │  Same parameters:                       │
         │  - cluster-name                         │
         │  - namespace                            │
         │  - resource-name                        │
         │  - resource-kind                        │
         │  - event-reason                         │
         │  - event-message                        │
         │                                         │
         └──────────────┬──────────────────────────┘
                        │
                        ▼
              ┌─────────────────────┐
              │ WorkflowTemplate:   │
              │ multi-cluster-triage│
              └─────────┬───────────┘
                        │
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
    HolmesGPT     GitLab Issue    Mattermost
```

**Why this works**: The sensor extracts these fields from Fluent Bit events:
- `cluster` → `cluster-name`
- `involvedObject.namespace` → `namespace`
- `involvedObject.name` → `resource-name`
- `involvedObject.kind` → `resource-kind`
- `reason` → `event-reason`
- `message` → `event-message`

The workflow template receives identical parameters regardless of source.

### Step 1: Manual Test (No Fluent Bit Required)

Submit a workflow manually to test the full pipeline:

```bash
CLUSTER=$(kubectl config current-context)
kubectl create -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: manual-test-
  namespace: argo-events
spec:
  serviceAccountName: argo-events-sa
  workflowTemplateRef:
    name: multi-cluster-triage
  arguments:
    parameters:
      - name: cluster-name
        value: "$CLUSTER"
      - name: namespace
        value: "default"
      - name: resource-name
        value: "test-pod"
      - name: resource-kind
        value: "Pod"
      - name: event-reason
        value: "OOMKilled"
      - name: event-message
        value: "Container exceeded memory limit"
      - name: gitlab-project
        value: "YOUR_ORG/YOUR_REPO"
EOF
```

### Watch Workflow Progress

```bash
kubectl get workflows -n argo-events -w
```

### Check Workflow Logs

```bash
# Get latest workflow name
WORKFLOW=$(kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

# Watch logs
kubectl logs -n argo-events -l workflows.argoproj.io/workflow=$WORKFLOW --all-containers -f
```

### Step 2: Enable Fluent Bit (After Manual Test Passes)

Once the manual test succeeds (GitLab issue created, Mattermost notification received), enable the full event flow:

```bash
# 1. Ensure sensor is deployed on AKS
kubectl apply -f 07-event-flow/02-sensor-production.yaml

# 2. Start Fluent Bit on source cluster
kubectl scale deployment fluent-bit-events -n monitoring --replicas=1 --context kind-argo-workflow

# 3. Generate a test event on source cluster
kubectl run test-event --image=invalid-image --restart=Never --context kind-argo-workflow

# 4. Watch for workflows on AKS
kubectl get workflows -n argo-events -w
```

**Expected result**: Within 1-2 minutes, you should see a workflow triggered automatically, creating a GitLab issue and Mattermost notification identical to the manual test.

## Stop/Start Event Flow

### Stop (save API credits)

```bash
# Stop Fluent Bit on source cluster
kubectl scale deployment fluent-bit-events -n monitoring --replicas=0 --context kind-argo-workflow

# Delete sensor on AKS
kubectl delete sensor fluent-bit-multi-cluster-triage -n argo-events
```

### Start

```bash
# Start Fluent Bit
kubectl scale deployment fluent-bit-events -n monitoring --replicas=1 --context kind-argo-workflow

# Reapply sensor
kubectl apply -f 07-event-flow/02-sensor-production.yaml
```

## Troubleshooting

### ASO Resources Not Reconciling

```bash
# Check ASO controller logs
kubectl logs -n azureserviceoperator-system -l app.kubernetes.io/name=azure-service-operator -f

# Verify credentials are set
kubectl get secret aso-controller-settings -n azureserviceoperator-system -o jsonpath='{.data}' | jq 'keys'
```

### EventSource Not Receiving Events

```bash
# Check EventSource status
kubectl describe eventsource eventhub-k8s-events -n argo-events

# Check Event Hub FQDN is correct
# Check secret has valid SAS key
```

### Workflows Not Triggering

```bash
# Check Sensor logs
kubectl logs -n argo-events -l sensor-name=fluent-bit-multi-cluster-triage -f

# Check EventBus is running
kubectl get eventbus -n argo-events

# Debug sensor to see raw events
kubectl get workflows -n argo-events -l purpose=debug
```

### Holmes Investigation Failing

```bash
# Check Holmes logs
kubectl logs -n holmesgpt -l app=holmes -f

# Verify API key is set (Gemini)
kubectl get secret holmes-secrets -n holmesgpt -o jsonpath='{.data.GOOGLE_API_KEY}' | base64 -d | head -c 10

# Check which model is configured
kubectl get deployment holmes -n holmesgpt -o jsonpath='{.spec.template.spec.containers[0].env[2].value}'
```

### Workflow RBAC Errors

```bash
# Error: "cannot create resource workflowtaskresults"
# Fix: Apply RBAC for workflow service account
kubectl apply -f 06-rbac/workflow-rbac.yaml

# Verify permissions
kubectl auth can-i create workflowtaskresults --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
```

### Mattermost Notifications Not Arriving

```bash
# Check webhook ConfigMap
kubectl get configmap mattermost-webhook-config -n argo-events -o yaml

# Test webhook directly
kubectl run test-curl --rm -it --image=curlimages/curl -- \
  curl -X POST "http://mattermost.mattermost.svc.cluster.local:8065/hooks/YOUR_HOOK_ID" \
  -H "Content-Type: application/json" \
  -d '{"text": "Test message"}'
```

### EventSource Kafka Connection Issues

```bash
# Check EventSource logs for TLS errors
kubectl logs -n argo-events -l eventsource-name=kafka-eventsource -f

# Event Hub requires TLS - ensure using port 9093
# fqdn should be: YOUR_NS.servicebus.windows.net:9093
```

## Cost Optimization

| Optimization | Setting | Impact |
|--------------|---------|--------|
| Use Gemini instead of Claude | `MODEL: gemini/gemini-2.0-flash` | ~10x cheaper |
| Limit investigation steps | `max_steps: 10` | Fewer API calls |
| Disable tool call results | `include_tool_call_results: false` | Smaller payloads |
| Stop event flow when idle | Scale Fluent Bit to 0 | No events = no API calls |

### Estimated Costs

| Provider | Model | Per Investigation |
|----------|-------|-------------------|
| Google | gemini-2.0-flash | ~$0.001-0.01 |
| Anthropic | claude-sonnet-4 | ~$0.05-0.20 |

## Quick Reference Commands

```bash
# Check all components status
kubectl get pods -n argo-events
kubectl get pods -n holmesgpt
kubectl get pods -n mattermost
kubectl get eventsource,sensor,eventbus -n argo-events

# View recent workflows
kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -10

# Check latest GitLab issues
glab issue list --repo YOUR_ORG/YOUR_REPO --per-page 5

# Switch AI model to Gemini
kubectl patch secret holmes-secrets -n holmesgpt --type merge -p '{"stringData":{"GOOGLE_API_KEY":"YOUR_KEY"}}'
kubectl patch deployment holmes -n holmesgpt --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/2/value","value":"gemini/gemini-2.0-flash"}]'
kubectl rollout restart deployment/holmes -n holmesgpt
```
