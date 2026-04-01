# Installation Checklist — Worker Cluster Triage Stack

End-to-end deployment from bare cluster to live event-driven triage. Work through in order — each step has a verification command.

**Target cluster:** `_______________`
**Date:** `_______________`
**Engineer:** `_______________`

---

## Prerequisites

Before starting, confirm you have:

```bash
# Cluster access
kubectl cluster-info
kubectl auth can-i create namespaces

# Helm 3
helm version

# Argo CLI (optional but useful)
argo version
```

- [ ] kubectl access to the target cluster
- [ ] Helm 3 installed
- [ ] This repo cloned locally
- [ ] Access to a container registry (for workflow images — `python:3.11-slim`, `bitnami/kubectl`)

---

## Step 1: Create Namespaces

```bash
kubectl create namespace argo
kubectl create namespace argo-events
kubectl create namespace kagent
```

**Verify:**
```bash
kubectl get ns argo argo-events kagent
```
- [ ] All three namespaces exist

---

## Step 2: Install Argo Workflows

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argo-workflows argo/argo-workflows \
  --namespace argo \
  --set server.extraArgs="{--auth-mode=server}" \
  --set controller.workflowNamespaces="{argo,argo-events}" \
  --wait
```

**Verify:**
```bash
kubectl get pods -n argo
# argo-workflows-server-xxx       Running
# argo-workflows-controller-xxx   Running
```
- [ ] Workflow controller running
- [ ] Server running

---

## Step 3: Install Argo Events

```bash
helm install argo-events argo/argo-events \
  --namespace argo-events \
  --wait
```

**Verify:**
```bash
kubectl get pods -n argo-events
# argo-events-controller-manager-xxx   Running
```
- [ ] Events controller running

---

## Step 4: Create EventBus (NATS)

```bash
kubectl apply -n argo-events -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      auth: token
EOF
```

**Verify:**
```bash
kubectl get eventbus -n argo-events
# default   true

kubectl get pods -n argo-events | grep eventbus
# eventbus-default-stan-0   Running
# eventbus-default-stan-1   Running
# eventbus-default-stan-2   Running
```
- [ ] EventBus shows `true`
- [ ] NATS pods running (3 replicas)

---

## Step 5: Install kagent (2 charts)

kagent requires two Helm charts. CRDs first, then the main chart (which includes controller, tools, UI, PostgreSQL, and built-in agents).

### 5a: CRDs (must be first)

```bash
helm repo add kagent https://kagent-dev.github.io/kagent
helm repo update

helm install kagent-crds kagent/kagent-crds \
  --namespace kagent \
  --create-namespace
```

**Verify:**
```bash
kubectl get crd agents.kagent.dev modelconfigs.kagent.dev remotemcpservers.kagent.dev
# agents.kagent.dev             YYYY-MM-DD
# modelconfigs.kagent.dev       YYYY-MM-DD
# remotemcpservers.kagent.dev   YYYY-MM-DD
```
- [ ] Agent CRD exists
- [ ] ModelConfig CRD exists
- [ ] RemoteMCPServer CRD exists

### 5b: kagent (controller + tools + UI + agents — all in one chart)

```bash
# Option A: Azure OpenAI
helm install kagent kagent/kagent \
  --namespace kagent \
  --set providers.default=azureOpenAI \
  --set providers.azureOpenAI.apiKey="YOUR_KEY" \
  --set providers.azureOpenAI.config.azureEndpoint="https://YOUR-INSTANCE.openai.azure.com" \
  --set providers.azureOpenAI.config.azureDeployment="gpt-4o" \
  --wait

# Option B: OpenAI
helm install kagent kagent/kagent \
  --namespace kagent \
  --set providers.default=openAI \
  --set providers.openAI.apiKey="YOUR_KEY" \
  --wait

# Option C: No default provider (configure ModelConfig manually in Step 6)
helm install kagent kagent/kagent \
  --namespace kagent \
  --wait
```

This single chart deploys everything:
- **kagent-controller** — reconciles Agent CRDs, runs the A2A HTTP server
- **kagent-tools** — MCP tool server (k8s_get_resources, k8s_get_pod_logs, k8s_describe_resource, etc.)
- **kagent-kmcp-controller** — manages RemoteMCPServer connections
- **kagent-ui** — web dashboard for chatting with agents
- **PostgreSQL** — bundled database (for sessions, future memory)
- **Built-in agents** — k8s-agent, helm-agent, observability-agent, etc. (all enabled by default)
- **RemoteMCPServer** — `kagent-tool-server` pointing at the tools pod

**Verify:**
```bash
kubectl get pods -n kagent
# kagent-controller-xxx               Running
# kagent-tools-xxx                    Running  ← MCP tool server
# kagent-kmcp-controller-xxx          Running
# kagent-ui-xxx                       Running
# kagent-postgresql-xxx               Running  ← (bundled, enabled by default)
# k8s-agent-xxx                       Running  ← built-in agent
# helm-agent-xxx                      Running  ← built-in agent
```
- [ ] kagent-controller running
- [ ] **kagent-tools running** (this is the MCP tool server — without it, agents have no k8s tools)
- [ ] kagent-ui running

**If kagent-tools is missing:**
```bash
# Check if it's disabled
helm get values kagent -n kagent -a | grep -A3 "kagent-tools"

# Enable it
helm upgrade kagent kagent/kagent --namespace kagent --set kagent-tools.enabled=true --wait

# Verify the RemoteMCPServer was created (this is how agents find the tools)
kubectl get remotemcpservers -n kagent
# kagent-tool-server   http://kagent-tools.kagent:8084/mcp
```
- [ ] RemoteMCPServer `kagent-tool-server` exists

**Verify agents can see the tools:**
```bash
kubectl get agents -n kagent
# k8s-agent             Ready   Accepted
# helm-agent            Ready   Accepted
# observability-agent   Ready   Accepted
```
- [ ] Built-in agents deployed and Ready

---

## Step 6: Configure LLM Access (ModelConfig)

### Option A: Azure OpenAI with API Key

```bash
# Create API key secret
kubectl create secret generic aoai-key \
  --from-literal=api-key="YOUR_AZURE_OPENAI_KEY" \
  -n kagent

# Create ModelConfig
kubectl apply -f - <<'EOF'
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: OpenAI
  model: gpt-4o
  apiKeySecret: aoai-key
  apiKeySecretKey: api-key
  openAI:
    baseUrl: https://YOUR-INSTANCE.openai.azure.com/openai/deployments/gpt-4o/v1
EOF
```

### Option B: Remote LiteLLM Proxy over HTTPS (cross-cluster via VirtualService)

This is the setup when LiteLLM runs on a different cluster and is exposed via Istio VirtualService over HTTPS.

```bash
# 1. Get the CA certificate
#    Option i: From the Istio cluster's TLS secret
kubectl --context=LITELLM_CLUSTER get secret <istio-tls-secret> -n istio-system \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

#    Option ii: From the live endpoint (if you don't have cluster access)
openssl s_client -connect litellm.your-domain.com:443 -showcerts < /dev/null 2>/dev/null \
  | openssl x509 -outform PEM > ca.crt

#    Option iii: If using a corporate CA, get it from your PKI team

# 2. Create the CA cert Secret on the KAGENT cluster
kubectl create secret generic litellm-ca-cert-secret \
  --from-file=ca.crt=ca.crt \
  -n kagent

# 3. Create the API key Secret
kubectl create secret generic litellm-key \
  --from-literal=api-key="YOUR_LITELLM_MASTER_KEY" \
  -n kagent

# 4. Apply the ModelConfig (edit baseUrl first!)
#    See modelconfig-remote-litellm.yaml in this bundle
kubectl apply -f modelconfig-remote-litellm.yaml
```

The ModelConfig for remote HTTPS LiteLLM:
```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: OpenAI
  model: gpt-4o
  apiKeySecret: litellm-key
  apiKeySecretKey: api-key
  openAI:
    baseUrl: https://litellm.your-domain.com/v1    # ← your VirtualService host
  tls:
    caCertSecretRef: litellm-ca-cert-secret         # ← Secret with CA cert
    caCertSecretKey: ca.crt
    disableSystemCAs: false
    disableVerify: false
```

**Quick test — skip TLS verification temporarily** (to isolate cert issues from other problems):
```yaml
  tls:
    disableVerify: true    # NOT for production — just to confirm connectivity works
```

**Troubleshooting if agents can't connect:**
```bash
# Can you reach LiteLLM from inside the kagent namespace?
kubectl run curl-test --rm -it --image=curlimages/curl -n kagent -- \
  curl -sv https://litellm.your-domain.com/health/liveliness

# With the CA cert:
kubectl run curl-test --rm -it --image=curlimages/curl -n kagent -- sh -c \
  "echo 'PASTE_CA_CERT_HERE' > /tmp/ca.crt && \
   curl -s --cacert /tmp/ca.crt https://litellm.your-domain.com/health/liveliness"

# Check if it's a DNS issue
kubectl run dns-test --rm -it --image=busybox -n kagent -- nslookup litellm.your-domain.com

# Check ModelConfig status
kubectl describe modelconfig default-model-config -n kagent

# Check kagent controller logs for TLS/connection errors
kubectl logs -n kagent -l app.kubernetes.io/name=kagent --tail=30 | grep -i "error\|tls\|cert\|refused\|timeout"

# Check if NetworkPolicy is blocking egress
kubectl get networkpolicy -n kagent
```

**Common issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `x509: certificate signed by unknown authority` | Missing or wrong CA cert in Secret | Get correct CA cert, recreate Secret |
| `connection refused` | Wrong URL or port | Check VirtualService host + port |
| `no such host` | DNS can't resolve the VirtualService hostname | Check CoreDNS, try IP instead of hostname |
| `context deadline exceeded` | NetworkPolicy blocking egress from kagent namespace | Add egress rule allowing HTTPS to LiteLLM |
| ModelConfig shows `Accepted` but agent still fails | API key wrong or model name mismatch | Verify key works with curl from inside the pod |
| curl works but agent doesn't | Secret name/key mismatch in ModelConfig | Check `apiKeySecret` and `apiKeySecretKey` match exactly |

### Option C: agentgateway with UAMI (production — see AGENTGATEWAY-TRANSITION.md)

**Verify:**
```bash
kubectl get modelconfig -n kagent
# default-model-config   OpenAI   gpt-4o   Accepted
```
- [ ] ModelConfig created and Accepted

---

## Step 6b: Test LLM Connectivity

**Do this now before going further.** Deploy a throwaway test agent and verify it can reach the LLM.

```bash
# Create a minimal test agent
kubectl apply -f - <<'EOF'
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: test-llm-connection
  namespace: kagent
spec:
  description: Temporary agent to test LLM connectivity
  declarative:
    modelConfig: default-model-config
    systemMessage: You are a test agent. Respond with "LLM connection successful" to any message.
    tools: []
EOF

# Wait for Ready
kubectl get agents -n kagent -w
# test-llm-connection   Declarative   True   True
```

```bash
# Port-forward and test
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &
sleep 3

curl -s --max-time 30 -X POST "http://localhost:8083/api/a2a/kagent/test-llm-connection/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"test","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Hello"}]}}}' | python3 -c "
import json,sys
d=json.loads(sys.stdin.read(),strict=False)
if 'error' in d:
    print('ERROR:', json.dumps(d['error'],indent=2))
else:
    for a in d.get('result',{}).get('artifacts',[]):
        for p in a.get('parts',[]):
            if p.get('kind')=='text': print(p['text'][:200])
    print('Status:', d.get('result',{}).get('status',{}).get('state','?'))
"

# Kill port-forward
pkill -f "port-forward.*kagent-controller.*8083"
```

**If this fails:** Check ModelConfig baseUrl, API key secret, network connectivity to LLM endpoint. Fix before proceeding.

```bash
# Troubleshooting
kubectl logs -n kagent -l app.kubernetes.io/name=kagent --tail=20
kubectl describe modelconfig default-model-config -n kagent
```

```bash
# Clean up test agent
kubectl delete agent test-llm-connection -n kagent
```

- [ ] Test agent responded successfully — LLM connection works
- [ ] Test agent cleaned up

---

## Step 7: Create RBAC for Workflows

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-events-sa
  namespace: argo-events
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-events-workflow-role
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates", "workflowtaskresults"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["events", "pods", "pods/log", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets", "statefulsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-events-workflow-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-events-workflow-role
subjects:
  - kind: ServiceAccount
    name: argo-events-sa
    namespace: argo-events
EOF
```

**Verify:**
```bash
kubectl auth can-i create workflows \
  --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# yes

kubectl auth can-i create workflowtaskresults \
  --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# yes
```
- [ ] SA can create workflows
- [ ] SA can create workflowtaskresults

---

## Step 8: Deploy WorkflowTemplate

```bash
kubectl apply -f 02-workflow-template.yaml
```

**Verify:**
```bash
kubectl get workflowtemplates -n argo-events
# kagent-triage   YYYY-MM-DD
```
- [ ] WorkflowTemplate exists

---

## Step 9: Create Notification Secrets (Optional)

Skip any you don't need — the workflow handles missing secrets gracefully.

```bash
# GitLab (for issue creation)
kubectl create secret generic gitlab-token -n argo-events \
  --from-literal=url="https://gitlab.your-domain.com" \
  --from-literal=token="YOUR_GITLAB_TOKEN" \
  --from-literal=project-id="YOUR_PROJECT_ID"

# Teams (via Logic App webhook)
kubectl create secret generic logic-app-webhook-secret -n argo-events \
  --from-literal=url="YOUR_LOGIC_APP_WEBHOOK_URL"

# Telegram
kubectl create secret generic telegram-bot-secret -n argo-events \
  --from-literal=token="YOUR_BOT_TOKEN"
```

- [ ] GitLab secret created (or skipped)
- [ ] Teams/Logic App secret created (or skipped)
- [ ] Telegram secret created (or skipped)

---

## Step 10: Deploy Your First Agent

Start with one namespace. Pick whichever exists on your cluster.

```bash
# Check what's noisy
kubectl get events -n cert-manager --field-selector type=Warning --sort-by='.lastTimestamp' | tail -5

# Deploy the agent
kubectl apply -f agent-cert-manager.yaml

# Wait for Ready
kubectl get agents -n kagent -w
# cert-manager-agent   Declarative   True   True
```

**Verify:**
```bash
kubectl get agents -n kagent
# cert-manager-agent   Ready   Accepted
```
- [ ] Agent deployed and Ready

---

## Step 11: Test the Agent Manually (No Events Yet)

Port-forward to kagent and send a manual A2A call to confirm the agent works:

```bash
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

curl -s --max-time 120 -X POST "http://localhost:8083/api/a2a/kagent/cert-manager-agent/" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"test-1","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Check the health of the cert-manager namespace. List any issues you find."}]}}}' | python3 -c "
import json,sys
d=json.loads(sys.stdin.read(),strict=False)
for a in d.get('result',{}).get('artifacts',[]):
    for p in a.get('parts',[]):
        if p.get('kind')=='text': print(p['text'][:1000])
"

# Kill port-forward when done
pkill -f "port-forward.*kagent-controller.*8083"
```

- [ ] Agent responds with cert-manager namespace analysis

---

## Step 12: Test the Workflow Manually

Submit a workflow manually to test the full pipeline (agent + GitLab + notification):

```bash
argo submit -n argo-events --from workflowtemplate/kagent-triage \
  -p event-namespace=cert-manager \
  -p event-name=test-manual \
  -p event-reason=ManualTest \
  -p event-message="Manual test of triage pipeline" \
  -p resource-kind=Pod \
  -p resource-name=test-pod \
  --wait

# Check logs
argo logs -n argo-events @latest
```

**Verify:**
```bash
argo list -n argo-events
# kagent-triage-xxxxx   Succeeded
```
- [ ] Workflow completed successfully
- [ ] Agent diagnosis in logs
- [ ] GitLab issue created (if secret configured)
- [ ] Notification received (if secret configured)

---

## Step 13: Deploy the Sensor (Turns On Live Events)

**This is the point of no return — after this, real K8s events will trigger workflows.**

```bash
kubectl apply -f sensor-cert-manager.yaml
```

**Verify:**
```bash
kubectl get sensors -n argo-events
# kagent-triage-cert-manager   true
```
- [ ] Sensor deployed and active

---

## Step 14: Deploy the EventSource (Starts Watching)

**This turns everything on. Events will flow.**

```bash
# IMPORTANT: Edit 01-eventsource.yaml first!
# Change the namespace from "test-autohealer" to the namespace you want to watch
# Or use "" to watch all namespaces

kubectl apply -f 01-eventsource.yaml
```

**Verify:**
```bash
kubectl get eventsources -n argo-events
# k8s-all-warnings   true

kubectl get pods -n argo-events | grep eventsource
# k8s-all-warnings-eventsource-xxx   Running
```
- [ ] EventSource deployed and running
- [ ] EventSource pod healthy

---

## Step 15: Validate with Fault Injection

```bash
# Inject a crashlooping pod in the target namespace
kubectl run crashloop-test --image=busybox --restart=Always \
  -n cert-manager -- sh -c "exit 1"

# Watch for workflow
kubectl get workflows -n argo-events -w
# Should see: kagent-triage-cert-manager-xxxxx within 60 seconds

# Check logs
argo logs -n argo-events @latest

# Clean up
kubectl delete pod crashloop-test -n cert-manager
```

- [ ] Warning event generated
- [ ] Sensor triggered workflow
- [ ] Agent diagnosed the crashloop
- [ ] GitLab issue created
- [ ] Notification received
- [ ] Test pod cleaned up

---

## Step 16: Add More Namespaces

Repeat steps 10 + 13 for each namespace:

```bash
# Deploy agent + sensor pair
kubectl apply -f agent-kyverno.yaml
kubectl apply -f sensor-kyverno.yaml

# Verify
kubectl get agents -n kagent
kubectl get sensors -n argo-events
```

Available in this bundle:
- cert-manager, kyverno, external-secrets, reloader, kro
- kube-system, flux-system, istio-system, istio-ingress, gatekeeper-system

---

## Step 17: Monitor for Noise

After 1-2 hours, check how many workflows fired:

```bash
# Count workflows
kubectl get workflows -n argo-events --no-headers | wc -l

# Recent workflows
kubectl get workflows -n argo-events --sort-by='.metadata.creationTimestamp' | tail -10

# If too noisy — reduce rate limit or delete sensor temporarily
kubectl delete sensor kagent-triage-cert-manager -n argo-events
```

- [ ] Workflow count is reasonable (not flooding)
- [ ] Rate limiting working as expected

---

## Quick Reference

| Component | Namespace | Check Command |
|-----------|-----------|---------------|
| Argo Workflows | argo | `kubectl get pods -n argo` |
| Argo Events | argo-events | `kubectl get pods -n argo-events` |
| EventBus | argo-events | `kubectl get eventbus -n argo-events` |
| EventSource | argo-events | `kubectl get eventsources -n argo-events` |
| Sensors | argo-events | `kubectl get sensors -n argo-events` |
| Workflows | argo-events | `kubectl get workflows -n argo-events` |
| kagent | kagent | `kubectl get pods -n kagent` |
| Agents | kagent | `kubectl get agents -n kagent` |
| ModelConfig | kagent | `kubectl get modelconfig -n kagent` |

## Teardown (if needed)

```bash
# Remove sensors first (stops event flow)
kubectl delete sensors --all -n argo-events

# Remove eventsource
kubectl delete eventsources --all -n argo-events

# Remove agents
kubectl delete agents -l app=kagent-triage -n kagent

# Remove workflow template
kubectl delete workflowtemplates kagent-triage -n argo-events

# Remove completed workflows
argo delete --completed -n argo-events
```
