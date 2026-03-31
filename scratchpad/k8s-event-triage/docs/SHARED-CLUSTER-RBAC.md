# Shared Cluster — KAgent & LLM Access Control

How to restrict KAgent CRDs and LiteLLM to platform team admins only on a shared AKS cluster.

---

## The Problem

KAgent CRDs (Agent, ModelConfig, RemoteMCPServer) and LiteLLM run on a shared cluster. Other teams shouldn't be able to create agents, change model configs, or call the LLM directly.

## 4 Layers of Protection

### 1. RBAC on KAgent CRDs

Only `platform-team-admins` Azure AD group can manage kagent resources:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-admin
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "remotemcpservers", "tools"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["pods", "services"]
    resourceNames: ["kagent-controller", "kagent-tool-server"]
    verbs: ["get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagent-admin-binding
subjects:
  - kind: Group
    name: "platform-team-admins"  # Azure AD group
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: kagent-admin
  apiGroup: rbac.authorization.k8s.io
```

### 2. Namespace RBAC

Only platform team can deploy into the `kagent` namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagent-namespace-admin
  namespace: kagent
subjects:
  - kind: Group
    name: "platform-team-admins"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
```

### 3. NetworkPolicy on LiteLLM

Only pods in `kagent` namespace can reach LiteLLM. Other teams' workloads are blocked:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: litellm-ingress
  namespace: kagent
spec:
  podSelector:
    matchLabels:
      app: litellm
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kagent
```

Combined with LiteLLM API keys — one key per consumer, rate-limited, revocable.

### 4. Kyverno Policy (belt-and-braces)

Even if someone gets RBAC through another path, Kyverno denies CRD creation:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-kagent-crds
spec:
  validationFailureAction: Enforce
  rules:
    - name: only-platform-team
      match:
        any:
          - resources:
              kinds:
                - Agent
                - ModelConfig
                - RemoteMCPServer
      exclude:
        any:
          - subjects:
              - kind: Group
                name: "platform-team-admins"
          - subjects:
              - kind: ServiceAccount
                name: "kagent-controller"
                namespace: "kagent"
      validate:
        message: "Only the platform team can manage kagent resources"
        deny: {}
```

---

## Summary

| Layer | Protects | Mechanism |
|-------|----------|-----------|
| ClusterRole RBAC | KAgent CRDs | Only `platform-team-admins` has verbs |
| Namespace RBAC | `kagent` namespace | Only platform team can deploy/modify |
| NetworkPolicy | LiteLLM service | Only `kagent` pods reach port 4000 |
| Kyverno policy | CRD creation | Deny by non-platform users at admission |

## TODO

- [ ] Replace `platform-team-admins` with actual Azure AD group object ID
- [ ] Create LiteLLM API keys per consumer and configure rate limits
- [ ] Apply and test on shared cluster
- [ ] Verify: non-platform user cannot `kubectl apply -f agent.yaml`
- [ ] Verify: non-kagent pod cannot `curl litellm:4000`
