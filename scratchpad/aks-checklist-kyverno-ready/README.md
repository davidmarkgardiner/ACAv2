# AKS Checklist - Kyverno Policy Implementation

Automated compliance checking for [The AKS Checklist](https://www.the-aks-checklist.com/) using Kyverno policies.

## Overview

This implementation provides:
- **86 Kyverno policies** mapped to AKS checklist items
- **Audit-mode deployment** for compliance reporting without blocking
- **Argo Workflow** for scheduled compliance scans with automatic pod cleanup
- **HTML/JSON reports** for visibility

## Quick Start

### 1. Install Policies in Audit Mode

```bash
# Apply all policies in audit mode (won't block anything)
kubectl apply -f policies/

# Or apply specific categories
kubectl apply -f policies/security/
kubectl apply -f policies/resources/
kubectl apply -f policies/application/
```

### 2. Deploy Argo Workflow

```bash
# Apply the workflow template and scheduled scans
kubectl apply -f argo-workflows/compliance-scan.yaml
```

### 3. Check Compliance Status

```bash
# View policy reports
kubectl get policyreport -A

# Get detailed violations
kubectl get policyreport -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.summary}{"\n"}{end}'

# Export to JSON for processing
kubectl get policyreport -A -o json > compliance-report.json
```

### 4. Run Ad-hoc Scan with Kyverno CLI

```bash
# Scan all resources against policies
kyverno apply policies/ --cluster --policy-report

# Scan specific namespace
kyverno apply policies/ --cluster -n production --policy-report
```

## Policy Categories

| Category | Policies | Checklist Coverage |
|----------|----------|-------------------|
| Security | 25 | Identity, Cluster Security |
| Resources | 15 | Resource Management, Limits |
| Application | 18 | Deployment Best Practices |
| Network | 12 | Network Policies, Ingress |
| Operations | 10 | Labels, Namespaces |

## Directory Structure

```
├── policies/
│   ├── security/           # Security-related policies
│   ├── resources/          # Resource limits, quotas
│   ├── application/        # Deployment best practices
│   ├── network/            # Network policies
│   └── operations/         # Operational best practices
├── argo-workflows/         # Automated scanning workflows
├── reports/                # Report templates
└── scripts/                # Helper scripts
```

---

## Argo Workflow Configuration

### Pod Cleanup & Noise Reduction

The workflow is configured to automatically clean up completed pods and workflows to minimize cluster noise:

| Setting | Value | Description |
|---------|-------|-------------|
| `podGC.strategy` | `OnWorkflowSuccess` | Deletes all pods when workflow succeeds |
| `podGC.deleteDelayDuration` | `60s` | Waits 60s before deletion for log collection |
| `ttlStrategy.secondsAfterSuccess` | `3600` | Deletes workflow 1 hour after success |
| `ttlStrategy.secondsAfterFailure` | `86400` | Keeps failed workflows 24h for debugging |
| `successfulJobsHistoryLimit` | `2` | Keeps only last 2 successful CronWorkflow runs |
| `failedJobsHistoryLimit` | `2` | Keeps only last 2 failed runs |

### Scheduled Scans

Two CronWorkflows are provided with different frequencies:

| CronWorkflow | Schedule | Purpose |
|--------------|----------|---------|
| `aks-compliance-scan-daily` | `0 6 * * *` (6 AM UTC daily) | Full compliance scan of all policies |
| `aks-compliance-scan-security-frequent` | `0 */6 * * *` (every 6 hours) | Critical/high severity policies only |

### Customizing Scan Frequency

To adjust schedules:

```bash
# Edit the CronWorkflow
kubectl edit cronworkflow aks-compliance-scan-daily -n argo-workflows
```

Common schedule patterns:
- Every 24 hours at 6 AM: `0 6 * * *`
- Every 12 hours: `0 */12 * * *`
- Every 6 hours: `0 */6 * * *`
- Every 4 hours: `0 */4 * * *`
- Weekdays only at 8 AM: `0 8 * * 1-5`

### Suspending Scheduled Scans

To temporarily pause scanning:

```bash
# Suspend a CronWorkflow
kubectl patch cronworkflow aks-compliance-scan-daily -n argo-workflows \
  --type merge -p '{"spec":{"suspend":true}}'

# Resume
kubectl patch cronworkflow aks-compliance-scan-daily -n argo-workflows \
  --type merge -p '{"spec":{"suspend":false}}'
```

### Manual Cleanup (if needed)

If you need to manually clean up old workflows:

```bash
# List all workflows
kubectl get workflows -n argo-workflows

# Delete completed workflows older than 1 hour
kubectl get workflows -n argo-workflows -o name | xargs -I {} kubectl delete {} -n argo-workflows

# Delete specific workflow
kubectl delete workflow <workflow-name> -n argo-workflows
```

### Monitoring Pod Count

To monitor running pods from compliance scans:

```bash
# Count pods from compliance workflows
kubectl get pods -n argo-workflows -l workflows.argoproj.io/workflow --no-headers | wc -l

# Watch pods in real-time
kubectl get pods -n argo-workflows -l workflows.argoproj.io/workflow -w
```

---

## Integration with Existing Kyverno

These policies use `validationFailureAction: Audit` by default, meaning:
- Violations are **recorded** but not **blocked**
- Policy Reports are generated automatically
- No impact on existing workloads

To enforce specific policies:
```yaml
spec:
  validationFailureAction: Enforce  # Change from Audit
```

## Checklist Mapping

See [CHECKLIST_MAPPING.md](./CHECKLIST_MAPPING.md) for the complete mapping of checklist items to Kyverno policies.
