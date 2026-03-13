<!--
Labels: bug, priority::high, k8s-event-triage
Milestone: Pipeline — Fix & Stabilise
Assignee:
-->

# Workflows created but pods not running — debug and fix

## Problem

The sensor is successfully creating Workflow CRs in `argo-events` namespace (confirmed — events arriving from workload clusters via Alloy). However, workflow pods are **not being created**. The Workflow objects exist but never progress to running state.

## Root Cause Investigation

Run through these checks in order:

### 1. Check workflow status
```bash
kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -20

# Detailed status of latest workflow
kubectl get workflow -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage \
  --sort-by=.metadata.creationTimestamp -o json | jq '.items[-1] | {
    name: .metadata.name,
    phase: .status.phase,
    message: .status.message,
    conditions: .status.conditions
  }'
```

### 2. Check if workflow controller watches argo-events namespace
```bash
kubectl get configmap workflow-controller-configmap -n argo -o yaml
# Look for: managedNamespace, namespace, or namespaceParallelism
```

**Most likely cause:** The Argo workflow controller (in `argo` namespace) only manages its own namespace by default. If `managedNamespace` is set to `argo`, it ignores workflows in `argo-events`.

### 3. Check workflow controller logs
```bash
kubectl logs -n argo -l app=workflow-controller --tail=100 | grep -i -E "error|fail|k8s-triage"
```

### 4. Check RBAC
```bash
kubectl auth can-i create pods -n argo-events --as=system:serviceaccount:argo:argo-workflow-controller
```

### 5. Nuclear test — manual workflow
```bash
cat <<'EOF' | kubectl create -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-manual-
  namespace: argo-events
spec:
  serviceAccountName: argo-events-sa
  entrypoint: hello
  templates:
    - name: hello
      container:
        image: alpine:3.18
        command: [echo, "hello from argo-events namespace"]
EOF
kubectl get pods -n argo-events -w
```

## Fix Options

**Option A (preferred):** Configure controller to watch all namespaces
```bash
kubectl edit configmap workflow-controller-configmap -n argo
# Set managedNamespace: "" (empty = all namespaces)
# Restart controller after
```

**Option B:** Move WorkflowTemplate + Sensor to `argo` namespace (simpler but changes the architecture)

## Acceptance Criteria

- [ ] Workflow pods are created when sensor triggers a workflow
- [ ] Workflow runs to completion (Succeeded status)
- [ ] `kubectl get workflows -n argo-events` shows recent Succeeded workflows
- [ ] Root cause documented in GOTCHAS.md
