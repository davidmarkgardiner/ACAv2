# Management Cluster — AKS System Namespace Triage

AKS system namespace agents + routing on the management cluster. Events arrive via Event Hub (OTLP pipeline from worker cluster Alloy).

## What Lives Here

| Component | Where | Purpose |
|-----------|-------|---------|
| Agent CRDs | `kagent` namespace | Specialist agents for each AKS system namespace |
| `agent-routing` ConfigMap | `argo-events` namespace | Routes events to the right agent |
| `k8s-triage-critical` WorkflowTemplate | `argo-events` namespace | OTLP parse + KAgent + GitLab + Teams + Mattermost |
| EventSource (Event Hub) | `argo-events` namespace | Receives OTLP events from worker cluster Alloy |
| Sensor (OTLP) | `argo-events` namespace | Triggers workflow on incoming events |

**No per-namespace sensors needed** — the OTLP pipeline's `parse-otlp` step routes events to the correct agent via the `agent-routing` ConfigMap.

## Namespaces Handled Here

These are AKS system namespaces — events come from the worker cluster via Alloy → Event Hub → OTLP pipeline.

| Agent | Namespace | Components |
|-------|-----------|------------|
| `kube-system-agent` | kube-system | CoreDNS, Cilium, metrics-server, CSI drivers, KEDA, konnectivity |
| `flux-system-agent` | flux-system | source-controller, kustomize-controller, helm-controller |
| `gatekeeper-system-agent` | gatekeeper-system | OPA Gatekeeper, Azure Policy webhook, audit |
| `aks-istio-system-agent` | aks-istio-system | istiod, sidecar injector, pilot, citadel |
| `aks-istio-ingress-agent` | aks-istio-ingress | Istio ingress gateway, Gateway API routes |

**Application namespaces (kyverno, cert-manager, external-dns, etc.) are NOT handled here** — they're triaged locally on the worker cluster. See `README-WORKER-CLUSTER.md`.

---

## Prerequisites

```bash
# On the MANAGEMENT cluster
kubectl get pods -n kagent                    # KAgent controller running
kubectl get remotemcpservers -n kagent        # Tool server available
kubectl get modelconfigs -n kagent            # Model config exists
kubectl get workflowtemplates -n argo-events  # k8s-triage-critical deployed
kubectl get eventsources -n argo-events       # Event Hub EventSource running
kubectl get eventbus -n argo-events           # NATS EventBus running
```

---

## Step 1: Deploy Agent Routing ConfigMap

```bash
kubectl apply -f aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/agent-routing.yaml
```

Verify (starts empty — all events go to default `sre-triage-agent`):

```bash
kubectl get configmap agent-routing -n argo-events -o yaml
```

---

## Step 2: Deploy Agents + Update Routing (One at a Time)

### 2a. kube-system — deploy first, always has events

```bash
# Deploy the agent
kubectl apply -f kagent-triage/aks/kube-system-agent.yaml

# Wait for Ready
kubectl get agents -n kagent -w
# kube-system-agent   Ready

# Add to routing
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\"}"}}'

# Verify
kubectl get configmap agent-routing -n argo-events \
  -o jsonpath='{.data.namespace-routes}' | jq .
```

**Test before moving on** — inject a fault on the worker cluster:

```bash
# --- On WORKER cluster ---
kubectl run crashloop-test --image=busybox --restart=Always \
  -n kube-system -- sh -c "exit 1"

# --- On MANAGEMENT cluster ---
# Wait for Alloy → Event Hub → EventSource → Sensor → Workflow
kubectl get workflows -n argo-events -w

# Check it routed to the right agent
argo logs -n argo-events @latest | grep "Agent:"
# Should show: Agent: kube-system-agent (routed)

# --- Clean up on WORKER cluster ---
kubectl delete pod crashloop-test -n kube-system
```

Verify full chain:

- [ ] Alloy forwarded event to Event Hub
- [ ] EventSource received it on management cluster
- [ ] Sensor triggered workflow
- [ ] `parse-otlp` routed to `kube-system-agent`
- [ ] KAgent analysis is sensible
- [ ] GitLab issue created (with URL)
- [ ] Logic App → Teams message (with GitLab link)
- [ ] Mattermost notification sent

### 2b. flux-system

```bash
kubectl apply -f kagent-triage/aks/flux-system-agent.yaml
kubectl get agents -n kagent -w  # wait Ready

kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\",\"flux-system\":\"flux-system-agent\"}"}}'
```

### 2c. gatekeeper-system

```bash
kubectl apply -f kagent-triage/aks/gatekeeper-system-agent.yaml
kubectl get agents -n kagent -w  # wait Ready

kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\",\"flux-system\":\"flux-system-agent\",\"gatekeeper-system\":\"gatekeeper-system-agent\"}"}}'
```

### 2d. aks-istio-system

```bash
kubectl apply -f kagent-triage/aks/istio-system-agent.yaml
kubectl get agents -n kagent -w  # wait Ready

kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\",\"flux-system\":\"flux-system-agent\",\"gatekeeper-system\":\"gatekeeper-system-agent\",\"aks-istio-system\":\"aks-istio-system-agent\"}"}}'
```

### 2e. aks-istio-ingress

```bash
kubectl apply -f kagent-triage/aks/istio-ingress-agent.yaml
kubectl get agents -n kagent -w  # wait Ready

kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\",\"flux-system\":\"flux-system-agent\",\"gatekeeper-system\":\"gatekeeper-system-agent\",\"aks-istio-system\":\"aks-istio-system-agent\",\"aks-istio-ingress\":\"aks-istio-ingress-agent\"}"}}'
```

### Verify final state

```bash
# All agents
kubectl get agents -n kagent

# Final routing
kubectl get configmap agent-routing -n argo-events \
  -o jsonpath='{.data.namespace-routes}' | jq .
```

Expected:

```json
{
  "kube-system": "kube-system-agent",
  "flux-system": "flux-system-agent",
  "gatekeeper-system": "gatekeeper-system-agent",
  "aks-istio-system": "aks-istio-system-agent",
  "aks-istio-ingress": "aks-istio-ingress-agent"
}
```

---

## Step 3: Update the Workflow Template

Apply the updated workflow (sends `gitlab_issue_url` to Logic App instead of `risk_level`):

```bash
kubectl apply -f aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/workflow-template.yaml
```

---

## Step 4: Redeploy the Logic App

The Logic App ARM template now expects `gitlab_issue_url`. Redeploy:

```bash
RESOURCE_GROUP="your-rg"

az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file kagent-triage/logic-app/arm-template.json \
  --parameters logicAppName=kagent-triage-webhook

# Get webhook URL
SUB_ID=$(az account show --query id -o tsv)
WEBHOOK_URL=$(az rest --method POST \
  --uri "/subscriptions/$SUB_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Logic/workflows/kagent-triage-webhook/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query 'value' -o tsv)

# Update secret on management cluster
kubectl delete secret logic-app-webhook-secret -n argo-events --ignore-not-found
kubectl create secret generic logic-app-webhook-secret \
  --from-literal=url="$WEBHOOK_URL" \
  -n argo-events
```

---

## Step 5: Enable Alloy Namespaces on Worker Cluster

Add namespaces to Alloy one at a time. Start with kube-system:

```yaml
loki.source.kubernetes_events "events" {
  namespaces = ["kube-system"]
  log_format = "json"
  forward_to = [loki.process.filter_warnings.receiver]
}
```

After testing each, add more:

```yaml
loki.source.kubernetes_events "events" {
  namespaces = ["kube-system", "flux-system", "gatekeeper-system", "aks-istio-system", "aks-istio-ingress"]
  log_format = "json"
  forward_to = [loki.process.filter_warnings.receiver]
}
```

```bash
helm upgrade alloy grafana/alloy -n monitoring -f alloy-values.yaml
```

### Noise check (on worker cluster) before enabling each namespace

```bash
kubectl get events -n <NAMESPACE> --field-selector type=Warning --sort-by='.lastTimestamp'
```

If too noisy — don't add to Alloy yet. Note the noise source and address it first.

---

## Troubleshooting

### Agent not routing correctly

```bash
kubectl get configmap agent-routing -n argo-events \
  -o jsonpath='{.data.namespace-routes}' | jq .
argo logs -n argo-events @latest | grep "target_agent"
```

### Agent not ready

```bash
kubectl describe agent <agent-name> -n kagent
kubectl get pods -n kagent -l kagent.dev/agent=<agent-name>
```

### Dedup cache blocking re-tests

```bash
kubectl delete configmap event-dedup-cache -n argo-events --ignore-not-found
```

### GitLab issue URL not showing in Teams

1. Workflow template reapplied? (Step 3)
2. Logic App ARM redeployed? (Step 4)
3. `gitlab-token` secret exists? `kubectl get secret -n argo-events | grep gitlab`
4. Check logs: `argo logs -n argo-events @latest | grep "GitLab"`
