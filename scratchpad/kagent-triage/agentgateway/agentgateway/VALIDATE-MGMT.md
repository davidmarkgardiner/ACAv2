# Management Cluster Validation Runbook

**Goal:** confirm agentgateway + AgentgatewayBackend + Azure OpenAI UAMI works
end-to-end on the management cluster **before** wiring up the worker cluster
or touching any kagent configuration.

**Time:** 15–20 minutes.

**Cluster context:** make sure you're on the management cluster throughout.

```bash
kubectl config current-context   # should be your mgmt cluster
kubectl get ns agentgateway-system 2>/dev/null || echo "not installed yet"
```

---

## 1. Preflight (2 min)

```bash
./preflight-check.sh
```

Must pass (✓ or ○, no ✗):
- Gateway API CRDs
- agentgateway CRDs
- Azure Workload Identity webhook

If any are ✗, install them using the commands the script prints.

---

## 2. Install agentgateway (2 min)

Skip this if `helm list -n agentgateway-system` already shows it installed.

```bash
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --version v1.1.0 -n agentgateway-system --create-namespace

helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --version v1.1.0 -n agentgateway-system

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=agentgateway \
  -n agentgateway-system --timeout=120s
```

**Expected:** `pod/agentgateway-xxx condition met`

---

## 3. Wire up Workload Identity for UAMI (5 min)

```bash
# Find the ServiceAccount the Helm chart created
SA=$(kubectl get sa -n agentgateway-system -o name | head -1 | cut -d/ -f2)
echo "SA name: $SA"

# Annotate it with your UAMI client ID
kubectl annotate sa $SA -n agentgateway-system \
  azure.workload.identity/client-id=<UAMI_CLIENT_ID> --overwrite

kubectl label sa $SA -n agentgateway-system \
  azure.workload.identity/use=true --overwrite

# Federate the UAMI with the SA
AKS_OIDC=$(az aks show --name <AKS_NAME> --resource-group <RG> \
  --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create \
  --identity-name <UAMI_NAME> --resource-group <RG> \
  --name agentgateway-fedcred \
  --issuer "$AKS_OIDC" \
  --subject "system:serviceaccount:agentgateway-system:$SA" \
  --audience api://AzureADTokenExchange

# Restart so the controller picks up the SA annotations
kubectl rollout restart deploy -n agentgateway-system
kubectl rollout status deploy -n agentgateway-system --timeout=60s

# Verify the UAMI has Cognitive Services OpenAI User role
az role assignment list --assignee <UAMI_CLIENT_ID> \
  --query "[?contains(scope, 'cognitiveservices') || contains(scope, 'OpenAI')]" -o table
```

**Expected:** A role assignment for "Cognitive Services OpenAI User" (or similar)
scoped to your Azure OpenAI resource.

---

## 4. Apply the management-cluster manifests (2 min)

Substitute `REPLACE_*` placeholders first (`grep -n REPLACE_ *.yaml`).

```bash
kubectl apply -f gateway-resources.yaml
kubectl apply -f ai-policy.yaml

# Pick ONE (do not apply both — same backend name):
#   (a) default scope:
kubectl apply -f backend-azure-openai.yaml
#   (b) custom AAD app scope (api://at12345-xxxx/.default):
# kubectl apply -f backend-azure-openai-customscope.yaml
# kubectl create job --from=cronjob/azure-openai-token-refresher \
#   azure-openai-token-init -n agentgateway-system
# kubectl get secret azure-openai-token -n agentgateway-system

# Optional (skip if CRDs not installed):
kubectl apply -f networkpolicy.yaml      # needs CNI w/ NetworkPolicy support
kubectl apply -f monitoring.yaml         # needs Prometheus Operator
```

**Expected:** each `kubectl apply` returns `created` with no errors.

---

## 5. Verify resources accepted by controller (1 min)

```bash
kubectl get gateway,agentgatewaybackend,agentgatewaypolicy,httproute \
  -n agentgateway-system
```

**Expected output:**

```
NAME                                           CLASS          ADDRESS          PROGRAMMED   AGE
gateway.../ai-gateway                          agentgateway   <ip>             True         ...

NAME                                            ACCEPTED   AGE
agentgatewaybackend.../azure-openai-backend     True       ...

NAME                                            AGE
agentgatewaypolicy.../azure-openai-ai-policy    ...

NAME                                     HOSTNAMES   AGE
httproute.../azure-openai-route                      ...
```

**Fail criteria:**
- `PROGRAMMED=False` → check `kubectl describe gateway ai-gateway -n agentgateway-system` for controller errors
- `ACCEPTED=False` → check `kubectl describe agentgatewaybackend ... ` — typically a schema error in the spec

---

## 6. Smoke test — chat completion through agentgateway (3 min)

```bash
kubectl port-forward -n agentgateway-system svc/ai-gateway 8080:80 &
PF=$!
sleep 2

# Substitute <DEPLOYMENT_NAME> with your Azure OpenAI deployment name
curl -s -X POST http://localhost:8080/azure/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<DEPLOYMENT_NAME>","messages":[{"role":"user","content":"Reply with just OK."}],"max_tokens":10}' \
  -m 60 | jq .

kill $PF
```

**Expected output (success):**

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "<deployment>",
  "choices": [{"message":{"role":"assistant","content":"OK"}, ...}],
  "usage": {"prompt_tokens": 14, "completion_tokens": 2, "total_tokens": 16}
}
```

**Fail criteria and what to check:**

| Response | Likely cause | Next step |
|---|---|---|
| `401 Unauthorized` | UAMI token not being fetched / wrong audience | Check logs (step 8). If custom scope, verify `AAD_SCOPE` env var in CronJob. |
| `403 Forbidden` | UAMI lacks "Cognitive Services OpenAI User" role | Re-run `az role assignment create` |
| `404 Not Found` | `deploymentName` in backend doesn't match Azure deployment | `kubectl edit agentgatewaybackend azure-openai-backend -n agentgateway-system` |
| `503` with `parse request EOF` | You hit `/azure/v1/models` (not a chat path) — AI backends only accept chat-shaped requests | Use `/chat/completions`, not `/models` |
| Timeout | Azure endpoint not reachable from cluster (egress rules, private endpoint DNS) | Check `kubectl get networkpolicy`; test with `curl` from a pod |

---

## 7. Verify native token metrics (1 min)

```bash
POD=$(kubectl get pod -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-class-name=agentgateway -o name | head -1)
kubectl port-forward -n agentgateway-system $POD 15020:15020 &
sleep 2

curl -s http://localhost:15020/metrics | \
  grep -E 'agentgateway_gen_ai_client_token_usage_sum\{' | head -4

kill %1 2>/dev/null
```

**Expected output:**

```
agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="input",
  gen_ai_operation_name="chat",gen_ai_system="azureopenai",
  gen_ai_request_model="<deployment>",...} 14.0
agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="output",...} 2.0
```

If sums are 0 or the metric is absent: the request didn't reach the backend
successfully. Go back to step 6 and look at response codes + logs.

---

## 8. Inspect logs if anything failed (1 min)

```bash
# Data-plane pod logs (shows each request and any upstream errors)
kubectl logs -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-class-name=agentgateway \
  --tail=50 | grep -E 'request|error|warn'

# Control-plane pod logs (shows config reconciliation + Secret informer events)
kubectl logs -n agentgateway-system \
  -l app.kubernetes.io/name=agentgateway \
  --tail=50 | grep -iE 'error|warn|token|secret|azureauth'
```

Look for:
- `gen_ai.provider.name=azureopenai` → backend identified correctly
- `endpoint=<your-endpoint>:443` → upstream address resolved
- `error="..."` → specific failure reason

---

## 9. (If using custom scope) Verify the CronJob ran (1 min)

```bash
# Jobs the CronJob created
kubectl get jobs -n agentgateway-system -l job-name \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].type,COMPLETE:.status.succeeded'

# Secret written by the job — value should start with "Bearer eyJ..."
kubectl get secret azure-openai-token -n agentgateway-system \
  -o jsonpath='{.data.Authorization}' | base64 -d | head -c 20 ; echo

# Job logs (if it failed)
kubectl logs -n agentgateway-system job/azure-openai-token-init
```

**Expected:** status `Complete`, secret starts with `Bearer eyJ`.

---

## 10. (Optional) Verify secret rotation doesn't disrupt (~2 min)

If you want to confirm the xDS hot-reload empirically on your own cluster
(already verified on the red cluster, see `SECRET-ROTATION-TEST.md`):

```bash
# Note current pod UID
POD=$(kubectl get pod -n agentgateway-system \
  -l gateway.networking.k8s.io/gateway-class-name=agentgateway -o name | head -1)
UID_BEFORE=$(kubectl get $POD -n agentgateway-system -o jsonpath='{.metadata.uid}')

# Force-rotate the secret (only relevant if using custom scope)
kubectl create job --from=cronjob/azure-openai-token-refresher \
  azure-openai-rotate-test -n agentgateway-system
sleep 10

# Make another request — should still succeed, same pod, no restarts
kubectl port-forward -n agentgateway-system svc/ai-gateway 8080:80 &
sleep 2
curl -s -X POST http://localhost:8080/azure/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<DEPLOYMENT_NAME>","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  -m 60 | jq '.choices[0].message.content'
kill %1 2>/dev/null

# Verify pod is the same
UID_AFTER=$(kubectl get $POD -n agentgateway-system -o jsonpath='{.metadata.uid}' 2>/dev/null)
[[ "$UID_BEFORE" == "$UID_AFTER" ]] && echo "PASS: no pod restart" || echo "FAIL: pod was replaced"
```

---

## Success criteria — can you proceed to worker cluster?

All of these must be ✅ before touching kagent:

- [ ] Gateway `PROGRAMMED=True`
- [ ] AgentgatewayBackend `ACCEPTED=True`
- [ ] Chat completion returns a response from Azure OpenAI
- [ ] Token metric shows non-zero sums with the right `gen_ai_system` label
- [ ] No repeated errors in data-plane logs
- [ ] (Custom scope only) CronJob completed and secret has `Bearer eyJ...` value

When all green, move to the worker-cluster section of `DEPLOY.md` (Steps 6 onwards).

---

## Rollback this validation

Leaves the cluster clean for retrying:

```bash
kubectl delete agentgatewaybackend,agentgatewaypolicy,httproute,gateway \
  -n agentgateway-system --all
kubectl delete secret azure-openai-token -n agentgateway-system 2>/dev/null
kubectl delete cronjob,job -n agentgateway-system -l refresher 2>/dev/null
# (Leave the Helm install and SA annotations — those are the time-consuming parts)
```
