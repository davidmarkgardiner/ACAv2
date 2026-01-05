# HolmesGPT Custom Runbooks

Add your own troubleshooting runbooks to guide Holmes investigations.

## Quick Start (5 minutes)

### Step 1: Create the Runbooks ConfigMap

```yaml
# runbooks-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-custom-runbooks
  namespace: holmesgpt
data:
  my-app.yaml: |
    runbooks:
      - match:
          issue_name: "(MyApp)|(my-app)|(database.*connection)"
        instructions: >
          Diagnose MyApp crashes and database issues.

          1. Check logs: kubectl logs POD_NAME -n NAMESPACE --tail=100
          2. Check config: kubectl get configmap myapp-config -o yaml
          3. Check secrets: kubectl get secret myapp-secrets

          Fixes:
          - Restart: kubectl rollout restart deployment/myapp
          - Fix DB URL: kubectl set env deployment/myapp DATABASE_URL=postgresql://db:5432/myapp
```

```bash
kubectl apply -f runbooks-configmap.yaml
```

### Step 2: Create the Holmes Config

```yaml
# holmes-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-config
  namespace: holmesgpt
data:
  config.yaml: |
    custom_runbooks:
      - /etc/holmes/runbooks/my-app.yaml
```

```bash
kubectl apply -f holmes-config.yaml
```

### Step 3: Update Helm Values

Add these to your `values.yaml`:

```yaml
additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-custom-runbooks
  - name: holmes-config
    configMap:
      name: holmes-config

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /etc/holmes/runbooks
    readOnly: true
  - name: holmes-config
    mountPath: /root/.holmes/config.yaml
    subPath: config.yaml
    readOnly: true
```

### Step 4: Deploy

```bash
helm upgrade --install holmesgpt holmesgpt/holmesgpt \
  -n holmesgpt \
  -f values.yaml
```

### Step 5: Verify

```bash
# Check files are mounted
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- ls /etc/holmes/runbooks/

# Check config loaded
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /root/.holmes/config.yaml
```

---

## Runbook Format

```yaml
runbooks:
  - match:
      issue_name: "regex pattern here"
    instructions: >
      Step-by-step instructions for Holmes to follow.

      1. First command: kubectl get pods
      2. Second command: kubectl logs POD_NAME

      Fixes:
      - Fix option 1: kubectl rollout restart deployment/app
      - Fix option 2: kubectl set env deployment/app KEY=value
```

**Match patterns use regex:**
- `"(word1)|(word2)"` - match either word
- `"error.*timeout"` - match with wildcard
- `"(OOM|OutOfMemory)"` - match abbreviations

---

## Adding More Runbooks

Add more files to the ConfigMap:

```yaml
data:
  my-app.yaml: |
    runbooks:
      - match:
          issue_name: "(MyApp)"
        instructions: >
          ...

  redis.yaml: |
    runbooks:
      - match:
          issue_name: "(Redis)|(cache)"
        instructions: >
          ...

  postgres.yaml: |
    runbooks:
      - match:
          issue_name: "(Postgres)|(database)"
        instructions: >
          ...
```

Update `holmes-config.yaml` to list all files:

```yaml
data:
  config.yaml: |
    custom_runbooks:
      - /etc/holmes/runbooks/my-app.yaml
      - /etc/holmes/runbooks/redis.yaml
      - /etc/holmes/runbooks/postgres.yaml
```

Apply and restart:

```bash
kubectl apply -f runbooks-configmap.yaml
kubectl apply -f holmes-config.yaml
kubectl rollout restart deployment/holmesgpt-holmes -n holmesgpt
```

---

## Troubleshooting

**Runbooks not found:**
```bash
# Check files exist
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- ls -la /etc/holmes/runbooks/

# Check config has correct paths
kubectl exec -n holmesgpt deploy/holmesgpt-holmes -- cat /root/.holmes/config.yaml
```

**Holmes not using runbooks:**
- Ensure `match.issue_name` regex matches your issue description
- Check Holmes logs: `kubectl logs -n holmesgpt deploy/holmesgpt-holmes`
