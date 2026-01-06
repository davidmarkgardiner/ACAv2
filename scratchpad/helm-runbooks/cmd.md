Here are the debug commands to run:

  # 1. Check if the ConfigMap exists
  kubectl get configmap my-custom-runbooks -n <namespace>

  # 2. See the actual volumes/mounts on the deployed pod
  kubectl get deployment <release-name>-holmes -n <namespace> -o yaml | grep -A 30 "volumes:"
  kubectl get deployment <release-name>-holmes -n <namespace> -o yaml | grep -A 20 "volumeMounts:"

  # 3. Check pod events for mount errors
  kubectl describe pod -l app=holmes -n <namespace> | grep -A 10 "Events:"

  # 4. Verify what values Helm is using
  helm get values <release-name> -n <namespace>

  # 5. Dry-run to see what would be rendered
  helm template <release-name> ./helm/holmes -f your-values.yaml | grep -A 30 "volumes:"

  # 6. Check if pod can see the mounted files
  kubectl exec -it $(kubectl get pod -l app=holmes -n <namespace> -o jsonpath='{.items[0].metadata.name}') -n <namespace> -- ls -la /etc/holmes/runbooks/

  The most likely issue: the ConfigMap my-custom-runbooks doesn't exist yet. Create it first:

  kubectl create configmap my-custom-runbooks \
    --from-file=runbooks.yaml=./my-runbooks.yaml \
    -n <namespace>
