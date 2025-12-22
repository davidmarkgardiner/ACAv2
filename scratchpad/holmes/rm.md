Yep, for the CLI approach you don't need port-forwarding - it just uses your kubeconfig directly.

For in-cluster deployment, if you want to interact with the Holmes server:

```bash
# Find the Holmes pod
kubectl get pods -n robusta -l app=holmes

# Port-forward to the Holmes server (default port 8080)
kubectl port-forward -n robusta svc/holmes 8080:8080

# Then you can hit the API
curl http://localhost:8080/api/investigate -X POST \
  -H "Content-Type: application/json" \
  -d '{"prompt": "what pods are unhealthy?"}'
```

Or if you just want to exec into the pod and run CLI commands:

```bash
kubectl exec -it -n robusta deploy/holmes -- holmes ask "what's wrong with my cluster?"
```

For **Robusta SaaS** (the most polished experience), you don't port-forward at all - you just log into [platform.robusta.dev](https://platform.robusta.dev) and use the web UI. Alerts get investigated automatically and you can click "Root Cause" on any alert.

Which deployment method are you going with?