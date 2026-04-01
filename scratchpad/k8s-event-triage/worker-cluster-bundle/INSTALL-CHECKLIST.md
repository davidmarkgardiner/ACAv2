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

## Step 5: Install kagent (3 charts)

kagent requires three Helm charts installed in order:

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
kubectl get crd agents.kagent.dev modelconfigs.kagent.dev
# agents.kagent.dev        YYYY-MM-DD
# modelconfigs.kagent.dev  YYYY-MM-DD
```
- [ ] Agent CRD exists
- [ ] ModelConfig CRD exists

### 5b: kagent controller + tools + UI

```bash
# Option A: Azure OpenAI
helm install kagent kagent/kagent \
  --namespace kagent \
  --set providers.default=azureOpenAI \
  --set providers.azureOpenAI.apiKey="YOUR_KEY" \
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

This deploys: controller, tool server (kagent-tools), UI, PostgreSQL, RBAC.

**Verify:**
```bash
kubectl get pods -n kagent
# kagent-controller-xxx   Running
# kagent-tools-xxx        Running    ← MCP tool server (k8s tools)
# kagent-ui-xxx           Running
# kagent-postgresql-xxx   Running    ← (if enabled)
```
- [ ] kagent-controller running
- [ ] kagent-tools running (this is the MCP tool server — provides k8s_get_resources, k8s_get_pod_logs, etc.)
- [ ] kagent-ui running

### 5c: Pre-built agents (optional)

```bash
# Installs k8s-agent, helm-agent, observability-agent, etc.
helm install kagent-agents kagent/agents \
  --namespace kagent
```

**Verify:**
```bash
kubectl get agents -n kagent
# k8s-agent             Ready   Accepted
# helm-agent            Ready   Accepted
# observability-agent   Ready   Accepted
```
- [ ] Pre-built agents deployed (optional — we deploy our own triage agents in Step 10)

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

### Option B: LiteLLM Proxy (if running separately)

```bash
kubectl create secret generic litellm-key \
  --from-literal=api-key="YOUR_LITELLM_KEY" \
  -n kagent

kubectl apply -f modelconfig-remote-litellm.yaml
# Edit the baseUrl and CA cert first!
```

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
