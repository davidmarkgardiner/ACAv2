# Custom Runbooks for Holmes Helm Installation

This example shows how to inject custom troubleshooting runbooks into Holmes when deploying via Helm, **without rebuilding the container image**.

## Features

- Custom runbooks for cert-manager and external-dns troubleshooting
- Token optimization settings (reduce ~60k tokens/request to ~15-25k)
- Fast model summarization using gpt-4o-mini
- Runtime injection via ConfigMaps
- Works with GitOps (ArgoCD / Flux)

## Included Runbooks

| Runbook | Description |
|---------|-------------|
| **external-dns-troubleshooting.md** | Diagnose external-dns not creating/updating DNS records in Route53, CloudFlare, Azure DNS, etc. |
| **cert-manager-troubleshooting.md** | Diagnose cert-manager certificate issuance failures, ACME challenges, and renewal issues |

## Files

```
helm-runbooks/
├── README.md                        # This file
├── runbooks-configmap.yaml          # ConfigMap with catalog.json + runbook markdown files
├── holmes-config-configmap.yaml     # ConfigMap with config.yaml referencing the runbooks
└── values.yaml                      # Helm values to mount both ConfigMaps
```

## Installation

### Step 1: Apply the ConfigMaps

```bash
# Create the runbooks ConfigMap (contains catalog.json + markdown files)
kubectl apply -f runbooks-configmap.yaml -n <namespace>

# Create the config ConfigMap (contains config.yaml that references runbooks)
kubectl apply -f holmes-config-configmap.yaml -n <namespace>
```

### Step 2: Install Holmes with Custom Values

```bash
helm upgrade --install holmes robusta/holmes \
  -n <namespace> \
  -f values.yaml \
  --set certificate="<your-robusta-certificate>"
```

Or combine with your existing values:

```bash
helm upgrade --install holmes robusta/holmes \
  -n <namespace> \
  -f your-existing-values.yaml \
  -f values.yaml
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Holmes Pod                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  /root/.holmes/config.yaml  ◄── holmes-config ConfigMap     │
│  │                                                           │
│  └── custom_runbook_catalogs:                               │
│        - /etc/holmes/runbooks/catalog.json                  │
│                      │                                       │
│                      ▼                                       │
│  /etc/holmes/runbooks/  ◄── holmes-custom-runbooks ConfigMap│
│  ├── catalog.json                                           │
│  ├── external-dns-troubleshooting.md                        │
│  └── cert-manager-troubleshooting.md                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### ConfigMaps

1. **`holmes-custom-runbooks`** (`runbooks-configmap.yaml`):
   - Contains `catalog.json` which lists available runbooks with descriptions
   - Contains the full markdown content of each runbook
   - Holmes LLM uses descriptions to match runbooks to user questions

2. **`holmes-config`** (`holmes-config-configmap.yaml`):
   - Contains `config.yaml` mounted at `/root/.holmes/config.yaml`
   - References the runbook catalog path
   - Holmes reads this on startup

3. **`values.yaml`**:
   - Mounts both ConfigMaps into the Holmes pod
   - Includes token optimization environment variables

## Token Optimization

The values.yaml includes settings to significantly reduce token usage:

| Setting | Default | Optimized | Effect |
|---------|---------|-----------|--------|
| `FAST_MODEL` | none | `gpt-4o-mini` | Summarizes large tool outputs (50-80% reduction) |
| `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_PCT` | 15% | 10% | Limits each tool response size |
| `TOOL_MAX_ALLOCATED_CONTEXT_WINDOW_TOKENS` | 25000 | 15000 | Caps max tokens per tool |
| `CONTEXT_WINDOW_COMPACTION_THRESHOLD_PCT` | 95% | 80% | Earlier context compaction |
| Disabled toolsets | all enabled | minimal | Smaller system prompt |

**Expected result**: Token usage drops from ~60k to ~15-25k per request.

## Testing

After installation, ask Holmes questions like:

```bash
# Test external-dns runbook
holmes ask "Why is external-dns not creating DNS records for my service?"

# Test cert-manager runbook
holmes ask "My certificate is stuck in pending state, why?"
```

Holmes will automatically select and follow the appropriate runbook based on the description match.

## Adding More Runbooks

1. **Add markdown content** to `runbooks-configmap.yaml` in the `data:` section

2. **Add catalog entry** to the `catalog.json` section:
   ```json
   {
     "id": "my-new-runbook.md",
     "update_date": "2026-01-05",
     "description": "Clear description for LLM matching",
     "link": "my-new-runbook.md"
   }
   ```

3. **Re-apply and restart**:
   ```bash
   kubectl apply -f runbooks-configmap.yaml -n <namespace>
   kubectl rollout restart deployment/<holmes-deployment> -n <namespace>
   ```

## Best Practices

- **Version runbooks in Git** and deploy via Helm/GitOps
- **Restart pods after updates** - ConfigMap changes aren't auto-reloaded
- **Use descriptive catalog descriptions** - the LLM uses these to match user questions
- **One ConfigMap per team** if different teams own different runbooks
- **Test runbooks** by asking questions that should trigger them

## Troubleshooting

### Runbooks not being picked up?

1. Verify ConfigMaps are created:
   ```bash
   kubectl get configmap holmes-custom-runbooks -n <namespace>
   kubectl get configmap holmes-config -n <namespace>
   ```

2. Check the mounts inside the pod:
   ```bash
   kubectl exec -it <holmes-pod> -n <namespace> -- ls -la /etc/holmes/runbooks/
   kubectl exec -it <holmes-pod> -n <namespace> -- cat /root/.holmes/config.yaml
   ```

3. Check Holmes logs for config loading:
   ```bash
   kubectl logs <holmes-pod> -n <namespace> | grep -i runbook
   ```

### Pod not starting?

Check for volume mount errors:
```bash
kubectl describe pod <holmes-pod> -n <namespace>
```
