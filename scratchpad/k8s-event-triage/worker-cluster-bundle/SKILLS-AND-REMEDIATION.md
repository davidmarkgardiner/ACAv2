# KAgent Skills & Remediation Setup

## Skills (Executable Code Bundles)

Skills in kagent 0.8.0+ are real code bundles (scripts, tools) loaded into the agent pod at startup via an init container (`skills-init`).

### How It Works

1. You define `spec.skills` on the Agent CRD
2. Kagent creates an init container using `cr.kagent.dev/kagent-dev/kagent/skills-init:<version>`
3. The init container clones git repos / pulls OCI images into an `emptyDir` volume at `/skills`
4. The main agent container mounts `/skills` read-only and discovers skills via `SKILL.md` files
5. The agent can execute scripts via the built-in `BashTool` (sandboxed)

### Skill Directory Structure

```
my-skill/
├── SKILL.md          # Required: frontmatter (name, description) + instructions
├── scripts/          # Optional: executable scripts the agent can run
│   └── diagnose.py
└── LICENSE.txt       # Optional
```

### SKILL.md Format

```markdown
---
name: cert-diagnostics
description: Diagnose cert-manager certificate issues
license: Complete terms in LICENSE.txt
---

# Cert Diagnostics

Run `scripts/diagnose.py` with the namespace as argument to check certificate health.
```

### Option 1: Git Repos (No Container Build Needed)

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: cert-manager-agent
  namespace: kagent
spec:
  type: Declarative
  skills:
    gitRefs:
      - url: "https://github.com/your-org/your-skills-repo.git"
        ref: main
        path: skills/cert-diagnostics    # subdirectory in the repo
        name: cert-diagnostics            # mounted as /skills/cert-diagnostics
    # Optional: for private repos
    gitAuthSecretRef:
      name: git-credentials
  declarative:
    # ... rest of agent spec
```

### Option 2: OCI Image Refs

```yaml
spec:
  skills:
    refs:
      - "ghcr.io/your-org/skills/cert-diagnostics:latest"
```

### Git Auth Secret (for private repos)

#### GitHub PAT Permissions Required

The skills-init container only needs to `git clone` repos. Minimum scopes:

| PAT Type | Scope | Notes |
|----------|-------|-------|
| **Fine-Grained** (recommended) | `Contents: Read-only` | Scope to specific repo(s) only |
| **Classic** | `repo` | Required for private repos; no scopes needed for public repos |

#### Create the Secret

```bash
kubectl create secret generic git-credentials \
  --namespace kagent \
  --from-literal=token="ghp_your_github_pat"
```

#### Or via manifest

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: git-credentials
  namespace: kagent
type: Opaque
stringData:
  token: "ghp_your_github_pat"     # HTTPS auth
  # OR
  # ssh-privatekey: |              # SSH auth
  #   -----BEGIN OPENSSH PRIVATE KEY-----
  #   ...
```

### Skills vs A2A Skills

| Feature | `spec.skills` | `a2aConfig.skills` |
|---------|---------------|---------------------|
| Purpose | Executable code bundles | Metadata for agent-to-agent discovery |
| Contains | Scripts, SKILL.md, files | Description, examples, tags |
| Runtime | Loaded into pod, executed via BashTool | Not executed — just a catalog entry |
| Requires | skills-init image, emptyDir volume | Nothing extra |

---

## Remediation Setup

The `kagent-tool-server` includes write/mutate tools out of the box:

- `k8s_patch_resource`
- `k8s_create_resource`
- `k8s_create_resource_from_url`
- `k8s_delete_resource`
- `k8s_apply_manifest`
- `k8s_execute_command`
- `k8s_label_resource` / `k8s_remove_label`
- `k8s_annotate_resource` / `k8s_remove_annotation`

### What You Need

Two things must be in place for remediation to work:

### 1. RBAC — Grant Write Permissions

The `kagent-tool-server` uses the agent pod's service account for kubectl calls. By default this may only have read access.

#### Cluster-Wide Remediation

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-remediation
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "replicasets", "statefulsets", "daemonsets", "jobs", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch", "patch", "update", "delete", "create"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies", "ingresses"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["cert-manager.io"]
    resources: ["certificates", "issuers", "clusterissuers", "certificaterequests"]
    verbs: ["get", "list", "watch", "patch", "update", "delete", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kagent-remediation-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kagent-remediation
subjects:
  - kind: ServiceAccount
    name: kagent
    namespace: kagent
```

#### Namespace-Scoped Remediation (Safer)

Use a `RoleBinding` per namespace to limit blast radius:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagent-remediation
  namespace: cert-manager    # scope to specific namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kagent-remediation
subjects:
  - kind: ServiceAccount
    name: kagent
    namespace: kagent
```

### 2. System Prompt — Tell the Agent to Act

Add remediation instructions to the agent's `systemMessage`. Without this, agents will diagnose but not fix:

```yaml
systemMessage: |
  You are a Kubernetes diagnostic and remediation agent for the cert-manager namespace.

  ## Remediation Policy

  When you identify the root cause of an issue:
  1. Attempt to fix it using available tools (k8s_patch_resource, k8s_apply_manifest, etc.)
  2. DO NOT perform destructive operations (deleting PVCs with data, deleting namespaces) without context
  3. Safe remediation actions (always attempt):
     - Restart a crashed pod (delete pod, let controller recreate)
     - Patch a misconfigured resource (fix labels, annotations, env vars)
     - Scale a deployment up/down
     - Update resource limits/requests
  4. After applying a fix, verify the resource has recovered using k8s_get_events and k8s_describe_resource
  5. Report what you did and the outcome

  CRITICAL: always use exact namespace 'cert-manager' when investigating.
```

### Verify RBAC Is Working

```bash
# Check what SA your agent pods use
kubectl get pods -n kagent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\n"}{end}'

# Test if the SA can patch deployments in cert-manager
kubectl auth can-i patch deployments -n cert-manager --as=system:serviceaccount:kagent:kagent

# Test if the SA can delete pods in cert-manager
kubectl auth can-i delete pods -n cert-manager --as=system:serviceaccount:kagent:kagent
```

### Tools to Include in Agent for Remediation

At minimum, include these in your agent's `toolNames`:

```yaml
tools:
  - type: McpServer
    mcpServer:
      kind: RemoteMCPServer
      name: kagent-tool-server
      toolNames:
        # Read (diagnosis)
        - k8s_get_resources
        - k8s_get_resource_yaml
        - k8s_describe_resource
        - k8s_get_events
        - k8s_get_pod_logs
        - k8s_get_available_api_resources
        # Write (remediation)
        - k8s_patch_resource
        - k8s_create_resource
        - k8s_delete_resource
        - k8s_apply_manifest
        - k8s_execute_command
```
