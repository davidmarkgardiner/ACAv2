# Debug: Workflows Created but Pods Not Running

The sensor is creating Workflow CRs, but the workflow pods aren't being created. Work through these steps in order.

---

## Step 1: Check Workflow Status

```bash
# List recent workflows - look at STATUS and MESSAGE columns
kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -20

# Get detailed status of one failing workflow
kubectl get workflow -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage \
  --sort-by=.metadata.creationTimestamp -o json | jq '.items[-1] | {
    name: .metadata.name,
    phase: .status.phase,
    message: .status.message,
    conditions: .status.conditions,
    nodes: (.status.nodes // {} | to_entries[] | {name: .value.displayName, phase: .value.phase, message: .value.message})
  }'
```

Common failure messages:
- **"failed to resolve"** → WorkflowTemplate not found (name mismatch or wrong namespace)
- **"error creating"** → RBAC issue creating pods
- **"exceeded quota"** → ResourceQuota blocking pod creation

---

## Step 2: Check Workflow Controller Logs

```bash
# Find the workflow controller (runs in argo namespace usually)
kubectl get pods -n argo -l app=workflow-controller

# Check controller logs for errors about your workflows
kubectl logs -n argo -l app=workflow-controller --tail=100 | grep -i -E "error|fail|k8s-triage"

# If controller is in a different namespace:
kubectl get pods -A -l app=workflow-controller
```

Key things to look for:
- **"Failed to submit workflow"** → controller can't process the workflow
- **"serviceaccount not found"** → `argo-events-sa` doesn't exist or isn't in the right namespace
- **"pods is forbidden"** → RBAC issue - the SA can't create pods

---

## Step 3: Check RBAC for Pod Creation

The `argo-events-sa` service account needs permission to create pods in `argo-events` namespace. Your current RBAC only grants `workflows`, `workflowtemplates`, and `workflowtaskresults` — **it's missing pod creation permissions**.

```bash
# Check what the SA can actually do
kubectl auth can-i create pods -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa
kubectl auth can-i create pods/log -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa
kubectl auth can-i get pods -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa

# Check all RBAC bindings for the SA
kubectl get rolebindings,clusterrolebindings -A -o json | jq '.items[] | select(.subjects[]? | .name == "argo-events-sa" and .namespace == "argo-events") | {name: .metadata.name, namespace: .metadata.namespace, role: .roleRef.name}'
```

**NOTE:** In Argo Workflows, the workflow controller (not the SA) creates the pods. BUT the controller checks the SA's permissions. The controller needs RBAC to create pods in the `argo-events` namespace. Check which SA the controller uses and whether it has cross-namespace permissions.

---

## Step 4: Check if Workflow Controller Manages `argo-events` Namespace

By default, the Argo workflow controller only manages workflows in its own namespace (usually `argo`). If your workflows are in `argo-events`, the controller may be ignoring them entirely.

```bash
# Check controller config - look for managed namespaces
kubectl get configmap workflow-controller-configmap -n argo -o yaml

# Look for these keys:
# - namespace: (if set, controller only watches this namespace)
# - managedNamespace: (same)
# - namespaceParallelism: (limits concurrent namespaces)
```

**Fix options:**

**Option A: Configure controller to watch `argo-events` namespace**
```bash
kubectl edit configmap workflow-controller-configmap -n argo
# Add or modify:
# managedNamespace: "" (empty = all namespaces)
# OR ensure it's not restricted to just "argo"
```

**Option B: Move workflows to `argo` namespace** (simpler)
- Change `namespace: argo-events` → `namespace: argo` in both `07-workflow-template.yaml` and `08-sensor.yaml`
- Copy the RBAC to the `argo` namespace

---

## Step 5: Check for Image Pull Issues

If pods are being created but immediately failing:

```bash
# Look for pending/failed pods
kubectl get pods -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage

# Check events in the namespace (pod scheduling, image pull, etc.)
kubectl get events -n argo-events --sort-by=.lastTimestamp | tail -30

# Check if the image is pullable
kubectl run test-pull --image=badouralix/curl-jq:alpine --rm -it --restart=Never -n argo-events -- echo "image works"
```

---

## Step 6: Check Sensor Logs

The sensor creates the Workflow CR. Verify it's doing that successfully:

```bash
# Get sensor pod logs
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=100

# Look for trigger execution results
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=100 | grep -i -E "trigger|workflow|error|fail"
```

---

## Quick Fix Checklist

Most likely cause: **workflow controller doesn't watch `argo-events` namespace**.

1. Check: `kubectl get configmap workflow-controller-configmap -n argo -o yaml`
2. If `managedNamespace` is set to `argo`, either:
   - Change it to `""` (all namespaces) and restart the controller
   - OR move your WorkflowTemplate + Sensor to target `argo` namespace instead

Second most likely: **RBAC** — the controller's SA needs pod/create in `argo-events`.

```bash
# Quick RBAC check
kubectl auth can-i create pods -n argo-events --as=system:serviceaccount:argo:argo-server
kubectl auth can-i create pods -n argo-events --as=system:serviceaccount:argo:argo-workflow-controller
```

---

## Nuclear Option: Test a Manual Workflow

Submit a bare-minimum workflow directly to confirm the controller can run anything in `argo-events`:

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

# Watch it
kubectl get workflow -n argo-events -w
kubectl get pods -n argo-events -w
```

If this also doesn't create pods → the controller definitely isn't watching `argo-events`.
If this works but sensor-triggered ones don't → the sensor is creating malformed Workflow CRs.
