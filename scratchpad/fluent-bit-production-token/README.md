# Implementation Guide: Fluent Bit + Event Hub (Production)

This directory contains the production-grade manifests for streaming Kubernetes events from multiple AKS clusters to a central Management Cluster using **Fluent Bit** and **Azure Key Vault** (via External Secrets).

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AKS Cluster                              │
│                                                                 │
│  ┌─────────────┐     ┌─────────────────┐     ┌───────────────┐ │
│  │ External    │────►│ K8s Secret      │────►│  Fluent Bit   │ │
│  │ Secrets Op  │     │ (eventhub-sas)  │     │  (Kafka Out)  │ │
│  └──────┬──────┘     └─────────────────┘     └───────┬───────┘ │
│         │                                            │         │
└─────────│────────────────────────────────────────────│─────────┘
          │                                            │
          ▼                                            ▼
   ┌─────────────┐                           ┌─────────────────┐
   │ Azure Key   │                           │  Azure Event    │
   │ Vault       │                           │  Hub            │
   └─────────────┘                           └────────┬────────┘
                                                      │
                                                      ▼
                                            ┌─────────────────┐
                                            │ Management      │
                                            │ Cluster (Argo)  │
                                            └─────────────────┘
```

1. **External Secrets Operator**: Syncs SAS token from Key Vault to K8s Secret
2. **Fluent Bit**: Uses SASL_PLAIN with SAS connection string
3. **Azure Event Hub**: Central message broker
4. **Argo Events**: Consumer on the Management Cluster

---

## 📋 Prerequisites

1. **External Secrets Operator** installed on the cluster
2. **ClusterSecretStore** configured for Azure Key Vault
3. Event Hub connection string stored in Key Vault

### Key Vault Setup

```bash
# Store the Event Hub connection string in Key Vault
az keyvault secret set \
  --vault-name YOUR_KEYVAULT \
  --name eventhub-connection-string \
  --value "Endpoint=sb://YOUR_NAMESPACE.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=YOUR_KEY"
```

---

## 🚀 Quick Start

```bash
# 1. Create namespace
kubectl create namespace monitoring

# 2. Apply External Secret (syncs SAS token from Key Vault)
kubectl apply -f 00-external-secret.yaml

# 3. Verify secret was created
kubectl get secret eventhub-sas-secret -n monitoring

# 4. Apply Fluent Bit config and deployment
kubectl apply -f 01-fluent-bit-config.yaml
kubectl apply -f 02-fluent-bit-deployment.yaml

# 5. Check logs
kubectl logs -n monitoring -l app=fluent-bit -f
```

---

## 🔐 Authentication Method

This setup uses **SAS (Shared Access Signature) tokens** for Event Hub authentication:

| Method | Security | Implementation |
|--------|----------|----------------|
| SAS Token | Medium | SASL_PLAIN with connection string |
| Key Vault | High | External Secrets syncs to K8s Secret |
| Rotation | 1 hour | ExternalSecret refreshInterval |

### Why Not Workload Identity?

Fluent Bit's Kafka plugin uses librdkafka, which doesn't support Azure AD's OAUTHBEARER mechanism with federated tokens. See [AUTHENTICATION-OPTIONS.md](./AUTHENTICATION-OPTIONS.md) for detailed analysis.

---

## 🛠️ Configuration

### Update for Your Environment

1. **00-external-secret.yaml**: Update `secretStoreRef.name` to match your ClusterSecretStore
2. **01-fluent-bit-config.yaml**: No changes needed (uses env vars)
3. **02-fluent-bit-deployment.yaml**: Update:
   - `CLUSTER_NAME`: Unique identifier for this cluster
   - `EVENTHUB_NAMESPACE`, `EVENTHUB_NAME`, `EVENTHUB_FQDN` in ConfigMap

---

## 🧪 Verification & Troubleshooting

### Check External Secret Sync
```bash
# Check if secret was synced
kubectl get externalsecret eventhub-sas-secret -n monitoring

# Should show STATUS: SecretSynced
```

### Check Fluent Bit Logs
```bash
kubectl logs -n monitoring -l app=fluent-bit

# Look for successful Kafka connection:
# [2024/01/15 10:00:00] [ info] [output:kafka:kafka.0] brokers=*.servicebus.windows.net:9093
```

### Verify Events Flowing
```bash
# Generate a test warning event
kubectl run test-pod --image=invalid-image-xyz --restart=Never

# Check Fluent Bit picked it up
kubectl logs -n monitoring -l app=fluent-bit | grep -i warning
```

### On Management Cluster
```bash
# Monitor EventSource for incoming messages
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events
```

---

## 📂 File Reference

### Manifests
| File | Purpose |
| :--- | :--- |
| `00-external-secret.yaml` | Syncs SAS token from Key Vault to K8s Secret |
| `01-fluent-bit-config.yaml` | Fluent Bit configuration (Inputs/Filters/Kafka Output) |
| `02-fluent-bit-deployment.yaml` | Deployment, RBAC, and ConfigMap |
| `03-eventsource-workload-identity.yaml` | Argo Events EventSource (Management Cluster) |
| `04-sensor-production.yaml` | Trigger logic for HolmesGPT and notifications |

### Documentation
| File | Purpose |
| :--- | :--- |
| `E2E-GUIDE.md` | Complete end-to-end deployment walkthrough |
| `EVENTHUB-INSPECTION.md` | **How to view events in Event Hub without portal access** |
| `AUTHENTICATION-OPTIONS.md` | Comparison of authentication methods |
| `STAKEHOLDERS.md` | High-level overview for stakeholders |
| `todo.md` | Deployment checklist |

---

## 🔄 Secret Rotation

The ExternalSecret is configured with `refreshInterval: 1h`, meaning:
- Every hour, ESO checks Key Vault for updates
- If you rotate the SAS key in Key Vault, it propagates automatically
- Fluent Bit pods need restart to pick up new secret (or use Reloader)

### Automatic Pod Restart on Secret Change

Consider using [Reloader](https://github.com/stakater/Reloader) for automatic restarts:

```yaml
# Add annotation to Deployment
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```

---

*For a high-level overview intended for stakeholders, see [STAKEHOLDERS.md](./STAKEHOLDERS.md).*
