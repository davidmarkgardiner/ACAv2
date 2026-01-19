# Local Testing Without Event Hub

Test the Argo Events Sensor → Workflow pipeline locally using a webhook EventSource.

## Prerequisites

```bash
# Verify Argo Events is installed and EventBus is running
kubectl get eventbus -n argo-events
# Should show: default   Running

# Verify ServiceAccount and RBAC exist
kubectl get sa argo-events-sa -n argo-events
kubectl auth can-i create workflows --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# Should return: yes
```

## Quick Test (3 Steps)

### Step 1: Deploy Test Resources

```bash
cd /Users//Desktop/repo/argo-workflow/application-stack/apps/holmesgpt/multi-cluster/fluent-bit-production/test-local

# Deploy webhook EventSource and test Sensor
kubectl apply -f 01-webhook-eventsource.yaml
kubectl apply -f 02-test-sensor.yaml

# Wait for pods to be ready
kubectl get pods -n argo-events -l eventsource-name=webhook-test
kubectl get pods -n argo-events -l sensor-name=webhook-test-sensor
```

### Step 2: Port-Forward to Webhook

```bash
# In a separate terminal
kubectl port-forward -n argo-events svc/eventsource-webhook-svc 12000:12000
```

### Step 3: Send Test Event

```bash
# Send a mock K8s warning event
curl -X POST http://localhost:12000/test-k8s-event \
  -H "Content-Type: application/json" \
  -d @test-payload.json

# Response should be: {"success": true}
```

## Verify It Worked

```bash
# Watch for workflow creation
kubectl get workflows -n argo-events -w

# Check workflow logs
kubectl logs -n argo-events -l workflows.argoproj.io/workflow --tail=50

# Or get the specific workflow
WF=$(kubectl get workflows -n argo-events -l purpose=local-testing -o name | tail -1)
kubectl logs -n argo-events $WF --tail=100
```

Expected output:
```
==========================================
LOCAL TEST - Event Received Successfully!
==========================================

Extracted Parameters:
  Cluster:       local-test-cluster
  Namespace:     default
  Resource:      test-pod-abc123
  Reason:        BackOff
  Message:       Back-off pulling image "invalid:nonexistent"

==========================================
SUCCESS: Sensor -> Workflow pipeline works!
==========================================
```

## Test Different Scenarios

### OOMKilled Event
```bash
curl -X POST http://localhost:12000/test-k8s-event \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Warning",
    "reason": "OOMKilled",
    "message": "Container exceeded memory limit",
    "involvedObject": {"kind": "Pod", "name": "memory-hog", "namespace": "production"},
    "cluster": "aks-prod-cluster"
  }'
```

### CrashLoopBackOff Event
```bash
curl -X POST http://localhost:12000/test-k8s-event \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Warning",
    "reason": "BackOff",
    "message": "Back-off restarting failed container",
    "involvedObject": {"kind": "Pod", "name": "crashing-app", "namespace": "apps"},
    "cluster": "aks-dev-cluster"
  }'
```

### FailedScheduling Event
```bash
curl -X POST http://localhost:12000/test-k8s-event \
  -H "Content-Type: application/json" \
  -d '{
    "type": "Warning",
    "reason": "FailedScheduling",
    "message": "0/3 nodes are available: insufficient cpu",
    "involvedObject": {"kind": "Pod", "name": "resource-hungry", "namespace": "batch"},
    "cluster": "aks-batch-cluster"
  }'
```

## Test Production Sensor with Webhook

To test the actual production sensor (which uses `multi-cluster-triage` workflow):

```bash
# Create a hybrid sensor that listens to BOTH webhook AND Event Hub
# This is useful for testing the production workflow locally

# First, verify the workflow template exists
kubectl get workflowtemplate multi-cluster-triage -n argo-events
```

## Cleanup

```bash
# Remove test resources
kubectl delete -f 02-test-sensor.yaml
kubectl delete -f 01-webhook-eventsource.yaml

# Delete test workflows
kubectl delete workflows -n argo-events -l purpose=local-testing
```

## Troubleshooting

### Webhook pod not starting
```bash
kubectl describe eventsource webhook-test -n argo-events
kubectl logs -n argo-events -l eventsource-name=webhook-test
```

### Sensor not triggering
```bash
kubectl describe sensor webhook-test-sensor -n argo-events
kubectl logs -n argo-events -l sensor-name=webhook-test-sensor
```

### Port-forward fails
```bash
# Check service exists
kubectl get svc eventsource-webhook-svc -n argo-events

# Check endpoints
kubectl get endpoints eventsource-webhook-svc -n argo-events
```

### Connection refused on curl
```bash
# Verify port-forward is still running
# The webhook pod needs time to start - wait 10-15 seconds after applying

# Check pod is ready
kubectl get pods -n argo-events -l eventsource-name=webhook-test
```
