<!--
Labels: infrastructure, priority::high, k8s-event-triage
Milestone: Pipeline — Production Hardening
Assignee:
-->

# Configure workflow controller for argo-events namespace

## Context

Argo Workflows controller (in `argo` namespace) needs to manage workflows in `argo-events` namespace. By default, the controller may only watch its own namespace.

## Tasks

- [ ] Check current controller config: `kubectl get configmap workflow-controller-configmap -n argo -o yaml`
- [ ] Set `managedNamespace: ""` or add `argo-events` to the watched namespaces
- [ ] Ensure the controller's service account has RBAC to create pods in `argo-events`
- [ ] Restart controller: `kubectl rollout restart deployment/workflow-controller -n argo`
- [ ] Verify with manual workflow submission to `argo-events` namespace

## RBAC Required

The workflow controller SA needs in `argo-events`:
- `pods` — create, get, list, watch, delete
- `pods/log` — get
- `configmaps` — get (for artifact storage)
- `workflows` — get, list, watch, update, patch

## Acceptance Criteria

- [ ] `kubectl get configmap workflow-controller-configmap -n argo -o yaml` shows `argo-events` is managed
- [ ] Manual workflow in `argo-events` creates pods and runs to Succeeded
- [ ] Controller logs show no RBAC errors
