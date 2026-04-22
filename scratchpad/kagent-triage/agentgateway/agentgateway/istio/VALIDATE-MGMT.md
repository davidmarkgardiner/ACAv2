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

## 11. (Optional) Expose via Istio wildcard Gateway (2 min)

Only needed when you're ready to let the worker cluster reach agentgateway
over the mesh. Skip this during initial validation — the port-forward smoke
test in step 6 already proves the in-cluster path works.

### 11a. Discover your existing wildcard Gateway

```bash
# Find Gateways with a wildcard host
kubectl get gateway.networking.istio.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.servers[*].hosts}{"\n"}{end}' \
  | grep '\*'

# Find the Istio ingress Service the Gateway is bound to
kubectl get svc -n istio-system -l istio=ingressgateway -o wide
```

Note the namespace/name of the wildcard Gateway and the wildcard domain
(e.g. `*.internal.example.com`). Pick a specific hostname under it for
agentgateway (e.g. `agentgateway.internal.example.com`).

### 11b. Verify the agentgateway Service

```bash
kubectl get svc -n agentgateway-system
```

Expected — a Service matching the `Gateway` resource name (`ai-gateway` here):
```
NAME         TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)
ai-gateway   ClusterIP   10.x.y.z      <none>        80/TCP
```

### 11c. Apply the VirtualService

Substitute placeholders in `istio-virtualservice.yaml`:
- `REPLACE_WITH_AGENTGATEWAY_HOST` — your chosen sub-hostname
- `REPLACE_WITH_SHARED_GATEWAY_NS` / `REPLACE_WITH_SHARED_GATEWAY_NAME` — from 11a

```bash
kubectl apply -f istio-virtualservice.yaml
kubectl get virtualservice -n agentgateway-system agentgateway-vs -o wide
```

### 11d. Test the VirtualService end-to-end

Run these in order — each layer tests something different so a failure
points at the layer that's broken.

**Set variables once:**
```bash
export HOSTNAME=agentgateway.<wildcard-domain>    # the host you picked in 11c
export DEPLOYMENT=<DEPLOYMENT_NAME>               # Azure OpenAI deployment
# Find the Istio ingress external IP:
export INGRESS_IP=$(kubectl get svc -n aks-istio-ingress \
  -l istio=aks-istio-ingressgateway-external \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
# (Standard Istio: kubectl get svc -n istio-system istio-ingressgateway -o ...)
echo "Ingress IP: $INGRESS_IP"
```

**Test 1 — DNS**
```bash
dig +short "$HOSTNAME"
```
Expected: returns the Istio ingress LB IP (or a CNAME that resolves to it).
If empty or wrong IP: add/fix the DNS record (A record → ingress IP, or
CNAME → the AKS cluster's FQDN).

**Test 2 — TCP/TLS connectivity**
```bash
openssl s_client -connect "$HOSTNAME:443" -servername "$HOSTNAME" \
  -brief </dev/null 2>&1 | head -20
```
Expected: TLS handshake succeeds, cert CN/SAN matches the wildcard.
If it fails: the wildcard Gateway isn't serving that hostname, or the
cert doesn't cover it.

**Test 3 — Istio routes the hostname to SOMETHING**
```bash
# Any path — expect 404 or agentgateway's "failed to parse request" 503.
# What we're checking: Istio accepted the Host header.
curl -sv -I "https://$HOSTNAME/" --resolve "$HOSTNAME:443:$INGRESS_IP" -m 10 2>&1 | head -15
```
Look for:
- `HTTP/2 404` or `503` with `x-envoy-upstream-service-time` header → Istio
  matched the VS and sent it to agentgateway. Good.
- `HTTP/2 404` with NO Envoy headers → Istio rejected the Host (no VS matched)
- `connection refused` / timeout → DNS or LB issue (go back to Test 1/2)

**Test 4 — Path matching works**
```bash
# A path NOT in the VS match list should 404 at Istio (no route)
curl -sv -o /dev/null -w "%{http_code}\n" \
  "https://$HOSTNAME/not-a-real-path" \
  --resolve "$HOSTNAME:443:$INGRESS_IP" -m 10
# Expected: 404

# A path in the VS match list should reach agentgateway
curl -sv -o /dev/null -w "%{http_code}\n" \
  "https://$HOSTNAME/azure/v1/nonexistent" \
  --resolve "$HOSTNAME:443:$INGRESS_IP" -m 10
# Expected: 503 with "failed to parse request" body — agentgateway reached
```

**Test 5 — Full chat completion via VirtualService**
```bash
curl -s -X POST "https://$HOSTNAME/azure/v1/chat/completions" \
  --resolve "$HOSTNAME:443:$INGRESS_IP" \
  -H "Content-Type: application/json" \
  -d '{"model":"'$DEPLOYMENT'","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  -m 60 | jq .
```
Expected: same success response as step 6 (the in-cluster port-forward test).
Same tokens, same content — just via ingress instead of port-forward.

**Test 6 — AuthorizationPolicy is blocking unauthorized sources**
(Only after `istio-authorization-policy.yaml` is applied)
```bash
# From an address NOT in the allow-list — expect 403 RBAC: access denied
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://$HOSTNAME/azure/v1/chat/completions" \
  --resolve "$HOSTNAME:443:$INGRESS_IP" -m 10
# Expected from your laptop if your IP isn't in the allow-list: 403
```

### 11e. Debug commands if any test fails

```bash
# VirtualService status + config
kubectl get virtualservice -n agentgateway-system agentgateway-vs -o yaml | yq .status

# Any Istio config errors across the cluster?
istioctl analyze -n agentgateway-system

# Ingress gateway logs — shows every incoming connection
kubectl logs -n aks-istio-ingress -l istio=aks-istio-ingressgateway-external --tail=50 \
  | grep -iE "$HOSTNAME|404|503|RBAC"

# Dump the effective route config for the hostname
istioctl proxy-config route -n aks-istio-ingress \
  deploy/aks-istio-ingressgateway-external --name https.443 \
  | grep -A5 "$HOSTNAME"
```

### 11f. Test from a worker cluster (the real scenario)

If you have access to a worker cluster already, spin up a throwaway pod and
make the same request — this exercises the actual cross-cluster network path:

```bash
# On the WORKER cluster:
kubectl run test-agw --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sv -X POST "https://$HOSTNAME/azure/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"'$DEPLOYMENT'","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
    -m 60
```

If this fails but step 5 from your laptop worked: check (a) DNS is resolvable
from inside the worker cluster, (b) the worker's egress IP is in the
AuthorizationPolicy `remoteIpBlocks`, (c) any Azure NSG / firewall between
the two clusters.

### 11e. Update the kagent ModelConfig (worker cluster)

In `modelconfig-azure.yaml` / `modelconfig-qwen.yaml` on the worker cluster,
set:
```yaml
spec:
  openAI:
    baseUrl: "https://agentgateway.<wildcard-domain>/azure/v1"
```

(Use `http://` if your wildcard Gateway terminates plain HTTP — but HTTPS
is strongly preferred.)

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
