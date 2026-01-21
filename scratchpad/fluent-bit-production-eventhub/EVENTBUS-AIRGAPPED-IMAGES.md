# EventBus Air-Gapped Image Configuration

JetStream EventBus uses 3 container images. For air-gapped environments, patch the StatefulSet after creation.

## Images Required

| Container | Default Image | Purpose |
|-----------|---------------|---------|
| nats | `nats:2.10.10` | Main NATS server |
| config-reloader | `natsio/nats-server-config-reloader:0.14.0` | Config reload sidecar |
| metrics | `natsio/prometheus-nats-exporter:0.14.0` | Metrics exporter |

## Mirror Images to Private Registry

```bash
REGISTRY="your-registry.example.com"

# Pull from public
docker pull nats:2.10.10
docker pull natsio/nats-server-config-reloader:0.14.0
docker pull natsio/prometheus-nats-exporter:0.14.0

# Tag for private registry
docker tag nats:2.10.10 ${REGISTRY}/nats:2.10.10
docker tag natsio/nats-server-config-reloader:0.14.0 ${REGISTRY}/natsio/nats-server-config-reloader:0.14.0
docker tag natsio/prometheus-nats-exporter:0.14.0 ${REGISTRY}/natsio/prometheus-nats-exporter:0.14.0

# Push to private registry
docker push ${REGISTRY}/nats:2.10.10
docker push ${REGISTRY}/natsio/nats-server-config-reloader:0.14.0
docker push ${REGISTRY}/natsio/prometheus-nats-exporter:0.14.0
```

## Patch StatefulSet with Private Registry Images

```bash
REGISTRY="your-registry.example.com"
NS="argo-events"

# Patch all 3 container images
kubectl patch statefulset eventbus-default-js -n $NS --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "'${REGISTRY}'/nats:2.10.10"},
  {"op": "replace", "path": "/spec/template/spec/containers/1/image", "value": "'${REGISTRY}'/natsio/nats-server-config-reloader:0.14.0"},
  {"op": "replace", "path": "/spec/template/spec/containers/2/image", "value": "'${REGISTRY}'/natsio/prometheus-nats-exporter:0.14.0"}
]'

# Restart pods to pick up new images
kubectl rollout restart statefulset eventbus-default-js -n $NS

# Watch rollout
kubectl rollout status statefulset eventbus-default-js -n $NS
```

## Verify Images

```bash
kubectl get pods -n argo-events -l eventbus-name=default -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: {.image}{"\n"}{end}{"\n"}{end}'
```

## One-Liner Patch

```bash
REGISTRY="your-registry.example.com" && \
kubectl patch statefulset eventbus-default-js -n argo-events --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "'${REGISTRY}'/nats:2.10.10"},
  {"op": "replace", "path": "/spec/template/spec/containers/1/image", "value": "'${REGISTRY}'/natsio/nats-server-config-reloader:0.14.0"},
  {"op": "replace", "path": "/spec/template/spec/containers/2/image", "value": "'${REGISTRY}'/natsio/prometheus-nats-exporter:0.14.0"}
]' && \
kubectl rollout restart statefulset eventbus-default-js -n argo-events
```

## Alternative: Add ImagePullSecrets

If your registry requires authentication:

```bash
# Create registry secret
kubectl create secret docker-registry regcred \
  --namespace argo-events \
  --docker-server=your-registry.example.com \
  --docker-username=<username> \
  --docker-password=<password>

# Patch StatefulSet to use imagePullSecrets
kubectl patch statefulset eventbus-default-js -n argo-events --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/imagePullSecrets", "value": [{"name": "regcred"}]}
]'
```

## Note: Patches Don't Persist

The EventBus controller manages the StatefulSet. If the EventBus is recreated, patches are lost.

**Options for persistence:**

1. **Kyverno/Gatekeeper policy** - Mutate images automatically
2. **Registry mirror** - Configure containerd/docker to mirror at cluster level
3. **Argo Events controller config** - Some versions support image overrides

### Kyverno Policy Example

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: replace-eventbus-images
spec:
  rules:
    - name: replace-nats-image
      match:
        resources:
          kinds:
            - StatefulSet
          namespaces:
            - argo-events
          selector:
            matchLabels:
              eventbus-name: default
      mutate:
        patchStrategicMerge:
          spec:
            template:
              spec:
                containers:
                  - name: nats
                    image: "your-registry.example.com/nats:2.10.10"
                  - name: config-reloader
                    image: "your-registry.example.com/natsio/nats-server-config-reloader:0.14.0"
                  - name: metrics
                    image: "your-registry.example.com/natsio/prometheus-nats-exporter:0.14.0"
```

## Quick Reference

```bash
# Check current images
kubectl get statefulset eventbus-default-js -n argo-events -o jsonpath='{range .spec.template.spec.containers[*]}{.name}: {.image}{"\n"}{end}'

# Check pod images
kubectl get pods -n argo-events -l eventbus-name=default -o jsonpath='{.items[0].spec.containers[*].image}'

# Check for image pull errors
kubectl describe pods -n argo-events -l eventbus-name=default | grep -A5 "Events:"
```
