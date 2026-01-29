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

### Restart-Based Fixes (Demos 01-05)

These demos trigger issues where a pod restart or cleanup resolves the immediate symptom.

| # | Scenario | Trigger Event | Fix |
|---|----------|---------------|-----|
| 01 | CrashLoopBackOff | Pod crash loop | `kubectl delete pod` |
| 02 | OOMKilled | Memory exceeded | `kubectl rollout restart deployment` |
| 03 | Failed/Evicted Pods | Pod failures | `kubectl delete pod` |
| 04 | Stuck Job | Job failed | `kubectl delete job` |
| 05 | Deployment Unhealthy | Readiness probe fail | `kubectl rollout restart deployment` |

### Root Cause Fixes (Demos 06-11)

These demos require Holmes to **diagnose the root cause and apply a targeted configuration change**. Restarting the pod does nothing - the same error returns immediately. Holmes must identify what's actually wrong and fix it.

| # | Scenario | Root Cause | Fix |
|---|----------|------------|-----|
| 06 | [OOM - Patch Limits](#demo-06-oom-patch-limits) | Memory limit too low (32Mi, needs 128Mi) | `kubectl patch deployment` to increase memory limits |
| 07 | [Missing ConfigMap](#demo-07-missing-configmap) | Pod references ConfigMap that doesn't exist | `kubectl create configmap` with required keys |
| 08 | [Wrong Image Tag](#demo-08-wrong-image-tag) | Image `nginx:99.99.99` doesn't exist | `kubectl set image` to valid tag |
| 09 | [Liveness Probe Wrong Path](#demo-09-liveness-probe-misconfigured) | Probe checks `/healthz`, app serves `/health` | `kubectl patch deployment` to fix probe path |
| 10 | [Pending - Quota Exhausted](#demo-10-pending-quota) | ResourceQuota CPU too restrictive | `kubectl patch resourcequota` to increase limits |
| 11 | [Service Selector Mismatch](#demo-11-service-selector-mismatch) | Service selector `myapp` vs pod label `my-app` | `kubectl patch svc` to fix selector |

---

## Root Cause Fix Details

### Demo 06: OOM Patch Limits

**What's broken:** Deployment has `limits.memory: 32Mi` but the app needs ~128Mi. Pod OOMKills repeatedly.

**Why restart doesn't work:** The memory limit is still 32Mi after restart - it will OOM again immediately.

**Holmes should:**
1. See `OOMKilled` in pod termination reason
2. Check current memory limits (32Mi)
3. Patch the deployment to increase limits

```bash
# Deploy
kubectl apply -f 06-oom-patch-limits-demo.yaml -n demo-autohealer

# Watch it OOMKill
kubectl get pods -n demo-autohealer -w

# Expected fix
kubectl patch deployment oom-patch-demo -n demo-autohealer \
  --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"256Mi"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"128Mi"}
  ]'

# Verify
kubectl get pods -n demo-autohealer -l app=oom-patch-demo
```

### Demo 07: Missing ConfigMap

**What's broken:** Pod mounts `configMapRef: app-settings` but that ConfigMap doesn't exist.

**Why restart doesn't work:** The ConfigMap still doesn't exist. Pod enters `CreateContainerConfigError`.

**Holmes should:**
1. See `CreateContainerConfigError` or failed mount event
2. Read events: `configmap "app-settings" not found`
3. Create the missing ConfigMap

```bash
# Deploy
kubectl apply -f 07-missing-configmap-demo.yaml -n demo-autohealer

# Watch it fail
kubectl get pods -n demo-autohealer -w
kubectl describe pod -l app=missing-configmap-demo -n demo-autohealer

# Expected fix
kubectl create configmap app-settings -n demo-autohealer \
  --from-literal=DATABASE_HOST=localhost \
  --from-literal=DATABASE_PORT=5432 \
  --from-literal=LOG_LEVEL=info \
  --from-literal=APP_ENV=development

# Verify - pod should start
kubectl get pods -n demo-autohealer -l app=missing-configmap-demo
```

### Demo 08: Wrong Image Tag

**What's broken:** Deployment uses `nginx:99.99.99` which doesn't exist in any registry.

**Why restart doesn't work:** The image still doesn't exist. Pod stays in `ImagePullBackOff`.

**Holmes should:**
1. See `ImagePullBackOff` status
2. Read events: `manifest unknown` or `not found`
3. Patch the image to a valid tag

```bash
# Deploy
kubectl apply -f 08-wrong-image-tag-demo.yaml -n demo-autohealer

# Watch it fail
kubectl get pods -n demo-autohealer -w

# Expected fix
kubectl set image deployment/wrong-image-demo \
  webapp=nginx:1.27-alpine -n demo-autohealer

# Verify
kubectl get pods -n demo-autohealer -l app=wrong-image-demo
```

### Demo 09: Liveness Probe Misconfigured

**What's broken:** App health endpoint is `/health` but liveness probe checks `/healthz` (404). Kubernetes kills a perfectly healthy app every ~15 seconds.

**Why restart doesn't work:** Restart makes it worse - it restarts, passes readiness (which correctly checks `/health`), then gets killed again by liveness checking `/healthz`.

**Holmes should:**
1. See high restart count and `Liveness probe failed: 404`
2. Notice readiness probe (on `/health`) passes but liveness (on `/healthz`) fails
3. Patch the liveness probe path

```bash
# Deploy
kubectl apply -f 09-liveness-probe-misconfigured-demo.yaml -n demo-autohealer

# Watch restarts climb
kubectl get pods -n demo-autohealer -w
kubectl describe pod -l app=liveness-misconfigured-demo -n demo-autohealer

# Expected fix
kubectl patch deployment liveness-misconfigured-demo -n demo-autohealer \
  --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/health"}
  ]'

# Verify - restarts should stop
kubectl get pods -n demo-autohealer -l app=liveness-misconfigured-demo
```

### Demo 10: Pending Quota

**What's broken:** Namespace has a ResourceQuota limiting CPU to 100m total. Deployment requests 200m. Pod stuck in `Pending`.

**Why restart doesn't work:** The quota is still 100m. No pod with >100m CPU request can ever schedule.

**Holmes should:**
1. See `Pending` pod status
2. Read events: `exceeded quota: tight-quota, requested: requests.cpu=200m, limited: requests.cpu=100m`
3. Patch the ResourceQuota

```bash
# Deploy (creates both the quota and the deployment)
kubectl apply -f 10-pending-quota-demo.yaml -n demo-autohealer

# Watch it stay Pending
kubectl get pods -n demo-autohealer -w
kubectl describe pod -l app=pending-quota-demo -n demo-autohealer

# Expected fix
kubectl patch resourcequota tight-quota -n demo-autohealer \
  -p '{"spec":{"hard":{"requests.cpu":"2","limits.cpu":"2","requests.memory":"512Mi","limits.memory":"512Mi"}}}'

# Verify - pod should schedule
kubectl get pods -n demo-autohealer -l app=pending-quota-demo
```

### Demo 11: Service Selector Mismatch

**What's broken:** Pods have label `app: my-app` but Service selector says `app: myapp` (missing hyphen). Service has 0 endpoints. Traffic returns 503.

**Why restart doesn't work:** Pods are running fine. The wiring is wrong.

**Holmes should:**
1. See Service with 0 endpoints
2. Compare Service selector (`app: myapp`) to Pod labels (`app: my-app`)
3. Patch the Service selector

```bash
# Deploy
kubectl apply -f 11-service-selector-mismatch-demo.yaml -n demo-autohealer

# Show the problem - 0 endpoints
kubectl get endpoints broken-service-demo -n demo-autohealer
kubectl describe svc broken-service-demo -n demo-autohealer

# Expected fix
kubectl patch svc broken-service-demo -n demo-autohealer \
  -p '{"spec":{"selector":{"app":"my-app"}}}'

# Verify - endpoints should populate
kubectl get endpoints broken-service-demo -n demo-autohealer
```

---

## Quick Start

```bash
# Deploy all demos at once
kubectl apply -f demos/ -n demo-autohealer

# Or deploy individually
kubectl apply -f demos/06-oom-patch-limits-demo.yaml -n demo-autohealer
kubectl apply -f demos/07-missing-configmap-demo.yaml -n demo-autohealer
kubectl apply -f demos/08-wrong-image-tag-demo.yaml -n demo-autohealer
kubectl apply -f demos/09-liveness-probe-misconfigured-demo.yaml -n demo-autohealer
kubectl apply -f demos/10-pending-quota-demo.yaml -n demo-autohealer
kubectl apply -f demos/11-service-selector-mismatch-demo.yaml -n demo-autohealer
```

## Cleanup

```bash
# Remove all demos
kubectl delete -f demos/ -n demo-autohealer

# Remove the quota (if demo 10 was applied)
kubectl delete resourcequota tight-quota -n demo-autohealer 2>/dev/null

# Remove the configmap (if demo 07 fix was applied)
kubectl delete configmap app-settings -n demo-autohealer 2>/dev/null

# Delete namespace entirely
kubectl delete namespace demo-autohealer
```

## Demo Presentation Order

For maximum impact, demo in this order:

1. **Demo 01 (CrashLoop)** - Show the existing restart-based healing works
2. **Demo 09 (Liveness Probe)** - Show that restarting a healthy app is wrong; Holmes patches the probe
3. **Demo 07 (Missing ConfigMap)** - Show Holmes creating a missing dependency
4. **Demo 06 (OOM Patch)** - Show Holmes increasing resource limits instead of restarting
5. **Demo 11 (Service Selector)** - Show Holmes debugging a subtle label mismatch
6. **Demo 10 (Quota)** - Show Holmes fixing infrastructure policy constraints

This order builds from "simple fix" to "Holmes is doing real detective work."
