# Production Pipeline Test

Test the full production pipeline locally using a webhook to simulate Event Hub:

```
Webhook → Sensor → Holmes Investigation → GitLab Issue Creation
```

## Files

```
test-production/
├── 00-rbac.yaml                  # Namespace, ServiceAccount, Role, EventBus
├── 01-secrets.yaml               # GitLab PAT and RocketChat webhook (EDIT THIS!)
├── 02-workflow-template.yaml     # multi-cluster-triage WorkflowTemplate
├── 03-webhook-eventsource.yaml   # Webhook to simulate Event Hub
├── 04-sensor-production-test.yaml # Production sensor (processes base64 payloads)
├── test-payload-eventhub.json    # Event Hub format payload (base64 body)
├── test-payload-raw.json         # Raw K8s event (for reference)
├── generate-payload.sh           # Helper to create Event Hub payloads
├── run-test.sh                   # Automated test script
└── README.md                     # This file
```

## Prerequisites

1. **Argo Events controller installed**
2. **GitLab PAT** with `api` scope

## Quick Start

### Step 1: Configure GitLab Secret

Edit `01-secrets.yaml` and replace `<YOUR_GITLAB_PAT>` with your GitLab Personal Access Token:

```bash
# Get a GitLab PAT from: GitLab > Settings > Access Tokens
# Required scope: api

vim 01-secrets.yaml
# Replace: <YOUR_GITLAB_PAT> with your actual token
```

### Step 2: Run the Test

```bash
cd test-production
chmod +x run-test.sh generate-payload.sh
./run-test.sh
```

### Step 3: Check GitLab

After the workflow completes, check your GitLab project for the new issue:
- https://gitlab.com/markgardiner/mcp-test-repo/-/issues

## Manual Testing

### Apply Resources

```bash
# 1. RBAC and EventBus
kubectl apply -f 00-rbac.yaml
kubectl get eventbus -n argo-events -w  # Wait for Running

# 2. Secrets (after editing!)
kubectl apply -f 01-secrets.yaml

# 3. Workflow Template
kubectl apply -f 02-workflow-template.yaml

# 4. EventSource and Sensor
kubectl apply -f 03-webhook-eventsource.yaml
kubectl apply -f 04-sensor-production-test.yaml
```

### Port-Forward and Send Event

```bash
# Terminal 1: Port-forward
kubectl port-forward -n argo-events svc/webhook-prod-test-svc 12000:12000

# Terminal 2: Send Event Hub format payload
curl -X POST http://localhost:12000/k8s-event \
  -H "Content-Type: application/json" \
  -d @test-payload-eventhub.json
```

### Watch Workflows

```bash
# Watch for workflow creation
kubectl get workflows -n argo-events -w

# Get workflow logs
kubectl logs -n argo-events -l purpose=production-testing -f
```

## Test Different Events

### Generate Custom Payloads

Use the helper script to create Event Hub format payloads:

```bash
# From raw JSON file
./generate-payload.sh test-payload-raw.json > my-test.json

# From inline JSON
echo '{"type":"Warning","reason":"OOMKilled","message":"Container killed due to OOM","involvedObject":{"kind":"Pod","name":"memory-hog","namespace":"apps"},"cluster":"aks-prod"}' | ./generate-payload.sh > oom-test.json

# Send it
curl -X POST http://localhost:12000/k8s-event \
  -H "Content-Type: application/json" \
  -d @oom-test.json
```

### Pre-built Test Scenarios

**OOMKilled Event:**
```bash
echo '{"type":"Warning","reason":"OOMKilled","message":"Container exceeded memory limit and was killed","involvedObject":{"kind":"Pod","name":"memory-intensive-app","namespace":"production"},"cluster":"aks-prod-cluster"}' | ./generate-payload.sh | \
curl -X POST http://localhost:12000/k8s-event -H "Content-Type: application/json" -d @-
```

**CrashLoopBackOff Event:**
```bash
echo '{"type":"Warning","reason":"BackOff","message":"Back-off restarting failed container","involvedObject":{"kind":"Pod","name":"crashing-service","namespace":"apps"},"cluster":"aks-staging"}' | ./generate-payload.sh | \
curl -X POST http://localhost:12000/k8s-event -H "Content-Type: application/json" -d @-
```

**FailedScheduling Event:**
```bash
echo '{"type":"Warning","reason":"FailedScheduling","message":"0/5 nodes are available: insufficient cpu","involvedObject":{"kind":"Pod","name":"resource-heavy-job","namespace":"batch"},"cluster":"aks-batch-cluster"}' | ./generate-payload.sh | \
curl -X POST http://localhost:12000/k8s-event -H "Content-Type: application/json" -d @-
```

## Understanding the Payload Format

### Event Hub Format (what the sensor receives)

```json
{
  "body": "<base64-encoded-k8s-event>",
  "id": "event-123",
  "partitionKey": "partition-0"
}
```

### Raw K8s Event (decoded from body)

```json
{
  "type": "Warning",
  "reason": "BackOff",
  "message": "Back-off pulling image \"invalid:nonexistent\"",
  "involvedObject": {
    "kind": "Pod",
    "name": "test-pod-abc123",
    "namespace": "production"
  },
  "cluster": "aks-prod-cluster"
}
```

### How the Sensor Processes It

1. Receives Event Hub format payload
2. Extracts `body` field
3. Base64 decodes it using `b64dec`
4. Parses JSON using `mustFromJson`
5. Extracts fields using `dig`
6. Passes to workflow template

## Workflow Behavior

### With HolmesGPT Available

1. Calls Holmes API for AI-powered investigation
2. Receives detailed analysis and recommendations
3. Creates GitLab issue with AI insights
4. Sends RocketChat notification (if configured)

### Without HolmesGPT (Fallback Mode)

1. Creates basic event report
2. Provides standard troubleshooting recommendations
3. Still creates GitLab issue
4. Notes that Holmes was unavailable

## Troubleshooting

### Sensor Not Triggering

```bash
# Check sensor status
kubectl describe sensor prod-test-gitlab-issues -n argo-events

# Check sensor logs
kubectl logs -n argo-events -l sensor-name=prod-test-gitlab-issues

# Common issues:
# - EventBus not running
# - Base64 decoding errors (check payload format)
```

### GitLab Issue Not Created

```bash
# Check workflow logs
kubectl logs -n argo-events -l purpose=production-testing --all-containers

# Common issues:
# - GitLab PAT invalid or expired
# - PAT missing 'api' scope
# - Project path incorrect
```

### Holmes API Timeout

The workflow will fall back to basic analysis if Holmes is not available.
Check Holmes deployment:

```bash
kubectl get pods -n holmesgpt
kubectl logs -n holmesgpt -l app=holmesgpt
```

## Cleanup

```bash
# Remove test resources
kubectl delete -f 04-sensor-production-test.yaml
kubectl delete -f 03-webhook-eventsource.yaml
kubectl delete -f 02-workflow-template.yaml

# Delete test workflows
kubectl delete workflows -n argo-events -l purpose=production-testing

# Optional: Remove secrets (if not needed elsewhere)
kubectl delete -f 01-secrets.yaml
```
