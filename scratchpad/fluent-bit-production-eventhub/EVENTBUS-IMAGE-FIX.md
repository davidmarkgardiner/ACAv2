# EventBus Not Using Private Registry Image

When updating the EventBus image, the controller may not pick up changes. The StatefulSet and pods need to be recreated.

## Diagnose

```bash
# Check what image the pods are actually using
kubectl get pods -n argo-events -l eventbus-name=default -o jsonpath='{.items[*].spec.containers[*].image}'

# Check the StatefulSet image
kubectl get statefulset -n argo-events -l eventbus-name=default -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'

# Check the EventBus spec
kubectl get eventbus default -n argo-events -o jsonpath='{.spec.nats.native.image}'
```

## Fix - Full Recreation

The EventBus controller creates a StatefulSet that doesn't get updated automatically. You need to delete and recreate.

```bash
NS=argo-events

# 1. Delete the StatefulSet (keeps EventBus)
kubectl delete statefulset -n $NS -l eventbus-name=default

# 2. Delete the pods
kubectl delete pods -n $NS -l eventbus-name=default --force --grace-period=0

# 3. Delete the EventBus (remove finalizers if stuck)
kubectl patch eventbus default -n $NS -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete eventbus default -n $NS

# 4. Verify it's gone
kubectl get eventbus,statefulset,pods -n $NS -l eventbus-name=default

# 5. Re-apply with correct image
kubectl apply -f 02a-mgmt-cluster-rbac.yaml

# 6. Verify new image is used
kubectl get pods -n $NS -l eventbus-name=default -o jsonpath='{.items[*].spec.containers[*].image}'
```

## One-Liner

```bash
NS=argo-events && \
kubectl delete statefulset -n $NS -l eventbus-name=default && \
kubectl delete pods -n $NS -l eventbus-name=default --force --grace-period=0 && \
kubectl patch eventbus default -n $NS -p '{"metadata":{"finalizers":null}}' --type=merge && \
kubectl delete eventbus default -n $NS && \
sleep 5 && \
kubectl apply -f 02a-mgmt-cluster-rbac.yaml
```

## Verify After Recreation

```bash
# Check EventBus is running
kubectl get eventbus -n argo-events

# Check image is correct (should show your private registry)
kubectl get pods -n argo-events -l eventbus-name=default -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'

# Check pods are running
kubectl get pods -n argo-events -l eventbus-name=default

# Check no image pull errors
kubectl describe pods -n argo-events -l eventbus-name=default | grep -A5 "Events:"
```

## If Image Pull Fails

```bash
# Check for ImagePullBackOff
kubectl get pods -n argo-events -l eventbus-name=default

# Get detailed error
kubectl describe pod -n argo-events -l eventbus-name=default | grep -A10 "Failed"

# Common issues:
# 1. Image doesn't exist in private registry
# 2. No imagePullSecrets configured
# 3. Registry authentication failed
```

### Add ImagePullSecrets (if needed)

```bash
# Create docker registry secret
kubectl create secret docker-registry regcred \
  --namespace argo-events \
  --docker-server=your-registry.example.com \
  --docker-username=<username> \
  --docker-password=<password>
```

Then update the EventBus to use it - add to `02a-mgmt-cluster-rbac.yaml`:

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
      auth: token
      image: your-registry.example.com/nats:2.10.14-alpine
      # Add imagePullSecrets
      imagePullSecrets:
        - name: regcred
      containerTemplate:
        # ... rest of config
```

## Alternative: Patch Existing EventBus

If you don't want to delete/recreate:

```bash
# Patch the image directly
kubectl patch eventbus default -n argo-events --type='json' \
  -p='[{"op": "replace", "path": "/spec/nats/native/image", "value": "your-registry.example.com/nats:2.10.14-alpine"}]'

# Then delete the StatefulSet to force recreation
kubectl delete statefulset -n argo-events -l eventbus-name=default

# Pods will be recreated with new image
kubectl get pods -n argo-events -l eventbus-name=default -w
```
