# Playbook — Management Cluster (Critical Triage)

Hook the Logic App (→ Teams) into the existing management cluster pipeline and enable Alloy namespace forwarding one at a time.

Everything else is already deployed and tested: Event Hub, EventSource, Sensor, Workflow (`k8s-triage-critical`), kagent agents, GitLab integration, Mattermost.

## The Flow

```
Worker AKS Cluster                     Management AKS Cluster
──────────────────                     ──────────────────────
K8s Warning Event
  │
  ▼
Alloy (OTLP wrap)
  │
  ▼
Azure Event Hub (Kafka)  ────────────► EventSource (eventhub-critical)
                                         │
                                         ▼
                                       Sensor (k8s-triage-critical)
                                         │
                                         ▼
                                       Workflow: k8s-triage-critical
                                         │
                                         ├─ validate-kagent
                                         ├─ parse-otlp (filter critical + route agent)
                                         └─ fan-out per event:
                                              ├─ KAgent A2A analysis
                                              ├─ GitLab issue creation
                                              ├─ Mattermost notification
                                              └─ Logic App → Teams  ← NEW
```

---

## Step 1: Deploy the Logic App

Same Logic App as the workload cluster — one Logic App can serve both tiers.

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

### Wire to Teams

Azure Portal → Logic App Designer → add action after trigger:
1. **Post Adaptive Card in a chat or channel** (Teams connector)
2. Map `event_namespace`, `event_reason`, `resource_name`, `agent_diagnosis`, `cluster`
3. Save → re-test with curl → confirm Teams message appears

---

## Step 2: Add Logic App Step to Management Workflow

The `k8s-triage-critical` workflow currently does: KAgent → GitLab → Mattermost.
Add a Logic App POST after GitLab, before Mattermost.

In `aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/workflow-template.yaml`, add the Logic App env var and step.

### 2a. Add env var to `investigate-and-report`

Add to the `env:` block (alongside `WEBHOOK_URL`, `KAGENT_URL`, `GITLAB_TOKEN`):

```yaml
          - name: LOGIC_APP_WEBHOOK_URL
            valueFrom:
              secretKeyRef:
                name: logic-app-webhook-secret
                key: url
                optional: true
```

### 2b. Add Logic App step after GitLab, before Mattermost

Insert this block between the GitLab section (STEP 2) and Mattermost section (STEP 3):

```bash
          # =================================================================
          # STEP 2.5: Logic App → Teams (if configured)
          # =================================================================
          if [ -n "$LOGIC_APP_WEBHOOK_URL" ]; then
            echo "Sending to Logic App..."

            jq -n \
              --rawfile analysis /tmp/analysis.txt \
              --arg namespace "$OBJ_NS" \
              --arg reason "$REASON" \
              --arg kind "$OBJ_KIND" \
              --arg name "$OBJ_NAME" \
              --arg cluster "$CLUSTER" \
              --arg risk "unknown" \
              --arg source "k8s-triage-critical" \
              --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{
                event_namespace: $namespace,
                event_reason: $reason,
                resource_kind: $kind,
                resource_name: $name,
                agent_diagnosis: ($analysis | .[0:4000]),
                risk_level: $risk,
                timestamp: $timestamp,
                source: $source,
                cluster: $cluster
              }' > /tmp/logic-app.json

            LA_HTTP=$(curl -s -o /tmp/la_response.txt -w "%{http_code}" \
              -X POST "$LOGIC_APP_WEBHOOK_URL" \
              -H "Content-Type: application/json" \
              -d @/tmp/logic-app.json \
              --max-time 10)

            echo "Logic App: HTTP $LA_HTTP"
            if [ "$LA_HTTP" != "200" ] && [ "$LA_HTTP" != "202" ]; then
              echo "Logic App error:"
              cat /tmp/la_response.txt 2>/dev/null
            fi
          else
            echo "No Logic App webhook configured, skipping"
          fi
```

### 2c. Update the summary at the end

Add Logic App to the done block:

```bash
          echo "  Logic App: ${LA_HTTP:-skipped}"
```

### 2d. Create the secret on the management cluster

```bash
kubectl create secret generic logic-app-webhook-secret \
  --from-literal=url="$WEBHOOK_URL" \
  -n argo-events
```

### 2e. Apply the updated workflow

```bash
kubectl apply -f aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/workflow-template.yaml
```

---

## Step 3: Quick Test (No Alloy Needed)

Use the existing QUICK-TEST to verify the Logic App step works end-to-end.

```bash
# Submit test workflow with OTLP payload
kubectl create -f aks-mgmt-stack/k8s-event-triage/eventhub-otlp-pipeline/tier-critical/test-parse-only.yaml

# Watch
argo watch -n argo-events @latest

# Check logs
argo logs -n argo-events @latest
```

**Verify:**
- [ ] Workflow Succeeded
- [ ] `Logic App: HTTP 200` in logs
- [ ] Azure Portal → Logic App → Run History shows the POST
- [ ] Teams message appeared (if wired)
- [ ] GitLab issue created (if token configured)
- [ ] Mattermost notification sent (if webhook configured)

---

## Step 4: Update Agent Routing

Add namespace-specialist agents to the routing ConfigMap. Events from these namespaces will go to the specialist agent instead of the default `sre-triage-agent`.

```bash
# Current routing (check what's there)
kubectl get configmap agent-routing -n argo-events -o yaml

# Add namespace routes one at a time
# Start with kube-system (always noisy, good first test)
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\"}"}}'

# After testing, add more:
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"{\"kube-system\":\"kube-system-agent\",\"flux-system\":\"flux-system-agent\",\"gatekeeper-system\":\"gatekeeper-system-agent\",\"istio-system\":\"istio-system-agent\",\"istio-ingress\":\"istio-ingress-agent\"}"}}'
```

Deploy the agents (if not already on the management cluster):

```bash
# One at a time
kubectl apply -f aks/kube-system-agent.yaml
kubectl get agents -n kagent
# Wait for Ready, then add the next
```

---

## Step 5: Enable Alloy Namespaces (One at a Time)

Alloy on each worker cluster forwards K8s events to Event Hub. Add namespaces to the Alloy config incrementally.

### Current Alloy config structure

Alloy watches K8s events, filters warnings, wraps in OTLP, and sends to Event Hub via Kafka protocol.

### Add a namespace

In the Alloy Helm values (on the worker cluster), add the namespace to the watcher:

```
# Start with one namespace
loki.source.kubernetes_events "events" {
  namespaces = ["kube-system"]
  log_format = "json"
  forward_to = [loki.process.filter_warnings.receiver]
}
```

Upgrade the Alloy Helm release, then verify events are flowing:

```bash
# On the management cluster, check EventSource logs
kubectl logs -n argo-events -l eventsource-name=eventhub-critical --tail=10

# Wait for a real event, or inject a test pod on the worker cluster
kubectl run crashloop-test --image=busybox --restart=Always \
  -n kube-system -- sh -c "exit 1"

# Watch for workflow to fire on management cluster
kubectl get workflows -n argo-events -w

# Clean up test pod on worker cluster
kubectl delete pod crashloop-test -n kube-system
```

### Verify the full chain

- [ ] Alloy picked up the event on worker cluster
- [ ] Event appeared in Event Hub
- [ ] EventSource received it on management cluster
- [ ] Sensor triggered workflow
- [ ] parse-otlp extracted the event and routed to correct agent
- [ ] KAgent analysed it
- [ ] GitLab issue created
- [ ] Logic App received payload → Teams message appeared

### Recommended namespace order

| # | Namespace | Why first |
|---|-----------|-----------|
| 1 | kube-system | Always has events, good for testing |
| 2 | flux-system | GitOps health is critical |
| 3 | gatekeeper-system | Policy engine health |
| 4 | istio-system | Service mesh control plane |
| 5 | istio-ingress | Ingress gateway |

After each namespace: wait for a real event or inject one, confirm the full chain works, then add the next.

---

## Troubleshooting

### Logic App returns 4xx
- Webhook URLs can expire — regenerate via `listCallbackUrl` (Step 1)
- Check `/tmp/la_response.txt` in the workflow pod logs for details

### Events not arriving from Alloy
```bash
# On worker cluster — check Alloy logs
kubectl logs -n monitoring -l app=alloy --tail=20

# On management cluster — check EventSource
kubectl logs -n argo-events -l eventsource-name=eventhub-critical --tail=20
```

### Agent routing not working
```bash
# Check the ConfigMap is valid JSON
kubectl get configmap agent-routing -n argo-events -o jsonpath='{.data.namespace-routes}' | jq .

# Check workflow logs — parse-otlp prints routing decisions
argo logs -n argo-events @latest | grep "target_agent"
```

### Dedup cache blocking re-tests
```bash
# Clear the memoize cache
kubectl delete configmap event-dedup-cache -n argo --ignore-not-found
```
