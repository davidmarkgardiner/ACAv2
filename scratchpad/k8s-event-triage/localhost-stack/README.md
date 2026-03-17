# K8s Event Triage + AI Remediation — Localhost Stack

Complete deployment guide for the triage/remediation pipeline on a local Kubernetes cluster. Designed to be repeatable by any agent or engineer.

**Tested:** proxmox-k8s (3 nodes, K8s v1.31.14, Longhorn storage, RTX 3060 GPU)
**Purpose:** Run scenarios through the full pipeline: Alert/Event -> Argo Events -> Argo Workflow -> KAgent AI analysis -> GitLab issue + Mattermost notification

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           proxmox-k8s cluster                                │
│                                                                              │
│  ┌─ monitoring ─────────┐     ┌─ argo-events ────────────────────────────┐  │
│  │ kube-prometheus-stack │     │                                          │  │
│  │ AlertManager ─────────────►│ EventSource (webhook :12000)             │  │
│  │                       │     │     │                                    │  │
│  │ PrometheusRules:      │     │     ▼                                    │  │
│  │  OOMKilled            │     │ EventBus (NATS native)                   │  │
│  │  CrashLoopBackOff     │     │     │                                    │  │
│  │  HighRestarts         │     │     ▼                                    │  │
│  │  CPU/Memory high      │     │ Sensor (rate limited 5/min)             │  │
│  └───────────────────────┘     │     │                                    │  │
│                                │     ▼                                    │  │
│  ┌─ argo ───────────────┐     │ Workflow                                 │  │
│  │ Argo Workflows v3.6.4│     │  ├─ validate                            │  │
│  │ Controller + Server   │     │  ├─ KAgent A2A (sre-triage-agent)       │  │
│  │                       │     │  ├─ GitLab issue creation               │  │
│  │ WorkflowTemplates:    │     │  └─ Mattermost notification             │  │
│  │  kagent-sre-workflow  │     └──────────────────────────────────────────┘  │
│  │  local-llm-analysis   │                                                   │
│  │  holmes-remediation   │     ┌─ kagent ─────────────────────────────────┐  │
│  └───────────────────────┘     │ KAgent v0.7.x                            │  │
│                                │  ├─ sre-triage-agent (readonly)          │  │
│  ┌─ kubeai ─────────────┐     │  └─ sre-remediation-agent (readwrite)    │  │
│  │ Qwen 2.5 14B (GPU)   │     │ Uses k8s tools + AKS-MCP via MCP        │  │
│  │ OpenAI-compatible API │     └──────────────────────────────────────────┘  │
│  └───────┬───────────────┘                                                   │
│          │                     ┌─ aks-mcp ────────────────────────────────┐  │
│          ▼                     │ AKS-MCP v0.0.12 (admin access)           │  │
│  ┌─ litellm ────────────┐     │ call_kubectl tool for diagnosis + fix     │  │
│  │ LiteLLM proxy         │     └──────────────────────────────────────────┘  │
│  │ Routes to KubeAI      │                                                   │
│  └───────────────────────┘     ┌─ holmesgpt ──────────────────────────────┐  │
│                                │ HolmesGPT 0.19.1 (optional, compare)     │  │
│                                │ Uses AKS-MCP for kubectl operations       │  │
│                                └──────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
         │                                           │
         ▼                                           ▼
  ┌──────────────┐                          ┌────────────────┐
  │ GitLab.com   │                          │ Mattermost     │
  │ Issue tracker│                          │ Webhook alerts │
  └──────────────┘                          └────────────────┘
```

## Prerequisites

| Component | Requirement | Notes |
|-----------|-------------|-------|
| Kubernetes | v1.28+ | Tested on v1.31.14 |
| GPU | NVIDIA (Ampere family, 12GB+ VRAM) | For Qwen 14B. RTX 3060 works. |
| Storage | Longhorn or local-path | `local-path` for workflow PVCs (Longhorn PVCs are unreliable for ephemeral workflow volumes) |
| Helm | v3.12+ | For chart installations |
| kubectl | v1.28+ | Matches cluster version |
| kube-prometheus-stack | Already deployed in `monitoring` ns | Helm release name: `kube-prom` (auto-detected) |

## Namespace Map

| Namespace | Purpose | Deployed By |
|-----------|---------|-------------|
| `monitoring` | Prometheus, AlertManager, Grafana | Pre-existing (kube-prometheus-stack) |
| `argo` | Argo Workflows controller + server | Phase 1 |
| `argo-events` | EventBus, EventSource, Sensor, Workflow pods | Phase 2 |
| `kubeai` | KubeAI + Qwen 14B model (GPU) | Phase 3 |
| `litellm` | LiteLLM proxy (routes to KubeAI) | Phase 3 |
| `kagent` | KAgent controller + SRE agents | Phase 4 |
| `aks-mcp` | AKS-MCP server (kubectl access for AI agents) | Phase 4 |


---

## Phase 1: Argo Workflows

```bash
# Install Argo Workflows v3.6.4
kubectl create namespace argo
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml

# Wait for controllers
kubectl wait --for=condition=available --timeout=120s deployment/workflow-controller -n argo
kubectl wait --for=condition=available --timeout=120s deployment/argo-server -n argo

# Verify
kubectl get pods -n argo
```

### Argo Server access (optional)

```bash
# Port forward for UI
kubectl port-forward -n argo svc/argo-server 2746:2746 &

# UI at https://localhost:2746 (self-signed cert, accept warning)
```

---

## Phase 2: Argo Events + Prometheus Alerting Pipeline

### 2a. Install Argo Events

```bash
# Pin to v1.9.10 — NEVER use 'stable' (floating tag, causes panics)
kubectl create namespace argo-events
kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml

# Wait for controller
kubectl wait --for=condition=available --timeout=120s deployment/controller-manager -n argo-events
```

### 2b. Deploy EventBus

The EventBus is required — EventSources and Sensors cannot communicate without it.

```bash
kubectl apply -f - <<'EOF'
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

# Wait for NATS pods
kubectl wait --for=condition=ready pod -l eventbus-name=default -n argo-events --timeout=120s
```

### 2c. Deploy Prometheus Alerting Pipeline

This wires AlertManager -> Argo Events -> Workflows. Files are in `../prometheus-alerting/`.

```bash
cd ../prometheus-alerting/

# Automated deployment (recommended)
chmod +x deploy.sh
./deploy.sh

# Or manual step-by-step:
# 1. Upgrade AlertManager with webhook receiver
helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring --reuse-values \
  -f 01-alertmanager-values.yaml --wait

# 2. Apply custom alerting rules
kubectl apply -f 02-custom-alerting-rules.yaml
kubectl label prometheusrule k8s-triage-alerting-rules -n monitoring "release=kube-prom" --overwrite

# 3. Deploy EventSource (webhook listener on port 12000)
kubectl apply -f 03-eventsource-alertmanager.yaml

# 4. Wait for EventSource
kubectl wait --for=condition=ready pod -l eventsource-name=alertmanager -n argo-events --timeout=120s

# 5. Deploy RBAC
kubectl apply -f 08-workflow-rbac.yaml

# 6. Deploy WorkflowTemplate
kubectl apply -f 04-workflow-template.yaml

# 7. Deploy Sensor
kubectl apply -f 05-sensor.yaml

# 8. Wait for Sensor
kubectl wait --for=condition=ready pod -l sensor-name=alertmanager-triage-sensor -n argo-events --timeout=120s

# 9. Import Grafana dashboard (optional)
kubectl apply -f 07-grafana-dashboard-configmap.yaml

cd ../localhost-stack/
```

### 2d. Verify

```bash
kubectl get eventbus,eventsource,sensor -n argo-events
kubectl logs -n argo-events -l eventsource-name=alertmanager --tail=5
# Expected: "Listening on :12000"

kubectl logs -n argo-events -l sensor-name=alertmanager-triage-sensor --tail=5
# Expected: "successfully subscribed to eventbus"
```

---

## Phase 3: AI Platform (KubeAI + LiteLLM)

### 3a. Deploy KubeAI with Qwen 14B

```bash
helm repo add kubeai https://www.kubeai.org
helm repo update

helm upgrade --install kubeai kubeai/kubeai \
  --namespace kubeai --create-namespace \
  -f ../../ai-platform/config/kubeai/kubeai-values.yaml \
  --wait

# Deploy the Qwen 14B model (requires GPU)
kubectl apply -f ../../ai-platform/config/kubeai/qwen-14b-model.yaml

# Wait for model to load (downloads ~8GB on first run)
kubectl wait --for=condition=ready pod -l model=qwen2.5-14b -n kubeai --timeout=600s

# Verify LLM is responding
kubectl run llm-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s http://kubeai.kubeai.svc.cluster.local/openai/v1/models | head -20
```

### 3b. Deploy LiteLLM

LiteLLM acts as a proxy, routing model requests to KubeAI. KAgent uses LiteLLM.

```bash
helm repo add litellm https://litellm.github.io/litellm-helm
helm repo update

helm upgrade --install litellm litellm/litellm \
  --namespace litellm --create-namespace \
  -f ../../ai-platform/config/litellm/litellm-values.yaml \
  --wait

# Verify LiteLLM can reach KubeAI
kubectl run litellm-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s -H "Authorization: Bearer sk-poc-homelab-1234" \
  http://litellm.litellm.svc.cluster.local:4000/v1/models
```

---

## Phase 4: KAgent + AKS-MCP

### 4a. Deploy AKS-MCP (kubectl access for AI agents)

```bash
kubectl apply -f ../../holmes-argoworkflows/aks-mcp/aks-mcp-local-admin.yaml

# Wait for AKS-MCP
kubectl wait --for=condition=available --timeout=120s deployment/aks-mcp -n aks-mcp

# Verify it can access the cluster
kubectl run mcp-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s -X POST http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list"}'
```

### 4b. Deploy KAgent

```bash
helm repo add kagent https://kagent-dev.github.io/kagent
helm repo update

# Create API key secret (LiteLLM master key)
kubectl create namespace kagent
kubectl create secret generic kagent-openai -n kagent \
  --from-literal=OPENAI_API_KEY=sk-poc-homelab-1234

# Deploy KAgent
helm upgrade --install kagent kagent/kagent \
  --namespace kagent \
  -f ../../ai-platform/config/kagent/kagent-values.yaml \
  --wait

# Apply ModelConfig to route agents to Qwen 14B via LiteLLM
kubectl apply -f ../../ai-platform/config/kagent/kagent-modelconfig-14b.yaml

# Verify KAgent controller
kubectl wait --for=condition=available --timeout=120s deployment/kagent-controller -n kagent

# List available agents
kubectl run kagent-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s http://kagent-controller.kagent.svc.cluster.local:8083/api/agents | head -50
```

### 4c. Deploy KAgent Workflow Templates

```bash
# KAgent SRE workflow (triage + remediation via A2A)
kubectl apply -f ../../holmes-argoworkflows/kagent-sre-workflow.yaml

# Local LLM analysis (direct call, no agents, fast)
kubectl apply -f ../../holmes-argoworkflows/local-llm-analysis-only.yaml

# Verify
kubectl get workflowtemplate -n argo
```

---

## Phase 5: HolmesGPT (Optional — for comparison)

Holmes is an alternative to KAgent. Deploy if you want to compare outputs.

```bash
helm repo add robusta https://robusta-dev.github.io/robusta-charts
helm repo update

helm upgrade --install holmes robusta/holmes \
  --namespace holmesgpt --create-namespace \
  -f ../../holmes-argoworkflows/helm-values-proxmox.yaml \
  --wait

# Deploy Holmes workflow template
kubectl apply -f ../../holmes-argoworkflows/holmes-remediation.yaml

# Verify Holmes is running
kubectl wait --for=condition=available --timeout=120s deployment/holmes-holmes -n holmesgpt
```

---

## Phase 6: Secrets & Integrations

### GitLab (for issue creation)

```bash
# Create GitLab PAT with api scope at https://gitlab.com/-/user_settings/personal_access_tokens
kubectl create secret generic gitlab-token -n argo \
  --from-literal=GITLAB_TOKEN='glpat-YOUR-TOKEN-HERE'
```

**GitLab project ID** is hardcoded in the workflow templates as `68265584`. Update if using a different project:

```bash
# Find your project ID: GitLab project -> Settings -> General -> Project ID
# Then update workflows:
kubectl get workflowtemplate kagent-sre-workflow -n argo -o yaml | \
  sed 's/68265584/YOUR_PROJECT_ID/' | kubectl apply -f -
```

### Mattermost (for notifications)

```bash
# Create an incoming webhook in Mattermost: Main Menu -> Integrations -> Incoming Webhooks
kubectl create secret generic mattermost-webhook -n argo \
  --from-literal=url='https://mattermost.your-domain.com/hooks/YOUR-WEBHOOK-ID'

# For the Prometheus alerting pipeline (different namespace)
kubectl create configmap mattermost-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL='https://mattermost.your-domain.com/hooks/YOUR-WEBHOOK-ID'
```

### Without GitLab/Mattermost

The workflows handle missing integrations gracefully:
- **GitLab:** The `create-gitlab-issue` step will fail but `continueOn: {failed: true}` means the workflow continues
- **Mattermost:** The notify step checks if the webhook URL is empty and skips if so

You can run the full pipeline without either — the KAgent analysis still runs and outputs are visible in the Argo Workflows UI.

---

## Test Scenarios

### Scenario 1: Manual KAgent Triage (fastest, no alerts needed)

Submit a workflow directly to test KAgent A2A:

```bash
# Create a broken pod first
kubectl run crash-test --image=nginx:does-not-exist --restart=Never -n default

# Wait for it to fail
sleep 10

# Submit triage workflow
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Investigate why this pod is failing" \
  -p event_type="ImagePullBackOff" \
  -p namespace="default" \
  -p resource_kind="Pod" \
  -p resource_name="crash-test" \
  -p severity="high" \
  -p error_message="Failed to pull image nginx:does-not-exist" \
  -p remediate="false" \
  --watch

# Check output
argo logs -n argo @latest

# Clean up
kubectl delete pod crash-test -n default
```

### Scenario 2: Manual KAgent Remediation (auto-fix)

```bash
# Create a deployment with wrong image
kubectl create deployment fix-me --image=nginx:wrong-tag -n default

# Wait for failure
sleep 15

# Submit REMEDIATION workflow (remediate=true uses sre-remediation-agent)
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p query="Fix this deployment - the image tag is wrong, use nginx:latest instead" \
  -p event_type="ImagePullBackOff" \
  -p namespace="default" \
  -p resource_kind="Deployment" \
  -p resource_name="fix-me" \
  -p severity="high" \
  -p error_message="Failed to pull image nginx:wrong-tag" \
  -p remediate="true" \
  --watch

# Verify the agent fixed it
kubectl get pods -n default -l app=fix-me

# Clean up
kubectl delete deployment fix-me -n default
```

### Scenario 3: Prometheus Alert -> Automated Triage (end-to-end)

This tests the full pipeline: Prometheus detects issue -> AlertManager fires webhook -> Argo Events triggers workflow -> KAgent analyzes.

```bash
# Create a CrashLoopBackOff pod (triggers PrometheusRule)
kubectl run crashloop-test --image=busybox --restart=Always -n default -- /bin/sh -c "exit 1"

# Wait for Prometheus to detect and AlertManager to fire (2-5 minutes)
# Monitor AlertManager
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093 &
# Check http://localhost:9093/#/alerts

# Watch for workflows being created automatically
watch kubectl get workflows -n argo-events

# When a workflow appears, check its output
argo logs -n argo-events @latest

# Clean up
kubectl delete pod crashloop-test -n default
```

### Scenario 4: Local LLM Analysis (no KAgent, direct model call)

```bash
argo submit -n argo --from=workflowtemplate/local-llm-analysis \
  -p query="Why is this pod failing?" \
  -p event_type="CrashLoopBackOff" \
  -p namespace="default" \
  -p resource_kind="Pod" \
  -p resource_name="crashloop-test" \
  -p severity="high" \
  --watch
```

### Scenario 5: Holmes Investigation (optional comparison)

```bash
argo submit -n argo --from=workflowtemplate/holmes-remediation \
  -p query="Investigate pod failure" \
  -p event_type="CrashLoopBackOff" \
  -p namespace="default" \
  -p resource_kind="Pod" \
  -p resource_name="crashloop-test" \
  -p severity="high" \
  -p remediate="false" \
  --watch
```

---

## Service Endpoints (Internal)

| Service | URL | Port | Used By |
|---------|-----|------|---------|
| KubeAI (OpenAI API) | `kubeai.kubeai.svc.cluster.local` | 80 | LiteLLM, Holmes, Local LLM workflow |
| LiteLLM proxy | `litellm.litellm.svc.cluster.local` | 4000 | KAgent agents |
| KAgent controller | `kagent-controller.kagent.svc.cluster.local` | 8083 | KAgent SRE workflow |
| AKS-MCP | `aks-mcp.aks-mcp.svc.cluster.local` | 8000 | Holmes, KAgent agents |
| Holmes API | `holmes-holmes.holmesgpt.svc.cluster.local` | 80 | Holmes workflow |
| AlertManager EventSource | `alertmanager-eventsource-svc.argo-events.svc.cluster.local` | 12000 | Prometheus AlertManager |
| Argo Server | `argo-server.argo.svc.cluster.local` | 2746 | UI + API |

---

## Key Gotchas

### 1. Storage class for workflow PVCs
Use `local-path`, NOT `longhorn`. Longhorn PVCs are unreliable for short-lived workflow volumes — they sometimes fail to bind before the workflow times out.

### 2. KAgent A2A trailing slash
The A2A endpoint requires a trailing slash: `POST /api/a2a/kagent/{agent-name}/`. Without it you get a 404.

### 3. KAgent A2A method
Use `message/send`, NOT `tasks/send`. The latter returns "unsupported method".

### 4. Namespace anchoring in prompts
Qwen 14B sometimes hallucinates namespace names. Always include `CRITICAL: use exact namespace "X"` in prompts to prevent this.

### 5. Holmes model prefix
Holmes uses LiteLLM-style model names: `openai/qwen3-14b`. Set via `OPENAI_API_BASE` (not `OPENAI_BASE_URL`).

### 6. Argo Events version
Pin to `v1.9.10`. The `stable` tag is a floating release that may introduce breaking changes.

### 7. inotify limits
If EventSource pods crash with "too many open files", increase inotify limits on cluster nodes:
```bash
sysctl -w fs.inotify.max_user_instances=512
```

### 8. EventBus must exist before EventSource/Sensor
The native NATS EventBus must be running before deploying EventSources or Sensors. Deploy `04-eventbus.yaml` first and wait for pods.

### 9. KAgent vs Holmes comparison results
KAgent won 5-0 against Holmes in head-to-head testing. KAgent's native k8s tools avoid the shell quoting issues that plague Holmes's `call_kubectl` subshell approach. Use KAgent as the primary agent; keep Holmes only for comparison.

---

## File References

All YAML manifests live in their original directories. This guide references them by relative path.

| Category | Directory | Key Files |
|----------|-----------|-----------|
| AI Platform | `../../ai-platform/config/` | `kubeai/kubeai-values.yaml`, `kubeai/qwen-14b-model.yaml`, `litellm/litellm-values.yaml`, `kagent/kagent-values.yaml`, `kagent/kagent-modelconfig-14b.yaml` |
| AKS-MCP | `../../holmes-argoworkflows/aks-mcp/` | `aks-mcp-local-admin.yaml` |
| Workflow Templates | `../../holmes-argoworkflows/` | `kagent-sre-workflow.yaml`, `local-llm-analysis-only.yaml`, `holmes-remediation.yaml`, `helm-values-proxmox.yaml` |
| Prometheus Pipeline | `../prometheus-alerting/` | `deploy.sh`, `01-alertmanager-values.yaml` through `08-workflow-rbac.yaml` |
| Event Hub Pipeline | `../eventhub-otlp-pipeline/` | Full pipeline for AKS (not needed for localhost) |
| AKS Working Config | `../working-config/` | Full Event Hub stack for AKS deployment |

---

## Teardown

```bash
# Phase 5: Holmes (optional)
helm uninstall holmes -n holmesgpt
kubectl delete namespace holmesgpt

# Phase 4: KAgent + AKS-MCP
helm uninstall kagent -n kagent
kubectl delete namespace kagent
kubectl delete -f ../../holmes-argoworkflows/aks-mcp/aks-mcp-local-admin.yaml

# Phase 3: AI Platform
helm uninstall litellm -n litellm
kubectl delete namespace litellm
helm uninstall kubeai -n kubeai
kubectl delete namespace kubeai

# Phase 2: Argo Events pipeline
kubectl delete sensor alertmanager-triage-sensor -n argo-events --ignore-not-found
kubectl delete eventsource alertmanager -n argo-events --ignore-not-found
kubectl delete eventbus default -n argo-events --ignore-not-found
kubectl delete -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml

# Phase 1: Argo Workflows
kubectl delete workflowtemplate --all -n argo
kubectl delete workflows --all -n argo
kubectl delete workflows --all -n argo-events
kubectl delete -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml

# Namespaces (careful — only if nothing else uses them)
kubectl delete namespace argo-events argo aks-mcp
```

---

## Troubleshooting

### No workflows trigger from alerts
Walk the chain: Prometheus -> AlertManager -> EventSource -> Sensor -> Workflow

```bash
# 1. Check Prometheus has the rules
kubectl get prometheusrule -n monitoring

# 2. Check AlertManager is firing
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093
# Visit http://localhost:9093/#/alerts

# 3. Check AlertManager webhook config
kubectl get secret alertmanager-kube-prom-kube-prometheus-alertmanager -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep argo

# 4. Check EventSource is receiving
kubectl logs -n argo-events -l eventsource-name=alertmanager --tail=20

# 5. Check Sensor is triggering
kubectl logs -n argo-events -l sensor-name=alertmanager-triage-sensor --tail=20

# 6. Check RBAC
kubectl auth can-i create workflows -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa
```

### KAgent returns empty analysis
- Check KAgent controller logs: `kubectl logs -n kagent -l app=kagent-controller --tail=50`
- Check LiteLLM is routing: `kubectl logs -n litellm -l app=litellm --tail=50`
- Check KubeAI model is loaded: `kubectl get pods -n kubeai -l model=qwen2.5-14b`
- Verify A2A endpoint: `curl http://kagent-controller.kagent.svc.cluster.local:8083/api/agents`

### Model not loading (GPU)
- Check GPU is available: `kubectl describe node | grep nvidia`
- Check NVIDIA device plugin: `kubectl get pods -n kube-system -l app=nvidia-device-plugin`
- Check model pod events: `kubectl describe pod -n kubeai -l model=qwen2.5-14b`
