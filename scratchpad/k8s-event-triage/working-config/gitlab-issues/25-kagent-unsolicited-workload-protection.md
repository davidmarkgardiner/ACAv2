<!--
Labels: security, kyverno, kagent, k8s-event-triage
Milestone: Phase 3 — Production Security & Migration
Assignee:
-->

# Protect kagent namespace from unsolicited workloads

## Context

The `kagent` namespace runs AI agents with access to cluster resources. If an attacker or misconfigured CI/CD pipeline deploys unauthorized workloads into this namespace, those workloads could inherit permissions or consume resources meant for kagent. This ticket covers admission control, resource limits, and network isolation to prevent unsolicited workloads.

## Problem

- Anyone with `create` permissions on Pods/Deployments in the `kagent` namespace can deploy arbitrary workloads
- Unauthorized pods could consume resources allocated for kagent agents
- Unauthorized pods in the namespace could potentially access kagent's service account tokens or network position

## Solutions

### 1. Kyverno/Gatekeeper Admission Policies

Restrict which workloads can be created in the `kagent` namespace using admission control.

#### Option A: Kyverno ClusterPolicy (recommended — already deployed)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-kagent-namespace
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: only-kagent-controller-creates-pods
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - kagent
      exclude:
        any:
          - subjects:
              - kind: ServiceAccount
                name: kagent-controller
                namespace: kagent
          - subjects:
              - kind: ServiceAccount
                name: argo-workflow-sa
                namespace: argo
      validate:
        message: "Only the kagent controller and Argo workflow service account can create pods in the kagent namespace."
        deny: {}
    - name: require-kagent-labels
      match:
        any:
          - resources:
              kinds:
                - Pod
                - Deployment
                - StatefulSet
              namespaces:
                - kagent
      validate:
        message: "All workloads in kagent namespace must have label 'app.kubernetes.io/managed-by: kagent'"
        pattern:
          metadata:
            labels:
              app.kubernetes.io/managed-by: kagent
```

#### Option B: Gatekeeper ConstraintTemplate (if using OPA)

- Create a `K8sRestrictNamespaceWorkloads` constraint template
- Apply constraint targeting `kagent` namespace
- Only allow workloads with `managed-by: kagent` label

### 2. ResourceQuota — Prevent Resource Exhaustion

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: kagent-quota
  namespace: kagent
spec:
  hard:
    pods: "20"
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    persistentvolumeclaims: "5"
    services.loadbalancers: "0"
    services.nodeports: "0"
```

### 3. LimitRange — Cap Individual Pod Resources

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: kagent-limit-range
  namespace: kagent
spec:
  limits:
    - type: Pod
      max:
        cpu: "2"
        memory: "4Gi"
    - type: Container
      default:
        cpu: "250m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "256Mi"
      max:
        cpu: "2"
        memory: "4Gi"
```

### 4. NetworkPolicy — Isolate kagent Pods

- [ ] Default deny-all ingress and egress in `kagent` namespace
- [ ] Allow egress only to: LiteLLM (port 4000), K8s API (port 6443), DNS (port 53)
- [ ] Allow ingress only from: `argo` namespace (workflow pods calling A2A API)
- [ ] See #24 for detailed NetworkPolicy manifests

### 5. RBAC — Restrict Deployment Permissions

- [ ] Only `kagent-controller` ServiceAccount and cluster admins can create/update Deployments in `kagent` namespace
- [ ] Remove any broad `edit` or `admin` ClusterRoleBindings that grant access to `kagent` namespace
- [ ] Audit existing RoleBindings in `kagent` namespace

## Implementation Steps

- [ ] Deploy Kyverno ClusterPolicy (Option A) to restrict pod creation in `kagent` namespace
- [ ] Apply ResourceQuota to `kagent` namespace
- [ ] Apply LimitRange to `kagent` namespace
- [ ] Apply NetworkPolicy (default deny + explicit allow rules)
- [ ] Audit existing RBAC bindings for `kagent` namespace
- [ ] Test: attempt to deploy an unauthorized pod — verify it is rejected
- [ ] Test: verify kagent controller can still create agent pods
- [ ] Test: verify Argo workflow pods can still call kagent A2A API

## Acceptance Criteria

- [ ] Non-kagent workloads are **rejected** from the `kagent` namespace by admission control
- [ ] Resource usage in `kagent` namespace is bounded by ResourceQuota
- [ ] Individual pod resources are capped by LimitRange
- [ ] No LoadBalancer or NodePort services allowed in `kagent` namespace
- [ ] kagent pods are network-isolated (only LiteLLM, K8s API, DNS egress; only Argo ingress)
- [ ] Existing kagent functionality is not broken by the new policies
