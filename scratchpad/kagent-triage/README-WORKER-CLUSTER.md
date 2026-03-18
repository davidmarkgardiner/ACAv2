# Worker Cluster — Application Namespace Triage

Application namespace agents + sensors on the worker cluster. Events are watched locally via K8s event watching — no Event Hub/OTLP needed.

## What Lives Here

| Component | Where | Purpose |
|-----------|-------|---------|
| Agent CRDs | `kagent` namespace | Specialist agents for each application namespace |
| Per-namespace Sensors | `argo-events` namespace | Watch K8s events and trigger workflows |
| `kagent-triage` WorkflowTemplate | `argo-events` namespace | KAgent A2A + GitLab + Teams + Telegram |
| K8s EventSource | `argo-events` namespace | Watches K8s warning events |
| EventBus (NATS) | `argo-events` namespace | Event transport |

**AKS system namespaces (kube-system, flux-system, gatekeeper, istio) are NOT handled here** — they're routed via the management cluster OTLP pipeline. See `README-MANAGEMENT-CLUSTER.md`.

## Namespaces Handled Here

Application/platform namespaces that run on the worker cluster. Create agents + sensors for each.

Example namespaces (will vary per cluster):

| Namespace | Components | Notes |
|-----------|------------|-------|
| kyverno | Kyverno policy engine, admission controller | Policy enforcement |
| cert-manager | Certificate issuance, ACME challenges | TLS certificates |
| external-dns | DNS record management | External DNS sync |
| ingress-nginx | NGINX ingress controller | (if not using Istio) |
| monitoring | Prometheus, Grafana, Alloy | Observability stack |

---

## Prerequisites

```bash
# On the WORKER cluster
kubectl get pods -n kagent                    # KAgent controller running
kubectl get remotemcpservers -n kagent        # Tool server available
kubectl get modelconfigs -n kagent            # Model config exists
kubectl get workflowtemplates -n argo-events  # kagent-triage deployed
kubectl get eventbus -n argo-events           # NATS EventBus running
kubectl get eventsources -n argo-events       # K8s warning events EventSource
```

---

## Step 1: Assess the Namespace

Before enabling any namespace, check what events are firing:

```bash
NAMESPACE="kyverno"  # change per namespace

# Warning events
kubectl get events -n $NAMESPACE --field-selector type=Warning --sort-by='.lastTimestamp'

# Count by reason
kubectl get events -n $NAMESPACE --field-selector type=Warning -o json | \
  jq -r '[.items[].reason] | group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count) | .[] | "\(.count)\t\(.reason)"'

# What's running
kubectl get pods -n $NAMESPACE
kubectl get deployments,daemonsets,statefulsets -n $NAMESPACE
```

**Decision:**
- Quiet (0-2 events/hour) — safe, proceed
- Moderate (3-10/hour) — proceed with rate limit of 2/min
- Noisy (10+/hour) — investigate first, fix root causes before enabling

---

## Step 2: Create the Agent

Copy an existing agent and customise it for the target namespace.

```bash
cp kagent-triage/aks/kube-system-agent.yaml kagent-triage/aks/<namespace>-agent.yaml
```

Things to change in the new file:

| Field | What to set |
|-------|-------------|
| `metadata.name` | `<namespace>-agent` |
| `metadata.labels.managed-namespace` | `<namespace>` |
| `metadata.labels.kagent-triage/namespace` | `<namespace>` |
| `spec.description` | One line about what runs here |
| `spec.declarative.systemMessage` | See below |

### System message — what to customise

1. **Namespace anchoring** (must be first line):
   ```
   CRITICAL: always use exact namespace "<namespace>" when investigating.
   ```

2. **Your Domain** — list the components in this namespace. Find them with:
   ```bash
   kubectl get deployments,daemonsets,statefulsets -n $NAMESPACE \
     -o custom-columns=KIND:.kind,NAME:.metadata.name
   ```

3. **Diagnostic Workflow** — step-by-step investigation order

4. **Common Failure Modes** — table: symptom / root cause / tool / fix

5. **Safety** — what NOT to do in this namespace

---

## Step 3: Create the Sensor

```bash
cp kagent-triage/aks/kube-system-sensor.yaml kagent-triage/aks/<namespace>-sensor.yaml
```

Things to change:

| Field | Value |
|-------|-------|
| `metadata.name` | `kagent-triage-<namespace>` |
| `metadata.labels.kagent-triage/namespace` | `<namespace>` |
| `spec.dependencies[0].filters.data[0].value[0]` | `<namespace>` |
| `spec.triggers[0].template.name` | `kagent-triage-<namespace>` |
| `spec.triggers[0].template.k8s.source.resource.metadata.generateName` | `kagent-triage-<namespace>-` |
| `spec.triggers[0].template.k8s.source.resource.spec.arguments.parameters[0].value` | `<namespace>` (event-namespace) |
| `spec.triggers[0].template.k8s.source.resource.spec.arguments.parameters[6].value` | `<namespace>-agent` (target-agent) |
| `spec.triggers[0].rateLimit.requestsPerUnit` | 2 for noisy, 5 for quiet |

---

## Step 4: Deploy

```bash
NAMESPACE="kyverno"  # change per namespace

# Deploy agent
kubectl apply -f kagent-triage/aks/${NAMESPACE}-agent.yaml

# Wait for Ready
kubectl get agents -n kagent -w
# <namespace>-agent   Ready

# Deploy sensor (this starts watching events)
kubectl apply -f kagent-triage/aks/${NAMESPACE}-sensor.yaml

# Verify sensor
kubectl get sensors -n argo-events
# kagent-triage-<namespace>   true
```

---

## Step 5: Test with Fault Injection

```bash
NAMESPACE="kyverno"  # change per namespace

# Inject a crashlooping pod
kubectl run crashloop-test --image=busybox --restart=Always \
  -n $NAMESPACE -- sh -c "exit 1"

# Watch for workflow
kubectl get workflows -n argo-events -w
# Should see: kagent-triage-<namespace>-xxxxx

# Check logs
argo logs -n argo-events @latest

# Verify:
# - [ ] Correct agent was used
# - [ ] Analysis is sensible for this namespace
# - [ ] GitLab issue created
# - [ ] Notifications sent

# Clean up
kubectl delete pod crashloop-test -n $NAMESPACE
```

---

## Step 6: Monitor for Noise

After enabling, watch for the first few hours:

```bash
# How many workflows fired?
kubectl get workflows -n argo-events --no-headers | wc -l

# Recent workflows
kubectl get workflows -n argo-events --sort-by='.metadata.creationTimestamp' | tail -10
```

If too noisy:
- **Quick fix:** Reduce sensor rate limit to 1/minute
- **Better fix:** Tune the agent prompt or add reason filters to the sensor
- **Nuclear option:** Delete the sensor until noise source is fixed
  ```bash
  kubectl delete sensor kagent-triage-<namespace> -n argo-events
  ```

---

## Rate Limits

Each sensor has a built-in rate limit to prevent workflow storms:

```yaml
rateLimit:
  unit: minute
  requestsPerUnit: 2  # max 2 workflows per minute per namespace
```

Adjust per namespace based on noise level.

---

## Troubleshooting

### Sensor not triggering

```bash
kubectl logs -n argo-events -l eventsource-name=k8s-warning-events --tail=20
kubectl logs -n argo-events -l sensor-name=kagent-triage-<namespace> --tail=20
kubectl get eventbus -n argo-events
```

### Agent returns empty analysis

```bash
kubectl get remotemcpservers -n kagent
kubectl logs -n kagent -l kagent.dev/agent=<namespace>-agent --tail=20
```

### Workflow fails with RBAC error

```bash
kubectl auth can-i create workflowtaskresults \
  --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# Should be: yes
```

---

## Per-Namespace Checklist

Copy for each namespace:

```
### Namespace: _______________
Date: _______________
Engineer: _______________

- [ ] Events checked: `kubectl get events -n $NS --field-selector type=Warning`
- [ ] Noise level: Low / Medium / High
- [ ] Noisy reasons noted: _______________
- [ ] Agent YAML created from template
- [ ] Agent deployed and Ready
- [ ] Sensor YAML created from template
- [ ] Sensor deployed and running
- [ ] Fault injected (crashloop pod)
- [ ] Workflow completed successfully
- [ ] Correct agent was used
- [ ] Analysis quality: Good / Needs tuning
- [ ] GitLab issue created
- [ ] Notifications received
- [ ] Test pod cleaned up
- [ ] Rate limit set to: ___/minute
```
