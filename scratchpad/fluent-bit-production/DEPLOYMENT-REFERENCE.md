# Deployment Reference: Complete YAML Manifest Guide

This document provides a complete reference to all YAML manifests required to deploy the Enterprise Multi-Cluster Event Pipeline with Fluent Bit and HolmesGPT.

## Architecture Overview

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────────┐
│        WORKER CLUSTER(S)            │     │        MANAGEMENT CLUSTER           │
│                                     │     │                                     │
│  ┌─────────────────────────────┐    │     │    ┌─────────────────────────────┐  │
│  │ Fluent Bit (monitoring ns)  │    │     │    │ Argo Events (argo-events)   │  │
│  │ - 01-fluent-bit-config      │    │     │    │ - EventBus                  │  │
│  │ - 02-fluent-bit-deployment  │────┼─────┼───►│ - 03-eventsource            │  │
│  └─────────────────────────────┘    │     │    │ - 04-sensor                 │  │
│                                     │     │    └──────────────┬──────────────┘  │
└─────────────────────────────────────┘     │                   │                 │
                                            │                   ▼                 │
            Azure Event Hub                 │    ┌─────────────────────────────┐  │
         (Kafka Interface)                  │    │ Workflow Templates          │  │
                                            │    │ - holmes-gitlab-issue       │  │
                                            │    └─────────────────────────────┘  │
                                            └─────────────────────────────────────┘
```

---

## Deployment Order

### Phase 1: Infrastructure Setup (Run Once)

| Order | File | Cluster | Purpose |
|:------|:-----|:--------|:--------|
| 1.1 | `00-setup-workload-identity.sh` | Both | Creates Azure resources, identities, and federation |

### Phase 2: Management Cluster Prerequisites

| Order | File | Location | Purpose |
|:------|:-----|:---------|:--------|
| 2.1 | `k8s/argo-events/01-namespace.yaml` | Management | Creates `argo-events` namespace |
| 2.2 | `k8s/argo-events/02-eventbus.yaml` | Management | Deploys NATS-based EventBus |
| 2.3 | `k8s/argo-events/07-rbac.yaml` | Management | RBAC for Argo Events |

### Phase 3: Worker Cluster - Fluent Bit

| Order | File | Location | Purpose |
|:------|:-----|:---------|:--------|
| 3.1 | `01-fluent-bit-config.yaml` | Worker | ConfigMap with Kafka OAUTHBEARER config |
| 3.2 | `02-fluent-bit-deployment.yaml` | Worker | Deployment + RBAC for event shipping |

### Phase 4: Management Cluster - Event Processing

| Order | File | Location | Purpose |
|:------|:-----|:---------|:--------|
| 4.1 | `03-eventsource-workload-identity.yaml` | Management | EventSource consuming from Event Hub |
| 4.2 | `workflow-gitlab-issue-creator.yaml` | Management | WorkflowTemplate for HolmesGPT + GitLab |
| 4.3 | `04-sensor-production.yaml` | Management | Sensor triggering workflows |

---

## File Details

### This Directory (`fluent-bit-production/`)

```
fluent-bit-production/
├── 00-setup-workload-identity.sh      # Master setup script
├── 01-fluent-bit-config.yaml          # Fluent Bit ConfigMap
├── 02-fluent-bit-deployment.yaml      # Fluent Bit Deployment + RBAC
├── 03-eventsource-workload-identity.yaml  # Argo EventSource (AAD auth)
├── 04-sensor-production.yaml          # Argo Sensor + Debug Sensor
├── README.md                          # Technical implementation guide
├── STAKEHOLDERS.md                    # Executive summary
├── DEPLOYMENT-REFERENCE.md            # This file
└── assets/                            # Presentation images
```

### Argo Events Base (`k8s/argo-events/`)

| File | Kind | Purpose |
|:-----|:-----|:--------|
| `01-namespace.yaml` | Namespace | Creates `argo-events` namespace |
| `02-eventbus.yaml` | EventBus | NATS streaming for event transport |
| `07-rbac.yaml` | ClusterRole/Binding | Permissions for event processing |

### HolmesGPT Workflows (`k8s/holmesgpt/`)

| File | Kind | Purpose |
|:-----|:-----|:--------|
| `workflow-gitlab-issue-creator.yaml` | WorkflowTemplate | HolmesGPT investigation + GitLab issue creation |
| `gitlab-mcp-integration.yaml` | ConfigMap | GitLab MCP server configuration |

---

## Quick Reference Commands

### Deploy to Worker Cluster

```bash
# Set context to worker cluster
kubectl config use-context <worker-cluster>

# Create namespace
kubectl create namespace monitoring

# Apply Fluent Bit manifests
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml

# Verify
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit
```

### Deploy to Management Cluster

```bash
# Set context to management cluster
kubectl config use-context <management-cluster>

# Prerequisites (if not already deployed)
kubectl apply -f ../../argo-events/01-namespace.yaml
kubectl apply -f ../../argo-events/02-eventbus.yaml
kubectl apply -f ../../argo-events/07-rbac.yaml

# EventSource and Sensor
kubectl apply -f 03-eventsource-workload-identity.yaml
kubectl apply -f ../workflow-gitlab-issue-creator.yaml
kubectl apply -f 04-sensor-production.yaml

# Verify
kubectl get eventsources -n argo-events
kubectl get sensors -n argo-events
kubectl get workflowtemplates -n argo-events
```

---

## Configuration Values to Update

Before deploying, update these placeholder values:

### In `02-fluent-bit-deployment.yaml`

```yaml
env:
  - name: AZURE_CLIENT_ID
    value: "REPLACE_WITH_CLIENT_ID"      # From setup script output
  - name: AZURE_TENANT_ID
    value: "REPLACE_WITH_TENANT_ID"      # From setup script output
  - name: CLUSTER_NAME
    value: "aks-prod-cluster"            # Your cluster name
```

### In `03-eventsource-workload-identity.yaml`

```yaml
azureEventsHub:
  k8s-warnings:
    fqdn: "REPLACE_WITH_EVENTHUB_FQDN"   # e.g., myns.servicebus.windows.net
```

### In `04-sensor-production.yaml`

```yaml
parameters:
  - src:
      dependencyName: k8s-warning-events
      dataKey: body
    dest: spec.arguments.parameters.0.value
    operation: append
  - dest: spec.arguments.parameters.1.value
    value: "your-gitlab-org/your-project"  # Your GitLab project path
```

---

## Dependencies Map

```
┌────────────────────────────────────────────────────────────────────┐
│                        EXTERNAL DEPENDENCIES                        │
├────────────────────────────────────────────────────────────────────┤
│  Azure Event Hub Namespace    │  Azure Managed Identities          │
│  - kube-events hub            │  - fluent-bit-events-sender        │
│  - argo-events consumer group │  - eventhub-receiver-identity      │
└────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────┐
│                        KUBERNETES PREREQUISITES                     │
├────────────────────────────────────────────────────────────────────┤
│  Worker Cluster               │  Management Cluster                 │
│  - OIDC Issuer enabled        │  - OIDC Issuer enabled             │
│  - Workload Identity enabled  │  - Workload Identity enabled       │
│  - monitoring namespace       │  - argo-events namespace           │
│                               │  - Argo Workflows installed        │
│                               │  - Argo Events installed           │
└────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────┐
│                        SECRETS & CONFIGMAPS                         │
├────────────────────────────────────────────────────────────────────┤
│  Created by setup script:                                          │
│  - eventhub-config (ConfigMap) - Event Hub connection details      │
│  - azure-eventhub-aad-config (ConfigMap) - Tenant ID for AAD       │
│  - gitlab-token (Secret) - GitLab API token for issue creation     │
└────────────────────────────────────────────────────────────────────┘
```

---

## Verification Checklist

### Worker Cluster

- [ ] Fluent Bit pod is running: `kubectl get pods -n monitoring`
- [ ] No auth errors in logs: `kubectl logs -n monitoring -l app=fluent-bit | grep -i error`
- [ ] Events being collected: `kubectl logs -n monitoring -l app=fluent-bit | grep -i "kubernetes_events"`
- [ ] Kafka connection established: Look for `SASL/OAUTHBEARER authentication succeeded`

### Management Cluster

- [ ] EventBus is running: `kubectl get eventbus -n argo-events`
- [ ] EventSource is active: `kubectl get eventsources -n argo-events`
- [ ] Sensor is active: `kubectl get sensors -n argo-events`
- [ ] WorkflowTemplate exists: `kubectl get workflowtemplates -n argo-events`

### End-to-End Test

```bash
# Generate a test warning event
kubectl run test-warning --image=nonexistent:v999 --restart=Never

# Watch for workflow execution
kubectl get workflows -n argo-events -w

# Check GitLab for created issue
```

---

## Troubleshooting

| Symptom | Check | Solution |
|:--------|:------|:---------|
| Fluent Bit not shipping events | `kubectl logs -n monitoring -l app=fluent-bit` | Verify AZURE_CLIENT_ID and TENANT_ID |
| EventSource not receiving | `kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events` | Check Event Hub FQDN and consumer group |
| Sensor not triggering | `kubectl describe sensor -n argo-events` | Verify EventBus is healthy |
| Workflow failing | `kubectl get workflows -n argo-events` | Check WorkflowTemplate parameters |

---

## Related Documentation

- [README.md](./README.md) - Technical implementation guide
- [STAKEHOLDERS.md](./STAKEHOLDERS.md) - Executive summary for stakeholders
- [Argo Events Docs](https://argoproj.github.io/argo-events/)
- [Fluent Bit Docs](https://docs.fluentbit.io/)
- [Azure Event Hub Kafka](https://docs.microsoft.com/en-us/azure/event-hubs/event-hubs-for-kafka-ecosystem-overview)
