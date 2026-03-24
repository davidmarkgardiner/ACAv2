# Pod Cleanup CronJob

Automated hourly cleanup of stale Kubernetes pods to free disk space on AKS nodes. Targets pods that are stuck in CrashLoopBackOff, or have been Completed/Failed for too long. Once pods are removed, kubelet garbage collection automatically reclaims the associated container images and layers.

## What It Does

The CronJob runs every hour and identifies pods matching any of these criteria:

| Condition | Default Threshold |
|-----------|-------------------|
| CrashLoopBackOff with excessive restarts | > 50 restarts |
| CrashLoopBackOff running too long | > 6 hours |
| Completed (Succeeded) pods | > 24 hours old |
| Failed pods | > 24 hours old |

Pods in excluded namespaces are never touched. By default these are: `kube-system`, `argo`, `argo-events`, `kagent`.

Every action is logged with UTC timestamps. The CronJob itself uses `ttlSecondsAfterFinished: 3600` so its own Job pods are cleaned up after 1 hour.

## Resources Created

- **ServiceAccount** `pod-cleanup` in `kube-system`
- **ClusterRole** `pod-cleanup` with get/list/delete on pods only
- **ClusterRoleBinding** `pod-cleanup`
- **CronJob** `pod-cleanup` in `kube-system`

## Deployment

```bash
kubectl apply -f pod-cleanup-cronjob.yaml
```

Verify the CronJob was created:

```bash
kubectl get cronjob pod-cleanup -n kube-system
```

Trigger a manual run to test:

```bash
kubectl create job --from=cronjob/pod-cleanup pod-cleanup-manual -n kube-system
```

Watch the logs:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=pod-cleanup --tail=100 -f
```

## Dry-Run Mode

The CronJob ships with `DRY_RUN=false` (live mode). To enable dry-run, which logs what it would delete without actually deleting anything:

```bash
kubectl set env cronjob/pod-cleanup -n kube-system DRY_RUN=true
```

To switch back to live mode:

```bash
kubectl set env cronjob/pod-cleanup -n kube-system DRY_RUN=false
```

Or edit the YAML directly and change the `DRY_RUN` environment variable value to `"true"`.

**Recommendation**: Deploy with `DRY_RUN=true` first, review logs from a few runs, then switch to live mode.

## Changing Thresholds

All thresholds are configurable via environment variables on the CronJob container:

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `false` | Log-only mode when `true` |
| `EXCLUDED_NAMESPACES` | `kube-system,argo,argo-events,kagent` | Comma-separated list of namespaces to skip |
| `CRASHLOOP_RESTART_THRESHOLD` | `50` | Minimum restart count to trigger cleanup |
| `CRASHLOOP_AGE_HOURS` | `6` | Hours a CrashLoopBackOff pod must exist before cleanup |
| `COMPLETED_AGE_HOURS` | `24` | Hours a Completed/Failed pod must exist before cleanup |

Example -- lower the restart threshold to 20:

```bash
kubectl set env cronjob/pod-cleanup -n kube-system CRASHLOOP_RESTART_THRESHOLD=20
```

## Excluding Additional Namespaces

Add namespace names to the `EXCLUDED_NAMESPACES` environment variable (comma-separated, no spaces):

```bash
kubectl set env cronjob/pod-cleanup -n kube-system \
  EXCLUDED_NAMESPACES=kube-system,argo,argo-events,kagent,monitoring,cert-manager
```

## How Kubelet GC Handles Image Cleanup

This CronJob only deletes **pods**. The actual disk space recovery happens through kubelet's built-in garbage collection:

1. **Container GC**: After pods are deleted, their stopped containers are removed by kubelet based on `--maximum-dead-containers-per-container` (default: 1) and `--maximum-dead-containers` (default: -1, unlimited).

2. **Image GC**: Kubelet monitors node disk usage and automatically removes unused container images when disk usage crosses thresholds:
   - `imageGCHighThresholdPercent` (default: 85%) -- GC starts removing images
   - `imageGCLowThresholdPercent` (default: 80%) -- GC stops once usage drops below this

3. **The chain**: Pod deletion -> container becomes unused -> kubelet removes container -> image has no running containers -> kubelet removes image when disk pressure triggers GC.

On AKS, these defaults are generally appropriate. If you need more aggressive cleanup, adjust kubelet configuration via AKS node pool settings.

## Monitoring

Check CronJob status:

```bash
# Last run status
kubectl get cronjob pod-cleanup -n kube-system

# Recent job history
kubectl get jobs -n kube-system -l app.kubernetes.io/name=pod-cleanup --sort-by=.metadata.creationTimestamp

# Logs from the most recent run
kubectl logs -n kube-system -l app.kubernetes.io/name=pod-cleanup --tail=50
```

## Troubleshooting

**CronJob pods themselves piling up**: The `ttlSecondsAfterFinished: 3600` setting ensures completed Job pods are cleaned up after 1 hour. Additionally, `successfulJobsHistoryLimit: 3` and `failedJobsHistoryLimit: 5` cap the history.

**Permission errors in logs**: Verify the ClusterRoleBinding exists and the ServiceAccount is correct:

```bash
kubectl auth can-i delete pods --all-namespaces --as=system:serviceaccount:kube-system:pod-cleanup
```

**Job not running on schedule**: Check `startingDeadlineSeconds` (300s). If the scheduler misses a window by more than 5 minutes, it skips that run. Check for resource pressure on the node.

**Job timing out**: The `activeDeadlineSeconds: 600` (10 minutes) kills jobs that hang. If you have thousands of pods to process, consider increasing this value.
