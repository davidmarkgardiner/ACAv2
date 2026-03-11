# EventBus NATS Troubleshooting & JetStream Migration

## The Problem

Argo Events 1.9.6 with the `nats: native` EventBus is prone to NATS connection lost errors. The built-in NATS StatefulSet pods crash or lose connectivity, causing EventSources and Sensors to restart in a loop.

Symptoms:
- EventSource/Sensor logs: `NATS connection lost`
- NATS pods in CrashLoopBackOff or OOMKilled
- Sensors and EventSources repeatedly restarting
- Events arriving in Event Hub but no workflows triggering

## Quick Triage

```bash
# 1. Check NATS pods
kubectl get pods -n argo-events -l controller=eventbus-controller
kubectl describe pods -n argo-events -l controller=eventbus-controller | grep -A5 "Last State"

# 2. Check for OOM
kubectl top pods -n argo-events -l controller=eventbus-controller

# 3. Check PVC health (NATS JetStream uses PVCs)
kubectl get pvc -n argo-events

# 4. Check EventBus status
kubectl get eventbus -n argo-events -o yaml

# 5. Check EventSource/Sensor logs for connection errors
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=50
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=50
```

## Common Root Causes

| Cause | Symptom | Fix |
|-------|---------|-----|
| NATS pods OOMKilled | `Last State: OOMKilled` in describe | Increase memory limits (see below) |
| PVC issues / slow storage | NATS pods stuck in Init or CrashLoop | Check storage class, switch to faster SC |
| Network latency between nodes | Intermittent NATS connection lost | Check node health, consider single-replica for dev |
| inotify limits too low | `too many open files` | `sysctl -w fs.inotify.max_user_instances=512` |

## Fix 1: Increase NATS Resources (Quick Fix)

The default native EventBus has minimal resource requests. Bump them:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      containerTemplate:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
      metricsContainerTemplate:
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      containerTemplate:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
EOF
```

## Fix 2: Migrate to JetStream EventBus (Recommended)

JetStream is the newer, more stable EventBus backend. Available in Argo Events 1.9.x.

### Step 1: Delete the existing EventBus

```bash
# Check current EventBus
kubectl get eventbus -n argo-events -o yaml

# Delete the old NATS native EventBus
kubectl delete eventbus default -n argo-events

# Wait for NATS pods to terminate
kubectl get pods -n argo-events -l controller=eventbus-controller -w
```

### Step 2: Deploy JetStream EventBus

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:
    version: "2.10.12"
    replicas: 3
    persistence:
      storageClassName: default          # Change to your storage class
      accessMode: ReadWriteOnce
      volumeSize: 10Gi
    settings: |
      max_mem_store: 256MB
      max_file_store: 1GB
    containerTemplate:
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          memory: 512Mi
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  jetstream:
    version: "2.10.12"
    replicas: 3
    persistence:
      storageClassName: default
      accessMode: ReadWriteOnce
      volumeSize: 10Gi
    settings: |
      max_mem_store: 256MB
      max_file_store: 1GB
    containerTemplate:
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          memory: 512Mi
EOF
```

### Step 3: Restart EventSources and Sensors

After switching the EventBus, existing EventSource and Sensor pods need to reconnect:

```bash
# Restart all EventSource pods
kubectl rollout restart deployment -n argo-events -l app.kubernetes.io/managed-by=eventsource-controller

# If the above doesn't match, delete pods directly (they'll be recreated)
kubectl delete pods -n argo-events -l eventsource-name=eventhub-k8s-events
kubectl delete pods -n argo-events -l eventsource-name=eventhub-critical
kubectl delete pods -n argo-events -l eventsource-name=eventhub-warnings
kubectl delete pods -n argo-events -l eventsource-name=eventhub-infra

# Restart all Sensor pods
kubectl delete pods -n argo-events -l sensor-name=k8s-event-triage
kubectl delete pods -n argo-events -l sensor-name=k8s-triage-critical
kubectl delete pods -n argo-events -l sensor-name=k8s-triage-warnings
kubectl delete pods -n argo-events -l sensor-name=k8s-triage-infra
```

### Step 4: Verify

```bash
# JetStream pods should be running
kubectl get pods -n argo-events -l controller=eventbus-controller

# EventSources should reconnect
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20
# Look for: "successfully connected to eventbus"

# Sensors should resubscribe
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=20
# Look for: "successfully subscribed to eventbus"
```

## Fix 3: Kafka EventBus (Eliminates NATS Entirely)

Since the pipeline already uses Event Hub (Kafka protocol), you can use a Kafka-based EventBus to eliminate the NATS dependency entirely. This uses Event Hub as both the event transport AND the internal bus.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  kafka:
    url: "evh-YOUR-NAMESPACE.servicebus.windows.net:9093"
    topic: "argo-events-bus"              # Separate topic from k8s-events
    version: "2.1.0"
    tls:
      caCertSecret:
        name: eventhub-tls-ca
        key: ca.pem
    sasl:
      mechanism: PLAIN
      userSecret:
        name: eventhub-credentials
        key: username
      passwordSecret:
        name: eventhub-credentials
        key: connection-string
```

**Note:** This requires a separate Event Hub topic (`argo-events-bus`) for the internal bus traffic. Create it:

```bash
az eventhubs eventhub create \
  --name argo-events-bus \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-YOUR-RG \
  --partition-count 2 \
  --cleanup-policy Delete \
  --retention-time 1
```

## Container Images Required

All images used in the pipeline that need to be mirrored to your private registry:

| Image | Used By | Purpose |
|-------|---------|---------|
| `badouralix/curl-jq:alpine` | All workflow templates (parse-otlp, classify-and-alert steps) | jq for OTLP parsing, curl for KAgent A2A + Mattermost |
| `grafana/alloy:v1.12.2` | Alloy deployment (workload cluster) | K8s event collection and OTLP export |
| `nats:2.10.12` | JetStream EventBus (if using Fix 2) | EventBus messaging backend |

### Mirror commands

```bash
# Replace YOUR_REGISTRY with your private registry (e.g., myregistry.azurecr.io)
REGISTRY=YOUR_REGISTRY

# Workflow image
docker pull badouralix/curl-jq:alpine
docker tag badouralix/curl-jq:alpine $REGISTRY/badouralix/curl-jq:alpine
docker push $REGISTRY/badouralix/curl-jq:alpine

# Alloy (workload cluster)
docker pull grafana/alloy:v1.12.2
docker tag grafana/alloy:v1.12.2 $REGISTRY/grafana/alloy:v1.12.2
docker push $REGISTRY/grafana/alloy:v1.12.2

# NATS (only if using JetStream EventBus)
docker pull nats:2.10.12
docker tag nats:2.10.12 $REGISTRY/nats:2.10.12
docker push $REGISTRY/nats:2.10.12
```

After mirroring, update the image references in:
- `tier-critical/workflow-template.yaml`
- `tier-warnings/workflow-template.yaml`
- `tier-infra/workflow-template.yaml`
- `04-workflow-template.yaml` (single-tier version)
- `alloy/03-deployment.yaml`
- EventBus manifest (if using JetStream with custom image)

## Summary: Which Fix to Choose

| Fix | Effort | Stability | Notes |
|-----|--------|-----------|-------|
| **1. Bump NATS resources** | Low (5 min) | Medium | Try this first, may not fully resolve |
| **2. JetStream EventBus** | Medium (30 min) | High | Recommended — drop-in replacement for native NATS |
| **3. Kafka EventBus** | Higher (1 hr) | Highest | Eliminates NATS entirely, reuses Event Hub infra |
