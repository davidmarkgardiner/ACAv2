# kagent-tools Deployment Guide

The kagent tool server provides K8s, Helm, Istio, and Cilium tools to agents via MCP protocol.

## Prerequisites

- kagent CRDs installed (`kagent-crds` helm chart)
- kagent controller running
- `kagent` namespace exists

## Install

```bash
helm upgrade --install kagent-tools ./kagent/helm/kagent/charts/kagent-tools-0.0.13.tgz \
  --namespace kagent
```

## Register the MCP Server

After the tool server pod is running, register it so agents can discover it:

```bash
kubectl apply -f - <<'EOF'
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: kagent-tool-server
  namespace: kagent
spec:
  url: "http://kagent-tools.kagent:8084/mcp"
  timeout: 30s
  sseReadTimeout: 5m0s
  description: "Official KAgent tool server"
EOF
```

## Verify

```bash
# Check pod is running
kubectl get pods -n kagent | grep tools

# Check RemoteMCPServer is accepted
kubectl get remotemcpservers -n kagent

# Test connectivity
kubectl run curl-test --rm -it --restart=Never \
  --image=curlimages/curl -n kagent -- \
  curl -s -o /dev/null -w "%{http_code}" \
  http://kagent-tools.kagent:8084/mcp \
  -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"test"}}}'
```

Expected: pod `1/1 Running`, RemoteMCPServer `Accepted: True`, curl returns `200`.

## RBAC Note

The chart creates a ClusterRole with full cluster-admin permissions (`apiGroups: ["*"], resources: ["*"], verbs: ["*"]`). If Azure Policy or OPA/Gatekeeper blocks this, create a scoped-down ClusterRole instead:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kagent-tools
  namespace: kagent
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-tools-readonly
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "rbac.authorization.k8s.io", "storage.k8s.io", "policy", "autoscaling"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "describe"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/log"]
    verbs: ["get", "create"]
  - nonResourceURLs: ["*"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-tools-readwrite
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "rbac.authorization.k8s.io", "storage.k8s.io", "policy", "autoscaling"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/log"]
    verbs: ["get", "create"]
  - nonResourceURLs: ["*"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagent-tools-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kagent-tools-readwrite  # Change to kagent-tools-readonly for read-only
subjects:
- kind: ServiceAccount
  name: kagent-tools
  namespace: kagent
EOF
```

Then install the chart with the existing ServiceAccount:

```bash
helm upgrade --install kagent-tools ./kagent/helm/kagent/charts/kagent-tools-0.0.13.tgz \
  --namespace kagent \
  --set fullnameOverride=kagent-tools
```

## What it deploys

| Resource | Name | Purpose |
|----------|------|---------|
| Deployment | kagent-tools | Tool server pod (port 8084) |
| Service | kagent-tools | ClusterIP service for agents to connect |
| ServiceAccount | kagent-tools | Identity for K8s API access |
| ClusterRole | kagent-tools-cluster-admin-role | Full K8s API access |
| ClusterRoleBinding | kagent-tools-cluster-admin-rolebinding | Binds SA to ClusterRole |

## Image

```
ghcr.io/kagent-dev/kagent/tools:0.0.13
```

If your cluster can't pull from ghcr.io, mirror the image to your internal registry and override:

```bash
helm upgrade --install kagent-tools ./kagent/helm/kagent/charts/kagent-tools-0.0.13.tgz \
  --namespace kagent \
  --set tools.image.registry=your-registry.azurecr.io \
  --set tools.image.repository=kagent/tools \
  --set tools.image.tag=0.0.13
```
