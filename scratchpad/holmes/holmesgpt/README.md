# HolmesGPT KRO Deployment

Deploy HolmesGPT as an AI-powered Kubernetes troubleshooting platform using KRO (Kubernetes Resource Orchestrator).

## Related AI Stack Components

This is part of the AI Operations stack. All KRO definitions are grouped in `ai-stack/`:

| Component | File | Description |
|-----------|------|-------------|
| **LiteLLM** | `ai-stack/uk8s-litellm.yaml` | AI gateway ResourceGraphDefinition |
| **LiteLLM Instance** | `ai-stack/example-litellm-instance.yaml` | Example instance |
| **AKS-MCP** | `ai-stack/uk8s-aks-mcp.yaml` | MCP server for kubectl/helm/az CLI |
| **AKS-MCP Instance** | `ai-stack/example-aks-mcp.yaml` | Example instance |
| **HolmesGPT** | `resourcegroup-updated.yaml` | AI troubleshooting agent |

**Deployment order:** LiteLLM → AKS-MCP → HolmesGPT

```
k8s/holmesgpt/
├── ai-stack/                        # Related AI stack KRO definitions
│   ├── uk8s-litellm.yaml            # LiteLLM RGD
│   ├── example-litellm-instance.yaml
│   ├── uk8s-aks-mcp.yaml            # AKS-MCP RGD
│   └── example-aks-mcp.yaml         # AKS-MCP instance
├── resourcegroup-updated.yaml       # HolmesGPT RGD
├── instance-updated.yaml            # HolmesGPT instance
└── README.md
```

## Architecture

```
Holmes Pod → LiteLLM Gateway → Azure OpenAI (via UAMI)
     ↓
Custom Runbooks (cert-manager, external-dns)
```

## Files

| File | Description |
|------|-------------|
| `resourcegroup-updated.yaml` | KRO ResourceGraphDefinition (production) |
| `instance-updated.yaml` | Instance template for production |
| `instance-test.yaml` | Test instance for validation |
| `resourcegroup.yaml` | Original RGD (reference only) |
| `instance.yaml` | Original instance (reference only) |

## Quick Start

### 1. Apply the ResourceGraphDefinition

```bash
kubectl apply -f k8s/holmesgpt/resourcegroup-updated.yaml
```

### 2. Verify RGD is Active

```bash
kubectl get resourcegraphdefinition holmes
# STATE should be "Active"
```

### 3. Deploy Holmes Instance

Edit `instance-updated.yaml` with your LiteLLM URL, then:

```bash
kubectl apply -f k8s/holmesgpt/instance-updated.yaml
```

### 4. Verify Deployment

```bash
kubectl get holmes -n kro
kubectl get pods -n holmesgpt
kubectl logs -n holmesgpt deployment/holmesgpt-holmes
```

## Configuration

### LLM Settings

Holmes connects to Azure OpenAI via LiteLLM gateway (no API keys needed - uses UAMI):

```yaml
spec:
  llm:
    model: gpt-4o
    litellmBaseUrl: http://litellm.litellm.svc.cluster.local:4000
```

### Environment Variables Set

| Variable | Value | Purpose |
|----------|-------|---------|
| `OPENAI_API_KEY` | `sk-litellm-proxy` | Placeholder for LiteLLM |
| `OPENAI_API_BASE` | LiteLLM URL | Gateway endpoint |
| `MODEL` | `gpt-4o` | Model to use |
| `LITELLM_BASE_URL` | LiteLLM URL | LiteLLM endpoint |

### Toolsets

| Toolset | Enabled | Description |
|---------|---------|-------------|
| `kubernetes/core` | true | K8s resource queries |
| `kubernetes/logs` | true | Pod log access |
| `internet` | true | Web search |
| `prometheus/metrics` | false | Prometheus queries |
| `robusta` | false | Robusta integration |

### Custom Runbooks

Two runbooks are included:

1. **external-dns.yaml** - Diagnose DNS record creation issues
   - Matches: `ExternalDNS`, `external-dns`, `DNS.*not.*creat`, `DNS.*record`

2. **cert-manager.yaml** - Diagnose certificate issuance issues
   - Matches: `Certificate`, `cert-manager`, `TLS`, `ACME`, `Let.*Encrypt`
   - Also handles webhook connectivity issues

## Resources Created

The RGD creates these resources per instance:

- Namespace
- ServiceAccount (with Workload Identity labels)
- ClusterRole (read-only K8s access)
- ClusterRoleBinding
- ConfigMap: `custom-toolsets-configmap` (toolsets + model config)
- ConfigMap: `holmes-config` (main config with runbook paths)
- ConfigMap: `holmes-custom-runbooks` (runbook definitions)
- Deployment
- Service (port 80 → 5050)

## Testing

### Deploy Test Instance

```bash
kubectl apply -f k8s/holmesgpt/instance-test.yaml
kubectl get pods -n holmes-test
kubectl logs -n holmes-test deployment/holmes-test-holmes
```

### Verify Runbooks Loaded

```bash
kubectl exec -n holmes-test deployment/holmes-test-holmes -- \
  cat /root/.holmes/config.yaml

kubectl exec -n holmes-test deployment/holmes-test-holmes -- \
  ls /etc/holmes/runbooks/
```

### Test API

```bash
kubectl exec -n holmes-test deployment/holmes-test-holmes -- \
  curl -s http://localhost:5050/healthz
# {"status":"healthy"}
```

### Cleanup Test

```bash
kubectl delete holmes holmes-test -n kro
kubectl delete ns holmes-test
```

## Troubleshooting

### Pod CrashLoopBackOff

Check logs for model validation errors:
```bash
kubectl logs -n holmesgpt deployment/holmesgpt-holmes
```

Common fix: Ensure `model_list.yaml` in ConfigMap is `{}` (empty) when using LiteLLM.

### Runbooks Not Loading

Verify config file mount:
```bash
kubectl exec -n holmesgpt deployment/holmesgpt-holmes -- \
  cat /root/.holmes/config.yaml
```

Verify runbook files exist:
```bash
kubectl exec -n holmesgpt deployment/holmesgpt-holmes -- \
  ls -la /etc/holmes/runbooks/
```

### LiteLLM Connection Issues

Test connectivity from Holmes pod:
```bash
kubectl exec -n holmesgpt deployment/holmesgpt-holmes -- \
  curl -s http://litellm.litellm.svc.cluster.local:4000/health
```

## Adding Custom Runbooks

1. Edit `resourcegroup-updated.yaml`, add to `runbooksconfigmap`:

```yaml
data:
  my-runbook.yaml: |
    runbooks:
      - match:
          issue_name: "(MyApp)|(my-app)"
        instructions: >
          Troubleshooting steps here...
```

2. Update `configconfigmap` to include the new runbook path:

```yaml
custom_runbooks:
  - /etc/holmes/runbooks/external-dns.yaml
  - /etc/holmes/runbooks/cert-manager.yaml
  - /etc/holmes/runbooks/my-runbook.yaml
```

3. Re-apply the RGD and restart the deployment.
