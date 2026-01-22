# Self-Hosted LLM with KAITO for HolmesGPT

## Problem Statement

You're hitting 429 rate limits (~1 call/minute) when using the corporate OpenAI endpoint for HolmesGPT investigations. This won't scale across hundreds of clusters per environment.

## Solution: KAITO Self-Hosted LLM

**Yes, KAITO can solve this problem.** KAITO deploys open-source LLMs on Kubernetes with OpenAI-compatible endpoints, eliminating rate limiting entirely.

---

## Architecture Options

### Option 1: Same Management Cluster (Recommended for PoC)

```
┌─────────────────────────────────────────────────────────────┐
│                    Management Cluster                        │
│                                                              │
│  ┌────────────────┐     ┌────────────────────────────────┐  │
│  │   Argo Events  │     │       KAITO Workspace          │  │
│  │   + Sensors    │────►│  (Phi-4-mini or Llama 3.1 8B)  │  │
│  └────────────────┘     │   OpenAI-compatible API        │  │
│          │              └────────────────────────────────┘  │
│          ▼                           │                       │
│  ┌────────────────┐                 ▼                       │
│  │   HolmesGPT    │◄────────────────┘                       │
│  │   Deployment   │     http://workspace-phi-4-mini:80      │
│  └────────────────┘                                          │
│          │                                                   │
│          ▼                                                   │
│  ┌────────────────┐                                          │
│  │  GitLab Issues │                                          │
│  └────────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
```

**Pros:**
- Single cluster to manage
- Lower latency (in-cluster networking)
- Simpler RBAC and networking
- Easier to get started

**Cons:**
- GPU nodes increase cluster costs
- Potential resource contention with Argo Workflows
- Blast radius if cluster has issues

### Option 2: Dedicated AI Cluster

```
┌────────────────────────────────┐    ┌─────────────────────────────┐
│     Management Cluster          │    │      AI/GPU Cluster         │
│                                 │    │                             │
│  ┌────────────────┐            │    │  ┌───────────────────────┐  │
│  │   HolmesGPT    │───────────────►│  │   KAITO Workspace     │  │
│  │                │   HTTP/gRPC │    │  │   (Phi-4-mini)        │  │
│  └────────────────┘            │    │  │   External LB / Istio │  │
│                                 │    │  └───────────────────────┘  │
└────────────────────────────────┘    └─────────────────────────────┘
```

**Pros:**
- Resource isolation
- Dedicated GPU quota
- Can scale independently
- Can serve multiple management clusters

**Cons:**
- Additional cluster overhead
- Cross-cluster networking complexity
- Higher operational burden

### My Recommendation

**Start with Option 1** (same management cluster) for proof of concept, then move to Option 2 if:
- GPU quota becomes an issue
- You need to serve multiple management clusters
- Resource contention is observed

---

## Model Recommendations for HolmesGPT

| Model | GPU Requirement | Memory | Best For | Recommended SKU |
|-------|-----------------|--------|----------|-----------------|
| **phi-4-mini-instruct** | 1x GPU | ~7GB | Fast responses, good reasoning | Standard_NC6s_v3 (V100 16GB) |
| **phi-3.5-mini-instruct** | 1x GPU | ~4GB | Budget option, smaller footprint | Standard_NC6s_v3 |
| **llama-3.1-8b-instruct** | 1x GPU | ~16GB | Better reasoning, larger context | Standard_NC24ads_A100_v4 |
| **mistral-7b-instruct** | 1x GPU | ~14GB | Strong general performance | Standard_NC24ads_A100_v4 |

### For Your Use Case (HolmesGPT Kubernetes Troubleshooting)

**Recommended: `phi-4-mini-instruct`**

Reasons:
1. Fast inference (~19-35ms TTFT on A10)
2. Supports tool calling (critical for HolmesGPT's MCP integration)
3. 131K token context window
4. Small footprint (7GB model weights)
5. Single V100 GPU is sufficient
6. Good cost/performance ratio

---

## Implementation Steps

### Step 1: Install KAITO on Management Cluster

```bash
# Install KAITO workspace controller
helm repo add kaito https://kaito-project.github.io/kaito/charts/kaito
helm repo update

helm upgrade --install kaito-workspace kaito/workspace \
  --namespace kaito-workspace \
  --create-namespace \
  --set clusterName="mgmt-cluster" \
  --wait
```

### Step 2: Set Up GPU Auto-Provisioning (Azure)

```bash
export RESOURCE_GROUP="your-rg"
export CLUSTER_NAME="mgmt-cluster"
export SUBSCRIPTION=$(az account show --query id -o tsv)
export IDENTITY_NAME="kaitoprovisioner"

# Create managed identity
az identity create --name $IDENTITY_NAME -g $RESOURCE_GROUP

# Get principal ID
export IDENTITY_PRINCIPAL_ID=$(az identity show --name $IDENTITY_NAME -g $RESOURCE_GROUP --query 'principalId' -o tsv)

# Assign Contributor role
az role assignment create \
  --assignee $IDENTITY_PRINCIPAL_ID \
  --scope /subscriptions/$SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME \
  --role "Contributor"

# Install GPU provisioner
export GPU_PROVISIONER_VERSION=0.3.8
curl -sO https://raw.githubusercontent.com/Azure/gpu-provisioner/main/hack/deploy/configure-helm-values.sh
chmod +x ./configure-helm-values.sh && ./configure-helm-values.sh $CLUSTER_NAME $RESOURCE_GROUP $IDENTITY_NAME

helm install gpu-provisioner \
  --values gpu-provisioner-values.yaml \
  --set settings.azure.clusterName=$CLUSTER_NAME \
  --wait \
  https://github.com/Azure/gpu-provisioner/raw/gh-pages/charts/gpu-provisioner-$GPU_PROVISIONER_VERSION.tgz \
  --namespace gpu-provisioner \
  --create-namespace

# Create federated credential
export AKS_OIDC_ISSUER=$(az aks show -n $CLUSTER_NAME -g $RESOURCE_GROUP --query "oidcIssuerProfile.issuerUrl" -o tsv)

az identity federated-credential create \
  --name kaito-federatedcredential \
  --identity-name $IDENTITY_NAME \
  -g $RESOURCE_GROUP \
  --issuer $AKS_OIDC_ISSUER \
  --subject system:serviceaccount:"gpu-provisioner:gpu-provisioner" \
  --audience api://AzureADTokenExchange
```

### Step 3: Deploy KAITO Workspace

```yaml
# kaito-phi4-workspace.yaml
apiVersion: kaito.sh/v1beta1
kind: Workspace
metadata:
  name: workspace-phi-4-mini
  namespace: holmesgpt
spec:
  resource:
    instanceType: "Standard_NC6s_v3"  # V100 16GB - sufficient for phi-4-mini
    labelSelector:
      matchLabels:
        apps: phi-4-mini
  inference:
    preset:
      name: phi-4-mini-instruct
```

```bash
kubectl apply -f kaito-phi4-workspace.yaml

# Monitor deployment (can take 10-30 minutes for GPU node provisioning)
kubectl get workspace workspace-phi-4-mini -w
```

### Step 4: Update HolmesGPT Configuration

Once KAITO workspace is ready, update HolmesGPT to use the self-hosted model:

```yaml
# Update holmes-secrets to use KAITO endpoint
apiVersion: v1
kind: Secret
metadata:
  name: holmes-secrets
  namespace: holmesgpt
type: Opaque
stringData:
  # Point to KAITO's OpenAI-compatible endpoint
  OPENAI_API_BASE: "http://workspace-phi-4-mini.holmesgpt.svc.cluster.local:80/v1"
  OPENAI_API_KEY: "not-needed-for-local"  # KAITO doesn't require auth by default
```

Or set environment variables in the HolmesGPT deployment:

```yaml
env:
  - name: OPENAI_API_BASE
    value: "http://workspace-phi-4-mini.holmesgpt.svc.cluster.local:80/v1"
  - name: OPENAI_MODEL
    value: "phi-4-mini-instruct"  # Model name from KAITO
```

### Step 5: Test the Integration

```bash
# Test KAITO endpoint directly
kubectl run -it --rm --restart=Never curl --image=curlimages/curl -- \
  curl -X POST http://workspace-phi-4-mini.holmesgpt.svc.cluster.local:80/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "phi-4-mini-instruct",
    "messages": [{"role": "user", "content": "What causes OOMKilled in Kubernetes?"}],
    "max_tokens": 200,
    "temperature": 0.1
  }'
```

---

## Cost Analysis

### Azure GPU SKU Pricing (Pay-as-you-go, East US)

| SKU | GPU | Memory | Price/Hour | Price/Month (24x7) |
|-----|-----|--------|------------|-------------------|
| Standard_NC6s_v3 | 1x V100 | 16GB | ~$3.06 | ~$2,200 |
| Standard_NC12s_v3 | 2x V100 | 32GB | ~$6.12 | ~$4,400 |
| Standard_NC24ads_A100_v4 | 1x A100 | 80GB | ~$3.67 | ~$2,650 |

### Cost vs Rate Limiting Trade-off

| Approach | Monthly Cost | Throughput | Rate Limited? |
|----------|--------------|------------|---------------|
| Corporate OpenAI | $0 (internal) | 1 req/min | YES |
| KAITO NC6s_v3 | ~$2,200 | 8-32 req/sec | NO |
| KAITO with spot VMs | ~$660-880 | 8-32 req/sec | NO |

**Key Insight**: If you're processing hundreds of events/day across many clusters, the GPU cost is justified by the massive throughput improvement (from 60 req/hour to potentially 115,000+ req/hour).

### Cost Optimization Options

1. **Use Spot VMs**: Enable `instanceType` with spot pricing for 60-70% savings
2. **Scale to zero**: Configure KEDA autoscaler to scale down when idle
3. **Smaller model**: Use phi-3.5-mini for even lower GPU requirements

---

## HolmesGPT Model Configuration

HolmesGPT supports OpenAI-compatible endpoints via these environment variables:

```bash
# Required
OPENAI_API_BASE=http://workspace-phi-4-mini:80/v1
OPENAI_MODEL=phi-4-mini-instruct

# Optional
OPENAI_API_KEY=not-needed  # KAITO doesn't require auth
```

The phi-4-mini model supports **tool calling**, which HolmesGPT uses for its MCP (Model Context Protocol) integration to query Kubernetes clusters.

---

## Alternative: Use LiteLLM as Proxy

If you want to keep the option of switching between models or adding fallbacks:

```yaml
# Deploy LiteLLM as a proxy to KAITO
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: holmesgpt
data:
  config.yaml: |
    model_list:
      - model_name: gpt-4
        litellm_params:
          model: openai/phi-4-mini-instruct
          api_base: http://workspace-phi-4-mini:80/v1
          api_key: not-needed
      - model_name: gpt-4-fallback
        litellm_params:
          model: azure/gpt-4
          api_base: ${AZURE_OPENAI_ENDPOINT}
          api_key: ${AZURE_OPENAI_KEY}
```

This gives you:
- Automatic fallback if KAITO is unavailable
- Model aliasing (HolmesGPT calls "gpt-4", LiteLLM routes to KAITO)
- Request logging and metrics

---

## Summary: Recommended Path Forward

1. **Deploy KAITO with phi-4-mini-instruct** on the management cluster
2. **Update HolmesGPT** to use the in-cluster KAITO endpoint
3. **Test thoroughly** with synthetic events
4. **Monitor throughput** - you should see ~8-32 QPS vs 1 QPM
5. **Consider LiteLLM proxy** if you need fallback to corporate OpenAI

This eliminates the 429 rate limiting issue entirely while keeping everything within your control and compliance boundaries.

---

## References

- [KAITO Documentation](https://kaito-project.github.io/kaito/docs/)
- [KAITO GPU Benchmarks](https://kaito-project.github.io/kaito/docs/gpu-benchmarks)
- [Azure GPU VM Sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes-gpu)
- [HolmesGPT Configuration](https://docs.robusta.dev/master/holmesgpt)
