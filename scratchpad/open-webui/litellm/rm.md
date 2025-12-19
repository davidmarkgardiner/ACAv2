Yes, you can absolutely deploy them in the same namespace - that simplifies the service discovery and is often cleaner for a single application stack.

## Same Namespace Deployment

```
┌─────────────────────────────────────────────────────────────┐
│                    Namespace: open-webui                     │
│                                                              │
│  ┌─────────────┐         ┌─────────────┐                    │
│  │  Open WebUI │────────▶│   LiteLLM   │──────▶ Azure OpenAI│
│  │   (Pod)     │         │   (Pod)     │       (External)   │
│  └─────────────┘         └─────────────┘                    │
│         │                       │                            │
│         ▼                       ▼                            │
│  ┌─────────────┐         ┌─────────────┐                    │
│  │ open-webui  │         │  litellm    │                    │
│  │  Service    │         │  Service    │                    │
│  └─────────────┘         └─────────────┘                    │
│                                 │                            │
│                                 ▼                            │
│                          ┌─────────────┐                    │
│                          │  litellm-sa │                    │
│                          │ (Workload ID)│                    │
│                          └─────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

When both are in the same namespace, the connection URL becomes simpler:

```yaml
# Instead of:
openaiBaseApiUrl: "http://litellm-service.litellm.svc.cluster.local:4000/v1"

# You can just use:
openaiBaseApiUrl: "http://litellm-service:4000/v1"
```

---

## Combined Deployment Example

### Single values file for Open WebUI + LiteLLM manifests

```yaml
# open-webui-values.yaml
nameOverride: "open-webui"

ollama:
  enabled: false

pipelines:
  enabled: false

# Point to LiteLLM in same namespace
openaiBaseApiUrl: "http://litellm-service:4000/v1"
openaiApiKey: "sk-litellm-master-key"

persistence:
  enabled: true
  size: 5Gi

serviceAccount:
  enable: true
  create: true
  name: "open-webui-sa"
```

### LiteLLM resources (same namespace)

```yaml
# litellm-all.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litellm-sa
  namespace: open-webui
  annotations:
    azure.workload.identity/client-id: "<YOUR-UAMI-CLIENT-ID>"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: open-webui
data:
  config.yaml: |
    model_list:
      - model_name: gpt-4
        litellm_params:
          model: azure/gpt-4
          api_base: https://your-resource.openai.azure.com/
          api_version: "2024-02-01"
      - model_name: gpt-35-turbo
        litellm_params:
          model: azure/gpt-35-turbo
          api_base: https://your-resource.openai.azure.com/
          api_version: "2024-02-01"
    
    litellm_settings:
      enable_azure_ad_token_refresh: true
    
    general_settings:
      master_key: "sk-litellm-master-key"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: open-webui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: litellm-sa
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:main-latest
          ports:
            - containerPort: 4000
          args:
            - "--config"
            - "/app/config.yaml"
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
      volumes:
        - name: config
          configMap:
            name: litellm-config
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-service
  namespace: open-webui
spec:
  selector:
    app: litellm
  ports:
    - port: 4000
      targetPort: 4000
  type: ClusterIP
```

---

## Deployment Commands

```bash
# Create namespace
kubectl create namespace open-webui

# Deploy LiteLLM first
kubectl apply -f litellm-all.yaml

# Set up Workload Identity federation
CLUSTER_NAME="your-aks-cluster"
RG_NAME="your-resource-group"
UAMI_NAME="your-uami-name"
NAMESPACE="open-webui"
SERVICE_ACCOUNT="litellm-sa"

# Get OIDC issuer
OIDC_ISSUER=$(az aks show -n $CLUSTER_NAME -g $RG_NAME --query oidcIssuerProfile.issuerUrl -o tsv)

# Create federated credential
az identity federated-credential create \
  --name "litellm-fedcred" \
  --identity-name $UAMI_NAME \
  --resource-group $RG_NAME \
  --issuer "$OIDC_ISSUER" \
  --subject "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"

# Deploy Open WebUI via Helm
helm repo add open-webui https://helm.openwebui.com/
helm repo update

helm upgrade --install open-webui open-webui/open-webui \
  -f open-webui-values.yaml \
  -n open-webui
```

---

## Verify Everything Works

```bash
# Check pods are running
kubectl get pods -n open-webui

# Check LiteLLM can auth to Azure (look for token acquisition logs)
kubectl logs -n open-webui -l app=litellm --tail=50

# Test LiteLLM endpoint from within cluster
kubectl run test --rm -it --image=curlimages/curl -n open-webui -- \
  curl -s http://litellm-service:4000/v1/models \
  -H "Authorization: Bearer sk-litellm-master-key"

# Should return list of models like:
# {"data":[{"id":"gpt-4","object":"model",...},{"id":"gpt-35-turbo",...}]}
```

---

## Quick Reference

| Setting | Value |
|---------|-------|
| **Namespace** | `open-webui` (both components) |
| **LiteLLM Service** | `litellm-service:4000` |
| **Open WebUI → LiteLLM** | `http://litellm-service:4000/v1` |
| **Auth** | Workload Identity on `litellm-sa` only |
| **Open WebUI SA** | No special permissions needed |

The key point is that only LiteLLM needs the Workload Identity configuration since it's the component authenticating to Azure OpenAI. Open WebUI just talks to LiteLLM over plain HTTP within the cluster.