# Argo Workflow Pod Cleanup & Scheduling Implementation Guide

This document provides instructions for implementing pod cleanup, noise reduction, and multi-frequency scheduling in Argo Workflows. Use this to apply the same patterns to other workflow projects.

---

## Problem Statement

Argo Workflows can create significant "pod noise" when:
- Completed pods persist indefinitely after workflow completion
- Workflow objects accumulate in the cluster
- CronWorkflows keep too many historical runs
- All policies run at the same frequency regardless of criticality

## Solution Overview

1. **Pod Garbage Collection (`podGC`)** - Automatically delete pods after workflow completion
2. **TTL Strategy (`ttlStrategy`)** - Automatically delete workflow objects after a time period
3. **History Limits** - Reduce the number of retained CronWorkflow runs
4. **Multi-frequency Scheduling** - Run critical checks more often than full scans

---

## Implementation Steps

### Step 1: Add Pod Garbage Collection

Add the `podGC` block to your WorkflowTemplate or Workflow spec:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: your-workflow-template
spec:
  # Add this block after serviceAccountName
  podGC:
    strategy: OnWorkflowSuccess    # Options: OnPodCompletion, OnPodSuccess, OnWorkflowSuccess, OnWorkflowCompletion
    deleteDelayDuration: 60s       # Wait before deletion (allows log collection)
```

**Strategy Options:**
| Strategy | When Pods Are Deleted |
|----------|----------------------|
| `OnPodCompletion` | Each pod deleted when it completes |
| `OnPodSuccess` | Each pod deleted when it succeeds |
| `OnWorkflowSuccess` | All pods deleted when workflow succeeds |
| `OnWorkflowCompletion` | All pods deleted when workflow completes (success or failure) |

**Recommendation:** Use `OnWorkflowSuccess` to preserve pods for debugging if workflow fails.

### Step 2: Add TTL Strategy

Add the `ttlStrategy` block to auto-delete workflow objects:

```yaml
spec:
  # Add after podGC block
  ttlStrategy:
    secondsAfterCompletion: 3600   # Delete 1 hour after completion (any status)
    secondsAfterSuccess: 3600      # Delete 1 hour after success
    secondsAfterFailure: 86400     # Keep failed workflows 24 hours for debugging
```

**Field Priority:** If multiple fields are set, the most specific one takes precedence:
- `secondsAfterSuccess` for successful workflows
- `secondsAfterFailure` for failed workflows
- `secondsAfterCompletion` as fallback for any completion

### Step 3: Reduce CronWorkflow History Limits

In your CronWorkflow spec, reduce history limits:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: your-cronworkflow
spec:
  schedule: "0 6 * * *"
  concurrencyPolicy: "Replace"

  # Reduce these values (defaults are higher)
  successfulJobsHistoryLimit: 2    # Keep only last 2 successful runs
  failedJobsHistoryLimit: 2        # Keep only last 2 failed runs

  # Optional: ability to pause scheduling
  suspend: false

  workflowSpec:
    # ... or use workflowTemplateRef
```

### Step 4: Create Multiple CronWorkflows for Different Frequencies

Create separate CronWorkflows for different scan frequencies:

**Daily Full Scan:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: compliance-scan-daily
spec:
  schedule: "0 6 * * *"  # Every day at 6 AM UTC
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  workflowSpec:
    workflowTemplateRef:
      name: your-workflow-template
    arguments:
      parameters:
        - name: severity-filter
          value: "critical,high,medium,low"  # All severities
```

**Frequent Critical Scan:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: compliance-scan-frequent
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  successfulJobsHistoryLimit: 1  # Keep only latest
  failedJobsHistoryLimit: 2
  workflowSpec:
    workflowTemplateRef:
      name: your-workflow-template
    arguments:
      parameters:
        - name: severity-filter
          value: "critical,high"  # Only critical/high
```

---

## Complete Example

Here's a complete WorkflowTemplate with all cleanup settings:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: example-workflow
  namespace: argo-workflows
spec:
  entrypoint: main
  serviceAccountName: workflow-sa

  # === POD CLEANUP ===
  podGC:
    strategy: OnWorkflowSuccess
    deleteDelayDuration: 60s

  # === WORKFLOW CLEANUP ===
  ttlStrategy:
    secondsAfterCompletion: 3600
    secondsAfterSuccess: 3600
    secondsAfterFailure: 86400

  templates:
    - name: main
      container:
        image: alpine:latest
        command: [echo, "Hello World"]

---
apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: example-workflow-scheduled
  namespace: argo-workflows
spec:
  schedule: "0 6 * * *"
  timezone: "UTC"
  concurrencyPolicy: "Replace"

  # === HISTORY LIMITS ===
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  suspend: false

  workflowSpec:
    workflowTemplateRef:
      name: example-workflow
```

---

## Common Cron Schedules

| Schedule | Cron Expression |
|----------|----------------|
| Every 24 hours at 6 AM | `0 6 * * *` |
| Every 12 hours | `0 */12 * * *` |
| Every 6 hours | `0 */6 * * *` |
| Every 4 hours | `0 */4 * * *` |
| Every hour | `0 * * * *` |
| Weekdays at 8 AM | `0 8 * * 1-5` |
| Every 15 minutes | `*/15 * * * *` |

---

## Operational Commands

### Suspend/Resume CronWorkflows

```bash
# Suspend
kubectl patch cronworkflow <name> -n <namespace> \
  --type merge -p '{"spec":{"suspend":true}}'

# Resume
kubectl patch cronworkflow <name> -n <namespace> \
  --type merge -p '{"spec":{"suspend":false}}'
```

### Monitor Pod Count

```bash
# Count workflow pods
kubectl get pods -n <namespace> -l workflows.argoproj.io/workflow --no-headers | wc -l

# Watch pods
kubectl get pods -n <namespace> -l workflows.argoproj.io/workflow -w
```

### Manual Cleanup

```bash
# List workflows
kubectl get workflows -n <namespace>

# Delete all completed workflows
kubectl delete workflows -n <namespace> --field-selector=status.phase=Succeeded

# Delete specific workflow
kubectl delete workflow <name> -n <namespace>
```

### View CronWorkflow Status

```bash
# List CronWorkflows
kubectl get cronworkflows -n <namespace>

# See last run time
kubectl get cronworkflow <name> -n <namespace> -o jsonpath='{.status.lastScheduledTime}'
```

---

## Checklist for Implementation

- [ ] Add `podGC` block with appropriate strategy
- [ ] Add `ttlStrategy` block with retention periods
- [ ] Reduce `successfulJobsHistoryLimit` (recommend: 2)
- [ ] Reduce `failedJobsHistoryLimit` (recommend: 2)
- [ ] Create separate CronWorkflow for frequent critical scans (if needed)
- [ ] Add `suspend: false` field for easy pause/resume
- [ ] Set `concurrencyPolicy: "Replace"` to prevent overlapping runs
- [ ] Validate YAML before applying
- [ ] Document schedules in README

---

## Expected Behavior After Implementation

| Event | Pods | Workflow Object |
|-------|------|-----------------|
| Workflow succeeds | Deleted after 60s | Deleted after 1 hour |
| Workflow fails | Preserved | Deleted after 24 hours |
| New CronWorkflow run | Previous runs cleaned up | Keeps last 2 of each status |

This reduces cluster noise from potentially hundreds of accumulated pods/workflows to just a handful at any given time.
