# Deleting Stuck Argo Events Resources

Argo Events resources (EventBus, EventSource, Sensor) often get stuck during deletion due to finalizers.

## Quick Fix

```bash
# Remove finalizers and delete
kubectl patch eventbus default -n argo-events -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete eventbus default -n argo-events
```

---

## EventBus Stuck

### Check Status

```bash
kubectl get eventbus -n argo-events
kubectl get eventbus default -n argo-events -o jsonpath='{.metadata.finalizers}'
```

### Remove Finalizers and Delete

```bash
# Patch out finalizers
kubectl patch eventbus default -n argo-events \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# Delete
kubectl delete eventbus default -n argo-events

# If still stuck, force delete
kubectl delete eventbus default -n argo-events --grace-period=0 --force
```

### Delete Dependent Resources First

```bash
# Delete EventBus pods (NATS)
kubectl delete pods -n argo-events -l eventbus-name=default --force --grace-period=0

# Delete StatefulSet
kubectl delete statefulset -n argo-events -l eventbus-name=default --force --grace-period=0

# Delete Services
kubectl delete svc -n argo-events -l eventbus-name=default

# Then delete EventBus
kubectl patch eventbus default -n argo-events -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete eventbus default -n argo-events
```

---

## EventSource Stuck

```bash
# Check finalizers
kubectl get eventsource eventhub-k8s-events -n argo-events -o jsonpath='{.metadata.finalizers}'

# Remove finalizers
kubectl patch eventsource eventhub-k8s-events -n argo-events \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# Delete
kubectl delete eventsource eventhub-k8s-events -n argo-events

# Delete associated pods
kubectl delete pods -n argo-events -l eventsource-name=eventhub-k8s-events --force --grace-period=0
```

---

## Sensor Stuck

```bash
# Check finalizers
kubectl get sensor fluent-bit-gitlab-issues -n argo-events -o jsonpath='{.metadata.finalizers}'

# Remove finalizers
kubectl patch sensor fluent-bit-gitlab-issues -n argo-events \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# Delete
kubectl delete sensor fluent-bit-gitlab-issues -n argo-events

# Delete associated pods
kubectl delete pods -n argo-events -l sensor-name=fluent-bit-gitlab-issues --force --grace-period=0
```

---

## Delete All Argo Events Resources

```bash
NS=argo-events

# Remove all finalizers
for resource in eventbus eventsource sensor; do
  for name in $(kubectl get $resource -n $NS -o name 2>/dev/null); do
    kubectl patch $name -n $NS -p '{"metadata":{"finalizers":null}}' --type=merge
  done
done

# Delete all
kubectl delete eventbus --all -n $NS --force --grace-period=0
kubectl delete eventsource --all -n $NS --force --grace-period=0
kubectl delete sensor --all -n $NS --force --grace-period=0

# Clean up pods
kubectl delete pods -n $NS -l app.kubernetes.io/part-of=argo-events --force --grace-period=0
```

---

## Nuclear Option - Delete via API

If nothing else works:

```bash
# Get the resource as JSON, remove finalizers, replace
kubectl get eventbus default -n argo-events -o json | \
  jq '.metadata.finalizers = []' | \
  kubectl replace --raw "/apis/argoproj.io/v1alpha1/namespaces/argo-events/eventbus/default" -f -

# Then delete
kubectl delete eventbus default -n argo-events
```

---

## Common Finalizers

| Resource | Finalizer | Purpose |
|----------|-----------|---------|
| EventBus | `eventbus-controller` | Cleanup NATS StatefulSet |
| EventSource | `eventsource-controller` | Cleanup event listener pods |
| Sensor | `sensor-controller` | Cleanup trigger pods |

---

## Prevent Future Issues

Before deleting, delete in reverse order:

```bash
# 1. Delete Sensors first (they depend on EventSource)
kubectl delete sensor --all -n argo-events

# 2. Delete EventSources (they depend on EventBus)
kubectl delete eventsource --all -n argo-events

# 3. Delete EventBus last
kubectl delete eventbus --all -n argo-events
```
