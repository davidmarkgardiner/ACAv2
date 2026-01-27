# HolmesGPT Auto-Healer Demo Scenarios

These are namespace-scoped demo scenarios that showcase HolmesGPT's ability to detect and auto-fix common Kubernetes issues.

## Prerequisites

1. Deploy the auto-healer stack (eventsource, sensor, workflowtemplate)
2. Ensure HolmesGPT is running
3. Create the demo namespace:
   ```bash
   kubectl create namespace demo-autohealer
   ```

## Demo Flow

1. Apply a broken deployment
2. Watch the K8s Warning events trigger Argo Events
3. See HolmesGPT analyze the issue
4. Watch the auto-fix get applied (or manual notification if unsafe)
5. Verify the fix worked

## Scenarios

| # | Scenario | Trigger Event | Expected Fix |
|---|----------|---------------|--------------|
| 1 | CrashLoopBackOff | Pod crash loop | `kubectl delete pod` |
| 2 | OOMKilled | Memory exceeded | `kubectl rollout restart deployment` |
| 3 | Failed/Evicted Pods | Pod failures | `kubectl delete pod` |
| 4 | Stuck Job | Job failed | `kubectl delete job` |
| 5 | Deployment Unhealthy | Readiness probe fail | `kubectl rollout restart deployment` |

## Quick Start

```bash
# Deploy all demos at once
kubectl apply -f demos/ -n demo-autohealer

# Or deploy individually
kubectl apply -f demos/01-crashloop-demo.yaml -n demo-autohealer
```

## Cleanup

```bash
kubectl delete -f demos/ -n demo-autohealer
```
