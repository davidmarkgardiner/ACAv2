# Holmes Auto-Remediation Setup Guide

This guide configures HolmesGPT to automatically execute remediation actions instead of just recommending them.

## Prerequisites

- AKS-MCP configured with `--access-level readwrite` or `--access-level admin`
- Holmes connected to the cluster with the AKS-MCP toolset enabled

---

## 1. Deployment Configuration

Add this to your `deployment.yaml` under the Holmes configuration:

```yaml
        llm_instructions: |
          # ADMIN REMEDIATION MODE ENABLED

          You have ADMINISTRATOR privileges and are REQUIRED to execute remediations, not just recommend them.

          ## TOOL YOU MUST USE

          Use ONLY this tool for remediation:

          | Tool | Purpose |
          |------|---------|
          | `call_kubectl` | Execute kubectl commands (delete, scale, rollout, patch, apply) |

          ## TOOLS TO IGNORE (Do Not Use)

          Do NOT use any other tools:

          - `az_aks_operations` - Not needed
          - `az_compute_operations` - Not needed
          - `az_network_resources` - Not needed
          - `az_monitoring` - Not needed
          - `get_aks_vmss_info` - Not needed
          - `az_advisor_recommendations` - Not needed
          - `az_detectors` - Not needed
          - `inspektorgadget` - Not needed
          - `call_az` - Not needed

          ## REMEDIATION WORKFLOW

          1. **Read the alert/issue context** - Understand what needs fixing
          2. **Execute the fix immediately** using `call_kubectl`
          3. **Verify with ONE kubectl get command** - Confirm the fix worked
          4. **Report what you did** - Not recommendations, actual actions taken

          ## CRITICAL: Execution vs Recommendation

          ❌ NEVER DO THIS:
          "To fix this, you should run: kubectl delete pod xyz"

          ✅ ALWAYS DO THIS:
          1. Execute: `call_kubectl` with "kubectl delete pod xyz -n namespace"
          2. Verify: `call_kubectl` with "kubectl get pod -n namespace"
          3. Report: "Deleted pod xyz. New pod is now Running."

          ## Common Remediations - Execute These Directly

          | Issue | Execute This |
          |-------|-------------|
          | CrashLoopBackOff | `kubectl delete pod <name> -n <ns>` |
          | OOMKilled | `kubectl delete pod <name> -n <ns>` |
          | ImagePullBackOff | `kubectl delete pod <name> -n <ns>` |
          | Stuck rollout | `kubectl rollout restart deployment/<name> -n <ns>` |
          | Stuck terminating | `kubectl delete pod <name> -n <ns> --force --grace-period=0` |
          | PDB blocking | `kubectl delete pdb <name> -n <ns>` |
          | Need scaling | `kubectl scale deployment/<name> --replicas=<n> -n <ns>` |
          | Evicted pod | `kubectl delete pod <name> -n <ns>` |
          | Pending pod | `kubectl delete pod <name> -n <ns>` |
          | Init container stuck | `kubectl delete pod <name> -n <ns>` |
          | CreateContainerError | `kubectl delete pod <name> -n <ns>` |
          | ConfigMap/Secret changed | `kubectl rollout restart deployment/<name> -n <ns>` |
          | Probe failing | `kubectl delete pod <name> -n <ns>` |
          | Failed Job | `kubectl delete job <name> -n <ns>` |
          | Deployment paused | `kubectl rollout resume deployment/<name> -n <ns>` |

          ## DO NOT

          - Do not run diagnostics before attempting remediation
          - Do not call any az_* tools
          - Do not explore node or network configuration
          - Do not just output recommendations

          ## OUTPUT FORMAT

          1. **Issue**: Brief statement of the problem
          2. **Action Taken**: The kubectl command you executed
          3. **Result**: Whether it succeeded and current state
```

---

## 2. Runbook File

Create `holmes/plugins/runbooks/remediation/auto-remediation.md`:

```markdown
# Auto-Remediation Runbook

## Goal

Execute remediations automatically using admin tools. Do not recommend - execute.

## Tool

Use ONLY `call_kubectl` for all remediations.

## Workflow

### Step 1: Identify the Issue
Read the alert context to understand what needs fixing.

### Step 2: EXECUTE Remediation (MANDATORY)

**DO NOT skip this step. DO NOT just recommend the command.**

Use `call_kubectl` to execute the fix:

| Symptom | Command to Execute |
|---------|-------------------|
| CrashLoopBackOff | `kubectl delete pod <name> -n <ns>` |
| OOMKilled | `kubectl delete pod <name> -n <ns>` |
| Stuck deployment | `kubectl rollout restart deployment/<name> -n <ns>` |
| Stuck terminating pod | `kubectl delete pod <name> -n <ns> --force --grace-period=0` |
| PDB blocking | `kubectl delete pdb <name> -n <ns>` |
| Need more replicas | `kubectl scale deployment/<name> --replicas=<n> -n <ns>` |
| Evicted pods | `kubectl delete pod <name> -n <ns>` |
| Pending pod | `kubectl delete pod <name> -n <ns>` |
| ImagePullBackOff | `kubectl delete pod <name> -n <ns>` (after secret/image fixed) |
| Init container stuck | `kubectl delete pod <name> -n <ns>` |
| CreateContainerError | `kubectl delete pod <name> -n <ns>` |
| ConfigMap changed | `kubectl rollout restart deployment/<name> -n <ns>` |
| Secret changed | `kubectl rollout restart deployment/<name> -n <ns>` |
| Liveness probe failing | `kubectl delete pod <name> -n <ns>` |
| Readiness probe failing | `kubectl delete pod <name> -n <ns>` |
| Failed Job | `kubectl delete job <name> -n <ns>` |
| Completed Job cleanup | `kubectl delete job <name> -n <ns>` |
| Too many replicas | `kubectl scale deployment/<name> --replicas=<n> -n <ns>` |
| Deployment paused | `kubectl rollout resume deployment/<name> -n <ns>` |

### Step 3: Verify

Run ONE verification command:

```
call_kubectl: kubectl get <resource> -n <namespace>
```

### Step 4: Report

Report what you EXECUTED and the outcome.

## RULES

1. You MUST execute remediations - you have admin access
2. Never just recommend - always execute
3. Always verify - confirm the fix worked
4. Report actions taken - not recommendations
```

---

## 3. Catalog Entry

Add to `holmes/plugins/runbooks/catalog.json`:

```json
{
  "name": "Auto-Remediation",
  "path": "remediation/auto-remediation.md",
  "description": "Enables automatic execution of kubectl remediation commands",
  "tags": ["remediation", "auto-fix", "kubectl", "admin"]
}
```

---

## 4. API Call (Optional)

If calling the Holmes API directly, pass custom sections:

```python
response = requests.post(
    "https://your-holmes-server/api/investigate",
    json={
        "title": "Pod CrashLoopBackOff",
        "source": "alertmanager",
        "sections": {
            "Issue": "Brief description of the problem",
            "Action Taken": "The kubectl command you executed using call_kubectl",
            "Result": "The outcome and current resource state",
            "Remaining": "Only if remediation failed - what manual steps are needed"
        },
        "context": {
            # your alert context
        }
    }
)
```

---

## 5. AKS-MCP Configuration

Ensure your AKS-MCP is configured with write access:

```json
{
  "mcpServers": {
    "aks-mcp": {
      "command": "aks-mcp",
      "args": [
        "--transport", "stdio",
        "--access-level", "readwrite"
      ]
    }
  }
}
```

---

## How It Works

| Before (Investigation Only) | After (Auto-Remediation) |
|-----------------------------|--------------------------|
| Holmes investigates | Holmes investigates |
| Holmes outputs: "You should run kubectl delete pod xyz" | Holmes executes: `call_kubectl("kubectl delete pod xyz")` |
| User manually runs the command | Holmes verifies: `call_kubectl("kubectl get pod")` |
| User verifies | Holmes reports: "Deleted pod xyz. New pod is Running." |

---

## Troubleshooting

**Holmes still just recommends instead of executing:**

1. Check AKS-MCP has `--access-level readwrite`
2. Verify `call_kubectl` tool is available in Holmes toolset
3. Ensure the runbook is in `catalog.json` and being loaded
4. Check `llm_instructions` is being applied in deployment

**Tool not found errors:**

1. Verify AKS-MCP is running and connected
2. Check Holmes logs for MCP connection errors
3. Ensure the MCP toolset is enabled in Holmes config

---

## Test Scenarios

Use these manifests to create broken pods and verify Holmes auto-remediation is working.

### Test 1: CrashLoopBackOff

Creates a pod that immediately crashes.

```yaml
# test-crashloop.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-crashloop
  namespace: default
spec:
  containers:
  - name: crasher
    image: busybox
    command: ["sh", "-c", "exit 1"]
```

```bash
kubectl apply -f test-crashloop.yaml
# Wait for CrashLoopBackOff status
kubectl get pod test-crashloop -w
# Trigger Holmes alert - expected remediation: kubectl delete pod test-crashloop
```

**Expected Holmes Action:** `kubectl delete pod test-crashloop -n default`

---

### Test 2: OOMKilled

Creates a pod that runs out of memory.

```yaml
# test-oom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-oom
  namespace: default
spec:
  containers:
  - name: oom
    image: polinux/stress
    command: ["stress", "--vm", "1", "--vm-bytes", "256M"]
    resources:
      limits:
        memory: "50Mi"
```

```bash
kubectl apply -f test-oom.yaml
# Wait for OOMKilled status
kubectl get pod test-oom -w
# Trigger Holmes alert - expected remediation: kubectl delete pod test-oom
```

**Expected Holmes Action:** `kubectl delete pod test-oom -n default`

---

### Test 3: ImagePullBackOff

Creates a pod with a non-existent image.

```yaml
# test-imagepull.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-imagepull
  namespace: default
spec:
  containers:
  - name: badimage
    image: nonexistent-registry.io/fake-image:v999
```

```bash
kubectl apply -f test-imagepull.yaml
# Wait for ImagePullBackOff status
kubectl get pod test-imagepull -w
# Trigger Holmes alert - expected remediation: kubectl delete pod test-imagepull
```

**Expected Holmes Action:** `kubectl delete pod test-imagepull -n default`

---

### Test 4: Stuck Deployment (Replicas Unavailable)

Creates a deployment that can't reach desired replicas.

```yaml
# test-stuck-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-stuck
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test-stuck
  template:
    metadata:
      labels:
        app: test-stuck
    spec:
      containers:
      - name: stuck
        image: busybox
        command: ["sh", "-c", "exit 1"]
```

```bash
kubectl apply -f test-stuck-deployment.yaml
# Wait for pods to enter CrashLoopBackOff
kubectl get pods -l app=test-stuck -w
# Trigger Holmes alert - expected remediation: kubectl rollout restart deployment/test-stuck
```

**Expected Holmes Action:** `kubectl rollout restart deployment/test-stuck -n default`

---

### Test 5: Pending Pod (Impossible Resource Request)

Creates a pod with resource requests that can't be satisfied.

```yaml
# test-pending.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pending
  namespace: default
spec:
  containers:
  - name: pending
    image: nginx
    resources:
      requests:
        cpu: "100"
        memory: "1000Gi"
```

```bash
kubectl apply -f test-pending.yaml
# Pod will stay Pending
kubectl get pod test-pending -w
# Trigger Holmes alert - expected remediation: kubectl delete pod test-pending
```

**Expected Holmes Action:** `kubectl delete pod test-pending -n default`

---

### Test 6: PDB Blocking (for upgrade scenarios)

Creates a restrictive PDB that would block node drains.

```yaml
# test-pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: test-pdb
  namespace: default
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app: critical-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: critical-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: critical-app
  template:
    metadata:
      labels:
        app: critical-app
    spec:
      containers:
      - name: app
        image: nginx
```

```bash
kubectl apply -f test-pdb.yaml
# PDB will block any disruption
kubectl get pdb test-pdb
# Trigger Holmes alert for PDB blocking upgrade
# Expected remediation: kubectl delete pdb test-pdb
```

**Expected Holmes Action:** `kubectl delete pdb test-pdb -n default`

---

### Test 7: Failed Job

Creates a job that fails.

```yaml
# test-failed-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: test-failed-job
  namespace: default
spec:
  backoffLimit: 1
  template:
    spec:
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "exit 1"]
      restartPolicy: Never
```

```bash
kubectl apply -f test-failed-job.yaml
# Wait for job to fail
kubectl get job test-failed-job -w
# Trigger Holmes alert - expected remediation: kubectl delete job test-failed-job
```

**Expected Holmes Action:** `kubectl delete job test-failed-job -n default`

---

### Cleanup

```bash
kubectl delete pod test-crashloop test-oom test-imagepull test-pending --ignore-not-found
kubectl delete deployment test-stuck critical-app --ignore-not-found
kubectl delete pdb test-pdb --ignore-not-found
kubectl delete job test-failed-job --ignore-not-found
```

---

## Verification Checklist

After running each test, verify:

- [ ] Holmes received the alert
- [ ] Holmes called `call_kubectl` with the remediation command
- [ ] Holmes called `call_kubectl` to verify the fix
- [ ] Holmes reported the action taken (not a recommendation)
- [ ] The resource was actually remediated in the cluster
