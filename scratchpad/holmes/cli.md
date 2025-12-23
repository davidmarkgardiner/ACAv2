# Fix: Add EmptyDir Volume for Holmes Cache

## Using Helm values.yaml

```yaml
# In your Helm values.yaml or deployment
extraVolumes:
  - name: holmes-cache
    emptyDir: {}

extraVolumeMounts:
  - name: holmes-cache
    mountPath: /root/.holmes
```

## Using Raw Deployment YAML

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmesgpt
spec:
  template:
    spec:
      containers:
        - name: holmes
          image: us-central1-docker.pkg.dev/genuine-flight-317411/devel/holmes:0.17.0
          volumeMounts:
            - name: holmes-cache
              mountPath: /root/.holmes
            # If you have config
            - name: config
              mountPath: /root/.holmes/config.yaml
              subPath: config.yaml
      volumes:
        - name: holmes-cache
          emptyDir: {}
        - name: config
          configMap:
            name: holmes-config
```

## If Using Helm Chart

```yaml
# values.yaml
extraVolumes:
  - name: holmes-cache
    emptyDir: {}

extraVolumeMounts:
  - name: holmes-cache
    mountPath: /root/.holmes

# If security context enforces read-only root
securityContext:
  readOnlyRootFilesystem: true  # Keep this for security

# The emptyDir provides writable space for:
# - /root/.holmes/toolsets_status.json (cache)
# - /root/.holmes/config.yaml (if generated)
```

## What Holmes Writes to ~/.holmes

| File                   | Purpose               |
|------------------------|-----------------------|
| `toolsets_status.json` | Cached toolset status |
| `config.yaml`          | User configuration    |
| `runbooks/`            | Custom runbooks       |

## Quick Test

```bash
# Check if volume is mounted
kubectl exec -it deploy/holmesgpt -- ls -la /root/.holmes

# Should now work
kubectl exec -it deploy/holmesgpt -- python holmes_cli.py toolset list
```
