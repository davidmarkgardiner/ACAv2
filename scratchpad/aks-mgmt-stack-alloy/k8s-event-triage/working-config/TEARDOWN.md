# Teardown — K8s Event Triage Pipeline

Clean removal of all pipeline components. Order matters — delete in reverse dependency order to avoid stuck finalizers.

## Quick Teardown (Full Stack)

```bash
# 1. Delete Sensor (stops new workflows from firing)
kubectl delete sensor k8s-event-triage -n argo-events --ignore-not-found

# 2. Delete EventSource (disconnects from Event Hub)
kubectl delete eventsource eventhub-k8s-events -n argo-events --ignore-not-found

# 3. Delete EventBus (must come AFTER EventSource — see Gotcha #7)
kubectl delete eventbus default -n argo-events --ignore-not-found

# 4. If EventBus stuck deleting (common), patch out the finalizer
kubectl patch eventbus default -n argo-events --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

# 5. Delete WorkflowTemplates
kubectl delete workflowtemplate k8s-event-triage -n argo-events --ignore-not-found
kubectl delete workflowtemplate k8s-event-triage-llm -n argo-events --ignore-not-found

# 6. Clean up any running/completed workflows
kubectl delete workflows --all -n argo-events

# 7. Delete RBAC
kubectl delete -f 06-rbac.yaml --ignore-not-found

# 8. Delete Alloy
kubectl delete deploy alloy -n monitoring --ignore-not-found
kubectl delete configmap alloy-config -n monitoring --ignore-not-found
kubectl delete sa alloy -n monitoring --ignore-not-found
kubectl delete clusterrole alloy --ignore-not-found
kubectl delete clusterrolebinding alloy --ignore-not-found
kubectl delete svc alloy -n monitoring --ignore-not-found

# 9. Delete secrets
kubectl delete secret alloy-eventhub -n monitoring --ignore-not-found
kubectl delete secret eventhub-credentials -n argo-events --ignore-not-found
kubectl delete secret eventhub-tls-ca -n argo-events --ignore-not-found
kubectl delete secret gitea-credentials -n argo-events --ignore-not-found

# 10. Clean up Fluent Bit remnants (if present from earlier wrong-collector deployment)
kubectl delete configmap fluent-bit-config -n monitoring --ignore-not-found
kubectl delete sa fluent-bit -n monitoring --ignore-not-found
kubectl delete ds fluent-bit -n monitoring --ignore-not-found
kubectl delete deploy fluent-bit -n monitoring --ignore-not-found

# 11. Clean up Ollama (if deployed for LLM triage testing)
kubectl delete deploy ollama -n monitoring --ignore-not-found
kubectl delete svc ollama -n monitoring --ignore-not-found
kubectl delete pvc ollama-data -n monitoring --ignore-not-found
kubectl delete secret eventhub-credentials -n monitoring --ignore-not-found
```

## Teardown Argo Events + Argo Workflows (Optional)

Only do this if you want to remove the entire Argo stack, not just the event triage pipeline.

```bash
# Argo Events (if installed via Helm)
helm uninstall argo-events -n argo-events

# Argo Events (if installed via kubectl apply)
kubectl delete -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml

# Argo Workflows
kubectl delete -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml

# If EventBus PVCs remain (JetStream only)
kubectl delete pvc -l app.kubernetes.io/name=eventbus-default-js -n argo-events
```

## Delete Namespaces (Optional)

Only if nothing else is using these namespaces:

```bash
kubectl delete namespace monitoring --ignore-not-found
kubectl delete namespace argo-events --ignore-not-found
kubectl delete namespace argo --ignore-not-found
```

**Warning:** Deleting namespaces removes EVERYTHING in them. Only do this if the namespaces were created solely for this pipeline.

## Verify Clean State

```bash
# Should return no resources
kubectl get eventbus,eventsource,sensor -n argo-events
kubectl get workflows -n argo-events
kubectl get pods -n argo-events
kubectl get pods -n monitoring -l app=alloy

# Check for orphaned PVCs (JetStream EventBus)
kubectl get pvc -n argo-events
```

## Troubleshooting Teardown

### EventBus stuck in "Terminating"

This happens when EventSource/Sensor still reference it. The controller loops with "can not delete an EventBus with N EventSources connected".

```bash
# Force-remove the finalizer
kubectl patch eventbus default -n argo-events --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

### Namespace stuck in "Terminating"

A namespace can get stuck if a CRD finalizer is blocking. Check:

```bash
kubectl get namespace argo-events -o json | jq '.status.conditions'
```

If it's waiting on a finalizer:

```bash
# Find what's blocking
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -n 1 kubectl get --show-kind --ignore-not-found -n argo-events

# If the blocking resource has a finalizer, patch it out
kubectl patch <resource> <name> -n argo-events --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

### Workflows won't delete

If workflows are stuck, force-delete:

```bash
kubectl delete workflows --all -n argo-events --force --grace-period=0
```

## Azure Resources (Not Managed by kubectl)

These live outside the cluster and need separate cleanup if no longer needed:

| Resource | How to Delete |
|----------|--------------|
| Event Hub topic (`k8s-events`) | Azure Portal or `az eventhubs eventhub delete` |
| Event Hub namespace | Azure Portal or `az eventhubs namespace delete` |
| Consumer groups | Deleted automatically with the topic |
| SAS keys | Deleted automatically with the namespace |

```bash
# Delete Event Hub topic only (keeps the namespace)
az eventhubs eventhub delete \
  --name k8s-events \
  --namespace-name REPLACE_EVENTHUB_NAMESPACE \
  --resource-group REPLACE_RESOURCE_GROUP

# Delete entire Event Hub namespace (deletes all topics, keys, consumer groups)
az eventhubs namespace delete \
  --name REPLACE_EVENTHUB_NAMESPACE \
  --resource-group REPLACE_RESOURCE_GROUP
```
