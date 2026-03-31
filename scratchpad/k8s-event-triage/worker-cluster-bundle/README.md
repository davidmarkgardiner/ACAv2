# Worker Cluster Bundle — K8s Event Triage with kagent

Everything you need to deploy event-driven triage on a worker cluster. All files copied from their original locations for easy deployment.

## How It Works

```
K8s Warning Event (e.g. CrashLoopBackOff in cert-manager namespace)
    │
    ▼
01-eventsource.yaml                    ← Watches K8s API for Warning events (real-time, not polling)
    │
    ▼
EventBus (NATS)                        ← Required by Argo Events (internal, lightweight)
    │
    ▼
sensor-cert-manager.yaml               ← Filters: namespace=cert-manager, rate limit 5/min
    │
    ▼
02-workflow-template.yaml              ← Shared workflow (ONE template for all namespaces)
    │
    ├─ find-agent      → Looks up the right kagent agent by namespace
    ├─ call-agent      → A2A call to cert-manager-agent for diagnosis
    ├─ create-gitlab   → Posts diagnosis as GitLab issue
    ├─ send-telegram   → Telegram notification
    └─ send-logic-app  → Logic App → Teams notification
```

**Key design:** One EventSource, one WorkflowTemplate, many Sensors. Each Sensor filters for a specific namespace and passes `target-agent` to the workflow. The workflow routes to the right kagent agent automatically.

## Files

### Infrastructure (deploy once)

| File | What | Namespace |
|------|------|-----------|
| `01-eventsource.yaml` | Watches K8s Warning events | `argo-events` |
| `02-workflow-template.yaml` | Shared triage workflow (find agent → A2A → GitLab → notify) | `argo-events` |
| `03-sensor-generic.yaml` | Generic sensor (fallback, uses k8s-agent) | `argo-events` |
| `modelconfig-remote-litellm.yaml` | ModelConfig pointing to LiteLLM proxy | `kagent` |

### Per-Namespace Agents (deploy to `kagent` namespace)

| File | Namespace Handled | Description |
|------|-------------------|-------------|
| `agent-cert-manager.yaml` | cert-manager | Certificate lifecycle, ACME challenges |
| `agent-kyverno.yaml` | kyverno | Policy engine, admission controller |
| `agent-external-secrets.yaml` | external-secrets | Secret syncing from vaults |
| `agent-reloader.yaml` | reloader | ConfigMap/Secret reload triggers |
| `agent-kro.yaml` | kro | Kubernetes Resource Orchestrator |
| `agent-kube-system.yaml` | kube-system | Core K8s components |
| `agent-flux-system.yaml` | flux-system | GitOps controller |
| `agent-istio-system.yaml` | istio-system | Service mesh control plane |
| `agent-istio-ingress.yaml` | aks-istio-ingress | Istio ingress gateway |
| `agent-gatekeeper-system.yaml` | gatekeeper-system | OPA Gatekeeper |
| `agent-test-ns.yaml` | test-ns | Test namespace (for validation) |

### Per-Namespace Sensors (deploy to `argo-events` namespace)

| File | Filters For | Routes To |
|------|-------------|-----------|
| `sensor-cert-manager.yaml` | namespace=cert-manager | cert-manager-agent |
| `sensor-kyverno.yaml` | namespace=kyverno | kyverno-agent |
| `sensor-external-secrets.yaml` | namespace=external-secrets | external-secrets-agent |
| `sensor-reloader.yaml` | namespace=reloader | reloader-agent |
| `sensor-kro.yaml` | namespace=kro | kro-agent |
| `sensor-kube-system.yaml` | namespace=kube-system | kube-system-agent |
| `sensor-flux-system.yaml` | namespace=flux-system | flux-system-agent |
| `sensor-istio-system.yaml` | namespace=istio-system | istio-system-agent |
| `sensor-istio-ingress.yaml` | namespace=aks-istio-ingress | istio-ingress-agent |
| `sensor-gatekeeper-system.yaml` | namespace=gatekeeper-system | gatekeeper-system-agent |
| `sensor-test-ns.yaml` | namespace=test-ns | test-ns-agent |

### Fault Injection Tests

| File | What It Does |
|------|-------------|
| `test-fault-cert-manager.yaml` | Injects crashloop in cert-manager |
| `test-fault-kyverno.yaml` | Injects crashloop in kyverno |
| `test-fault-external-secrets.yaml` | Injects crashloop in external-secrets |
| `test-fault-kro.yaml` | Injects crashloop in kro |
| `test-fault-reloader.yaml` | Injects crashloop in reloader |

### Documentation

| File | What |
|------|------|
| `ONBOARDING-NEW-NAMESPACE.md` | Step-by-step guide to add a new namespace |

## Prerequisites

Before deploying, you need these on the worker cluster:

```bash
# 1. Argo Events controller + EventBus (NATS)
kubectl get pods -n argo-events          # Controller running
kubectl get eventbus -n argo-events      # default EventBus exists

# 2. Argo Workflows controller
kubectl get pods -n argo                 # Workflow controller running

# 3. kagent
kubectl get pods -n kagent               # kagent-controller running
kubectl get modelconfigs -n kagent       # At least one ModelConfig

# 4. RBAC
kubectl auth can-i create workflowtaskresults \
  --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# Should be: yes
```

## Deployment Order

### Step 1: Infrastructure (once per cluster)

```bash
# ModelConfig (skip if already configured)
kubectl apply -f modelconfig-remote-litellm.yaml

# EventSource — starts watching K8s Warning events
kubectl apply -f 01-eventsource.yaml

# Shared workflow template
kubectl apply -f 02-workflow-template.yaml

# Verify
kubectl get eventsources -n argo-events
kubectl get workflowtemplates -n argo-events
```

### Step 2: Pick your namespaces

Deploy agent + sensor pairs for each namespace you want to monitor:

```bash
# Example: enable cert-manager triage
kubectl apply -f agent-cert-manager.yaml       # → kagent namespace
kubectl apply -f sensor-cert-manager.yaml      # → argo-events namespace

# Example: enable kyverno triage
kubectl apply -f agent-kyverno.yaml
kubectl apply -f sensor-kyverno.yaml

# Verify agents are Ready
kubectl get agents -n kagent

# Verify sensors are running
kubectl get sensors -n argo-events
```

### Step 3: Test with fault injection

```bash
# Inject a fault
kubectl apply -f test-fault-cert-manager.yaml

# Watch for workflow
kubectl get workflows -n argo-events -w

# Check logs
argo logs -n argo-events @latest

# Clean up
kubectl delete -f test-fault-cert-manager.yaml
```

## Adding a New Namespace

See `ONBOARDING-NEW-NAMESPACE.md` for the full guide. Quick version:

1. Copy an existing agent YAML, change the namespace references and system message
2. Copy the matching sensor YAML, change the namespace filter and target-agent
3. `kubectl apply` both
4. Fault inject to test

## Secrets Required

| Secret | Namespace | Keys | Purpose |
|--------|-----------|------|---------|
| `gitlab-token` | `argo-events` | `url`, `token`, `project-id` | GitLab issue creation |
| `telegram-bot-secret` | `argo-events` | `token` | Telegram notifications |
| `logic-app-webhook-secret` | `argo-events` | `url` | Teams via Logic App |

All are optional — the workflow skips notification steps gracefully if secrets are missing.

## Source Locations

These files are copies. Originals live at:

| Bundle File | Original Location |
|-------------|-------------------|
| `01-eventsource.yaml` | `application-stack/core/argo-events/auto-healer/eventsource.yaml` |
| `02-workflow-template.yaml` | `kagent-triage/02-workflow-kagent-triage.yaml` |
| `03-sensor-generic.yaml` | `kagent-triage/03-sensor-kagent-triage.yaml` |
| `agent-*.yaml` | `kagent-triage/*.yaml` or `kagent-triage/aks/*.yaml` |
| `sensor-*.yaml` | `kagent-triage/*.yaml` or `kagent-triage/aks/*.yaml` |
| `test-fault-*.yaml` | `kagent-triage/*-fault-injection.yaml` |
| `modelconfig-*.yaml` | `kagent-triage/aks/modelconfig-remote-litellm.yaml` |
