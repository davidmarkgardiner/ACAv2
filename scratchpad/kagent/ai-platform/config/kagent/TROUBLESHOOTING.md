# kagent Troubleshooting Guide

## "Failed to create MCP session" / "Errors in Task Group"

This error occurs when the agent pod cannot establish a connection to the MCP tool server. Common causes: RBAC permissions, network policies, or tool server not running.

### Step 1: Check agent pod logs

```bash
# Replace k8s-agent with the agent name that's failing
kubectl logs -n kagent deploy/k8s-agent --tail=50
```

Look for connection refused, timeout, or permission errors.

### Step 2: Check tool server is healthy

```bash
kubectl get pods -n kagent | grep tools
kubectl logs -n kagent deploy/kagent-tools --tail=30
```

The tool server pod should be `1/1 Running`. Check logs for startup errors or K8s API auth failures.

### Step 3: Check RemoteMCPServer CRD status

```bash
kubectl describe remotemcpserver kagent-tool-server -n kagent
```

Look for:
- `Accepted: True` = good
- `Accepted: False` = check the `Message` field in conditions for the actual error

### Step 4: Test network connectivity from agent to tool server

```bash
kubectl run curl-test --rm -it --restart=Never \
  --image=curlimages/curl -n kagent -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://kagent-tools.kagent:8084/mcp \
  -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"test"}}}'
```

- `200` = tool server is reachable and responding
- Connection refused / timeout = network policy or pod not running
- `403` / `401` = auth issue

### Step 5: Check RBAC

```bash
# Check ClusterRoleBindings for kagent
kubectl get clusterrolebinding | grep kagent

# Check ServiceAccounts in kagent namespace
kubectl get serviceaccount -n kagent

# Check what permissions the tool server SA has
kubectl auth can-i list pods --as=system:serviceaccount:kagent:kagent-tools -n default
kubectl auth can-i get nodes --as=system:serviceaccount:kagent:kagent-tools
```

The tool server needs cluster-wide read access to K8s resources. In enterprise/AKS environments, Azure Policy or OPA/Gatekeeper may block the ClusterRole creation.

### Step 6: Check if Azure Policy / Gatekeeper is blocking

```bash
# Check for constraint violations
kubectl get constraints -A 2>/dev/null
kubectl get k8sazurev1blockdefault -A 2>/dev/null

# Check for denied events
kubectl get events -n kagent --field-selector reason=FailedCreate --sort-by='.lastTimestamp'
```

### Step 7: Check the controller logs

```bash
kubectl logs -n kagent deploy/kagent-controller --tail=50
```

The controller reconciles Agent CRDs into deployments. Check for errors creating pods or services.

---

## Model Errors (400 / Invalid model name)

```
Error code: 400 - Invalid model name passed in model=xxx
```

The ModelConfig references a model name that doesn't exist in LiteLLM.

```bash
# Check what models LiteLLM knows about
kubectl run curl-test --rm -it --restart=Never \
  --image=curlimages/curl -n kagent -- \
  curl -s http://litellm.litellm.svc:4000/v1/models \
  -H "Authorization: Bearer YOUR_LITELLM_KEY"

# Check what ModelConfig the agent is using
kubectl get agents -n kagent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.declarative.modelConfig}{"\n"}{end}'

# Check the ModelConfig
kubectl get modelconfig -n kagent
```

Fix: Update the ModelConfig CRD to match a model name that LiteLLM serves.

---

## Agent "thinking" forever / Slow responses

### Check if prompt is being truncated

```bash
# Check the model pod logs for truncation warnings
kubectl logs -n kubeai $(kubectl get pods -n kubeai -l app.kubernetes.io/component=model -o name | head -1) --tail=20
```

Look for: `truncating input prompt limit=4096 prompt=15000`

Fix: Increase the model context window. For Ollama models, set `OLLAMA_NUM_CTX`:

```yaml
# In the KubeAI Model CR
spec:
  env:
    OLLAMA_NUM_CTX: "16384"
```

### Check if model is overloaded

```bash
kubectl top pod -n kubeai
```

---

## Grafana MCP errors

### "no Host in request URL"

The `GRAFANA_URL` is wrong. Check the configmap:

```bash
kubectl get configmap kagent-grafana-mcp -n kagent -o jsonpath='{.data.GRAFANA_URL}'
```

Should be `http://grafana-service.namespace.svc:port` (no trailing `/api`).

### "failed to list datasources: 404"

The URL has `/api` appended — the Grafana MCP server adds `/api` itself. Remove it from your URL.

### "failed to discover MCP datasources" (datasources=0)

This is informational, not an error. It means no Grafana datasources have MCP proxying configured. The agent can still use dashboard/alert/search tools.

---

## Quick health check

Run this to get a full status overview:

```bash
echo "=== Pods ===" && \
kubectl get pods -n kagent && \
echo -e "\n=== Agents ===" && \
kubectl get agents -n kagent && \
echo -e "\n=== ModelConfigs ===" && \
kubectl get modelconfig -n kagent && \
echo -e "\n=== RemoteMCPServers ===" && \
kubectl get remotemcpservers -n kagent && \
echo -e "\n=== Recent Events ===" && \
kubectl get events -n kagent --sort-by='.lastTimestamp' | tail -10
```
