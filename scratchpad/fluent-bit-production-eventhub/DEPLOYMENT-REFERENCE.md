# Deployment Reference: File Manifest Guide

Quick reference for all YAML manifests in this deployment.

## Architecture

```
WORKER CLUSTER                          MANAGEMENT CLUSTER
──────────────                          ──────────────────

[External Secrets] ──► [K8s Secret]     [EventSource] ◄── Event Hub
                            │                  │
                            ▼                  ▼
                      [Fluent Bit] ───► [Sensor] ───► [HolmesGPT]
                            │                            │
                            └── Event Hub ◄──────────────┘
```

---

## Deployment Order

### Worker Cluster (run for each AKS cluster sending events)

| Order | File | Purpose |
|:------|:-----|:--------|
| 1 | `00-external-secret.yaml` | Sync SAS token from Key Vault |
| 2 | `01-fluent-bit-config.yaml` | ConfigMap: Kafka output to Event Hub |
| 3 | `02-fluent-bit-deployment.yaml` | Deployment + RBAC + ConfigMap |

```bash
kubectl apply -f 00-external-secret.yaml
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml
```

### Management Cluster

| Order | File | Purpose |
|:------|:-----|:--------|
| 1 | `03-eventsource-workload-identity.yaml` | Consume events from Event Hub |
| 2 | `04-sensor-production.yaml` | Trigger HolmesGPT workflows |

```bash
kubectl apply -f 03-eventsource-workload-identity.yaml
kubectl apply -f 04-sensor-production.yaml
```

---

## Files in This Directory

```
fluent-bit-production/
├── 00-external-secret.yaml             # ExternalSecret → Key Vault
├── 01-fluent-bit-config.yaml           # Fluent Bit ConfigMap
├── 02-fluent-bit-deployment.yaml       # Fluent Bit Deployment + RBAC
├── 03-eventsource-workload-identity.yaml   # Argo EventSource
├── 04-sensor-production.yaml           # Argo Sensor
├── README.md                           # Overview
├── E2E-GUIDE.md                        # Full deployment walkthrough
├── STAKEHOLDERS.md                     # Executive summary
└── assets/                             # Architecture diagrams
```

---

## Configuration Values to Update

### `00-external-secret.yaml`
```yaml
secretStoreRef:
  name: azure-keyvault    # <-- Your ClusterSecretStore name
```

### `02-fluent-bit-deployment.yaml`
```yaml
# ConfigMap section
data:
  EVENTHUB_NAMESPACE: "your-namespace"
  EVENTHUB_NAME: "kube-events"
  EVENTHUB_FQDN: "your-namespace.servicebus.windows.net"

# Deployment section
env:
  - name: CLUSTER_NAME
    value: "your-cluster-name"    # Unique per cluster
```

### `03-eventsource-workload-identity.yaml`
```yaml
azureEventsHub:
  k8s-warnings:
    fqdn: "your-namespace.servicebus.windows.net"
    hubName: "kube-events"
```

---

## Verification Commands

```bash
# Worker Cluster
kubectl get externalsecret -n monitoring          # Should be SecretSynced
kubectl get secret eventhub-sas-secret -n monitoring
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit

# Management Cluster
kubectl get eventsource -n argo-events
kubectl get sensor -n argo-events
kubectl get workflows -n argo-events
```

---

## Related Documentation

- [E2E-GUIDE.md](./E2E-GUIDE.md) - Complete step-by-step deployment
- [README.md](./README.md) - Overview and quick start
- [STAKEHOLDERS.md](./STAKEHOLDERS.md) - Executive summary
