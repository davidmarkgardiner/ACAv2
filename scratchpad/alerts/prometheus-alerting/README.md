# Prometheus AlertManager -> Argo Events Triage Pipeline

Automated alert triage pipeline that routes Prometheus AlertManager alerts through Argo Events into triage workflows, with Mattermost notifications for real-time visibility.

---

https://excalidraw.com/#json=7JdW2pOCzg9eUOpeKQPoZ,_XBHgo3xJOWHHzvpd_rddQ

## Architecture Overview

```
 Prometheus         AlertManager         Argo Events         Argo Events         Mattermost
 (Metrics +         (Routes alerts       EventSource         Sensor              (Alert
  Alert Rules)       to webhook)         (Webhook receiver)  (Triggers workflow)  notifications)

 ┌──────────┐      ┌──────────────┐     ┌──────────────┐   ┌──────────────┐    ┌───────────┐
 │Prometheus│─────>│ AlertManager │────>│ EventSource  │──>│   Sensor     │──> │ Mattermost│
 │          │rules │              │POST │  :12000      │   │              │    │  Webhook  │
 │          │fire  │  webhook     │/alerts│            │   │ WorkflowRef: │    │  :8065    │
 └──────────┘      │  receiver    │     └──────────────┘   │ alertmanager │    └───────────┘
                   └──────────────┘                        │ -triage      │
                                                           └──────────────┘
```

See `prometheus-alerting-architecture.excalidraw` for the full architecture diagram (open with [Excalidraw](https://excalidraw.com)).

---

## Prerequisites

| Component | Required | Notes |
|-----------|----------|-------|
| **kube-prometheus-stack** | Yes | Helm release in namespace `monitoring` (auto-detected: `kube-prom`, `prometheus-stack`, or `prom-stack`) |
| **Argo Events** | Yes | Installed in namespace `argo-events` with EventBus (`default`) |
| **Argo Workflows** | Yes | Controller running, able to create Workflows in `argo-events` namespace |
| **Mattermost** | Yes | Running in namespace `mattermost` with incoming webhook configured |
| **kubectl** | Yes | Configured with cluster access |
| **helm** | Yes | With `prometheus-community` repo added |

### Mattermost Webhook ConfigMap

Create the Mattermost webhook config before deploying:

```bash
# Create incoming webhook in Mattermost first, then:
kubectl create configmap mattermost-webhook-config \
  --namespace argo-events \
  --from-literal=WEBHOOK_URL="http://mattermost.mattermost.svc.cluster.local:8065/hooks/YOUR_WEBHOOK_ID"
```

---

## File Reference

| File | Kind | Namespace | Description |
|------|------|-----------|-------------|
| `01-alertmanager-values.yaml` | Helm values | `monitoring` | Adds `argo-events-webhook` receiver to AlertManager config; routes matching alerts to EventSource webhook at `http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts` |
| `02-custom-alerting-rules.yaml` | PrometheusRule | `monitoring` | Custom alert rules: OOMKilledContainer, PodHighRestarts, FailedScheduling, ContainerCPUHigh, ContainerMemoryHigh, PVCNearCapacity |
| `03-eventsource-alertmanager.yaml` | EventSource | `argo-events` | Webhook listener on port 12000, endpoint `/alerts`, receives AlertManager POST payloads |
| `04-workflow-template.yaml` | WorkflowTemplate | `argo-events` | `alertmanager-triage` template: parses alert payload with jq, sends Mattermost notifications with color-coded attachments |
| `05-sensor.yaml` | Sensor | `argo-events` | Filters for `status: firing` alerts, triggers `alertmanager-triage` workflow with rate limit (5/min) |
| `06-grafana-dashboard.json` | Dashboard JSON | - | Raw Grafana dashboard for alert triage visualization |
| `07-grafana-dashboard-configmap.yaml` | ConfigMap | `monitoring` | Wraps dashboard JSON for Grafana sidecar auto-import (label `grafana_dashboard: "1"`) |
| `deploy.sh` | Script | - | Deploys all manifests in correct order with prerequisite checks and verification |
| `test-alerts.sh` | Script | - | End-to-end testing: webhook injection, failing pod creation, workflow verification, cleanup |
| `prometheus-alerting-architecture.excalidraw` | Diagram | - | Architecture diagram (Excalidraw format) |

---

## Deployment

### Quick Start

```bash
cd aks-mgmt-stack/k8s-event-triage/prometheus-alerting
chmod +x deploy.sh
./deploy.sh
```

### Manual Step-by-Step

If you prefer to apply manifests individually:

```bash
# 1. Upgrade AlertManager with webhook receiver (use your actual Helm release name)
helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  -f 01-alertmanager-values.yaml \
  --wait

# 2. Apply custom alerting rules
kubectl apply -f 02-custom-alerting-rules.yaml

# 3. Deploy EventSource (webhook listener)
kubectl apply -f 03-eventsource-alertmanager.yaml

# 4. Wait for EventSource pod
kubectl wait --for=condition=ready pod \
  -l eventsource-name=alertmanager \
  -n argo-events --timeout=120s

# 5. Deploy WorkflowTemplate
kubectl apply -f 04-workflow-template.yaml

# 6. Deploy Sensor
kubectl apply -f 05-sensor.yaml

# 7. Wait for Sensor pod
kubectl wait --for=condition=ready pod \
  -l sensor-name=alertmanager-triage-sensor \
  -n argo-events --timeout=120s

# 8. (Optional) Import Grafana dashboard
kubectl apply -f 07-grafana-dashboard-configmap.yaml
```

### Verify Deployment

```bash
# Check EventSource
kubectl get eventsource -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting

# Check Sensor
kubectl get sensor -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting

# Check PrometheusRule
kubectl get prometheusrule k8s-triage-alerting-rules -n monitoring

# Check running pods
kubectl get pods -n argo-events -l app.kubernetes.io/part-of=prometheus-alerting
```

---

## Testing

### Quick Start

```bash
chmod +x test-alerts.sh
./test-alerts.sh --all
```

### Test Modes

| Mode | Command | Description |
|------|---------|-------------|
| **Webhook test** | `./test-alerts.sh --webhook-test` | Sends a mock AlertManager payload directly to the EventSource |
| **OOMKill pod** | `./test-alerts.sh --create-oom` | Creates a pod that will be OOMKilled (triggers OOMKilledContainer alert) |
| **CrashLoop pod** | `./test-alerts.sh --create-crashloop` | Creates a pod that crash-loops (triggers PodHighRestarts alert) |
| **ImagePull pod** | `./test-alerts.sh --create-imagepull` | Creates a pod with an invalid image |
| **Verify** | `./test-alerts.sh --verify` | Checks for triggered triage workflows |
| **Cleanup** | `./test-alerts.sh --cleanup` | Removes all test pods and workflows |
| **Full sequence** | `./test-alerts.sh --all` | Runs webhook test + creates failing pods + waits 60s + verifies |

### Webhook Test (Manual)

Port-forward the EventSource service in one terminal:

```bash
kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000
```

Then send a test payload:

```bash
curl -X POST http://localhost:12000/alerts \
  -H "Content-Type: application/json" \
  -d '{
  "version": "4",
  "status": "firing",
  "receiver": "argo-events-webhook",
  "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning",
      "namespace": "default",
      "pod": "test-pod-123"
    },
    "annotations": {
      "summary": "Manual test alert",
      "description": "Testing the triage pipeline end-to-end"
    },
    "startsAt": "2024-01-01T00:00:00.000Z"
  }]
}'
```

### Verify Workflows Were Created

```bash
kubectl get workflows -n argo-events -l event-type=prometheus-alert
```

---

## Placeholders and Secrets

| Placeholder / Secret | Location | Description |
|----------------------|----------|-------------|
| `mattermost-webhook-config` (ConfigMap) | `argo-events` namespace | Must contain key `WEBHOOK_URL` with Mattermost incoming webhook URL |
| `kube-prom` (Helm release) | `monitoring` namespace | Name of the kube-prometheus-stack Helm release (auto-detected by `deploy.sh`) |
| `argo-events-sa` (ServiceAccount) | `argo-events` namespace | Service account used by EventSource, Sensor, and Workflows |
| `default` (EventBus) | `argo-events` namespace | Argo Events EventBus name (NATS-based) |
| AlertManager webhook URL | `01-alertmanager-values.yaml` | `http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts` |

---

## Alert Rules Reference

Custom PrometheusRule `k8s-triage-alerting-rules` defines these alerts:

| Alert | Severity | Condition | For |
|-------|----------|-----------|-----|
| **OOMKilledContainer** | critical | Container terminated with reason OOMKilled | 0m |
| **PodHighRestarts** | warning | Container restarted >3 times in 5 minutes | 0m |
| **FailedScheduling** | warning | Pod unschedulable | 2m |
| **ContainerCPUHigh** | warning | CPU usage >80% of limit | 5m |
| **ContainerMemoryHigh** | warning | Memory usage >80% of limit | 5m |
| **PVCNearCapacity** | warning | PVC usage >85% of capacity | 5m |

All rules exclude system namespaces: `kube-system`, `argo-events`, `argo`, `monitoring`.

AlertManager routes alerts matching these names to the `argo-events-webhook` receiver.

### Default kube-prometheus-stack Alerts

The AlertManager routing matcher (`01-alertmanager-values.yaml`) also captures built-in alerts from kube-prometheus-stack that match the pattern `KubePod.*|KubeContainer.*`. These fire out of the box without any custom PrometheusRule:

| Alert | Source | Severity | Description |
|-------|--------|----------|-------------|
| **KubePodCrashLooping** | kube-prometheus-stack | warning | Pod restarting frequently (CrashLoopBackOff) |
| **KubePodNotReady** | kube-prometheus-stack | warning | Pod has been in non-Ready state for >15m |
| **KubeContainerWaiting** | kube-prometheus-stack | warning | Container waiting in non-running state for >1h |
| **CPUThrottlingHigh** | kube-prometheus-stack | info | Container CPU throttling >25% for 15m |

These alerts are routed to the `argo-events-webhook` receiver alongside the custom rules, so both custom and built-in alerts flow through the same triage pipeline. The `continue: true` flag ensures they are also delivered to the `default-receiver`.

---

## Grafana Dashboard

The dashboard (`06-grafana-dashboard.json`) is auto-imported by the Grafana sidecar via the ConfigMap (`07-grafana-dashboard-configmap.yaml`).

### Accessing the Dashboard

```bash
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80
# Open http://localhost:3000 -> search "Prometheus Alert Triage"
```

Default Grafana credentials (kube-prometheus-stack): `admin` / `prom-operator`

### Dashboard Panels

| Section | Panels | Description |
|---------|--------|-------------|
| **Alert Overview** | Active Firing Alerts, Critical Alerts, Warning Alerts, Pending Alerts | Stat panels showing current alert counts with color thresholds |
| **Alert Timeline** | Alerts by Name, Alert Duration | Time series of alert firing history and how long each alert has been active |
| **Pod Health** | Pod Issues by Reason, Pod Restarts (1h) | Breakdown of pod failure reasons and restart counts over the last hour |
| **Resource Utilization** | Container CPU Usage vs Limit, Container Memory Usage vs Limit | Gauge panels showing how close containers are to resource limits |
| **OOM & Scheduling** | OOMKilled Events, Unschedulable Pods | Dedicated panels tracking OOMKill history and scheduling failures |

The dashboard uses a `${datasource}` template variable for Prometheus data source selection.

---

## Mattermost Message Format

Alerts are sent to Mattermost as rich webhook messages with color-coded attachments:

| Severity | Emoji | Color | Example |
|----------|-------|-------|---------|
| critical | :red_circle: | `#e74c3c` (red) | `:red_circle: :fire: **OOMKilledContainer**` |
| warning | :large_orange_circle: | `#e67e22` (orange) | `:large_orange_circle: :fire: **PodHighRestarts**` |
| info | :white_circle: | `#95a5a6` (grey) | `:white_circle: :fire: **InfoAlert**` |

Status indicators: :fire: = firing, :white_check_mark: = resolved.

Each message includes three attachments:
1. **Alert Details** - Markdown table with severity, status, namespace, pod, container, and timestamp
2. **Description** - Full alert description with runbook link (if available)
3. **Quick Commands** - `kubectl describe` and `kubectl logs` commands for the affected pod

### Mattermost Setup

The workflow reads the webhook URL from ConfigMap `mattermost-webhook-config` (key: `WEBHOOK_URL`) in the `argo-events` namespace. Uses `badouralix/curl-jq:latest` image for shell/jq/curl processing.

---

## Troubleshooting

### EventSource pod not starting

```bash
# Check EventSource status
kubectl describe eventsource alertmanager -n argo-events

# Check pod logs
kubectl logs -n argo-events -l eventsource-name=alertmanager

# Verify EventBus is running
kubectl get eventbus -n argo-events
```

### Sensor pod not starting

```bash
# Check Sensor status
kubectl describe sensor alertmanager-triage-sensor -n argo-events

# Check pod logs
kubectl logs -n argo-events -l sensor-name=alertmanager-triage-sensor
```

### Alerts not reaching EventSource

```bash
# Check AlertManager config was applied
kubectl get secret alertmanager-kube-prom-kube-prometheus-alertmanager \
  -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d

# Port-forward AlertManager UI
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093
# Open http://localhost:9093/#/status to verify receiver config

# Check if the EventSource service is reachable from AlertManager
kubectl run curl-test --rm -it --image=curlimages/curl:latest --restart=Never -- \
  curl -v http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts
```

### Workflows not being created

```bash
# Check Sensor logs for trigger errors
kubectl logs -n argo-events -l sensor-name=alertmanager-triage-sensor --tail=50

# Check rate limiting (max 5 workflows/minute)
kubectl get workflows -n argo-events -l event-type=prometheus-alert --sort-by=.metadata.creationTimestamp

# Verify WorkflowTemplate exists
kubectl get workflowtemplate alertmanager-triage -n argo-events
```

### Mattermost messages not sending

```bash
# Check workflow logs
kubectl logs -n argo-events -l workflows.argoproj.io/workflow-template=alertmanager-triage --tail=50

# Verify ConfigMap exists and has correct webhook URL
kubectl get configmap mattermost-webhook-config -n argo-events -o jsonpath='{.data.WEBHOOK_URL}'

# Test webhook directly from within the cluster
kubectl run mm-test --rm -it --image=curlimages/curl:latest --restart=Never -n argo-events -- \
  curl -s -X POST "$(kubectl get configmap mattermost-webhook-config -n argo-events -o jsonpath='{.data.WEBHOOK_URL}')" \
  -H "Content-Type: application/json" -d '{"text":"Test message"}'

# Check Mattermost pod is running
kubectl get pods -n mattermost
```

### PrometheusRule not being picked up

```bash
# Verify the rule has the correct label for Prometheus to discover it
kubectl get prometheusrule k8s-triage-alerting-rules -n monitoring -o jsonpath='{.metadata.labels}'

# Check Prometheus targets and rules
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/alerts to see if rules are loaded
```

---

## Port-Forward Commands

```bash
# AlertManager UI (check receiver config, silence alerts)
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-alertmanager 9093:9093

# Prometheus UI (check alert rules, query metrics)
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090

# Grafana (view dashboard)
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80

# EventSource webhook (for manual webhook testing)
kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000

# Argo Workflows UI (view triage workflow runs)
kubectl port-forward -n argo svc/argo-server 2746:2746
```

---

## Cleanup

To remove all pipeline components:

```bash
# Remove Argo Events resources
kubectl delete sensor alertmanager-triage-sensor -n argo-events --ignore-not-found
kubectl delete eventsource alertmanager -n argo-events --ignore-not-found
kubectl delete workflowtemplate alertmanager-triage -n argo-events --ignore-not-found

# Remove PrometheusRule
kubectl delete prometheusrule k8s-triage-alerting-rules -n monitoring --ignore-not-found

# Remove Grafana dashboard
kubectl delete configmap prometheus-alert-triage-dashboard -n monitoring --ignore-not-found

# Remove AlertManager webhook receiver (re-apply original values)
helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring --reuse-values \
  --set alertmanager.config.receivers=null
```
