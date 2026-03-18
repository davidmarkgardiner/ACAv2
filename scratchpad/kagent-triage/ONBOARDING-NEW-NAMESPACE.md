# Onboarding a New Namespace to KAgent Triage

Repeatable process for adding a new namespace to AI-powered event triage. Follow these steps for each namespace, one at a time.

## Overview

```
1. Assess  →  2. Create Agent  →  3. Deploy  →  4. Route  →  5. Test  →  6. Enable
```

---

## Step 1: Assess the Namespace

Check what events are actually firing before you turn anything on.

```bash
NAMESPACE="<your-namespace>"

# Warning events in the last hour
kubectl get events -n $NAMESPACE --field-selector type=Warning --sort-by='.lastTimestamp'

# Count by reason
kubectl get events -n $NAMESPACE --field-selector type=Warning -o json | \
  jq -r '[.items[].reason] | group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count) | .[] | "\(.count)\t\(.reason)"'

# What's running in the namespace
kubectl get pods -n $NAMESPACE
kubectl get deployments,daemonsets,statefulsets -n $NAMESPACE
```

**Decision point:**
- Quiet (0-2 events/hour) — safe to enable, proceed
- Moderate (3-10 events/hour) — enable with rate limit
- Noisy (10+ events/hour) — investigate noise first, fix root causes, or use management cluster OTLP pipeline (has dedup + critical-only filter)

---

## Step 2: Create the Agent CRD

Copy an existing agent as a template and customise it.

```bash
cp kagent-triage/aks/kube-system-agent.yaml kagent-triage/aks/<namespace>-agent.yaml
```

Edit the new file. Things to change:

| Field | Example |
|-------|---------|
| `metadata.name` | `<namespace>-agent` |
| `metadata.labels.managed-namespace` | `<namespace>` |
| `metadata.labels.kagent-triage/namespace` | `<namespace>` |
| `spec.description` | One line about what runs in this namespace |
| `spec.declarative.systemMessage` | Update the namespace anchoring, components, failure modes |

**Key parts of the system message to update:**

1. **Namespace anchoring** (line 1):
   ```
   CRITICAL: always use exact namespace "<namespace>" when investigating.
   ```

2. **Your Domain** — list the actual components running in this namespace

3. **Diagnostic Workflow** — step-by-step investigation order specific to this namespace's components

4. **Common Failure Modes** — table of symptom/root cause/tool/fix

5. **Safety** — what NOT to do in this namespace

**Tip:** To find out what's running:
```bash
kubectl get deployments,daemonsets,statefulsets -n $NAMESPACE -o custom-columns=KIND:.kind,NAME:.metadata.name
```

---

## Step 3: Create the Sensor (Worker Cluster Only)

Skip this step if using the management cluster OTLP pipeline.

```bash
cp kagent-triage/aks/kube-system-sensor.yaml kagent-triage/aks/<namespace>-sensor.yaml
```

Edit the new file. Things to change:

| Field | Value |
|-------|-------|
| `metadata.name` | `kagent-triage-<namespace>` |
| `metadata.labels.kagent-triage/namespace` | `<namespace>` |
| `spec.dependencies[0].filters.data[0].value[0]` | `<namespace>` |
| `spec.triggers[0].template.name` | `kagent-triage-<namespace>` |
| `spec.triggers[0].template.k8s.source.resource.metadata.generateName` | `kagent-triage-<namespace>-` |
| `spec.triggers[0].template.k8s.source.resource.spec.arguments.parameters[0].value` | `<namespace>` |
| `spec.triggers[0].template.k8s.source.resource.spec.arguments.parameters[6].value` | `<namespace>-agent` |
| `spec.triggers[0].rateLimit.requestsPerUnit` | Start with 2 for noisy, 5 for quiet |

---

## Step 4: Deploy

### On the target cluster

```bash
# Deploy agent first
kubectl apply -f kagent-triage/aks/<namespace>-agent.yaml

# Wait for Ready
kubectl get agents -n kagent -w
```

### Management cluster — update routing

```bash
# Get current routes
CURRENT=$(kubectl get configmap agent-routing -n argo-events \
  -o jsonpath='{.data.namespace-routes}')
echo "Current: $CURRENT"

# Add your namespace (edit the JSON to add your entry)
# e.g., if current is {"kube-system":"kube-system-agent"}
# new should be {"kube-system":"kube-system-agent","<namespace>":"<namespace>-agent"}
kubectl patch configmap agent-routing -n argo-events --type merge \
  -p '{"data":{"namespace-routes":"<updated-json>"}}'
```

### Worker cluster — deploy sensor

```bash
kubectl apply -f kagent-triage/aks/<namespace>-sensor.yaml
kubectl get sensors -n argo-events
```

---

## Step 5: Test with Fault Injection

```bash
NAMESPACE="<your-namespace>"

# Inject a crashlooping pod
kubectl run crashloop-test --image=busybox --restart=Always \
  -n $NAMESPACE -- sh -c "exit 1"

# Watch for workflow
kubectl get workflows -n argo-events -w

# Check logs when workflow completes
argo logs -n argo-events @latest

# Verify
# - [ ] Workflow used the correct agent
# - [ ] Analysis is sensible for this namespace
# - [ ] GitLab issue created
# - [ ] Teams/Mattermost notification received

# Clean up
kubectl delete pod crashloop-test -n $NAMESPACE
```

---

## Step 6: Enable in Alloy (Management Cluster Pipeline Only)

If using the OTLP pipeline, add the namespace to Alloy on the worker cluster:

```yaml
loki.source.kubernetes_events "events" {
  namespaces = ["kube-system", "flux-system", ..., "<namespace>"]
  log_format = "json"
  forward_to = [loki.process.filter_warnings.receiver]
}
```

```bash
helm upgrade alloy grafana/alloy -n monitoring -f alloy-values.yaml
```

---

## Step 7: Monitor for Noise

After enabling, watch for the first few hours:

```bash
# Workflow count — are we getting flooded?
kubectl get workflows -n argo-events --no-headers | wc -l

# Check dedup is working
kubectl get configmap event-dedup-cache -n argo-events -o json | \
  jq '.data | keys | length'
```

If too noisy:
- **Quick fix:** Reduce sensor rate limit to 1/minute
- **Better fix:** Tune the agent's system prompt to handle known-noisy events
- **Nuclear option:** Remove the sensor/route until the noise source is fixed

---

## Checklist

```
Namespace: _______________
Date: _______________
Engineer: _______________

Assessment:
- [ ] Events checked, noise level: Low / Medium / High
- [ ] Components documented

Deployment:
- [ ] Agent CRD created and applied
- [ ] Agent status: Ready
- [ ] Routing updated (management) OR sensor deployed (worker)

Testing:
- [ ] Fault injected
- [ ] Workflow completed successfully
- [ ] Correct agent was routed to
- [ ] Analysis quality: Good / OK / Needs tuning
- [ ] GitLab issue created
- [ ] Notifications received
- [ ] Test pod cleaned up

Enablement:
- [ ] Alloy updated (management pipeline) OR sensor live (worker)
- [ ] Monitoring for noise: OK / Too noisy (action: ___)

Sign-off: _______________
```
