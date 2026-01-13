---
name: flux-gitops
description: Implement GitOps workflows using Flux CD v2 including GitRepositories, Kustomizations, HelmReleases, ImageAutomation, notifications, and multi-tenancy patterns. This skill should be used when setting up GitOps pipelines, configuring Flux sources and reconciliation, implementing Helm deployments via GitOps, setting up image automation, or troubleshooting Flux sync issues.
---

# Flux GitOps Workflow

## Overview

This skill provides comprehensive guidance for implementing GitOps workflows using Flux CD v2, from basic setup to advanced multi-tenancy and image automation patterns.

## Flux Architecture

```
Flux Components
├── Source Controller
│   ├── GitRepository - Git source
│   ├── OCIRepository - OCI artifacts
│   ├── HelmRepository - Helm charts
│   └── Bucket - S3-compatible storage
├── Kustomize Controller
│   └── Kustomization - Deploy manifests
├── Helm Controller
│   └── HelmRelease - Helm chart deployments
├── Notification Controller
│   ├── Provider - Alert destinations
│   ├── Alert - Notification rules
│   └── Receiver - Incoming webhooks
└── Image Automation
    ├── ImageRepository - Track image tags
    ├── ImagePolicy - Select image versions
    └── ImageUpdateAutomation - Update Git
```

## Bootstrap and Setup

### Install Flux CLI

```bash
# macOS
brew install fluxcd/tap/flux

# Linux
curl -s https://fluxcd.io/install.sh | sudo bash

# Verify
flux --version
flux check --pre
```

### Bootstrap to Git Repository

```bash
# GitHub
flux bootstrap github \
  --owner=<org> \
  --repository=<repo> \
  --path=clusters/production \
  --personal

# Azure DevOps
flux bootstrap git \
  --url=https://dev.azure.com/<org>/<project>/_git/<repo> \
  --branch=main \
  --path=clusters/production \
  --token-auth

# GitLab
flux bootstrap gitlab \
  --owner=<group> \
  --repository=<repo> \
  --path=clusters/production
```

## Source Configuration

### GitRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: app-source
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/org/app-repo
  ref:
    branch: main
  secretRef:
    name: git-credentials  # For private repos
  ignore: |
    # Exclude files from reconciliation
    !.git
    !/deploy
```

### HelmRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
# OCI-based Helm repository
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: azure-marketplace
  namespace: flux-system
spec:
  type: oci
  interval: 1h
  url: oci://mcr.microsoft.com/azuremarketplace/charts
```

### OCIRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: manifests
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/org/manifests
  ref:
    tag: latest
  secretRef:
    name: oci-credentials
```

## Kustomization

### Basic Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-deployment
  namespace: flux-system
spec:
  interval: 10m
  targetNamespace: production
  sourceRef:
    kind: GitRepository
    name: app-source
  path: ./deploy/overlays/production
  prune: true
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: my-app
      namespace: production
  timeout: 5m
```

### Kustomization with Dependencies

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure
  prune: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  dependsOn:
    - name: infrastructure
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps
  prune: true
```

### Kustomization with Variable Substitution

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-config
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: app-source
  path: ./deploy
  prune: true
  postBuild:
    substitute:
      ENVIRONMENT: production
      REPLICAS: "3"
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
      - kind: Secret
        name: cluster-secrets
```

## HelmRelease

### Basic HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: podinfo
      version: ">=6.0.0"
      sourceRef:
        kind: HelmRepository
        name: podinfo
        namespace: flux-system
  values:
    replicaCount: 2
    ingress:
      enabled: true
```

### HelmRelease with Values from ConfigMap/Secret

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
  namespace: production
spec:
  interval: 5m
  chart:
    spec:
      chart: my-app
      version: "1.0.0"
      sourceRef:
        kind: HelmRepository
        name: private-charts
        namespace: flux-system
  valuesFrom:
    - kind: ConfigMap
      name: app-values
      valuesKey: values.yaml
    - kind: Secret
      name: app-secrets
      valuesKey: secrets.yaml
  values:
    environment: production
```

### HelmRelease with Drift Detection

```yaml
spec:
  driftDetection:
    mode: enabled  # or warn
    ignore:
      - paths: ["/spec/replicas"]
        target:
          kind: Deployment
```

## Image Automation

### Track Image Updates

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  image: myregistry.azurecr.io/my-app
  interval: 5m
  secretRef:
    name: acr-credentials
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: my-app
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: my-app
  policy:
    semver:
      range: ">=1.0.0"
    # Or use alphabetical/numerical ordering
    # alphabetical:
    #   order: asc
    # numerical:
    #   order: asc
```

### Auto-Update Git Repository

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: my-app-automation
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: app-source
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: flux@company.com
        name: Flux Automation
      messageTemplate: |
        Automated image update

        Updates:
        {{range .Updated.Images}}
        - {{.}}
        {{end}}
    push:
      branch: main
  update:
    path: ./deploy
    strategy: Setters
```

### Mark Images for Update

```yaml
# In your deployment manifest
spec:
  containers:
  - name: app
    image: myregistry.azurecr.io/my-app:1.0.0 # {"$imagepolicy": "flux-system:my-app"}
```

## Notifications

### Configure Alert Provider

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack
  namespace: flux-system
spec:
  type: slack
  channel: deployments
  secretRef:
    name: slack-webhook
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: teams
  namespace: flux-system
spec:
  type: msteams
  secretRef:
    name: teams-webhook
```

### Create Alerts

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: deployment-alerts
  namespace: flux-system
spec:
  providerRef:
    name: slack
  eventSeverity: error
  eventSources:
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
  exclusionList:
    - ".*upgrade.*"
```

### Webhook Receiver

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Receiver
metadata:
  name: github-webhook
  namespace: flux-system
spec:
  type: github
  events:
    - ping
    - push
  secretRef:
    name: webhook-secret
  resources:
    - kind: GitRepository
      name: app-source
```

## Multi-Tenancy

### Repository Structure

```
clusters/
├── production/
│   ├── flux-system/           # Flux components
│   ├── infrastructure/        # Shared infra
│   └── tenants/               # Tenant configs
│       ├── tenant-a/
│       │   ├── kustomization.yaml
│       │   └── rbac.yaml
│       └── tenant-b/
│           ├── kustomization.yaml
│           └── rbac.yaml
infrastructure/
├── sources/                    # Shared sources
├── policies/                   # Kyverno/OPA
└── monitoring/                 # Observability
tenants/
├── tenant-a/
│   └── apps/
└── tenant-b/
    └── apps/
```

### Tenant Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tenant-a
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: tenants
  path: ./tenants/tenant-a
  prune: true
  serviceAccountName: tenant-a-reconciler
  targetNamespace: tenant-a
```

## Troubleshooting

### Check Flux Status

```bash
# Overall status
flux check

# Get all Flux resources
flux get all -A

# Check specific resource
flux get sources git -n flux-system
flux get kustomizations -n flux-system
flux get helmreleases -n flux-system
```

### Debug Reconciliation

```bash
# Force reconciliation
flux reconcile source git <name>
flux reconcile kustomization <name>
flux reconcile helmrelease <name>

# View logs
flux logs --level=error
flux logs --kind=Kustomization --name=<name>

# Describe resource
kubectl describe kustomization <name> -n flux-system
kubectl describe helmrelease <name> -n <namespace>
```

### Common Issues

**Source Not Ready:**
```bash
# Check source status
kubectl get gitrepository -A
kubectl describe gitrepository <name> -n flux-system

# Verify credentials
kubectl get secret <secret-name> -n flux-system -o yaml
```

**Kustomization Failed:**
```bash
# Check events
kubectl get events -n flux-system --field-selector involvedObject.name=<kustomization>

# Validate locally
kustomize build ./path/to/kustomization
```

**HelmRelease Not Reconciling:**
```bash
# Check helm history
helm history <release-name> -n <namespace>

# View HelmRelease conditions
kubectl get helmrelease <name> -n <namespace> -o yaml | yq '.status.conditions'
```

Run `scripts/flux-diagnostics.sh` for comprehensive troubleshooting:
```bash
./scripts/flux-diagnostics.sh
```

## Quick Reference

| Task | Command |
|------|---------|
| Check status | `flux get all -A` |
| Force sync | `flux reconcile kustomization <name>` |
| View logs | `flux logs --level=error` |
| Suspend/Resume | `flux suspend/resume kustomization <name>` |
| Export resources | `flux export source git <name>` |
| Trace issues | `flux trace kustomization <name>` |

## Resources

- **scripts/flux-diagnostics.sh** - Comprehensive Flux health check
- **scripts/flux-export-all.sh** - Export all Flux resources
- **references/flux-crd-reference.md** - Complete CRD field reference
- **assets/flux-templates/** - Starter templates for common patterns
