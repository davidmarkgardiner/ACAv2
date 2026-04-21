# DEPLOY.md — Quick Reference

**Goal:** swap LiteLLM for agentgateway. kagent on worker cluster → agentgateway on
management cluster (via Istio VirtualService) → Azure OpenAI (via UAMI).

**This doc is a checklist. For context and alternatives, see `INSTALL.md`.**

---

## 0. Preflight — check CRDs before you start

Before anything else, run the preflight check on **both** clusters:

```bash
# On each cluster context in turn:
./preflight-check.sh                             # current context
./preflight-check.sh --context=<mgmt-cluster>
./preflight-check.sh --context=<worker-cluster>
```

It tells you which CRDs are installed, which are missing, and how to install each.

**Minimum required CRDs:**

| Cluster | Component | Helm install |
|---|---|---|
| Management | Gateway API CRDs | `helm upgrade -i gateway-api oci://registry.k8s.io/gateway-api/charts/gateway-api --version v1.5.0 -n gateway-system --create-namespace` |
| Management | agentgateway CRDs | `helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds --version v1.1.0 -n agentgateway-system --create-namespace` |
| Management | agentgateway controller | `helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway --version v1.1.0 -n agentgateway-system` |
| Management | Istio | `istioctl install --set profile=default` (or via your existing method) |
| Worker | kagent | already installed if kagent is running |

**If you need to mirror to a private registry** (air-gapped or restricted environments):

```bash
# Pull the OCI chart to a local tarball
helm pull oci://registry.k8s.io/gateway-api/charts/gateway-api --version v1.5.0
helm pull oci://cr.agentgateway.dev/charts/agentgateway-crds --version v1.1.0
helm pull oci://cr.agentgateway.dev/charts/agentgateway --version v1.1.0

# Push to your private registry
helm push gateway-api-v1.5.0.tgz oci://<your-registry>/charts
helm push agentgateway-crds-v1.1.0.tgz oci://<your-registry>/charts
helm push agentgateway-v1.1.0.tgz oci://<your-registry>/charts

# Then install from your mirror:
helm upgrade -i gateway-api oci://<your-registry>/charts/gateway-api --version v1.5.0 ...
```

**Container images** to mirror (agentgateway controller pulls these):
```bash
# Inspect what the chart pulls:
helm template oci://cr.agentgateway.dev/charts/agentgateway --version v1.1.0 | grep image:
# Typically: cr.agentgateway.dev/agentgateway/agentgateway:v1.1.0
```

**Optional CRDs (skip the matching manifest if absent):**

| Manifest | Requires | If missing |
|---|---|---|
| `monitoring.yaml` | Prometheus Operator | Skip this file. Logs via Alloy still work. |
| `istio-virtualservice.yaml`, `istio-authorization-policy.yaml` | Istio | Skip these; you lose cross-cluster access and the policy-layer auth |
| `networkpolicy.yaml` | CNI with NetworkPolicy support (Calico, Cilium) | Skip if using a CNI that doesn't honour NetworkPolicy |

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

### 1. Install Gateway API + agentgateway (all via Helm)

```bash
# Gateway API CRDs
helm upgrade -i gateway-api oci://registry.k8s.io/gateway-api/charts/gateway-api \
  --version v1.5.0 \
  --namespace gateway-system --create-namespace

# agentgateway CRDs
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version v1.1.0 \
  --namespace agentgateway-system --create-namespace

# agentgateway controller
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.1.0 \
  --namespace agentgateway-system

kubectl wait --for=condition=ready pod -l app=agentgateway \
  -n agentgateway-system --timeout=120s
```

> **Restricted registries?** If your cluster can't pull from `registry.k8s.io`
> or `cr.agentgateway.dev`, see the "mirror to a private registry" block in
> Section 0 above.

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
| `backend-azure-openai.yaml` (default scope) | `REPLACE_RESOURCE.openai.azure.com` | your Azure OpenAI endpoint |
| `backend-azure-openai.yaml` (default scope) | `REPLACE_DEPLOYMENT_NAME` | your Azure OpenAI deployment |
| `backend-azure-openai.yaml` (default scope) | `REPLACE_WITH_UAMI_CLIENT_ID` | UAMI client ID |
| `backend-azure-openai-customscope.yaml` | `REPLACE_WITH_UAMI_CLIENT_ID` | UAMI client ID |
| `backend-azure-openai-customscope.yaml` | `REPLACE_WITH_CUSTOM_APP_ID` | AAD app ID in `api://<id>/.default` (get from existing LiteLLM config) |
| `backend-azure-openai-customscope.yaml` | `REPLACE_RESOURCE.openai.azure.com` | Azure OpenAI endpoint |
| `backend-azure-openai-customscope.yaml` | `REPLACE_DEPLOYMENT_NAME` | Azure OpenAI deployment |
| `backend-kubeai.yaml` | `REPLACE_WITH_PRIMARY_MODEL` | KubeAI model name (if using local models) |
| `backend-kubeai.yaml` | `REPLACE_WITH_FALLBACK_MODEL` | second KubeAI model (or remove block) |
| `monitoring.yaml` | `kube-prom` | your Prometheus release label |

### 4. Apply manifests in order

Apply what your cluster has CRDs for (run preflight first to confirm):

```bash
# ─── Always apply ──────────────────────────────────────────────────────────
kubectl apply -f gateway-resources.yaml
kubectl apply -f ai-policy.yaml

# ─── Pick ONE Azure OpenAI backend: ────────────────────────────────────────
# (a) Default scope (https://cognitiveservices.azure.com/.default):
kubectl apply -f backend-azure-openai.yaml

# (b) CUSTOM AAD app scope (e.g. api://at12345-xxxx/.default) — USE THIS if
#     your LiteLLM uses a custom audience. Sets up a CronJob token refresher
#     because agentgateway's native azureAuth only supports the default scope.
kubectl apply -f backend-azure-openai-customscope.yaml

# After applying (b), run the job once to seed the secret before traffic:
kubectl create job --from=cronjob/azure-openai-token-refresher \
  azure-openai-token-init -n agentgateway-system

# Verify the secret has the correct key name and Bearer prefix:
kubectl get secret azure-openai-token -n agentgateway-system \
  -o jsonpath='{.data.Authorization}' | base64 -d | head -c 20; echo
# Expected output begins with: "Bearer eyJ..."

# ─── Optional: only if you have KubeAI installed ───────────────────────────
kubectl apply -f backend-kubeai.yaml

# ─── Optional: only if CNI supports NetworkPolicy ──────────────────────────
kubectl apply -f networkpolicy.yaml

# ─── Optional: only if Istio CRDs are installed ────────────────────────────
kubectl apply -f istio-virtualservice.yaml
kubectl apply -f istio-authorization-policy.yaml

# ─── Optional: only if Prometheus Operator CRDs are installed ──────────────
kubectl apply -f monitoring.yaml

# Sanity check what got applied
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

## Observability

Three things come out of the box once `monitoring.yaml` is applied and the Alloy
snippets pasted in:

### 1. Logs — both agentgateway AND kagent → central Loki

Two options depending on how much detail you want:

**Option A — Pod log scraping (simple, no kagent Helm change):**
Paste the log-discovery snippet from `monitoring.yaml` into the existing Alloy
config on each cluster:
- Mgmt cluster Alloy: namespace `agentgateway-system`
- Worker cluster Alloy: namespace `kagent`

Then:
```bash
kubectl rollout restart daemonset/alloy -n monitoring   # or deployment/
```

**Option B — Structured OTLP logs from kagent (richer):**
On the worker cluster, layer in the extra Helm values file to enable kagent's
OTEL log exporter:
```bash
helm upgrade kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --namespace kagent \
  -f kagent-values.yaml \
  -f kagent-values-otel.yaml
```
kagent will then send structured logs to Alloy on `:4317` with agent name,
model, session ID, token counts, latency as fields. Requires Alloy OTLP receiver
(see snippet in `monitoring.yaml`).

### 2. Metrics — agentgateway + kagent, native Prometheus

Applying `monitoring.yaml` on each cluster gives you:

- **Management cluster:** agentgateway Envoy stats + `agentgateway_gen_ai_client_token_usage`
  (input/output tokens per model)
- **Worker cluster:** kagent controller metrics (`kagent_agent_requests_total`,
  `kagent_agent_request_duration_seconds`) + Go runtime stats

Useful queries (see bottom of `monitoring.yaml`):
```promql
# Input tokens/min per model
sum by (gen_ai_request_model) (
  rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="input"}[1m]) * 60
)

# Avg tokens/request
sum by (gen_ai_request_model) (rate(agentgateway_gen_ai_client_token_usage_sum[5m]))
/
sum by (gen_ai_request_model) (rate(agentgateway_gen_ai_client_token_usage_count[5m]))
```

Alerts included:

| Alert | Cluster | Triggers on |
|---|---|---|
| `AgentgatewayDown` | mgmt | Gateway not scraping for 5m |
| `AgentgatewayHighErrorRate` | mgmt | 5xx rate > 5% for 10m |
| `AgentgatewayHighLatency` | mgmt | p95 > 10s for 10m |
| `AgentgatewayRunawayTokenUsage` | mgmt | > 100k input tokens/min for 5m (stuck agent / retry storm) |
| `AgentgatewayNoTokenActivity` | mgmt | 0 requests for 30m (silent failure signal) |
| `KagentControllerDown` | worker | Controller metrics absent for 2m |
| `KagentHighErrorRate` | worker | Any agent error rate > 10% for 5m |
| `KagentAgentHighLatency` | worker | Any agent p95 > 60s for 10m |
| `KagentCannotReachGateway` | worker | All requests failing for 15m+ (cross-cluster connectivity broken) |

### 3. Traces (optional) — via Alloy OTLP → Tempo

If you have Tempo in the central stack, enable OTEL tracing in agentgateway Helm
values and paste the OTLP receiver snippet from `monitoring.yaml` into Alloy.
Agentgateway traces follow OpenTelemetry `gen_ai.*` semantic conventions, so you
get per-request spans with prompt/completion token counts, model, user, etc.

Skip this if Tempo isn't installed — the Prometheus token metric is enough for
most cost/usage tracking.

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
