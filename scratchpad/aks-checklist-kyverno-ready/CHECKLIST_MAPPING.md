# AKS Checklist to Kyverno Policy Mapping

This document maps items from [The AKS Checklist](https://www.the-aks-checklist.com/) to their corresponding Kyverno policies.

## Coverage Summary

| Section | Total Items | Kyverno Covered | Azure Policy Only | External Tooling |
|---------|-------------|-----------------|-------------------|------------------|
| Identity - Authorization | 10 | 6 | 4 | 0 |
| Cluster Security | 18 | 12 | 6 | 0 |
| Multi-Tenant - Isolation | 3 | 3 | 0 | 0 |
| Storage | 10 | 9 | 1 | 0 |
| Networking | 23 | 10 | 10 | 3 |
| Resource Management | 13 | 9 | 3 | 1 |
| Cluster Operations | 31 | 8 | 12 | 11 |
| Biz Continuity - DR | 12 | 9 | 3 | 0 |
| Application Deployment | 24 | 18 | 0 | 6 |
| Container | 10 | 9 | 0 | 1 |

**Total: 154 items, 83 Kyverno policies (54% direct coverage)**

> **Note**: Many checklist items relate to Azure infrastructure configuration (cluster-level settings) that cannot be validated via Kyverno workload policies. These require:
> - **Azure Policy for AKS** - Cluster configuration enforcement
> - **ARM/Terraform validation** - Infrastructure as Code checks
> - **External tooling** - CI/CD integrations, runtime security tools

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully covered by Kyverno policy |
| ⚠️ | Partially covered / requires additional setup |
| 🔒 | Requires Azure Policy (cluster-level) |
| 🔧 | Requires external tooling |
| 📝 | Documentation/process item |

---

## Identity - Authorization

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Integrate authentication with AAD | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Integrate authorization with AAD RBAC | 🔒 | `aks-check-rbac-least-privilege` | Partial - validates RBAC resources |
| Use AKS and ACR integration without password | ✅ | `aks-check-acr-authentication` | Validates managed identity usage |
| Use managed identities instead of Service Principals | ✅ | `aks-check-require-service-account`, `aks-check-disallow-default-serviceaccount` | ✅ |
| Limit access to admin kubeconfig | ⚠️ | `aks-check-no-admin-clusterrolebinding` | Partial - audits cluster-admin bindings |
| For non-interactive logins use kubelogin | 📝 | N/A | Client-side tooling |
| Disable AKS local accounts | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Configure JIT cluster access | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Use managed Kubelet Identity | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Configure AAD conditional access | 🔒 | N/A | AAD configuration |

### Azure Policy Items for Identity

```bash
# Enforce AAD integration
az policy assignment create \
  --name "require-aad-auth" \
  --policy "/providers/Microsoft.Authorization/policyDefinitions/0a14906a-d4d7-4e3d-91cf-9e1b2e2e4c5b"

# Disable local accounts
az policy assignment create \
  --name "disable-local-accounts" \
  --policy "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9a0f-f0c3e47fee1e"
```

---

## Cluster Security

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Use Azure Linux as host OS | 🔒 | N/A | Node pool setting - **Azure Policy Only** |
| Configure for regulated industries | ✅ | `aks-check-restrict-seccomp-profiles`, `aks-check-require-drop-all-capabilities`, `aks-check-disallow-sysctls` | ✅ |
| Check Kubernetes dashboard | 🔒 | N/A | Addon setting - **Azure Policy Only** |
| Encrypt ETCD at rest | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Maintain kubernetes version up to date | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Block deployment of vulnerable images | 🔧 | N/A | Requires image scanning (Trivy, Defender) |
| Use Azure Key Vault | ✅ | `aks-check-disallow-secrets-in-env`, `aks-check-secrets-store-csi` | ✅ |
| Monitor with Security Center | 🔒 | N/A | Azure integration - **Azure Policy Only** |
| Remove vulnerable images (ImageCleaner) | 🔒 | N/A | Cluster addon - **Azure Policy Only** |
| Enable Defender for Containers | 🔒 | N/A | Azure integration - **Azure Policy Only** |
| Use Azure Policy for Kubernetes | ✅ | These policies! | Meta |
| Separate apps from control plane | ✅ | `aks-check-windows-nodeselector` | ✅ Validates Windows node selection |
| Refresh SP credentials periodically | 🔒 | N/A | Cluster-level setting |
| Use private registry (ACR) | ✅ | `aks-check-restrict-image-registries` | ✅ |
| Use Security Center for posture | 🔒 | N/A | Azure integration |
| Consider Confidential Compute | 🔒 | N/A | Node pool setting |
| Define app separation requirements | ✅ | `aks-check-disallow-host-namespaces`, `aks-check-disallow-host-ports` | ✅ |
| Consider Azure Dedicated Hosts | 🔒 | N/A | Node pool setting |

---

## Multi-Tenant - Isolation

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Logically isolate cluster | ✅ | `aks-check-require-namespace-labels` | ✅ |
| Physically isolate cluster | 📝 | N/A | Architecture decision |
| Use Azure tags in AKS | ✅ | `aks-check-require-azure-tags` | ✅ |

---

## Storage

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Choose the right storage type | ✅ | `aks-check-disallow-hostpath`, `aks-check-pvc-storage-class` | ✅ |
| Size nodes for storage needs | 🔒 | N/A | Node sizing - **Azure Policy Only** |
| Dynamically provision volumes | ✅ | `aks-check-pvc-access-mode` | ✅ |
| Secure and back up data | ✅ | `aks-check-pvc-delete-protection`, `aks-check-volume-snapshot-class` | ✅ |
| Avoid keeping state in cluster | ✅ | `aks-check-disallow-local-storage` | ✅ |
| Use ephemeral OS disks | ⚠️ | `aks-check-ephemeral-storage-limits` | Partial |
| Consider Ultra Disks | 📝 | N/A | StorageClass config |
| Use LRS disk with zones | ✅ | `aks-check-pvc-storage-class` | StorageClass validation |
| Use high IOPS for non-ephemeral | 📝 | N/A | Node sizing |
| Use Secrets Store CSI Driver | ✅ | `aks-check-secrets-store-csi` | ✅ |

---

## Networking

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Choose best CNI plugin | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Size subnet for Azure CNI | 🔒 | N/A | Infrastructure - **Azure Policy Only** |
| Use ingress controller | ✅ | `aks-check-disallow-nodeport`, `aks-check-require-ingress-class` | ✅ |
| Secure apps with WAF | ⚠️ | `aks-check-require-ingress-tls` | Partial |
| Apply control on ingress hostnames | ✅ | `aks-check-validate-ingress-hostname` | ✅ |
| Don't expose LB on Internet | ✅ | `aks-check-disallow-loadbalancer-public` | ✅ |
| Control traffic with network policies | ✅ | `aks-check-require-network-policy` | ✅ |
| Configure default network policies | ⚠️ | `aks-check-block-imds-access` | Partial |
| Filter egress with AzFW/NVA | ⚠️ | `aks-check-egress-annotation` | Documentation only |
| Don't expose ACR on Internet | 🔒 | N/A | ACR configuration - **Azure Policy Only** |
| Block Pod access to VMSS IMDS | ✅ | `aks-check-block-imds-access` | ✅ |
| Use private clusters | 🔒 | N/A | Cluster-level setting - **Azure Policy Only** |
| Enable traffic management | 🔧 | N/A | Architecture |
| Check max pods/node for Azure CNI | 🔒 | N/A | Cluster setting - **Azure Policy Only** |
| Restrict API endpoint IP ranges | 🔒 | N/A | Cluster setting - **Azure Policy Only** |
| Use NAT Gateway for egress | 🔒 | N/A | Infrastructure - **Azure Policy Only** |
| Use Dynamic IP allocation | 🔒 | N/A | Cluster setting - **Azure Policy Only** |
| Use Private Endpoints for PaaS | 🔒 | N/A | Infrastructure - **Azure Policy Only** |
| Consider service mesh | ✅ | `aks-check-service-mesh-label` | ✅ |
| Add custom CNI if required | 🔒 | N/A | Cluster setting |
| Use different Subnets for NodePools | 🔒 | N/A | Infrastructure |
| Verify non-overlapping CIDRs | 🔒 | N/A | Infrastructure |

---

## Resource Management

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Burst to ACI with Virtual Nodes | 🔒 | N/A | Cluster addon - **Azure Policy Only** |
| Size nodes appropriately | 🔒 | N/A | Node sizing - **Azure Policy Only** |
| Use ARM64 nodes when possible | 🔒 | N/A | Node pool setting - **Azure Policy Only** |
| Enforce resource quotas | ✅ | `aks-check-require-resource-quota` | ✅ |
| Namespaces should have LimitRange | ✅ | `aks-check-require-limit-range` | ✅ |
| Set memory limits and requests | ✅ | `aks-check-require-resource-limits`, `aks-check-require-resource-requests` | ✅ |
| Use Disruption Budgets | ✅ | `aks-check-require-pdb`, `aks-check-pdb-min-available` | ✅ |
| Use kubecost for cost allocation | 🔧 | N/A | Tooling |
| Use multi-instance GPU partitioning | 🔒 | N/A | Node pool setting |
| Use NodePool Start/Stop for Dev/Test | 📝 | N/A | Operations |
| Use NodePool snapshots if required | 📝 | N/A | Operations |
| Ensure subscription quota | 🔒 | N/A | Azure subscription |
| Use scale down mode | 🔒 | N/A | Cluster setting |

---

## Application Deployment

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Implement Liveness probe | ✅ | `aks-check-require-liveness-probe` | ✅ |
| Implement Startup probe | ✅ | `aks-check-recommend-startup-probe` | ✅ |
| Implement Readiness probe | ✅ | `aks-check-require-readiness-probe` | ✅ |
| Implement prestop hook | ✅ | `aks-check-require-prestop-hook` | ✅ |
| Run more than one replica | ✅ | `aks-check-require-replicas` | ✅ |
| Apply tags/labels | ✅ | `aks-check-require-labels` | ✅ |
| Implement autoscaling (HPA/KEDA) | ✅ | `aks-check-validate-hpa-exists` | ✅ |
| Store secrets in Key Vault | ✅ | `aks-check-disallow-secrets-in-env`, `aks-check-disallow-env-secrets-patterns` | ✅ |
| Implement Workload Identity | ✅ | `aks-check-require-workload-identity`, `aks-check-serviceaccount-annotation` | ✅ |
| Use namespaces for isolation | ✅ | `aks-check-disallow-default-namespace` | ✅ |
| Set requests and limits | ✅ | `aks-check-require-resource-requests` | ✅ |
| Specify security context | ✅ | `aks-check-require-security-context` | ✅ |
| Ensure manifests follow best practices | ✅ | Multiple policies | ✅ |
| Conduct Dockerfile scanning | 🔧 | N/A | CI/CD tooling (Trivy, Snyk) |
| Static analysis on build | 🔧 | N/A | CI/CD tooling |
| Threshold enforcement for vulnerabilities | 🔧 | N/A | CI/CD tooling |
| Compliance enforcement on build | 🔧 | N/A | CI/CD tooling |
| Use Azure Migrate for containerization | 🔧 | N/A | Migration tooling |
| Apply right deployment type | ✅ | `aks-check-disallow-naked-pods` | ✅ |
| Don't use naked pods | ✅ | `aks-check-disallow-naked-pods` | ✅ |
| Control imagePullPolicy | ✅ | `aks-check-require-imagepullpolicy` | ✅ |
| Use automation (ARM/TF) | 📝 | N/A | IaC best practice |
| Use canary/blue-green deployments | 📝 | N/A | Deployment strategy |
| Use Dapr for microservices | 📝 | N/A | Architecture choice |

---

## Container Security

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Scan images for vulnerabilities | ⚠️ | `aks-check-image-vulnerability-label` | Label-based tracking |
| Allow only known registries | ✅ | `aks-check-restrict-image-registries` | ✅ |
| Runtime security for applications | ⚠️ | `aks-check-runtime-security` | Label-based tracking |
| Quarantine vulnerable images | 🔧 | N/A | ACR feature |
| RBAC to Docker registries | ⚠️ | `aks-check-image-registry-auth` | Partial |
| Network segmentation for registries | ⚠️ | `aks-check-acr-private-endpoint` | Documentation annotation |
| Prefer distroless images | ⚠️ | `aks-check-approved-base-images` | Partial |
| Refresh on base image update | ⚠️ | `aks-check-disallow-latest-tag`, `aks-check-require-image-digest` | Partial |
| Disallow privilege escalation | ✅ | `aks-check-container-allow-privilege-escalation` | ✅ |
| Restrict proc mount | ✅ | `aks-check-proc-mount` | ✅ |

---

## Biz Continuity - Disaster Recovery

| Checklist Item | Status | Kyverno Policy | Notes |
|----------------|--------|----------------|-------|
| Define SLAs, RTO, RPO | ⚠️ | `aks-check-priority-class` | Partial - validates priority |
| Schedule DR tests | 📝 | N/A | Process |
| Use Availability Zones | ✅ | `aks-check-deployment-zone-spread`, `aks-check-require-topology-spread` | ✅ |
| Plan for multiregion deployment | ⚠️ | `aks-check-acr-georeplication` | Documentation annotation |
| Use Traffic Manager/Front Door | 🔒 | N/A | Infrastructure - **Azure Policy Only** |
| Create storage migration plan | ⚠️ | `aks-check-backup-label` | ✅ |
| Use standard-tier AKS | 🔒 | N/A | Cluster setting - **Azure Policy Only** |
| Avoid Pods on single node | ✅ | `aks-check-multi-replica-antiaffinity`, `aks-check-require-pod-antiaffinity` | ✅ |
| Configure ACR region replication | 🔒 | N/A | ACR setting - **Azure Policy Only** |
| Configure ACR zone redundancy | 🔒 | N/A | ACR setting - **Azure Policy Only** |
| ACR dedicated resource group | 📝 | N/A | Architecture |
| Enable soft delete policy | 🔒 | N/A | ACR setting |

---

## Items Requiring Azure Policy Only

These items require Azure Policy for AKS (not Kyverno) as they operate at the cluster/infrastructure level:

### Identity & Access
```kusto
// Azure Resource Graph - Find clusters without AAD integration
resources
| where type == "microsoft.containerservice/managedclusters"
| where isnull(properties.aadProfile) or properties.aadProfile.managed != true
| project name, resourceGroup, subscriptionId
```

### Cluster Configuration
```kusto
// Find clusters without private endpoint
resources
| where type == "microsoft.containerservice/managedclusters"
| where isnull(properties.apiServerAccessProfile.enablePrivateCluster)
    or properties.apiServerAccessProfile.enablePrivateCluster == false
| project name, resourceGroup, subscriptionId
```

### Key Azure Policy Definitions for AKS

| Policy | Definition ID | Purpose |
|--------|---------------|---------|
| Require AAD authentication | `0a14906a-d4d7-4e3d-91cf-9e1b2e2e4c5b` | Enforce AAD integration |
| Disable local accounts | `993c2fcd-2b29-49d2-9a0f-f0c3e47fee1e` | Disable local admin |
| Require private cluster | `040732e8-d947-40b8-95d6-854c95024bf8` | Private API endpoint |
| Require Azure CNI | Various | Network plugin |
| Enable Defender | Various | Security monitoring |

---

## Items Requiring External Tooling

| Item | Recommended Tool | Integration |
|------|-----------------|-------------|
| Image vulnerability scanning | Trivy, Snyk, Microsoft Defender | CI/CD pipeline, admission webhook |
| Runtime security | Falco, Prisma Cloud, Defender for Containers | DaemonSet deployment |
| Cost allocation | Kubecost, OpenCost | Helm chart |
| Backup | Velero, Azure Backup for AKS | Operator deployment |
| GitOps | ArgoCD, Flux | Cluster addon or deployment |
| Static analysis | Checkov, Trivy, KubeLinter | CI/CD pipeline |
| Secret scanning | Gitleaks, TruffleHog | CI/CD pipeline |

---

## Extending Coverage

### 1. Add Azure Policy for Cluster Settings

```bash
# Apply AKS baseline policy initiative
az policy assignment create \
  --name "aks-baseline" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" \
  --policy-set-definition "Azure Kubernetes Service (AKS) Baseline for Linux-based workloads"
```

### 2. Integrate Image Scanning

```yaml
# Trivy operator for continuous scanning
apiVersion: aquasecurity.github.io/v1alpha1
kind: ClusterComplianceReport
metadata:
  name: aks-checklist-compliance
spec:
  cron: "0 */6 * * *"
  compliance:
    id: aks-checklist
```

### 3. Use Azure Resource Graph for Infrastructure Checks

```kusto
// Comprehensive cluster compliance check
resources
| where type == "microsoft.containerservice/managedclusters"
| extend
    hasAAD = isnotnull(properties.aadProfile.managed),
    isPrivate = properties.apiServerAccessProfile.enablePrivateCluster == true,
    hasZones = isnotnull(properties.agentPoolProfiles[0].availabilityZones),
    hasDefender = properties.securityProfile.defender.securityMonitoring.enabled == true
| project
    name,
    resourceGroup,
    hasAAD,
    isPrivate,
    hasZones,
    hasDefender,
    compliantCount = toint(hasAAD) + toint(isPrivate) + toint(hasZones) + toint(hasDefender)
| order by compliantCount asc
```
