# Custom Runbooks for Holmes Helm Installation

This example shows how to inject custom troubleshooting runbooks into Holmes when deploying via Helm, with **token optimization** settings to reduce API costs.

## Features

- Custom runbooks for cert-manager and external-dns troubleshooting
- Token optimization settings (reduce ~60k tokens/request to ~15-25k)
- Fast model summarization using gpt-4o-mini
- Minimal toolset configuration

## Included Runbooks

| Runbook | Description |
|---------|-------------|
| **external-dns-troubleshooting.md** | Diagnose external-dns not creating/updating DNS records in Route53, CloudFlare, Azure DNS, etc. |
| **cert-manager-troubleshooting.md** | Diagnose cert-manager certificate issuance failures, ACME challenges, and renewal issues |

## Installation

### Step 1: Apply the ConfigMap

```bash
kubectl apply -f runbooks-configmap.yaml -n <your-namespace>
```

### Step 2: Install Holmes with Custom Values

```bash
helm upgrade --install holmes robusta/holmes \
  -n <your-namespace> \
  -f values.yaml \
  --set certificate="<your-robusta-certificate>"
```

Or combine with your existing values:

```bash
helm upgrade --install holmes robusta/holmes \
  -n <your-namespace> \
  -f your-existing-values.yaml \
  -f values.yaml
```

## How It Works

1. **ConfigMap** (`runbooks-configmap.yaml`):
   - Contains `catalog.json` which lists available runbooks with descriptions
   - Contains the full markdown content of each runbook
   - Holmes uses descriptions to match runbooks to user questions

2. **Values** (`values.yaml`):
   - Mounts the ConfigMap at `/etc/holmes/runbooks`
   - Sets `CUSTOM_RUNBOOK_CATALOGS` env var to point to the catalog
   - Includes token optimization settings

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

Holmes will automatically select and follow the appropriate runbook.

## Adding More Runbooks

1. Add your markdown runbook content to `runbooks-configmap.yaml` in the `data:` section
2. Add an entry to `catalog.json` with:
   - `id`: Unique identifier (usually the filename)
   - `description`: Clear description (used by LLM to match to questions)
   - `link`: Filename in the same ConfigMap
3. Re-apply the ConfigMap and restart Holmes pods

## File Structure

```
helm-runbooks/
├── README.md                    # This file
├── runbooks-configmap.yaml      # ConfigMap with catalog + runbook content
└── values.yaml                  # Helm values to mount runbooks
```
