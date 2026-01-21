# Medium Noise Filter Profile

**Balanced** - Critical + health events, system namespaces excluded.

## What Gets Through

| Filter | Criteria |
|--------|----------|
| Event Type | `Warning` only |
| Namespaces | Blacklist (excluded): `kube-system`, `kube-public`, `kube-node-lease`, `cert-manager`, `gatekeeper-system`, `flux-system`, `external-secrets`, `azureserviceoperator-system`, `argo-events`, `argo`, `argocd`, `istio-system`, `linkerd` |
| Event Reasons | Critical: `CrashLoopBackOff`, `OOMKilled`, `NodeNotReady`, `FailedMount`, `FailedScheduling`, `Evicted`<br>Health: `Unhealthy`, `ProbeWarning`, `FailedKillPod`, `BackOff` |

## Estimated Volume

~50-200 events/day per cluster

## Use Cases

- After successful low-noise testing
- Application namespaces monitoring
- Balanced noise vs coverage
- Teams with moderate alert fatigue tolerance

## Customization

### Add Namespaces to Blacklist

Edit `filters.conf` Step 2:

```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Exclude       involvedObject.namespace ^(kube-system|kube-public|...|YOUR-NEW-EXCLUSION)$
```

### Add Event Reasons

Edit `filters.conf` Step 3:

```ini
[FILTER]
    Name          grep
    Match         kube.events.*
    Regex         reason ^(CrashLoopBackOff|OOMKilled|...|NEW-REASON)$
```

## Event Reasons Explained

| Reason | Description | Severity |
|--------|-------------|----------|
| `CrashLoopBackOff` | Container crash loop | Critical |
| `OOMKilled` | Out of memory | Critical |
| `NodeNotReady` | Node health issue | Critical |
| `FailedMount` | Volume mount failure | Critical |
| `FailedScheduling` | Cannot schedule pod | Critical |
| `Evicted` | Pod evicted | Critical |
| `Unhealthy` | Health check failed | Health |
| `ProbeWarning` | Probe timeout/failure | Health |
| `FailedKillPod` | Cannot terminate pod | Health |
| `BackOff` | Container restart backoff | Health |

## Deployment

```bash
# Deploy to source cluster
kubectl apply -f fluent-bit-config.yaml

# Restart Fluent Bit to pick up changes
kubectl rollout restart daemonset fluent-bit -n monitoring
```

## Verification

```bash
# Check Fluent Bit logs
kubectl logs -n monitoring -l app=fluent-bit --tail=50

# Check EventHub incoming messages (Azure Portal)
# Should see moderate message volume
```
