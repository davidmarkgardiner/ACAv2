# HolmesGPT Custom Runbooks Guide

Upload your own custom runbooks to HolmesGPT via the Helm chart to guide AI-powered troubleshooting for organization-specific scenarios.

## Overview

Custom runbooks allow you to:
- Define step-by-step investigation procedures for known issues
- Provide organization-specific commands and checks
- Guide Holmes through your unique infrastructure patterns
- Include company-specific fix recommendations

## Quick Start

### 1. Create Your Runbook Files

Create a directory structure for your runbooks:

```bash
mkdir -p runbooks/
```

Create a runbook file (e.g., `runbooks/my-app-crash.md`):

```markdown
# MyApp Crash Troubleshooting

Application crashes during startup or runtime.

## Investigation Steps

1. **Check application logs**
   ```bash
   kubectl logs POD_NAME -n NAMESPACE --tail=100
   kubectl logs POD_NAME -n NAMESPACE --previous
   ```
   - Look for connection errors to database
   - Check for missing configuration
   - Identify startup failures

2. **Verify ConfigMap values**
   ```bash
   kubectl get configmap myapp-config -n NAMESPACE -o yaml
   ```
   - Ensure DATABASE_URL is set correctly
   - Verify API keys are present

3. **Check secrets**
   ```bash
   kubectl get secret myapp-secrets -n NAMESPACE
   ```
   - Confirm all required secrets exist

## Common Fixes

**Fix 1: Missing database connection**
```bash
kubectl set env deployment/myapp DATABASE_URL=postgresql://db:5432/myapp
```

**Fix 2: Restart with fresh config**
```bash
kubectl rollout restart deployment/myapp -n NAMESPACE
```

## Expected Resolution

Pod should transition to Running state. Logs show successful database connection.
```

### 2. Create the Catalog File

Create `runbooks/catalog.json` to index your runbooks:

```json
{
  "catalog": [
    {
      "id": "my-app-crash",
      "update_date": "2025-01-05",
      "description": "Troubleshoot MyApp crashes including database connection failures, missing configuration, and startup issues",
      "link": "my-app-crash.md"
    },
    {
      "id": "redis-connection-timeout",
      "update_date": "2025-01-05",
      "description": "Diagnose Redis connection timeouts and cache failures",
      "link": "redis-connection.md"
    }
  ]
}
```

### 3. Create a ConfigMap

Package your runbooks into a Kubernetes ConfigMap:

```bash
# Create ConfigMap from runbook files
kubectl create configmap holmes-runbooks \
  --from-file=catalog.json=runbooks/catalog.json \
  --from-file=my-app-crash.md=runbooks/my-app-crash.md \
  --from-file=redis-connection.md=runbooks/redis-connection.md \
  -n holmes
```

Or use a YAML manifest:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-runbooks
  namespace: holmes
data:
  catalog.json: |
    {
      "catalog": [
        {
          "id": "my-app-crash",
          "update_date": "2025-01-05",
          "description": "Troubleshoot MyApp crashes including database connection failures",
          "link": "my-app-crash.md"
        }
      ]
    }
  my-app-crash.md: |
    # MyApp Crash Troubleshooting

    Application crashes during startup or runtime.

    ## Investigation Steps

    1. **Check application logs**
       ```bash
       kubectl logs POD_NAME -n NAMESPACE --tail=100
       ```

    ## Common Fixes

    **Fix 1: Restart deployment**
    ```bash
    kubectl rollout restart deployment/myapp
    ```

    ## Expected Resolution

    Pod transitions to Running state.
```

### 4. Configure Helm Values

Add the following to your Helm values file:

```yaml
# Custom runbook configuration
custom_runbook_catalogs:
  - "/runbooks/catalog.json"

# Mount the ConfigMap as a volume
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-runbooks

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /runbooks
```

### 5. Deploy Holmes

```bash
# Apply the ConfigMap first
kubectl apply -f holmes-runbooks-configmap.yaml

# Install/upgrade Holmes with custom values
helm upgrade --install holmes holmesgpt/holmesgpt \
  -n holmes \
  -f helm-values.yaml
```

## Complete Helm Values Example

```yaml
# helm-values-with-runbooks.yaml

image: holmes
registry: us-central1-docker.pkg.dev/genuine-flight-317411/devel
replicas: 1

enableServiceLinks: false

# LLM Configuration
modelList:
  - model_name: gpt-4o-mini
    litellm_params:
      model: gpt-4o-mini
      api_base: http://litellm.litellm.svc.cluster.local:4000

# MCP Server Integration
toolsets:
  kubernetes/core:
    enabled: false
  kubernetes/logs:
    enabled: false

mcp_servers:
  aks-mcp:
    description: "AKS cluster operations"
    config:
      mode: streamable-http
      url: http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp
    llm_instructions: |
      Use kubectl_get, kubectl_describe, kubectl_logs for investigations.

# Environment Variables
additionalEnvVars:
  - name: OPENAI_API_KEY
    value: "sk-litellm-proxy"
  - name: OPENAI_API_BASE
    value: "http://litellm.litellm.svc.cluster.local:4000"

# ================================================
# CUSTOM RUNBOOKS CONFIGURATION
# ================================================

# Path to custom runbook catalog(s)
custom_runbook_catalogs:
  - "/runbooks/catalog.json"

# Mount ConfigMap containing runbooks
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-runbooks

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /runbooks
    readOnly: true

# ================================================

# Health Probes
livenessProbe:
  tcpSocket:
    port: 5050
  initialDelaySeconds: 30
  periodSeconds: 30

readinessProbe:
  tcpSocket:
    port: 5050
  initialDelaySeconds: 10
  periodSeconds: 10

# Resources
resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    memory: 2Gi
```

## Runbook Catalog Structure

The `catalog.json` file indexes all your runbooks:

| Field | Description | Example |
|-------|-------------|---------|
| `id` | Unique identifier for the runbook | `"my-app-crash"` |
| `update_date` | Last update date (YYYY-MM-DD) | `"2025-01-05"` |
| `description` | Detailed description for LLM matching | `"Troubleshoot database connection failures..."` |
| `link` | Relative path to runbook markdown file | `"my-app-crash.md"` |

**Important**: The `description` field is used by Holmes to match runbooks to issues. Make it descriptive and include relevant keywords.

## Runbook Markdown Structure

Each runbook should follow this structure:

```markdown
# [Issue Title]

[Brief description of the issue - 1-2 sentences]

## Investigation Steps

1. **[Step Name]**
   ```bash
   # Diagnostic command
   kubectl get pods -n NAMESPACE
   ```
   - What to look for in output
   - Red flags to identify

2. **[Next Step]**
   ...

## Common Fixes

**Fix 1: [Description]**
```bash
# Fix command
kubectl set image deployment/app container=image:v2
```
- When to use this fix
- Expected outcome

**Fix 2: [Alternative fix]**
...

## Expected Resolution

[Description of successful outcome and verification steps]
```

## Multiple Runbook Catalogs

You can configure multiple catalogs from different sources:

```yaml
custom_runbook_catalogs:
  - "/runbooks/core/catalog.json"      # Core platform runbooks
  - "/runbooks/apps/catalog.json"      # Application-specific runbooks
  - "/runbooks/security/catalog.json"  # Security incident runbooks

additionalVolumes:
  - name: core-runbooks
    configMap:
      name: holmes-runbooks-core
  - name: app-runbooks
    configMap:
      name: holmes-runbooks-apps
  - name: security-runbooks
    configMap:
      name: holmes-runbooks-security

additionalVolumeMounts:
  - name: core-runbooks
    mountPath: /runbooks/core
  - name: app-runbooks
    mountPath: /runbooks/apps
  - name: security-runbooks
    mountPath: /runbooks/security
```

## Using Secrets in Runbooks

For runbooks that need access to sensitive data (like API endpoints):

```yaml
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-runbooks
  - name: runbook-secrets
    secret:
      secretName: holmes-runbook-secrets

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /runbooks
  - name: runbook-secrets
    mountPath: /runbooks/secrets
    readOnly: true
```

## Verification

### 1. Check ConfigMap is created

```bash
kubectl get configmap holmes-runbooks -n holmes -o yaml
```

### 2. Verify volume mount

```bash
kubectl exec -n holmes deploy/holmes-holmes -- ls -la /runbooks/
```

Expected output:
```
catalog.json
my-app-crash.md
redis-connection.md
```

### 3. Check Holmes loaded runbooks

```bash
kubectl logs -n holmes deploy/holmes-holmes | grep -i "runbook\|catalog"
```

### 4. Test runbook matching

```bash
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "MyApp crash",
    "description": "MyApp pod is crashing with database connection error",
    "subject": {"name": "myapp", "namespace": "production"},
    "context": {}
  }'
```

## Updating Runbooks

### Option 1: Update ConfigMap (requires pod restart)

```bash
# Update ConfigMap
kubectl create configmap holmes-runbooks \
  --from-file=catalog.json=runbooks/catalog.json \
  --from-file=my-app-crash.md=runbooks/my-app-crash.md \
  -n holmes \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Holmes to pick up changes
kubectl rollout restart deployment/holmes-holmes -n holmes
```

### Option 2: Use GitOps (recommended)

Store runbooks in Git and use ArgoCD/Flux to sync:

```yaml
# argocd-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: holmes-runbooks
spec:
  source:
    repoURL: https://github.com/your-org/runbooks.git
    path: kubernetes/
  destination:
    namespace: holmes
```

## Troubleshooting

### Runbooks not loading

1. Check volume mount:
   ```bash
   kubectl exec -n holmes deploy/holmes-holmes -- cat /runbooks/catalog.json
   ```

2. Verify catalog.json format (must be valid JSON):
   ```bash
   kubectl get cm holmes-runbooks -n holmes -o jsonpath='{.data.catalog\.json}' | jq .
   ```

3. Check file paths in catalog match actual files:
   ```bash
   kubectl exec -n holmes deploy/holmes-holmes -- ls /runbooks/
   ```

### Holmes not matching runbooks

1. Improve `description` field with more keywords
2. Test with explicit issue description matching runbook
3. Check Holmes logs for runbook selection:
   ```bash
   kubectl logs -n holmes deploy/holmes-holmes | grep -i "runbook"
   ```

## Best Practices

1. **Write descriptive catalog entries** - The description is how Holmes matches issues to runbooks
2. **Include specific commands** - Don't just describe, provide exact kubectl commands
3. **Cover multiple scenarios** - Each runbook should handle common variations
4. **Keep runbooks updated** - Update `update_date` when making changes
5. **Version control runbooks** - Store in Git for history and review
6. **Test before deploying** - Verify runbooks work with Holmes locally first
7. **Organize by category** - Use directories for different issue types

## Example Runbooks Library

See the following example runbooks in the `references/runbook-examples.md` file:

- ImagePullBackOff
- CrashLoopBackOff
- OOMKilled
- Pending Pods
- Service Connectivity

Use these as templates for creating your organization-specific runbooks.
