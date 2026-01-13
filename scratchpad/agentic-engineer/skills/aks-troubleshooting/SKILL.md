---
name: aks-troubleshooting
description: Diagnose and resolve Azure Kubernetes Service (AKS) issues including node problems, networking (Azure CNI/overlay), Workload Identity, cluster upgrades, Azure add-ons (KEDA, AGIC, Key Vault CSI), and Azure Monitor integration. This skill should be used when troubleshooting AKS-specific infrastructure issues, investigating node failures, debugging Azure networking problems, or resolving Workload Identity authentication issues.
---

# AKS Troubleshooting

## Overview

This skill provides systematic approaches for diagnosing and resolving Azure Kubernetes Service issues, from node-level problems to Azure-specific integrations and networking configurations.

## Diagnostic Decision Tree

```
AKS Issue Detected
├── Node Issues → See "Node Troubleshooting"
│   ├── Node NotReady
│   ├── Node scaling failures
│   └── VM-level issues
├── Networking Issues → See "Networking Troubleshooting"
│   ├── Pod connectivity
│   ├── Service/Ingress problems
│   └── DNS resolution
├── Authentication Issues → See "Workload Identity Troubleshooting"
│   ├── Managed Identity failures
│   └── Azure resource access denied
├── Add-on Issues → See "Azure Add-ons Troubleshooting"
│   ├── KEDA scaling problems
│   ├── AGIC configuration
│   └── Key Vault CSI driver
└── Cluster Issues → See "Cluster Operations"
    ├── Upgrade failures
    └── API server connectivity
```

## Node Troubleshooting

### Check Node Status

```bash
# Get node status overview
kubectl get nodes -o wide

# Describe node for detailed status
kubectl describe node <node-name>

# Check node conditions
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'

# View node events
kubectl get events --field-selector involvedObject.kind=Node --sort-by='.lastTimestamp'
```

### Run Diagnostic Script

Execute `scripts/aks-node-diagnostics.sh` to gather comprehensive node health information:

```bash
./scripts/aks-node-diagnostics.sh <node-name>
```

### Common Node Issues

**NotReady State:**
1. Check kubelet logs: `az aks command invoke -g <rg> -n <cluster> --command "journalctl -u kubelet --since '1 hour ago'"`
2. Verify VM health: `az vm get-instance-view -g MC_<rg>_<cluster>_<region> -n <vmss-instance>`
3. Check disk pressure: `kubectl describe node | grep -A5 "Conditions"`

**Node Scaling Failures:**
```bash
# Check cluster autoscaler status
kubectl -n kube-system logs -l app=cluster-autoscaler --tail=100

# View autoscaler events
kubectl get events -n kube-system --field-selector reason=ScaleUp

# Check node pool configuration
az aks nodepool show -g <rg> --cluster-name <cluster> -n <nodepool> -o yaml
```

**VM Extension Failures:**
```bash
# Check VMSS instance view for extension status
az vmss get-instance-view -g MC_<rg>_<cluster>_<region> -n <vmss-name> --instance-id <id>
```

## Networking Troubleshooting

### Azure CNI Diagnostics

```bash
# Check CNI configuration
kubectl get pods -n kube-system -l k8s-app=azure-cni-networkmonitor

# Verify IP allocation
az network vnet subnet show -g <vnet-rg> --vnet-name <vnet> -n <subnet> --query 'ipConfigurations'

# Check available IPs in subnet
az network vnet subnet show -g <vnet-rg> --vnet-name <vnet> -n <subnet> --query 'addressPrefix'
```

### Pod Connectivity Issues

```bash
# Test pod-to-pod connectivity
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -qO- <target-pod-ip>

# Check network policies
kubectl get networkpolicies -A

# Verify CoreDNS
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

### Service and Ingress

```bash
# Check service endpoints
kubectl get endpoints <service-name>

# Verify load balancer
az network lb show -g MC_<rg>_<cluster>_<region> -n kubernetes

# Check ingress controller logs (AGIC)
kubectl -n kube-system logs -l app=ingress-appgw
```

### DNS Resolution

```bash
# Test DNS from pod
kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default

# Check CoreDNS config
kubectl -n kube-system get configmap coredns -o yaml
```

## Workload Identity Troubleshooting

### Verify Configuration

```bash
# Check OIDC issuer
az aks show -g <rg> -n <cluster> --query "oidcIssuerProfile"

# Verify federated credential
az identity federated-credential list -g <rg> --identity-name <identity-name>

# Check service account annotations
kubectl get serviceaccount <sa-name> -o yaml
```

### Common Issues

**Token Not Injected:**
```bash
# Verify azure-workload-identity webhook
kubectl get pods -n kube-system -l azure-workload-identity.io/system=true

# Check pod for projected token
kubectl exec <pod> -- ls -la /var/run/secrets/azure/tokens/
```

**Authentication Failures:**
```bash
# Check audience configuration
kubectl describe pod <pod> | grep -A10 "Volumes:"

# Verify managed identity
az identity show -g <rg> -n <identity-name> --query "clientId"
```

Run `scripts/workload-identity-check.sh` for automated validation:
```bash
./scripts/workload-identity-check.sh <namespace> <service-account>
```

## Azure Add-ons Troubleshooting

### KEDA

```bash
# Check KEDA operator
kubectl get pods -n kube-system -l app=keda-operator

# View scaled object status
kubectl get scaledobject -A
kubectl describe scaledobject <name>

# Check KEDA metrics
kubectl get hpa -A | grep keda
```

### Application Gateway Ingress Controller (AGIC)

```bash
# Check AGIC pod logs
kubectl -n kube-system logs -l app=ingress-appgw --tail=100

# Verify Application Gateway backend pools
az network application-gateway show -g <rg> -n <appgw> --query "backendAddressPools"

# Check ingress configuration
kubectl get ingress -A -o wide
```

### Key Vault CSI Driver

```bash
# Verify CSI driver pods
kubectl get pods -n kube-system -l app=secrets-store-csi-driver

# Check SecretProviderClass
kubectl get secretproviderclass -A
kubectl describe secretproviderclass <name>

# View sync status
kubectl get secretproviderclasspodstatus -A
```

## Cluster Operations

### Upgrade Troubleshooting

```bash
# Check upgrade status
az aks show -g <rg> -n <cluster> --query "provisioningState"

# View upgrade history
az aks get-upgrades -g <rg> -n <cluster>

# Check node pool upgrade status
az aks nodepool show -g <rg> --cluster-name <cluster> -n <nodepool> --query "provisioningState"
```

### API Server Connectivity

```bash
# Test API server connection
kubectl cluster-info

# Check API server health
kubectl get --raw='/healthz'

# Verify control plane
az aks show -g <rg> -n <cluster> --query "powerState"
```

### Azure Monitor Integration

```bash
# Check Container Insights agent
kubectl get pods -n kube-system -l component=ama-logs

# Verify metrics collection
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes"

# Check Prometheus integration (if enabled)
kubectl get pods -n kube-system -l app.kubernetes.io/name=prometheus
```

## Quick Reference Commands

| Issue | Command |
|-------|---------|
| Node status | `kubectl get nodes -o wide` |
| Pod events | `kubectl get events --sort-by='.lastTimestamp'` |
| Kubelet logs | `az aks command invoke -g <rg> -n <cluster> --command "journalctl -u kubelet -n 100"` |
| Network policies | `kubectl get networkpolicies -A` |
| DNS test | `kubectl run test --image=busybox --rm -it -- nslookup kubernetes` |
| OIDC issuer | `az aks show -g <rg> -n <cluster> --query oidcIssuerProfile.issuerUrl` |

## Resources

- **scripts/aks-node-diagnostics.sh** - Comprehensive node health diagnostics
- **scripts/workload-identity-check.sh** - Validate Workload Identity configuration
- **scripts/network-connectivity-test.sh** - Test pod and service connectivity
- **references/aks-error-codes.md** - Common AKS error codes and resolutions
