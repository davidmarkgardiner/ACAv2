# HolmesGPT Custom Runbooks Guide

Upload your own custom runbooks to HolmesGPT via the Helm chart to guide AI-powered troubleshooting for organization-specific scenarios.

## Overview

Custom runbooks allow you to:
- Define step-by-step investigation procedures for known issues
- Provide organization-specific commands and checks
- Guide Holmes through your unique infrastructure patterns
- Include company-specific fix recommendations

## Runbook Formats

Holmes supports **two runbook formats**:

| Format | Best For | File Type |
|--------|----------|-----------|
| **YAML with Match Patterns** | Simple pattern-based matching | `.yaml` files |
| **JSON Catalog + Markdown** | Rich documentation with detailed steps | `catalog.json` + `.md` files |

---

## Format 1: YAML with Match Patterns (Recommended)

This format is simpler and works well for pattern-based matching. **Verified working on local Kubernetes.**

### Step 1: Create YAML Runbook Files

Create a directory for your runbooks:

```bash
mkdir -p runbooks/
```

Create a YAML runbook file (e.g., `runbooks/my-app.yaml`):

```yaml
# runbooks/my-app.yaml
runbooks:
  - match:
      issue_name: "(MyApp)|(my-app)|(database.*connection)|(startup.*fail)"
    instructions: >
      Diagnose MyApp crashes and database connection failures.

      1. Check application logs:
         kubectl logs POD_NAME -n NAMESPACE --tail=100
         kubectl logs POD_NAME -n NAMESPACE --previous
         Look for: connection errors, missing config, startup failures

      2. Verify ConfigMap values:
         kubectl get configmap myapp-config -n NAMESPACE -o yaml
         Ensure DATABASE_URL is set correctly
         Verify API keys are present

      3. Check secrets exist:
         kubectl get secret myapp-secrets -n NAMESPACE
         Confirm all required secrets are present

      Common Fixes:
      - Missing database connection: kubectl set env deployment/myapp DATABASE_URL=postgresql://db:5432/myapp
      - Restart with fresh config: kubectl rollout restart deployment/myapp -n NAMESPACE

      Expected Resolution: Pod transitions to Running state with successful database connection.

  - match:
      issue_name: "(Redis)|(redis)|(cache.*fail)|(connection.*timeout)"
    instructions: >
      Diagnose Redis connection timeouts and cache failures.

      1. Check Redis pod status: kubectl get pods -l app=redis -n NAMESPACE
      2. Test Redis connectivity: kubectl exec -it deploy/myapp -- redis-cli -h redis ping
      3. Check Redis logs: kubectl logs -l app=redis -n NAMESPACE --tail=50

      Common Fixes:
      - Redis not running: kubectl rollout restart deployment/redis
      - Connection string wrong: kubectl set env deployment/myapp REDIS_URL=redis://redis:6379
```

### Step 2: Create ConfigMap

```bash
kubectl create configmap holmes-custom-runbooks \
  --from-file=my-app.yaml=runbooks/my-app.yaml \
  --from-file=cert-manager.yaml=runbooks/cert-manager.yaml \
  -n holmesgpt
```

Or use a manifest:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-custom-runbooks
  namespace: holmesgpt
data:
  my-app.yaml: |
    runbooks:
      - match:
          issue_name: "(MyApp)|(database.*connection)"
        instructions: >
          Diagnose MyApp crashes...

          1. Check logs: kubectl logs POD_NAME -n NAMESPACE
          2. Verify config: kubectl get configmap myapp-config -o yaml

          Fixes:
          - Restart: kubectl rollout restart deployment/myapp
```

### Step 3: Create Holmes Config

Create a config file that references your runbooks:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
  namespace: holmesgpt
data:
  config.yaml: |
    # Custom runbooks - explicit paths required (no auto-discovery)
    custom_runbooks:
      - /etc/holmes/runbooks/my-app.yaml
      - /etc/holmes/runbooks/cert-manager.yaml
```

### Step 4: Configure Helm Values

```yaml
# helm-values.yaml

# Mount runbooks ConfigMap
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-custom-runbooks

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /etc/holmes/runbooks
    readOnly: true

# Mount Holmes config
# Note: The Helm chart may already mount config at /root/.holmes/config.yaml
# Check your chart version for the correct approach
```

### Step 5: Deploy

```bash
kubectl apply -f holmes-custom-runbooks.yaml
kubectl apply -f holmes-config.yaml
helm upgrade --install holmesgpt holmesgpt/holmesgpt -n holmesgpt -f helm-values.yaml
```

### YAML Format Reference

```yaml
runbooks:
  - match:
      issue_name: "regex pattern to match issue titles"
    instructions: >
      Multi-line instructions for Holmes to follow.

      Include:
      1. Diagnostic commands with kubectl
      2. What to look for in output
      3. Common fixes with exact commands
      4. Expected resolution
```

**Match patterns use regex** - common patterns:
- `"(Pod)|(pod)|(container)"` - Match any of these words
- `"CrashLoop.*BackOff"` - Match with wildcards
- `"(OOM|OutOfMemory)"` - Match abbreviations

---

## Format 2: JSON Catalog + Markdown

This format provides richer documentation with separate markdown files for each runbook.

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
  -n holmesgpt
```

Or use a YAML manifest:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-runbooks
  namespace: holmesgpt
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
  -n holmesgpt \
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
kubectl get configmap holmes-runbooks -n holmesgpt -o yaml
```

### 2. Verify volume mount

```bash
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- ls -la /etc/holmes/runbooks/
```

Expected output:
```
catalog.json
my-app-crash.md
redis-connection.md
```

### 3. Check Holmes loaded runbooks

```bash
kubectl logs -n holmesgpt deploy/holmesgpt-holmes | grep -i "runbook\|catalog"
```

### 4. Test runbook matching

```bash
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- \
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
  -n holmesgpt \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Holmes to pick up changes
kubectl rollout restart deployment/holmesgpt-holmes -n holmesgpt
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
    namespace: holmesgpt
```

## Troubleshooting

### Runbooks not loading

1. Check volume mount:
   ```bash
   # For YAML format (mounted at /etc/holmes/runbooks/)
   kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- ls -la /etc/holmes/runbooks/

   # For JSON catalog format (mounted at /runbooks/)
   kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /runbooks/catalog.json
   ```

2. Verify runbook content is readable:
   ```bash
   kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /etc/holmes/runbooks/cert-manager.yaml
   ```

3. Check Holmes config references the runbooks:
   ```bash
   kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /root/.holmes/config.yaml
   ```

### Holmes not matching runbooks

1. Improve `description` field with more keywords
2. Test with explicit issue description matching runbook
3. Check Holmes logs for runbook selection:
   ```bash
   kubectl logs -n holmesgpt deploy/holmesgpt-holmes | grep -i "runbook"
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

---

## Verified Working Configuration

This configuration has been tested and verified on a local Kubernetes cluster.

### Namespace: `holmesgpt`

**ConfigMap: holmes-custom-runbooks**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-custom-runbooks
  namespace: holmesgpt
data:
  cert-manager.yaml: |
    runbooks:
      - match:
          issue_name: "(Certificate)|(cert-manager)|(TLS)|(ACME)|(Let.*Encrypt)"
        instructions: >
          Diagnose why cert-manager is not issuing certificates.

          1. Check cert-manager pods: kubectl get pods -n cert-manager
          2. Get Certificate status: kubectl describe certificate <name> -n <namespace>
          3. Find CertificateRequest: kubectl get certificaterequest -n <namespace>
          4. Check Issuer/ClusterIssuer: kubectl describe clusterissuer <name>
          5. For ACME, check Order: kubectl get order -n <namespace>
          6. For ACME, check Challenge: kubectl get challenge -n <namespace>
          7. Review cert-manager logs: kubectl logs -n cert-manager deploy/cert-manager

  external-dns.yaml: |
    runbooks:
      - match:
          issue_name: "(ExternalDNS)|(external-dns)|(DNS.*not.*creat)|(DNS.*record)"
        instructions: >
          Diagnose why external-dns is not creating DNS records.

          1. Check external-dns pod status: kubectl get pods -n external-dns
          2. Review external-dns logs: kubectl logs -n external-dns deploy/external-dns --tail=200
          3. Verify Services have annotation: external-dns.alpha.kubernetes.io/hostname
          4. Check deployment args for --domain-filter restrictions
```

**ConfigMap: holmes-config**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
  namespace: holmesgpt
data:
  config.yaml: |
    # IMPORTANT: HolmesGPT only loads runbooks listed here explicitly.
    # No directory scanning or auto-discovery.
    custom_runbooks:
      - /etc/holmes/runbooks/external-dns.yaml
      - /etc/holmes/runbooks/cert-manager.yaml
```

**Volume Mounts in Deployment:**
```yaml
volumes:
  - name: custom-runbooks
    configMap:
      name: holmes-custom-runbooks
  - name: holmes-config
    configMap:
      name: holmes-config

volumeMounts:
  - name: custom-runbooks
    mountPath: /etc/holmes/runbooks
    readOnly: true
  - name: holmes-config
    mountPath: /root/.holmes/config.yaml
    subPath: config.yaml
    readOnly: true
```

### Verification Commands

```bash
# Check runbooks are mounted
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- ls -la /etc/holmes/runbooks/

# Verify config file
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /root/.holmes/config.yaml

# Test Holmes API with cert-manager query
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- curl -s -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Certificate not issuing",
    "description": "cert-manager Certificate is stuck in pending",
    "subject": {"name": "my-cert", "namespace": "default"},
    "context": {}
  }'
```

### Test Results

- **Pod Status**: Running (holmesgpt-holmes-6978848555-qq9w5)
- **Files Mounted**: cert-manager.yaml, external-dns.yaml
- **Config Loaded**: /root/.holmes/config.yaml with custom_runbooks paths
- **API Response**: Holmes successfully investigates and provides analysis
