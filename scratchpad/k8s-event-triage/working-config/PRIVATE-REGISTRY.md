# Private Registry Setup

How to run the entire K8s Event Triage pipeline using only your private container registry.

## Why This Is Needed

The Argo Events controller reads default image references from a **ConfigMap** (`argo-events-controller-config`), not from the EventBus CR. Setting `natsImage` or `streamImage` on the EventBus YAML does NOT reliably override all images. The controller will still try to pull sidecars (config-reloader, metrics-exporter) from Docker Hub.

**The fix:** Override images at the **Helm chart level** so the ConfigMap is populated with your private registry URLs from the start.

## Step 1: Import Images to Your Registry

### Azure Container Registry (ACR)

```bash
REGISTRY="your-registry.azurecr.io"

# Argo Events controller + EventSource + Sensor
az acr import --name $REGISTRY --source quay.io/argoproj/argo-events:v1.9.10 --image argoproj/argo-events:v1.9.10

# NATS (JetStream EventBus)
az acr import --name $REGISTRY --source docker.io/library/nats:2.10.10 --image nats:2.10.10

# NATS config reloader sidecar
az acr import --name $REGISTRY --source docker.io/natsio/nats-server-config-reloader:0.14.0 --image natsio/nats-server-config-reloader:0.14.0

# NATS metrics exporter sidecar
az acr import --name $REGISTRY --source docker.io/natsio/prometheus-nats-exporter:0.14.0 --image natsio/prometheus-nats-exporter:0.14.0

# NATS Streaming (only if using native NATS EventBus instead of JetStream)
az acr import --name $REGISTRY --source docker.io/library/nats-streaming:0.25.6 --image nats-streaming:0.25.6

# Grafana Alloy
az acr import --name $REGISTRY --source docker.io/grafana/alloy:v1.12.2 --image grafana/alloy:v1.12.2

# Workflow step image
az acr import --name $REGISTRY --source docker.io/badouralix/curl-jq:alpine --image badouralix/curl-jq:alpine
```

### Docker Hub (mirror/retag)

```bash
REGISTRY="your-registry.example.com"

# Pull, tag, push
for img in \
  "nats:2.10.10" \
  "natsio/nats-server-config-reloader:0.14.0" \
  "natsio/prometheus-nats-exporter:0.14.0" \
  "nats-streaming:0.25.6" \
  "grafana/alloy:v1.12.2" \
  "badouralix/curl-jq:alpine"; do
  docker pull "$img"
  docker tag "$img" "$REGISTRY/$img"
  docker push "$REGISTRY/$img"
done

# Quay.io images
docker pull quay.io/argoproj/argo-events:v1.9.10
docker tag quay.io/argoproj/argo-events:v1.9.10 "$REGISTRY/argoproj/argo-events:v1.9.10"
docker push "$REGISTRY/argoproj/argo-events:v1.9.10"
```

## Step 2: Deploy Argo Events with Private Registry Images

Edit `helm-values-argo-events.yaml` and replace all `REPLACE_REGISTRY` with your registry URL.

```bash
REGISTRY="your-registry.azurecr.io"

# Replace placeholders
sed "s|REPLACE_REGISTRY|${REGISTRY}|g" helm-values-argo-events.yaml > /tmp/argo-events-values.yaml

# Install/upgrade Argo Events
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argo-events argo/argo-events \
  -n argo-events --create-namespace \
  -f /tmp/argo-events-values.yaml
```

## Step 3: Verify the ConfigMap

After Helm deploy, check that the controller ConfigMap has your registry URLs:

```bash
kubectl get configmap argo-events-controller-config -n argo-events -o yaml
```

Look for the `jetstream` section — all image references should point to your registry:

```yaml
jetstream:
  versions:
    - version: "latest"
      natsImage: "your-registry.azurecr.io/nats:2.10.10"
      configReloaderImage: "your-registry.azurecr.io/natsio/nats-server-config-reloader:0.14.0"
      metricsExporterImage: "your-registry.azurecr.io/natsio/prometheus-nats-exporter:0.14.0"
```

## Step 4: Deploy EventBus

Now when you `kubectl apply -f 04-eventbus.yaml`, the controller will use the ConfigMap images (your private registry) for all pods — including sidecars.

No need for `streamImage`, `reloaderImage`, or `metricsImage` on the EventBus CR.

## Step 5: Update Remaining Manifests

Replace image references in the application manifests:

| File | Image Field | Replace With |
|------|-------------|--------------|
| `03-alloy.yaml` | `image: grafana/alloy:v1.12.2` | `image: REGISTRY/grafana/alloy:v1.12.2` |
| `07-workflow-template.yaml` | `image: badouralix/curl-jq:alpine` | `image: REGISTRY/badouralix/curl-jq:alpine` |

## Why CR-Level Overrides Don't Work

The EventBus CR supports fields like `streamImage` (JetStream) and `natsImage` (native NATS). However:

1. The controller reconciler reads the **ConfigMap** first for version-to-image mappings
2. CR-level fields only override the main NATS container in some code paths
3. Sidecar images (config-reloader, metrics-exporter) are **always** read from the ConfigMap
4. This means even if the main NATS container pulls from your registry, the sidecars still try Docker Hub

The Helm values approach overrides the ConfigMap itself, so **all** images (main + sidecars) use your registry.

## Complete Image Inventory

| Image | Source | Used By |
|-------|--------|---------|
| `argoproj/argo-events:v1.9.10` | quay.io | Controller, EventSource, Sensor pods |
| `nats:2.10.10` | Docker Hub | JetStream EventBus main container |
| `natsio/nats-server-config-reloader:0.14.0` | Docker Hub | JetStream EventBus sidecar |
| `natsio/prometheus-nats-exporter:0.14.0` | Docker Hub | JetStream EventBus metrics sidecar |
| `nats-streaming:0.25.6` | Docker Hub | Native NATS EventBus (if not using JetStream) |
| `grafana/alloy:v1.12.2` | Docker Hub | Alloy event collector |
| `badouralix/curl-jq:alpine` | Docker Hub | Workflow step (parse-and-log) |

## AKS-Specific: ACR Integration

If your AKS cluster is attached to ACR, pods can pull without imagePullSecrets:

```bash
# Attach ACR to AKS (one-time)
az aks update -n YOUR_CLUSTER -g YOUR_RG --attach-acr YOUR_ACR_NAME
```

If not attached, create an imagePullSecret in each namespace:

```bash
for ns in argo-events monitoring argo; do
  kubectl create secret docker-registry acr-secret -n $ns \
    --docker-server=YOUR_REGISTRY.azurecr.io \
    --docker-username=YOUR_SP_ID \
    --docker-password=YOUR_SP_SECRET
done
```
