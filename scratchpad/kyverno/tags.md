Great question - this is a common pattern for CMDB traceability and cost attribution. The answer is **both**, but in a clean way:

## What Kyverno Can Do Natively

**Namespace → Deployment injection**: Kyverno handles this elegantly. You can use a `mutate` policy with context to pull namespace labels/annotations and inject them:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-cmdb-from-namespace
spec:
  rules:
    - name: inject-cmdb-labels
      match:
        any:
          - resources:
              kinds:
                - Deployment
      context:
        - name: namespaceLabels
          apiCall:
            urlPath: "/api/v1/namespaces/{{request.namespace}}"
            jmesPath: "metadata.labels"
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              cmdb-app-id: "{{ namespaceLabels.\"cmdb-app-id\" || 'unknown' }}"
              cost-centre: "{{ namespaceLabels.\"cost-centre\" || 'unknown' }}"
          spec:
            template:
              metadata:
                labels:
                  cmdb-app-id: "{{ namespaceLabels.\"cmdb-app-id\" || 'unknown' }}"
```

## What Kyverno Can't Do

**AKS cluster tags** - these live in ARM, not the Kubernetes API. Kyverno can only see what's inside the cluster, not Azure resource metadata.

## The Hybrid Approach

You need a lightweight sync job to bridge Azure → Kubernetes, then Kyverno takes over:

```yaml
# 1. CronJob to sync AKS tags to a ConfigMap
apiVersion: batch/v1
kind: CronJob
metadata:
  name: sync-aks-tags
  namespace: platform-system
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: aks-tag-syncer
          containers:
            - name: sync
              image: mcr.microsoft.com/azure-cli:latest
              command:
                - /bin/bash
                - -c
                - |
                  # Get cluster tags using managed identity
                  TAGS=$(az aks show \
                    --resource-group ${CLUSTER_RG} \
                    --name ${CLUSTER_NAME} \
                    --query tags -o json)
                  
                  # Update ConfigMap
                  kubectl create configmap cluster-tags \
                    --from-literal=tags="${TAGS}" \
                    --dry-run=client -o yaml | kubectl apply -f -
              env:
                - name: CLUSTER_RG
                  value: "your-rg"
                - name: CLUSTER_NAME
                  value: "your-cluster"
          restartPolicy: OnFailure
```

```yaml
# 2. Kyverno policy combining both sources
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-cmdb-and-cluster-tags
spec:
  rules:
    - name: inject-all-metadata
      match:
        any:
          - resources:
              kinds:
                - Deployment
      context:
        - name: nsLabels
          apiCall:
            urlPath: "/api/v1/namespaces/{{request.namespace}}"
            jmesPath: "metadata.labels"
        - name: clusterTags
          configMap:
            name: cluster-tags
            namespace: platform-system
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              cmdb-app-id: "{{ nsLabels.\"cmdb-app-id\" || 'unknown' }}"
              cluster-environment: "{{ clusterTags.data.environment || 'unknown' }}"
              cluster-cost-centre: "{{ clusterTags.data.\"cost-centre\" || 'unknown' }}"
```

## Do You Need Reloader?

**Probably not** for this use case:

| Scenario | Reloader Needed? |
|----------|------------------|
| New deployments pick up current tags | No - Kyverno mutates on admission |
| Existing deployments update when tags change | Yes - or use Kyverno's `mutateExisting` |
| You want pod restarts on tag changes | Yes |

If you want existing workloads to update when cluster tags change, Kyverno's `mutateExisting: true` can handle that without Reloader - it'll patch existing resources when the policy triggers.

## Recommendation

1. **Sync job** (CronJob or Argo CronWorkflow) to pull AKS tags → ConfigMap
2. **Single Kyverno policy** that combines namespace CMDB data + cluster tags ConfigMap
3. **Skip Reloader** - use `mutateExisting` if you need retroactive updates

This keeps your GitOps clean - the sync job is declarative, and all the injection logic stays in Kyverno policies. Want me to flesh out a more complete example with the workload identity setup for the Azure CLI calls?