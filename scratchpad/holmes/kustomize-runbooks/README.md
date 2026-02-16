# Custom Runbooks with Kustomize + Reloader

Deploy custom troubleshooting runbooks to Holmes using Kustomize `configMapGenerator` and [Reloader](https://github.com/stakater/Reloader) for automatic restarts on changes.

## How It Works

1. Kustomize generates ConfigMaps from your `catalog.json` and `.md` runbook files
2. Holmes loads the catalog at startup and makes runbooks available to the LLM
3. Reloader watches for ConfigMap changes and triggers a rolling restart so Holmes picks up new runbooks

## Directory Structure

```
kustomize-runbooks/
├── kustomization.yaml
├── config.yaml                  # Holmes config pointing to catalog
├── catalog.json                 # Index of available runbooks
├── dns-troubleshooting.md       # Example runbook
└── deployment-patch.yaml        # Patch for volumes + Reloader annotation
```

## Setup

### 1. Create your runbook files

Write markdown runbooks following the structure in `examples/custom_runbook_catalog/example_troubleshooting.md`. Each runbook should have:

- **Goal** - What issues it addresses
- **Workflow** - Step-by-step diagnostic procedure
- **Synthesize Findings** - How to interpret results
- **Recommended Remediation** - Solutions based on findings

### 2. Register runbooks in catalog.json

Every runbook must be listed in `catalog.json`. The `description` field is what the LLM uses to decide which runbook to fetch, so make it descriptive:

```json
{
  "catalog": [
    {
      "id": "dns-troubleshooting",
      "update_date": "2026-02-16",
      "description": "Troubleshooting DNS resolution and CoreDNS issues in Kubernetes clusters",
      "link": "dns-troubleshooting.md"
    }
  ]
}
```

All four fields are required:

| Field | Description |
|-------|-------------|
| `id` | Unique identifier for the runbook |
| `update_date` | Last updated date (YYYY-MM-DD) |
| `description` | Description used by the LLM to match runbook to issues |
| `link` | Path to the markdown file, relative to catalog.json |

### 3. Add to kustomization.yaml

```yaml
configMapGenerator:
  - name: holmes-custom-runbooks
    files:
      - catalog.json
      - dns-troubleshooting.md
      # Add more runbook files here

  - name: holmes-config
    files:
      - config.yaml
```

### 4. Create config.yaml

```yaml
custom_runbook_catalogs:
  - /etc/holmes/runbooks/catalog.json
```

### 5. Patch the Holmes deployment

Add volume mounts and Reloader annotation via `deployment-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmes
  annotations:
    configmap.reloader.stakater.com/reload: "holmes-custom-runbooks,holmes-config"
spec:
  template:
    spec:
      volumes:
        - name: custom-runbooks
          configMap:
            name: holmes-custom-runbooks
        - name: holmes-config
          configMap:
            name: holmes-config
      containers:
        - name: holmes
          volumeMounts:
            - name: custom-runbooks
              mountPath: /etc/holmes/runbooks
              readOnly: true
            - name: holmes-config
              mountPath: /root/.holmes/config.yaml
              subPath: config.yaml
              readOnly: true
```

Include the patch in your `kustomization.yaml`:

```yaml
patches:
  - path: deployment-patch.yaml
```

## Adding a New Runbook

```bash
# 1. Create the markdown file
vim my-new-runbook.md

# 2. Add entry to catalog.json
# 3. Add filename to kustomization.yaml configMapGenerator files list
# 4. Apply
kubectl apply -k .
# Reloader detects the ConfigMap change and restarts Holmes automatically
```

## Multiple Teams / Catalogs

If different teams manage their own runbooks, use separate catalogs mounted at different paths:

```yaml
# config.yaml
custom_runbook_catalogs:
  - /etc/holmes/runbooks/team-a/catalog.json
  - /etc/holmes/runbooks/team-b/catalog.json
```

Each catalog's directory is used as the search path for its `link` entries, so teams can manage their files independently.

## Troubleshooting

```bash
# Verify files are mounted in the pod
kubectl exec -it <holmes-pod> -- ls -la /etc/holmes/runbooks/

# Verify config is mounted
kubectl exec -it <holmes-pod> -- cat /root/.holmes/config.yaml

# Check Holmes logs for catalog loading errors
kubectl logs <holmes-pod> | grep -i runbook

# Verify Reloader is watching the deployment
kubectl get deployment holmes -o jsonpath='{.metadata.annotations}'
```

## Key Notes

- Holmes loads runbooks **once at startup** -- pod restart is required after changes (Reloader handles this)
- The `link` path in catalog.json is resolved relative to the **directory containing catalog.json**
- Kustomize appends a hash suffix to ConfigMap names and automatically updates volume references
- Missing runbook files are logged as errors but don't crash Holmes
