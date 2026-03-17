# Today's Playbook — Local Triage on AKS Worker Clusters

Deploy kagent triage locally on each AKS worker cluster. Each cluster watches its own K8s events, triages them with a local kagent agent, creates GitLab tickets, and pings the Logic App (→ Teams).

Management cluster / Event Hub / Alloy is already wired and tested — that's phase 2 (not today).

## The Flow

```
Same AKS Cluster
──────────────────────────────────────────────────────────
K8s Warning Event (e.g. CrashLoopBackOff in kyverno ns)
  │
  ▼
EventSource (k8s-warning-events)      ← watches K8s events locally
  │
  ▼
Sensor (per-namespace filter)          ← one sensor per namespace
  │
  ▼
Workflow: kagent-triage                ← shared template, all sensors use it
  │
  ├─ find-agent         → matches namespace to agent name
  ├─ create-conversation → A2A call to kagent (uses kagent-tool-server k8s tools)
  ├─ send-logic-app      → POST to Logic App webhook (→ Teams)
  └─ send-telegram       → optional, skips if no token
```

kagent uses its built-in k8s tools (`k8s_get_resources`, `k8s_get_pod_logs`, `k8s_describe_resource`, etc.) via `kagent-tool-server`. No AKS-MCP needed — just RBAC on the kagent service account.

---

## Prerequisites

Check these exist on the target AKS cluster before starting:

- [ ] Argo Workflows installed
- [ ] Argo Events installed + EventBus (NATS) running in `argo-events`
- [ ] kagent installed (controller + tool-server in `kagent` namespace)
- [ ] ModelConfig deployed in `kagent` namespace (Azure OpenAI or LiteLLM)
- [ ] `argo-events-sa` ServiceAccount with RBAC for workflows + workflowtaskresults

---

## Step 1: Push & Pull

```bash
# From Mac
cd ~/Desktop/repo/argo-workflow
git add kagent-triage/
git commit -m "kagent triage: full pipeline for lift-and-shift"
git push

# At work
git pull
cd kagent-triage/
```

---

## Step 2: Deploy the Logic App

Standalone — no cluster dependencies. Do this first so you have the webhook URL ready.

```bash
RESOURCE_GROUP="your-rg"
LOCATION="uksouth"

# Deploy
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file logic-app/arm-template.json \
  --parameters logicAppName=kagent-triage-webhook

# Get webhook URL
SUB_ID=$(az account show --query id -o tsv)
WEBHOOK_URL=$(az rest --method POST \
  --uri "/subscriptions/$SUB_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/kagent-triage-webhook/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv)
echo "Webhook URL: $WEBHOOK_URL"

# Test it
curl -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d @logic-app/test-payload.json
# Expect: 200, {"status":"received","message":"Triage event logged successfully"}
```

### Wire to Teams (optional, can do later)

Azure Portal → Logic App Designer → add action after trigger:
1. **Post Adaptive Card in a chat or channel** (Teams connector)
2. Map `event_namespace`, `event_reason`, `resource_name`, `agent_diagnosis`
3. Save → re-test with curl

---

## Step 3: Create Secrets on AKS

```bash
# Logic App webhook
kubectl create secret generic logic-app-webhook-secret \
  --from-literal=url="$WEBHOOK_URL" \
  -n argo-events

# GitLab token (for auto-creating issues)
kubectl create secret generic gitlab-token \
  --from-literal=GITLAB_TOKEN="glpat-xxxx" \
  -n argo-events

# Telegram (optional — workflow skips gracefully if missing)
# kubectl create secret generic telegram-bot-secret \
#   --from-literal=token="YOUR_BOT_TOKEN" \
#   -n argo-events
```

---

## Step 4: Deploy the EventSource

This watches K8s Warning events cluster-wide. One per cluster.

```bash
# Check if one already exists
kubectl get eventsources -n argo-events

# If not, deploy the local K8s event watcher
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: k8s-warning-events
  namespace: argo-events
spec:
  eventBusName: default
  resource:
    warning-events:
      namespace: ""
      group: ""
      version: v1
      resource: events
      eventTypes:
        - ADD
      filter:
        afterEventTime: "2024-01-01T00:00:00Z"
        fields:
          - key: type
            operation: "=="
            value: Warning
EOF

# Verify pod starts
kubectl get pods -n argo-events -l eventsource-name=k8s-warning-events
```

**Note:** if your EventSource has a different name, update the `eventSourceName` in each sensor before deploying them.

---

## Step 5: Deploy the Workflow Template

Update these values before applying:

| What | Homelab Value | Your Work Value |
|------|---------------|-----------------|
| `telegram-chat-id` (line 26) | `xxx` | Your channel ID, or leave as-is (skips if no token) |
| `CLUSTER_NAME` (line 404) | `kind-homelab` | Your AKS cluster name |

```bash
# Edit, then apply
kubectl apply -f 02-workflow-kagent-triage.yaml

# Verify
kubectl get workflowtemplates -n argo-events
```

---

## Step 6: Deploy Agents + Sensors — One Namespace at a Time

Target namespaces for local triage:

| # | Namespace | Agent File | Sensor File | What It Watches |
|---|-----------|------------|-------------|-----------------|
| 1 | kyverno | `kyverno-agent.yaml` | `kyverno-sensor.yaml` | Policy engine issues |
| 2 | external-secrets | `external-secrets-agent.yaml` | `external-secrets-sensor.yaml` | Secret sync failures |
| 3 | cert-manager | `cert-manager-agent.yaml` | `cert-manager-sensor.yaml` | Certificate issues |
| 4 | reloader | `reloader-agent.yaml` | `reloader-sensor.yaml` | ConfigMap/Secret reload issues |

### For each namespace:

#### A. Deploy the Agent

```bash
# Example: kyverno
kubectl apply -f kyverno-agent.yaml

# Wait for agent pod to be Running
kubectl get agents -n kagent
kubectl get pods -n kagent -l agent-name=kyverno-agent
```

#### B. Smoke Test the Agent (recommended)

```bash
# Port-forward kagent controller
kubectl port-forward -n kagent svc/kagent-controller 8083:8083 &

# A2A call to verify the agent responds
curl -s -X POST http://localhost:8083/api/a2a/kagent/kyverno-agent/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "test-1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "Check the kyverno namespace for any warnings or issues"}]
      }
    }
  }' | jq '.result.artifacts[0].parts[0].text' -r | head -20
```

#### C. Deploy the Sensor

```bash
kubectl apply -f kyverno-sensor.yaml

# Verify sensor pod is running
kubectl get sensors -n argo-events
kubectl get pods -n argo-events -l sensor-name=kagent-triage-kyverno
```

#### D. Test End-to-End

Inject a fault to trigger the full pipeline:

```bash
# Create a crashlooping pod in the target namespace
kubectl run crashloop-test --image=busybox --restart=Always \
  -n kyverno -- sh -c "exit 1"

# Watch for workflow to fire
kubectl get workflows -n argo-events -w

# Once workflow shows Succeeded, verify:
# 1. Logic App: Azure Portal → Logic App → Run History
# 2. Teams: check the channel (if wired)
# 3. GitLab: check for new issue

# Clean up
kubectl delete pod crashloop-test -n kyverno
```

#### E. Confirm ✓

- [ ] Agent pod Running
- [ ] A2A smoke test returned a diagnosis
- [ ] Sensor pod Running
- [ ] Workflow triggered and Succeeded
- [ ] Logic App received the payload
- [ ] GitLab issue created (if token configured)

### Then move to the next namespace.

---

## Step 7: Verify Everything Together

Once all agents and sensors are deployed:

```bash
# All agents ready
kubectl get agents -n kagent

# All sensors running
kubectl get sensors -n argo-events

# All sensor pods healthy
kubectl get pods -n argo-events -l app=sensor

# Recent workflows
kubectl get workflows -n argo-events --sort-by=.metadata.creationTimestamp | tail -10
```

---

## Troubleshooting

### Workflow fails with workflowtaskresults RBAC error

```bash
# The argo-events-sa needs this ClusterRole
kubectl create clusterrole argo-events-workflow-runner \
  --verb=create,get,list,watch \
  --resource=workflows,workflowtemplates,workflowtaskresults

kubectl create clusterrolebinding argo-events-workflow-runner \
  --clusterrole=argo-events-workflow-runner \
  --serviceaccount=argo-events:argo-events-sa
```

### find-agent step can't find the right agent

The workflow matches namespace name to agent name. Agent names must contain the namespace:
- `kyverno-agent` matches events from `kyverno` namespace ✓
- `my-custom-agent` would NOT match ✗

### Logic App returns 4xx

- Webhook URLs can expire — regenerate via `listCallbackUrl` (Step 2)
- Check payload has all required fields: `event_namespace`, `event_reason`, `resource_kind`, `resource_name`, `agent_diagnosis`

### Sensor fires but no workflow appears

```bash
# Check sensor logs
kubectl logs -n argo-events -l sensor-name=kagent-triage-kyverno --tail=20

# Common: EventSource name mismatch
# Sensors reference eventSourceName: k8s-warning-events
# Make sure your EventSource is named exactly that
kubectl get eventsources -n argo-events
```

### Agent pod won't start

```bash
# Check if ModelConfig exists
kubectl get modelconfigs -n kagent

# Check kagent-tool-server is running
kubectl get pods -n kagent -l app=kagent-tool-server
```

---

## What's Next (Not Today)

- **Management cluster triage** — critical namespaces (kube-system, flux-system, gatekeeper-system, istio) via Event Hub. Already built and tested in `aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/`
- **Alloy deployment** — forward events from worker clusters to Event Hub
- **Agent routing ConfigMap** — namespace→agent mapping for management cluster workflow
- **Logic App → Teams Adaptive Card** — rich formatting for the Teams notification
