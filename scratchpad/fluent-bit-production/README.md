# Implementation Guide: Fluent Bit + Event Hub (Production)

This directory contains the production-grade manifests for streaming Kubernetes events from multiple AKS clusters to a central Management Cluster using **Fluent Bit** and **Azure Workload Identity**.

## 🏗️ Architecture

1.  **Fluent Bit**: In-cluster agent using `OAUTHBEARER` to authenticate with Azure.
2.  **Azure Event Hub**: Central message broker.
3.  **Argo Events**: Consumer on the Management Cluster.

---

## 📋 Prerequisites

Execute these commands on each AKS cluster before proceeding:

```bash
# 1. Enable OIDC Issuer
az aks update -g $RG -n $CLUSTER --enable-oidc-issuer

# 2. Enable Workload Identity
az aks update -g $RG -n $CLUSTER --enable-workload-identity
```

---

## 🚀 Quick Start (Automated)

We have provided a "one-shot" script that handles the Azure resources, Managed Identities, and Kubernetes secrets.

```bash
export RESOURCE_GROUP="your-rg"
export CLUSTER_NAME="your-aks-cluster"
export LOCATION="uksouth"

# Run the setup
chmod +x 00-setup-workload-identity.sh
./00-setup-workload-identity.sh
```

**What the script does:**
*   Creates Event Hub Namespace/Hub if they don't exist.
*   Creates two Managed Identities (`fluent-bit-events-sender` and `eventhub-receiver-identity`).
*   Assigns RBAC roles (`Data Sender` / `Data Receiver`).
*   Establishes Federated Identity credentials for the ServiceAccounts.
*   Creates the necessary Kubernetes ConfigMaps/Secrets for the logic.

---

## 🛠️ Manual Configuration (Step-by-Step)

If you prefer not to use the script, follow these steps manually:

### 1. Create Identities & RBAC
```bash
# Create Identites
az identity create -g $RG -n fluent-bit-events-sender
az identity create -g $RG -n eventhub-receiver-identity

# Assign Sender Role
az role assignment create --assignee <SENDER_PRINCIPAL_ID> \
    --role "Azure Event Hubs Data Sender" \
    --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<ns>

# Create Federated Credential
az identity federated-credential create --name fed-fluent-bit \
    --identity-name fluent-bit-events-sender --resource-group $RG \
    --issuer "$OIDC_ISSUER" --subject "system:serviceaccount:monitoring:fluent-bit-events"
```

### 2. Update Manifests
After running the script or manual commands, update **`02-fluent-bit-deployment.yaml`** with:
*   `AZURE_CLIENT_ID`: The ClientID of the sender identity.
*   `AZURE_TENANT_ID`: Your Azure Tenant ID.
*   `CLUSTER_NAME`: Unique name for the cluster.

---

## 🧪 Verification & Troubleshooting

### Check Agent Connection
```bash
# Check Fluent Bit logs for Kafka connection status
kubectl logs -n monitoring -l app=fluent-bit

# Look for: "SASL/OAUTHBEARER authentication succeeded"
```

### Check Data Reception
On the Management Cluster:
```bash
# Monitor the EventSource for incoming messages
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events

# Verify Base64 Message Decoding
# Azure Event Hub payloads are base64 encoded.
# The Sensor (04-sensor-production.yaml) decodes this automatically.
```

## 📂 File Reference

| File | Purpose |
| :--- | :--- |
| `00-setup-workload-identity.sh` | **Master Setup Script**. Provisions identities and federation. |
| `01-fluent-bit-config.yaml` | Fluent Bit configuration (Inputs/Filters/Kafka Output). |
| `02-fluent-bit-deployment.yaml` | Deployment & RBAC for the event-shipping agent. |
| `03-eventsource-workload-identity.yaml` | Argo Events configuration for the Management Cluster. |
| `04-sensor-production.yaml` | Trigger logic for HolmesGPT investigation and GitLab. |

---
*For a high-level overview intended for stakeholders, see [STAKEHOLDERS.md](./STAKEHOLDERS.md).*
