# Health Probes Configuration

Health probes for Azure Container Apps ensure your Function App is healthy and receives traffic only when ready.

## Summary

Your Function App now includes **three types of health probes**:

| Probe Type | Purpose | Path | Frequency | Failure Threshold |
|------------|---------|------|-----------|-------------------|
| **Startup** | Initial health check | `/api/health` | Every 5s | 30 failures (150s) |
| **Readiness** | Ready for traffic | `/api/health` | Every 5s | 3 failures (15s) |
| **Liveness** | Container is healthy | `/api/health` | Every 10s | 3 failures (30s) |

## Probe Types Explained

### 1. Startup Probe
**Purpose:** Determines when the container has successfully started.

```bicep
{
  type: 'Startup'
  httpGet: {
    path: '/api/health'
    port: 80
    scheme: 'HTTP'
  }
  initialDelaySeconds: 0      // Start checking immediately
  periodSeconds: 5            // Check every 5 seconds
  timeoutSeconds: 3           // 3 second timeout
  successThreshold: 1         // 1 success = started
  failureThreshold: 30        // 30 failures (150s) before restart
}
```

**Why it matters:**
- **Prevents premature restarts** during cold starts
- Allows up to **150 seconds** for Azure Functions to initialize
- Critical for **scale-to-zero** scenarios (10-30s cold start)
- Once startup succeeds, liveness/readiness probes take over

**What happens:**
- ✅ Success → Container marked as "started", liveness probe begins
- ❌ 30 Failures → Container restarted (likely bad image or config)

### 2. Readiness Probe
**Purpose:** Determines if the container can accept traffic.

```bicep
{
  type: 'Readiness'
  httpGet: {
    path: '/api/health'
    port: 80
    scheme: 'HTTP'
  }
  initialDelaySeconds: 5      // Wait 5s before first check
  periodSeconds: 5            // Check every 5 seconds
  timeoutSeconds: 3
  successThreshold: 1
  failureThreshold: 3         // 3 failures (15s) = not ready
}
```

**Why it matters:**
- **Prevents failed requests** during startup or high load
- Removes container from load balancer if unhealthy
- Container **stays running** but doesn't receive traffic
- Automatically added back when healthy

**What happens:**
- ✅ Success → Traffic routed to container
- ❌ Failure → Traffic stopped, container stays running, retries every 5s

### 3. Liveness Probe
**Purpose:** Determines if the container is still running properly.

```bicep
{
  type: 'Liveness'
  httpGet: {
    path: '/api/health'
    port: 80
    scheme: 'HTTP'
  }
  initialDelaySeconds: 10     // Wait 10s after startup succeeds
  periodSeconds: 10           // Check every 10 seconds
  timeoutSeconds: 3
  successThreshold: 1
  failureThreshold: 3         // 3 failures (30s) = restart
}
```

**Why it matters:**
- **Restarts hung or crashed containers**
- Less aggressive than readiness (30s vs 15s grace period)
- Prevents cascading failures from stuck processes

**What happens:**
- ✅ Success → Container continues running
- ❌ 3 Failures → Container **restarted**

## Health Endpoint Requirements

Your `/api/health` endpoint must:

### ✅ Return HTTP 200 Status
```python
@app.route(route="health")
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"status": "healthy"}),
        mimetype="application/json",
        status_code=200  # ← Must be 200
    )
```

### ✅ Respond Quickly (< 3 seconds)
```python
# ❌ BAD: Slow database checks
def health_check(req):
    database.connect()  # Don't do this!
    return func.HttpResponse("OK", status_code=200)

# ✅ GOOD: Fast check
def health_check(req):
    return func.HttpResponse("OK", status_code=200)
```

### ✅ Be Lightweight
```python
# Health checks run every 5-10 seconds
# Don't perform expensive operations
```

## Probe Timeline Example

Here's what happens when a container starts with **scale-to-zero**:

```
Time  | Startup Probe | Readiness Probe | Liveness Probe | Traffic | Status
------|---------------|-----------------|----------------|---------|--------
  0s  | Starting...   | Not started     | Not started    | ❌ No   | Cold start
  5s  | Check #1 ✅   | Starting...     | Not started    | ❌ No   | Initializing
 10s  | ✅ Success    | Check #1 ✅     | Starting...    | ✅ Yes  | Ready!
 20s  | (stopped)     | ✅ Healthy      | Check #1 ✅    | ✅ Yes  | Serving
 30s  | (stopped)     | ✅ Healthy      | Check #2 ✅    | ✅ Yes  | Serving
```

**After 3 minutes idle:**
```
Time  | Scale Status  | Probes         | Traffic | Notes
------|---------------|----------------|---------|------------------
180s  | Scaling to 0  | All stopped    | ❌ No   | No traffic
300s  | Scaled to 0   | Container gone | ❌ No   | Zero replicas
301s  | Request!      | Container created | ❌ No | Starting...
306s  | Starting      | Startup running | ❌ No  | Cold start
315s  | Started       | Readiness ✅    | ✅ Yes | Request served!
```

## Configuration Options

### Default Configuration (Recommended)
```bicep
// In your deployment
healthProbesEnabled: true          // Enable all probes
healthProbePath: '/api/health'    // Your health endpoint
healthProbePort: 80               // Azure Functions port
```

### Disable Probes (Not Recommended)
```bicep
healthProbesEnabled: false        // No health checking
// Container Apps will use TCP checks instead
```

### Custom Health Endpoint
```bicep
healthProbePath: '/healthz'       // Different path
healthProbePort: 8080             // Different port
```

## Troubleshooting

### Issue: Container keeps restarting

**Check liveness probe failures:**
```bash
az containerapp revision list \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --query "[0].properties.{name:name,health:healthState,replicas:replicas}"
```

**View container logs:**
```bash
az containerapp logs show \
  --name funcapp-ca-dev \
  --resource-group rg-funcapp-dev \
  --tail 100 | grep -i "health\|probe\|error"
```

**Common causes:**
- Health endpoint returns non-200 status
- Health endpoint times out (>3s)
- Function runtime failed to start
- Missing environment variables

### Issue: Traffic not routing to new container

**Check readiness probe:**
```bash
# Test health endpoint manually
curl https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/health
```

**Common causes:**
- Readiness probe failing but liveness passing
- Health endpoint slow to respond
- Container started but not fully initialized

### Issue: Slow cold starts

**Adjust startup probe:**
```bicep
failureThreshold: 60  // Increase from 30 to 300s (60 × 5s)
```

**Or optimize function:**
- Reduce dependencies
- Use smaller base image
- Pre-warm with minimum replicas

## Deployment

The probes are automatically configured when you deploy:

```bash
# Standard deployment (probes enabled by default)
az deployment group create \
  --name funcapp-deployment \
  --resource-group rg-funcapp-dev \
  --template-file bicep/templates/function-app-deployment.bicep \
  --parameters @bicep/parameters/function-app-dev.bicepparam
```

## Verification

After deployment, verify probes are working:

```bash
#!/bin/bash

RESOURCE_GROUP="rg-funcapp-dev"
CONTAINER_APP="funcapp-ca-dev"

# Get container app details
az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.template.containers[0].probes' \
  -o json

# Test health endpoint
FQDN=$(az containerapp show \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --query 'properties.configuration.ingress.fqdn' \
  -o tsv)

echo "Testing health endpoint..."
curl -w "\nStatus: %{http_code}\nTime: %{time_total}s\n" \
  "https://$FQDN/api/health"

# Check replica health
az containerapp replica list \
  --name $CONTAINER_APP \
  --resource-group $RESOURCE_GROUP \
  --revision latest \
  --query "[].{name:name,running:properties.runningState,created:properties.createdTime}"
```

## Best Practices

### ✅ DO:
- Use `/api/health` for all three probe types
- Keep health checks lightweight (<100ms)
- Return HTTP 200 for healthy, anything else for unhealthy
- Test health endpoint during development
- Monitor probe failures in production

### ❌ DON'T:
- Don't check external dependencies (databases, APIs)
- Don't perform heavy computations
- Don't return 200 when dependencies are down
- Don't disable probes in production
- Don't use authentication on health endpoints

## Advanced: Custom Health Logic

If you need complex health checks:

```python
@app.route(route="health")
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """
    Comprehensive health check with different responses
    for startup vs runtime
    """
    try:
        # Minimal check - always passes if runtime is up
        health_status = {
            "status": "healthy",
            "timestamp": datetime.utcnow().isoformat(),
            "runtime": "ok"
        }

        # Optional: Check critical resources (not recommended for probes)
        # Use a separate endpoint like /api/status for detailed checks

        return func.HttpResponse(
            json.dumps(health_status),
            mimetype="application/json",
            status_code=200
        )
    except Exception as e:
        # Only return unhealthy if runtime itself is broken
        return func.HttpResponse(
            json.dumps({"status": "unhealthy", "error": str(e)}),
            mimetype="application/json",
            status_code=503
        )
```

## ARM Template Equivalent

If using ARM templates directly:

```json
{
  "containers": [
    {
      "name": "funcapp-ca-dev",
      "image": "myregistry.azurecr.io/function-app:latest",
      "probes": [
        {
          "type": "Liveness",
          "httpGet": {
            "path": "/api/health",
            "port": 80,
            "scheme": "HTTP"
          },
          "initialDelaySeconds": 10,
          "periodSeconds": 10,
          "timeoutSeconds": 3,
          "successThreshold": 1,
          "failureThreshold": 3
        },
        {
          "type": "Readiness",
          "httpGet": {
            "path": "/api/health",
            "port": 80,
            "scheme": "HTTP"
          },
          "initialDelaySeconds": 5,
          "periodSeconds": 5,
          "timeoutSeconds": 3,
          "successThreshold": 1,
          "failureThreshold": 3
        },
        {
          "type": "Startup",
          "httpGet": {
            "path": "/api/health",
            "port": 80,
            "scheme": "HTTP"
          },
          "initialDelaySeconds": 0,
          "periodSeconds": 5,
          "timeoutSeconds": 3,
          "successThreshold": 1,
          "failureThreshold": 30
        }
      ]
    }
  ]
}
```

## References

- [Container Apps Health Probes](https://learn.microsoft.com/azure/container-apps/health-probes)
- [Kubernetes Probe Best Practices](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Azure Functions Health Checks](https://learn.microsoft.com/azure/azure-functions/functions-monitoring)
