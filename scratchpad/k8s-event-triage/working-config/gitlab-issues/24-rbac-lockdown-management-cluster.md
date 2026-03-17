<!--
Labels: security, rbac, kagent, k8s-event-triage
Milestone: Phase 3 — Production Security & Migration
Assignee:
-->

# RBAC lockdown — secure kagent on management cluster

## Context

As kagent agents move toward production, the management cluster needs strict RBAC controls. Currently agents may have broader access than necessary. This ticket covers locking down service accounts, network access, and audit logging for kagent on the management cluster.

## Requirements

### 1. Read-Only by Default

- [ ] All kagent triage agents use **read-only** service accounts
- [ ] Allowed verbs: `get`, `list`, `watch`, `describe`
- [ ] No `create`, `delete`, `patch`, `update` unless explicitly granted for remediation agents
- [ ] Remediation agents (future, per #18 human-in-the-loop) use a separate service account with write access

### 2. Namespace-Scoped RBAC

- [ ] Each agent has a dedicated `ServiceAccount` in the `kagent` namespace
- [ ] Each agent has a `Role` (not `ClusterRole`) in its target namespace only
- [ ] `RoleBinding` links the agent's SA to the target namespace Role
- [ ] No agent can access namespaces outside its assignment

Example:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kagent-cert-manager-reader
  namespace: cert-manager
rules:
  - apiGroups: ["", "apps", "batch", "cert-manager.io"]
    resources: ["pods", "events", "deployments", "replicasets", "jobs",
                "certificates", "certificaterequests", "issuers", "clusterissuers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagent-cert-manager-reader-binding
  namespace: cert-manager
subjects:
  - kind: ServiceAccount
    name: kagent-cert-manager-agent
    namespace: kagent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kagent-cert-manager-reader
```

### 3. NetworkPolicy — Restrict kagent Pod Communication

- [ ] kagent pods can only reach:
  - LiteLLM proxy service (ClusterIP, port 4000)
  - Kubernetes API server (port 6443)
- [ ] kagent pods cannot receive ingress from outside the cluster
- [ ] kagent pods cannot reach the internet directly (egress restricted)
- [ ] LiteLLM proxy can reach Azure OpenAI endpoint only (egress restricted)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kagent-egress-restrict
  namespace: kagent
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: kagent
  policyTypes:
    - Egress
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argo
      ports:
        - port: 8080
          protocol: TCP
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - port: 6443
          protocol: TCP
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: litellm
      ports:
        - port: 4000
          protocol: TCP
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

### 4. No External Ingress

- [ ] kagent A2A API is ClusterIP only — no Ingress, no LoadBalancer
- [ ] No NodePort services in kagent namespace
- [ ] Argo Workflows accesses kagent via internal ClusterIP service only

### 5. Audit Logging

- [ ] Enable Kubernetes audit logging for kagent service accounts
- [ ] All API calls made by kagent agents are logged with:
  - Timestamp, verb, resource, namespace, response code
- [ ] Audit logs forwarded to Loki via Alloy (ties into #19)
- [ ] Alert on unexpected write operations from triage (read-only) agents

### 6. Prevent Unsolicited Workloads in kagent Namespace

- [ ] See dedicated ticket #25 for Kyverno/Gatekeeper policies
- [ ] This ticket covers RBAC: restrict who can create Deployments/Pods in `kagent` namespace

### 7. Service Account Token Rotation

- [ ] Use bound service account tokens (automatic in K8s 1.24+)
- [ ] Set token expiry to 1 hour (default)
- [ ] No long-lived static tokens for kagent service accounts
- [ ] Verify `automountServiceAccountToken: false` on pods that do not need API access

## Acceptance Criteria

- [ ] kagent triage agents can only **read** resources in their assigned namespaces
- [ ] kagent agents **cannot** create, delete, or modify cluster-scoped resources
- [ ] kagent pods cannot reach arbitrary endpoints (NetworkPolicy enforced)
- [ ] No external ingress to kagent API
- [ ] All kagent API calls are captured in audit logs
- [ ] Service account tokens are short-lived and auto-rotated
- [ ] RBAC matrix documented (agent → namespace → verbs → resources)
