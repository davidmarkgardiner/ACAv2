# DEPLOY.md — Quick Reference

**Goal:** swap LiteLLM for agentgateway. kagent on worker cluster → agentgateway on
management cluster (via Istio VirtualService) → Azure OpenAI (via UAMI).

**This doc is a checklist. For context and alternatives, see `INSTALL.md`.**

---

## Values to collect before you start

```
UAMI client ID            = ________________________________________
UAMI resource ID          = ________________________________________
Azure OpenAI endpoint     = <resource>.openai.azure.com
Azure OpenAI deployment   = e.g. gpt-4o
Azure OpenAI API version  = 2024-10-21  (or whatever your resource supports)
AKS OIDC issuer URL       = ________________________________________
Prometheus release label  = ________________________________________
```

Commands to find them:

```bash
# UAMI client ID
az identity show --name <uami-name> --resource-group <rg> --query clientId -o tsv

# Azure OpenAI endpoint
az cognitiveservices account show --name <aoai> --resource-group <rg> \
  --query properties.endpoint -o tsv

# AKS OIDC issuer
az aks show --name <aks-name> --resource-group <rg> \
  --query oidcIssuerProfile.issuerUrl -o tsv

# Prometheus release label
kubectl get prometheus -A -o jsonpath='{.items[0].spec.serviceMonitorSelector}'
```

---

## Management Cluster (agentgateway)

### 1. Install agentgateway

```bash
# Gateway API CRDs (skip if already installed)
kubectl get crd gateways.gateway.networking.k8s.io 2>/dev/null \
  || kubectl apply --server-side -f \
     https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# agentgateway CRDs + controller
helm upgrade -i --create-namespace --namespace agentgateway-system \
  --version v1.1.0 agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds

helm upgrade -i --namespace agentgateway-system \
  --version v1.1.0 agentgateway oci://cr.agentgateway.dev/charts/agentgateway

kubectl wait --for=condition=ready pod -l app=agentgateway \
  -n agentgateway-system --timeout=120s
```

### 2. Wire up Workload Identity for UAMI

```bash
# Find the ServiceAccount the Helm chart created
SA=$(kubectl get sa -n agentgateway-system -o name | head -1 | cut -d/ -f2)
echo "SA name: $SA"

# Annotate it with the UAMI client ID
kubectl annotate sa $SA -n agentgateway-system \
  azure.workload.identity/client-id=<UAMI_CLIENT_ID> --overwrite

# Label it to opt into workload identity pod label projection
kubectl label sa $SA -n agentgateway-system \
  azure.workload.identity/use=true --overwrite

# Restart the controller to pick up the annotation
kubectl rollout restart deploy -n agentgateway-system
kubectl rollout status deploy -n agentgateway-system

# Federate the UAMI with the SA
az identity federated-credential create \
  --identity-name <UAMI_NAME> --resource-group <RG> \
  --name agentgateway-fedcred \
  --issuer <OIDC_ISSUER> \
  --subject system:serviceaccount:agentgateway-system:$SA \
  --audience api://AzureADTokenExchange

# Verify the UAMI has permission on Azure OpenAI
az role assignment list --assignee <UAMI_CLIENT_ID> \
  --scope <AZURE_OPENAI_RESOURCE_ID> -o table
# Must include "Cognitive Services OpenAI User" (or similar)
```

### 3. Substitute placeholders in manifests

Find `REPLACE_*` placeholders and substitute real values:

```bash
cd ai-platform/agentgateway
grep -n REPLACE_ *.yaml
```

Key values to replace:

| File | Placeholder | Value |
|---|---|---|
| `backend-azure-openai.yaml` | `REPLACE_RESOURCE.openai.azure.com` | your Azure OpenAI endpoint |
| `backend-azure-openai.yaml` | `REPLACE_DEPLOYMENT_NAME` | your Azure OpenAI deployment |
| `backend-azure-openai.yaml` | `REPLACE_WITH_UAMI_CLIENT_ID` | UAMI client ID |
| `backend-kubeai.yaml` | `REPLACE_WITH_PRIMARY_MODEL` | KubeAI model name (if using local models) |
| `backend-kubeai.yaml` | `REPLACE_WITH_FALLBACK_MODEL` | second KubeAI model (or remove block) |
| `monitoring.yaml` | `kube-prom` | your Prometheus release label |

### 4. Apply manifests in order

```bash
kubectl apply -f gateway-resources.yaml
kubectl apply -f backend-azure-openai.yaml
kubectl apply -f backend-kubeai.yaml              # skip if no KubeAI in work cluster
kubectl apply -f ai-policy.yaml
kubectl apply -f networkpolicy.yaml
kubectl apply -f istio-virtualservice.yaml
kubectl apply -f istio-authorization-policy.yaml
kubectl apply -f monitoring.yaml

# Sanity check
kubectl get gateway,httproute,agentgatewaybackend,agentgatewaypolicy \
  -n agentgateway-system
```

### 5. Smoke test Azure OpenAI from the management cluster

```bash
kubectl port-forward -n agentgateway-system svc/ai-gateway 8080:80 &
PF_PID=$!

# List models — should hit Azure OpenAI via UAMI
curl -s http://localhost:8080/azure/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<deployment-name>","messages":[{"role":"user","content":"ping"}]}' \
  | jq .

kill $PF_PID
```

Expected: JSON response from Azure OpenAI with a completion.

If you get **401/403**: UAMI federation or role assignment is wrong.
If you get **timeout**: SA not annotated correctly or workload identity webhook not running.

---

## Worker Cluster (kagent)

### 6. Dummy secret + ModelConfig

```bash
# Dummy key — agentgateway holds real creds, kagent just needs a secret ref
kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key="not-required" \
  --dry-run=client -o yaml | kubectl apply -f -

# Substitute hostname in modelconfig-azure.yaml
# REPLACE_AGENTGATEWAY_HOSTNAME → ai-gateway.agentgateway-system.svc.cluster.local
# (works if the worker cluster is in the same Istio mesh as the management cluster)
sed -i.bak 's|REPLACE_AGENTGATEWAY_HOSTNAME|ai-gateway.agentgateway-system.svc.cluster.local|g' \
  modelconfig-azure.yaml
sed -i.bak 's|REPLACE_WITH_DEPLOYMENT_NAME|<deployment-name>|g' modelconfig-azure.yaml

kubectl apply -f modelconfig-azure.yaml
```

### 7. Cross-cluster smoke test

```bash
# From a pod in the worker cluster's mesh (e.g. kagent namespace)
kubectl run test-curl -n kagent --rm -it --image=curlimages/curl -- \
  curl -sv http://ai-gateway.agentgateway-system.svc.cluster.local/azure/v1/models
```

Expected: a 200 response listing deployments.

### 8. Migrate one agent, test, then roll out

```bash
# Pick a low-risk agent first
kubectl patch agent k8s-agent -n kagent --type merge \
  -p '{"spec":{"declarative":{"modelConfig":"agentgateway-azure-openai"}}}'

# Test it end-to-end
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
curl -s -X POST "http://localhost:8083/api/a2a/kagent/k8s-agent/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"How many nodes in this cluster?"}]}}}' \
  | jq '.result.artifacts[0].parts[0].text'

# If that works, roll out to all agents
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"agentgateway-azure-openai"}}}'
done
```

---

## Logging (management + worker)

The Alloy operator is already shipping to central Loki. Paste the snippet at the
bottom of `monitoring.yaml` into the existing Alloy config on each cluster:

- Management cluster Alloy: discover `agentgateway-system` pods
- Worker cluster Alloy: discover `kagent` namespace pods

Then restart Alloy to pick up the new config:

```bash
kubectl rollout restart daemonset/alloy -n monitoring
# or:
kubectl rollout restart deployment/alloy -n monitoring
```

---

## Rollback

```bash
# Revert all agents to the previous ModelConfig (whatever you used with LiteLLM)
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"<previous-modelconfig-name>"}}}'
done
```

LiteLLM and agentgateway can coexist while you verify — just leave LiteLLM running
until all agents are migrated and stable.

---

## What's in this folder

| File | When |
|---|---|
| `DEPLOY.md` | You are here. |
| `INSTALL.md` | Longer walkthrough with context. |
| `gateway-resources.yaml` | Gateway, HTTPRoutes (mgmt cluster). |
| `backend-kubeai.yaml` | Skip if no KubeAI. |
| `backend-azure-openai.yaml` | UAMI + Azure OpenAI (mgmt cluster). |
| `ai-policy.yaml` | Timeouts, rate limit, PII guard (mgmt cluster). |
| `networkpolicy.yaml` | Restrict ingress/egress (mgmt cluster). |
| `istio-virtualservice.yaml` | Cross-cluster routing (mgmt cluster). |
| `istio-authorization-policy.yaml` | Allow only kagent SA (mgmt cluster). |
| `monitoring.yaml` | ServiceMonitor, alerts, Alloy snippet. |
| `modelconfig-kubeai.yaml` | kagent → KubeAI (worker cluster). |
| `modelconfig-azure.yaml` | kagent → Azure OpenAI (worker cluster). |
| `TEST-PLAN.md` | Full test suite from Factory review. |
| `FACTORY-REVIEW.md` | Factory quality-gate notes. |
