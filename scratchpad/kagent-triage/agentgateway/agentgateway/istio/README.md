# agentgateway — kagent LiteLLM replacement

Replace LiteLLM with [agentgateway](https://agentgateway.dev) as the AI gateway
between kagent (worker cluster) and LLM providers (Azure OpenAI via UAMI,
KubeAI, vLLM-hosted Qwen). Includes Istio wildcard ingress, monitoring, and
secret-rotation-safe UAMI custom-scope workflow.

## Architecture

```
┌─ Worker cluster ────────────────────────────┐   ┌─ Management cluster ──────────────────────┐
│                                             │   │                                           │
│  kagent                                     │   │  Istio ingress (aks-istio-ingress)        │
│   ModelConfig: agentgateway-azure-openai    │   │     │ wildcard cert *.<domain>            │
│   baseUrl: https://agentgateway.<domain>    │───┼─►   │                                     │
│                                             │   │     ▼                                     │
└─────────────────────────────────────────────┘   │  VirtualService (istio-virtualservice)    │
                                                  │     │  hosts: [agentgateway.<domain>]     │
                                                  │     │  gateways: [shared-wildcard]        │
                                                  │     ▼                                     │
                                                  │  agentgateway (ai-gateway:80)             │
                                                  │     │  HTTPRoutes:                        │
                                                  │     │    /azure/v1   → azure-openai-bknd  │
                                                  │     │    /openai/v1  → kubeai-bknd        │
                                                  │     │    /qwen/v1    → vllm-qwen-bknd     │
                                                  │     ▼                                     │
                                                  │  AgentgatewayBackends                     │
                                                  │     │  • azureopenai + UAMI (or CronJob)  │
                                                  │     │  • openai (KubeAI / vLLM)           │
                                                  │     ▼                                     │
                                                  │  Azure OpenAI / KubeAI / vLLM             │
                                                  └───────────────────────────────────────────┘
```

## Start Here

| Task | Read |
|---|---|
| First-time deploy at work | `DEPLOY.md` |
| Validate mgmt cluster before worker | `VALIDATE-MGMT.md` |
| Check required CRDs | `./preflight-check.sh` |
| Understand why secret rotation is safe | `SECRET-ROTATION-TEST.md` |
| See what the Factory review flagged | `FACTORY-REVIEW.md` |

## Files

### Management cluster — always apply

| File | Purpose |
|---|---|
| `gateway-resources.yaml` | GatewayClass, Gateway, HTTPRoutes for `/openai/v1` + `/azure/v1`, ReferenceGrant |
| `ai-policy.yaml` | AgentgatewayPolicy: timeouts, rate limits, PII guard |
| `istio-virtualservice.yaml` | VirtualService attaching specific host under the shared wildcard Gateway to agentgateway |
| `istio-authorization-policy.yaml` | Source IP allow-list (with optional API key / JWT upgrade paths) |

### Management cluster — pick one Azure backend

| File | Use when |
|---|---|
| `backend-azure-openai.yaml` | Azure OpenAI scope is the default `https://cognitiveservices.azure.com/.default` |
| `backend-azure-openai-customscope.yaml` | Custom AAD app audience (e.g. `api://at12345-xxxx/.default`). Uses a CronJob token refresher |

### Management cluster — optional backends

| File | Use when |
|---|---|
| `backend-kubeai.yaml` | KubeAI local model server available |
| `backend-vllm-qwen.yaml` | vLLM-hosted Qwen model — HTTPRoute at `/qwen/v1` with URL rewrite |

### Management cluster — optional infrastructure

| File | Requires |
|---|---|
| `networkpolicy.yaml` | CNI with NetworkPolicy support (Calico, Cilium) |
| `monitoring.yaml` | Prometheus Operator CRDs |

### Worker cluster

| File | Applies when |
|---|---|
| `modelconfig-azure.yaml` | Pointing kagent at Azure OpenAI backend |
| `modelconfig-kubeai.yaml` | Pointing kagent at KubeAI backend |
| `modelconfig-qwen.yaml` | Pointing kagent at vLLM/Qwen backend |
| `kagent-values-otel.yaml` | Want richer kagent → Alloy OTLP logs/traces (Helm values overlay) |

## Empirical Validation Status

Proven on the red cluster (see `SECRET-ROTATION-TEST.md`):

- ✅ agentgateway v1.1.0 Helm install
- ✅ AgentgatewayBackend with `provider.openai` + `host` + `port`
- ✅ HTTPRoute with `URLRewrite` (`/qwen/v1` → `/openai/v1`)
- ✅ `secretRef` with `Authorization` key and `Bearer <value>` content
- ✅ End-to-end chat completion (2.5s, 20 tokens, real response)
- ✅ Native Prometheus token metrics emitted (`agentgateway_gen_ai_client_token_usage`)
- ✅ Secret rotation via `kubectl patch secret` → xDS push → data-plane pod picks up new value with **zero restarts and zero connection drops** (~1s propagation)

Not yet tested in production:

- Custom-scope UAMI CronJob against real Azure AD (schema validated; end-to-end needs real UAMI + Azure OpenAI)
- Istio VirtualService via wildcard Gateway (pattern documented; depends on your shared Gateway)
- Cross-cluster from worker kagent (end-to-end smoke depends on network path between clusters)

## Deploy Order — Minimum Viable

```bash
# 0. Preflight both clusters
./preflight-check.sh --context=<mgmt-cluster>
./preflight-check.sh --context=<worker-cluster>

# 1. Management cluster: install + apply
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version v1.1.0 -n agentgateway-system --create-namespace
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.1.0 -n agentgateway-system

kubectl apply -f gateway-resources.yaml
kubectl apply -f backend-azure-openai.yaml     # or -customscope
kubectl apply -f ai-policy.yaml
kubectl apply -f istio-virtualservice.yaml
kubectl apply -f istio-authorization-policy.yaml

# 2. Management cluster: validate end-to-end (see VALIDATE-MGMT.md for full flow)
kubectl port-forward -n agentgateway-system svc/ai-gateway 8080:80 &
curl -s -X POST http://localhost:8080/azure/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<deployment>","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  | jq .choices[0].message.content

# 3. Worker cluster: dummy secret + ModelConfig + roll out
kubectl create secret generic litellm-key -n kagent \
  --from-literal=api-key="not-required" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f modelconfig-azure.yaml
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"agentgateway-azure-openai"}}}'
done
```

## Common Gotchas

1. **`Route not found` / `failed to parse request: EOF`** — testing with GET or empty body. AI backends only accept POST with a valid chat-completions JSON body. Use `curl -X POST -H "Content-Type: application/json" -d '{"model":"...","messages":[...]}'`.

2. **`host`/`port` belong at `spec.ai.provider.*`, NOT inside `openai`/`azureopenai`** — webhook rejects nested. Always set them as siblings of the provider type object.

3. **Secret data key must be literally `Authorization`** — not `api-key`. Value is used verbatim as the `Authorization` HTTP header, so include the `Bearer ` prefix for AAD tokens.

4. **Envoy metrics port is 15020** (agentgateway-specific) — not 15090 (Istio default).

5. **AKS Istio add-on = separate mesh per cluster.** Worker reaches mgmt via HTTPS ingress, not mesh. AuthorizationPolicy must use source IP / API key / JWT — not ServiceAccount principals.

## Rollback

All agents back to the original ModelConfig (LiteLLM or whatever was there before):

```bash
for agent in $(kubectl get agent -n kagent -o name | sed 's|agent.kagent.dev/||'); do
  kubectl patch agent "$agent" -n kagent --type merge \
    -p '{"spec":{"declarative":{"modelConfig":"<previous-modelconfig-name>"}}}'
done
```

Leave agentgateway running during rollback — nothing routes to it once no
ModelConfig references it.
