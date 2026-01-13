---
name: kyverno-policies
description: Write, validate, test, and deploy Kyverno policies for Kubernetes security and governance. This skill covers policy types (validate, mutate, generate, verifyImages), policy testing with kyverno CLI, policy exceptions, and GitOps deployment patterns. This skill should be used when creating security policies, enforcing best practices, implementing admission control, or automating resource generation in Kubernetes clusters.
---

# Kyverno Policies

## Overview

This skill provides guidance for writing, testing, and deploying Kyverno policies for Kubernetes admission control, mutation, and resource generation.

## Policy Types

```
Kyverno Policy Types
├── Validate → Enforce rules, block or audit non-compliant resources
├── Mutate → Automatically modify resources on creation/update
├── Generate → Create additional resources when triggers fire
└── VerifyImages → Validate container image signatures and attestations
```

## Writing Validate Policies

### Basic Structure

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require Labels
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Requires all pods to have specific labels.
spec:
  validationFailureAction: Enforce  # or Audit
  background: true
  rules:
    - name: check-labels
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "Label 'app.kubernetes.io/name' is required."
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
```

### Common Validate Patterns

**Require Resource Limits:**
```yaml
spec:
  rules:
    - name: require-limits
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "CPU and memory limits are required."
        pattern:
          spec:
            containers:
            - resources:
                limits:
                  memory: "?*"
                  cpu: "?*"
```

**Deny Privileged Containers:**
```yaml
spec:
  rules:
    - name: deny-privileged
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            containers:
            - securityContext:
                privileged: "!true"
```

**Restrict Image Registries:**
```yaml
spec:
  rules:
    - name: validate-registries
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "Images must be from approved registries."
        pattern:
          spec:
            containers:
            - image: "myregistry.azurecr.io/* | gcr.io/my-project/*"
```

## Writing Mutate Policies

### Add Default Labels

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-labels
spec:
  rules:
    - name: add-labels
      match:
        any:
        - resources:
            kinds:
            - Pod
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              +(environment): "production"
              +(managed-by): "kyverno"
```

### Inject Sidecar Container

```yaml
spec:
  rules:
    - name: inject-sidecar
      match:
        any:
        - resources:
            kinds:
            - Deployment
            namespaces:
            - production
      mutate:
        patchStrategicMerge:
          spec:
            template:
              spec:
                containers:
                - name: sidecar
                  image: my-sidecar:latest
                  resources:
                    limits:
                      memory: "64Mi"
                      cpu: "100m"
```

### Set Default Security Context

```yaml
spec:
  rules:
    - name: set-security-context
      match:
        any:
        - resources:
            kinds:
            - Pod
      mutate:
        patchStrategicMerge:
          spec:
            securityContext:
              +(runAsNonRoot): true
              +(seccompProfile):
                +(type): RuntimeDefault
            containers:
            - (name): "*"
              securityContext:
                +(allowPrivilegeEscalation): false
                +(readOnlyRootFilesystem): true
```

## Writing Generate Policies

### Generate NetworkPolicy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-network-policy
spec:
  rules:
    - name: generate-netpol
      match:
        any:
        - resources:
            kinds:
            - Namespace
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            podSelector: {}
            policyTypes:
            - Ingress
            - Egress
```

### Generate ResourceQuota

```yaml
spec:
  rules:
    - name: generate-quota
      match:
        any:
        - resources:
            kinds:
            - Namespace
            selector:
              matchLabels:
                type: tenant
      generate:
        apiVersion: v1
        kind: ResourceQuota
        name: default-quota
        namespace: "{{request.object.metadata.name}}"
        synchronize: true
        data:
          spec:
            hard:
              requests.cpu: "4"
              requests.memory: "8Gi"
              limits.cpu: "8"
              limits.memory: "16Gi"
```

## Image Verification

### Verify Image Signatures

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds:
            - Pod
      verifyImages:
      - imageReferences:
        - "myregistry.azurecr.io/*"
        attestors:
        - entries:
          - keyless:
              subject: "https://github.com/my-org/*"
              issuer: "https://token.actions.githubusercontent.com"
              rekor:
                url: https://rekor.sigstore.dev
```

## Policy Testing

### Using Kyverno CLI

```bash
# Install Kyverno CLI
kubectl krew install kyverno

# Test policy against resource
kyverno apply policy.yaml --resource resource.yaml

# Test with multiple resources
kyverno apply policy.yaml --resource-dir ./resources/

# Test with variables
kyverno apply policy.yaml --resource resource.yaml \
  --set request.namespace=production

# Validate policy syntax
kyverno validate policy.yaml
```

### Test Script

Run `scripts/test-policy.sh` to validate and test policies:

```bash
./scripts/test-policy.sh policies/ test-resources/
```

### Writing Test Cases

```yaml
# test-require-labels.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: test-require-labels
policies:
  - require-labels.yaml
resources:
  - pod-with-labels.yaml
  - pod-without-labels.yaml
results:
  - policy: require-labels
    rule: check-labels
    resource: pod-with-labels
    status: pass
  - policy: require-labels
    rule: check-labels
    resource: pod-without-labels
    status: fail
```

Run test:
```bash
kyverno test .
```

## Policy Exceptions

### Create Exception for Specific Workload

```yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: allow-privileged-monitoring
  namespace: monitoring
spec:
  exceptions:
  - policyName: disallow-privileged
    ruleNames:
    - deny-privileged
  match:
    any:
    - resources:
        kinds:
        - Pod
        namespaces:
        - monitoring
        names:
        - "prometheus-*"
        - "node-exporter-*"
```

## GitOps Deployment

### Directory Structure

```
policies/
├── cluster-policies/
│   ├── security/
│   │   ├── disallow-privileged.yaml
│   │   ├── require-non-root.yaml
│   │   └── restrict-registries.yaml
│   ├── best-practices/
│   │   ├── require-labels.yaml
│   │   └── require-probes.yaml
│   └── mutations/
│       ├── add-default-labels.yaml
│       └── set-security-context.yaml
├── policy-exceptions/
│   └── monitoring-exceptions.yaml
└── kustomization.yaml
```

### Kustomization

```yaml
# policies/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster-policies/security/
  - cluster-policies/best-practices/
  - cluster-policies/mutations/
  - policy-exceptions/
```

## Policy Best Practices

1. **Start with Audit mode** - Use `validationFailureAction: Audit` initially
2. **Add annotations** - Document purpose, category, and severity
3. **Use namespaceSelector** - Exclude system namespaces
4. **Test thoroughly** - Use Kyverno CLI before deployment
5. **Implement gradually** - Roll out policies incrementally
6. **Monitor policy reports** - Check PolicyReports for violations

### Exclude System Namespaces

```yaml
spec:
  rules:
    - name: require-labels
      match:
        any:
        - resources:
            kinds:
            - Pod
      exclude:
        any:
        - resources:
            namespaces:
            - kube-system
            - kube-public
            - kyverno
```

## Monitoring and Reports

```bash
# View policy reports
kubectl get policyreport -A
kubectl get clusterpolicyreport

# Get detailed report
kubectl describe policyreport -n <namespace>

# Count violations by policy
kubectl get policyreport -A -o json | jq '.items[].results[] | select(.result=="fail") | .policy' | sort | uniq -c
```

## Quick Reference

| Task | Command |
|------|---------|
| Validate policy | `kyverno validate policy.yaml` |
| Test policy | `kyverno apply policy.yaml --resource test.yaml` |
| Run tests | `kyverno test .` |
| View reports | `kubectl get policyreport -A` |
| Check violations | `kubectl get clusterpolicyreport -o yaml` |

## Resources

- **scripts/test-policy.sh** - Validate and test policies
- **scripts/policy-report-summary.sh** - Generate policy violation summary
- **references/policy-library.md** - Common policy patterns and examples
- **assets/policy-templates/** - Starter policy templates
