# Manual Triage via RocketChat

This integration allows users to manually submit events for AI triage through RocketChat, complementing the automated Fluent Bit pipeline.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Triage Pipeline                                 │
│                                                                             │
│  ┌──────────────────┐                                                       │
│  │   AUTOMATED      │     Fluent Bit → Event Hub → Argo Events → Workflow   │
│  │   (Fluent Bit)   │                                                       │
│  └──────────────────┘                                                       │
│                                                                             │
│  ┌──────────────────┐     ┌─────────────────┐     ┌─────────────────────┐   │
│  │   MANUAL         │     │   RocketChat    │     │  Argo Events        │   │
│  │   (RocketChat)   │────►│   Outgoing      │────►│  Webhook            │   │
│  │                  │     │   Webhook       │     │  EventSource        │   │
│  │ @triage ns/pod   │     │                 │     │                     │   │
│  │   reason         │     │                 │     │                     │   │
│  └──────────────────┘     └─────────────────┘     └──────────┬──────────┘   │
│                                                              │              │
│                                                              ▼              │
│                                                   ┌─────────────────────┐   │
│                                                   │  Sensor             │   │
│                                                   │  (triggers workflow)│   │
│                                                   └──────────┬──────────┘   │
│                                                              │              │
│                                                              ▼              │
│                                                   ┌─────────────────────┐   │
│                                                   │  multi-cluster-     │   │
│                                                   │  triage Workflow    │   │
│                                                   │  (Holmes + GitLab)  │   │
│                                                   └─────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- RocketChat installed and running
- Argo Events installed with EventBus configured
- `multi-cluster-triage` WorkflowTemplate deployed
- HolmesGPT running with cluster access

## Setup

### Step 1: Deploy Argo Events Components

```bash
# Deploy the webhook EventSource and Sensor
kubectl apply -f manual-triage-integration.yaml

# Verify the EventSource is running
kubectl get eventsource manual-triage-webhook -n argo-events
kubectl get pods -n argo-events -l eventsource-name=manual-triage-webhook

# Verify the Sensor is running
kubectl get sensor manual-triage-sensor -n argo-events
```

### Step 2: Configure RocketChat Incoming Webhook (for results)

1. Go to **Administration → Integrations**
2. Click **+ New** → **Incoming WebHook**
3. Configure:
   - **Enabled**: Yes
   - **Name**: Triage Results
   - **Post to Channel**: #alerts (or your channel)
   - **Post as**: Triage Bot
4. **Save** and copy the webhook URL
5. Update the secret:

```bash
kubectl create secret generic rocketchat-incoming-webhook \
  --namespace=argo-events \
  --from-literal=webhook-url="https://YOUR_DOMAIN/rocketchat/hooks/WEBHOOK_ID/TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 3: Configure RocketChat Outgoing Webhook

1. Go to **Administration → Integrations**
2. Click **+ New** → **Outgoing WebHook**
3. Configure:

| Field | Value |
|-------|-------|
| **Enabled** | Yes |
| **Name** | Manual Triage |
| **Event Trigger** | Message Sent |
| **Channel** | #general (or comma-separated list) |
| **Trigger Words** | @triage, /triage |
| **URLs** | http://manual-triage-webhook-eventsource-svc.argo-events.svc.cluster.local:12000/triage |
| **Impersonate User** | No |
| **Post as** | Triage Bot |
| **Script Enabled** | Yes |

4. Copy the script from `manual-triage-webhook-script.yaml` (the `webhook-script.js` content) into the **Script** field

5. **Save**

### Step 4: Test the Integration

```bash
# In RocketChat, type:
@triage default/nginx-test CrashLoopBackOff

# Check if workflow was triggered
kubectl get workflows -n argo-events -l app=manual-triage --sort-by=.metadata.creationTimestamp | tail -5

# Check EventSource logs
kubectl logs -n argo-events -l eventsource-name=manual-triage-webhook --tail=50

# Check Sensor logs
kubectl logs -n argo-events -l sensor-name=manual-triage-sensor --tail=50
```

## Usage

### Basic Format

```
@triage namespace/pod-name reason
```

Examples:
```
@triage payments/checkout-xyz OOMKilled
@triage default/nginx CrashLoopBackOff
@triage kube-system/coredns ImagePullBackOff
```

### With Cluster Name

```
@triage namespace/pod-name reason cluster-name
```

Examples:
```
@triage payments/checkout-xyz OOMKilled prod-cluster
@triage monitoring/prometheus-0 Unhealthy dev-cluster
```

### Flag Format

```
@triage --namespace=X --pod=Y --reason=Z [--cluster=W]
```

Examples:
```
@triage --namespace=payments --pod=checkout-xyz --reason=OOMKilled
@triage --namespace=kube-system --deployment=coredns --reason=Unhealthy --cluster=prod
```

### Reason Shortcuts

| Short | Full |
|-------|------|
| oom | OOMKilled |
| crash | CrashLoopBackOff |
| imagepull | ImagePullBackOff |
| schedule | FailedScheduling |
| backoff | BackOff |
| unhealthy | Unhealthy |
| mount | FailedMount |

## What Happens

1. User types `@triage payments/checkout-xyz OOMKilled` in RocketChat
2. RocketChat outgoing webhook parses the input
3. Structured JSON sent to Argo Events webhook
4. Sensor triggers `multi-cluster-triage` workflow
5. Workflow:
   - Calls HolmesGPT to investigate the issue
   - Creates GitLab issue with analysis
6. Results posted back to RocketChat channel

## Troubleshooting

### Webhook not triggering

```bash
# Check EventSource is running
kubectl get eventsource manual-triage-webhook -n argo-events

# Check EventSource pod logs
kubectl logs -n argo-events -l eventsource-name=manual-triage-webhook

# Test webhook directly
curl -X POST http://localhost:12000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "default",
    "resource_name": "test-pod",
    "resource_kind": "Pod",
    "reason": "CrashLoopBackOff",
    "cluster": "kind-argo-workflow",
    "message": "Test request"
  }'
```

### Sensor not processing events

```bash
# Check Sensor status
kubectl describe sensor manual-triage-sensor -n argo-events

# Check Sensor logs
kubectl logs -n argo-events -l sensor-name=manual-triage-sensor
```

### Workflow not running

```bash
# Check if WorkflowTemplate exists
kubectl get workflowtemplate multi-cluster-triage -n argo-events

# Check workflow status
kubectl get workflows -n argo-events -l app=manual-triage
kubectl describe workflow <workflow-name> -n argo-events
```

### RocketChat not receiving results

1. Verify incoming webhook URL in secret:
```bash
kubectl get secret rocketchat-incoming-webhook -n argo-events -o jsonpath='{.data.webhook-url}' | base64 -d
```

2. Test incoming webhook manually:
```bash
curl -X POST "https://YOUR_DOMAIN/rocketchat/hooks/ID/TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Test message"}'
```

## Testing

Run the automated test script to validate the integration:

```bash
# Full test suite (deploy + test)
./test-manual-triage.sh

# Or run individual steps:
./test-manual-triage.sh prereq      # Check prerequisites
./test-manual-triage.sh deploy      # Deploy components only
./test-manual-triage.sh test        # Run tests (assumes deployed)
./test-manual-triage.sh cleanup     # Remove test workflows
./test-manual-triage.sh full-cleanup # Remove everything
```

### Test Cases

1. **Direct Webhook Call** - Sends JSON directly to the webhook endpoint
2. **Workflow Execution** - Verifies the triage workflow runs
3. **Simulated RocketChat Payload** - Tests the payload format from RocketChat

### Manual Testing

```bash
# Port forward to the webhook
kubectl port-forward -n argo-events svc/manual-triage-webhook-eventsource-svc 12000:12000

# Send a test request
curl -X POST http://localhost:12000/triage \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "default",
    "resource_name": "test-pod",
    "resource_kind": "Pod",
    "reason": "CrashLoopBackOff",
    "cluster": "kind-argo-workflow",
    "message": "Manual test"
  }'

# Check workflows
kubectl get workflows -n argo-events -l app=manual-triage
```

## Files

| File | Purpose |
|------|---------|
| `manual-triage-integration.yaml` | Argo Events EventSource, Sensor, Service |
| `manual-triage-webhook-script.yaml` | RocketChat webhook script (ConfigMap) |
| `test-manual-triage.sh` | Automated test script |
| `MANUAL-TRIAGE-SETUP.md` | This setup guide |

## Comparison with Automated Pipeline

| Feature | Automated (Fluent Bit) | Manual (RocketChat) |
|---------|------------------------|---------------------|
| Trigger | K8s Warning events | User command |
| Latency | Real-time | On-demand |
| Scope | All Warning events | Specific resources |
| Use case | Proactive monitoring | Targeted investigation |
| Coverage | 24/7 automated | Human-initiated |

Both pipelines use the same `multi-cluster-triage` workflow template, ensuring consistent investigation and GitLab issue creation.
