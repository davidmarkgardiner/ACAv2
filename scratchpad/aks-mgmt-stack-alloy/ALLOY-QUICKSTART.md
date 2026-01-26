# Alloy Quick Deploy Cheat Sheet

**Clean deployment using ConfigMap for environment variables. No scripts required.**

---

## Files to Deploy

```
workload-cluster/
├── 02-alloy-config.yaml    # Alloy River config (uses env() - no editing needed)
├── 03-alloy-deployment.yaml # Deployment + ConfigMap for env vars (EDIT THIS)
└── 04-alloy-secret.yaml     # Secret template (or use kubectl create)
```

---

## Step 1: Create Namespace

```bash
kubectl create namespace monitoring
```

---

## Step 2: Edit ConfigMap (03-alloy-deployment.yaml)

Open `aks-mgmt-stack/k8s-event-triage/workload-cluster/03-alloy-deployment.yaml` and edit the `alloy-env` ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alloy-env
  namespace: monitoring
data:
  CLUSTER_NAME: "aks-prod-westeurope"        # <-- Your cluster name
  CLUSTER_REGION: "westeurope"               # <-- Azure region
  CLUSTER_ENVIRONMENT: "production"          # <-- dev/staging/production
  EVENTHUB_FQDN: "k8s-events-hub.servicebus.windows.net"  # <-- Your FQDN
  EVENTHUB_NAME: "kube-events"               # <-- Your topic name
```

---

## Step 3: Create Secret

**Option A: kubectl create (easiest)**

```bash
kubectl create secret generic alloy-eventhub \
  --namespace monitoring \
  --from-literal=connection-string='Endpoint=sb://YOUR-NAMESPACE.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...'
```

**Option B: Get connection string first**

```bash
# Get connection string from Azure
az eventhubs namespace authorization-rule keys list \
  --resource-group YOUR_RG \
  --namespace-name YOUR-NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv

# Then create secret
kubectl create secret generic alloy-eventhub \
  --namespace monitoring \
  --from-literal=connection-string='<PASTE_OUTPUT_HERE>'
```

---

## Step 4: Apply

```bash
cd aks-mgmt-stack/k8s-event-triage/workload-cluster

kubectl apply -f 02-alloy-config.yaml
kubectl apply -f 03-alloy-deployment.yaml
```

---

## Step 5: Verify

```bash
# Check pod
kubectl get pods -n monitoring -l app=alloy

# Check logs
kubectl logs -n monitoring -l app=alloy -f

# Generate test event
kubectl run test-crash --image=invalid-image-xyz --restart=Never
kubectl delete pod test-crash
```

---

## Access Alloy UI

```bash
kubectl port-forward -n monitoring svc/alloy 12345:12345
# Open http://localhost:12345
```

---

## Configuration Summary

| What | Where | Sensitive? |
|------|-------|------------|
| Cluster name, region, env | `alloy-env` ConfigMap | No |
| Event Hub FQDN, topic | `alloy-env` ConfigMap | No |
| Connection string | `alloy-eventhub` Secret | Yes |

The Alloy config (`02-alloy-config.yaml`) reads everything via `env()` - no editing needed.

---

## Troubleshooting

**Pod not starting?**
```bash
kubectl describe pod -n monitoring -l app=alloy
kubectl logs -n monitoring -l app=alloy --previous
```

**Check env vars are set?**
```bash
kubectl exec -n monitoring deploy/alloy -- env | grep -E 'CLUSTER|EVENTHUB'
```

**Connection issues?**
```bash
# Test FQDN reachable
kubectl exec -n monitoring deploy/alloy -- wget -qO- --timeout=5 https://YOUR-NAMESPACE.servicebus.windows.net
```
