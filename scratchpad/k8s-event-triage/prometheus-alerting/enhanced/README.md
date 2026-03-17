# Enhanced Prometheus Alerting → Argo Events Triage Pipeline

An advanced, production-ready alert triage pipeline that routes Prometheus AlertManager alerts through Argo Events into automated triage workflows, with multi-channel notifications (Mattermost, Slack, generic webhooks) and GitLab issue integration.

## 🚀 What's New in v2.0

| Feature | Original | Enhanced |
|---------|----------|----------|
| **Alert Rules** | 6 basic rules | 15+ comprehensive rules |
| **Notifications** | Mattermost only | Mattermost + Slack + Webhook |
| **GitLab Issues** | Basic creation | Deduplication, better formatting |
| **Error Handling** | Minimal | Comprehensive with retries |
| **Security** | None | NetworkPolicies included |
| **Testing** | Basic script | Comprehensive with load testing |
| **Deployment** | Simple script | Interactive wizard, dry-run mode |
| **Dashboard** | Basic panels | 15+ panels with triage metrics |

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
│  Prometheus │────>│ AlertManager │────>│  EventSource │────>│    Sensor    │────>│ Argo Workflows   │
│   (Alerts)  │     │  (Routes to  │     │  (Webhook    │     │ (Triggers    │     │ (Triage Pipeline)│
│             │     │  webhook)    │     │  on :12000)  │     │  workflow)   │     │                  │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────────┘     └──────────────────┘
                                                                                           │
         ┌─────────────────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              TRIAGE WORKFLOW STEPS                                       │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│  1. Parse & Validate Alert Payload                                                       │
│  2. Deduplicate (prevent alert storms)                                                   │
│  3. Create GitLab Issue (optional)                                                       │
│  4. Send Notifications (Mattermost/Slack/Webhook)                                        │
│  5. Collect Metrics                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

## 📋 Prerequisites

| Component | Required | Version |
|-----------|----------|---------|
| Kubernetes | Yes | 1.24+ |
| kube-prometheus-stack | Yes | Any |
| Argo Events | Yes | v1.8+ |
| Argo Workflows | Yes | v3.5+ |
| kubectl | Yes | 1.24+ |
| helm | Yes | 3.12+ |

## 📁 File Reference

| File | Description |
|------|-------------|
| `01-alertmanager-values.yaml` | Enhanced AlertManager config with inhibit rules |
| `02-custom-alerting-rules.yaml` | 15+ comprehensive Prometheus alert rules |
| `03-eventsource-alertmanager.yaml` | EventSource with health checks |
| `04-workflow-template.yaml` | Multi-channel triage workflow |
| `05-sensor.yaml` | Sensors for firing and resolved alerts |
| `06-network-policies.yaml` | Security policies for components |
| `07-notification-config.yaml` | ConfigMaps and Secrets templates |
| `08-grafana-dashboard.json` | Enhanced Grafana dashboard |
| `09-grafana-dashboard-configmap.yaml` | Dashboard as ConfigMap |
| `deploy.sh` | Interactive deployment script |
| `test-alerts.sh` | Comprehensive testing suite |

## 🚀 Quick Start

### 1. Clone and Navigate

```bash
cd aks-mgmt-stack/k8s-event-triage/prometheus-alerting/enhanced
chmod +x deploy.sh test-alerts.sh
```

### 2. Interactive Setup (Recommended)

```bash
./deploy.sh --interactive
```

This wizard will:
- Check prerequisites
- Configure notification channels
- Set up GitLab integration (optional)
- Deploy all components

### 3. Or Deploy Non-Interactively

```bash
# Dry-run first to see what will be deployed
./deploy.sh --dry-run

# Deploy everything
./deploy.sh

# Deploy specific components
./deploy.sh --components eventsource,sensor
```

### 4. Configure Notifications

#### Mattermost

```bash
# Create webhook ConfigMap
kubectl create configmap notification-config \
  --namespace argo-events \
  --from-literal=MATTERMOST_WEBHOOK_URL="https://mattermost.example.com/hooks/"

# Create webhook secret
echo -n "your-webhook-token" | base64
# Copy output to 07-notification-config.yaml or create secret:
kubectl create secret generic mattermost-webhook-secret \
  --namespace argo-events \
  --from-literal=WEBHOOK_TOKEN="your-token"
```

#### Slack

```bash
kubectl create configmap notification-config \
  --namespace argo-events \
  --from-literal=SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

#### GitLab Issues

```bash
kubectl create secret generic gitlab-mcp-secret \
  --namespace argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="your-token"

# Update workflow template with your project
sed -i 's|value: ""|value: "your-group/your-project"|' 04-workflow-template.yaml
kubectl apply -f 04-workflow-template.yaml
```

## 🧪 Testing

### Quick Tests

```bash
# Test webhook directly (no port-forward needed)
./test-alerts.sh webhook

# Test via localhost port-forward
kubectl port-forward -n argo-events svc/alertmanager-eventsource-svc 12000:12000
./test-alerts.sh webhook-local

# Create test pods to trigger real alerts
./test-alerts.sh pod-oom      # OOMKill
./test-alerts.sh pod-crash    # CrashLoopBackOff
./test-alerts.sh pod-image    # ImagePullBackOff
./test-alerts.sh pod-pending  # Unschedulable
```

### Full Test Suite

```bash
# Run comprehensive tests
./test-alerts.sh all

# Keep resources for inspection
./test-alerts.sh all --no-cleanup

# Cleanup when done
./test-alerts.sh cleanup
```

### Load Testing

```bash
# Send 50 concurrent alerts
./test-alerts.sh load 50
```

## 📊 Alert Rules Reference

### Pod Failure Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `OOMKilledContainer` | critical | Container terminated with OOMKilled |
| `PodHighRestarts` | warning | >3 restarts in 10 minutes |
| `PodCrashLoopBackOff` | critical | Container in CrashLoopBackOff state |
| `PodImagePullBackOff` | warning | Cannot pull image |
| `ContainerWaitingTooLong` | warning | Container creating for >5min |

### Scheduling Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `FailedScheduling` | warning | Pod unschedulable for >2min |
| `NodeMemoryPressure` | critical | Node has memory pressure |
| `NodeDiskPressure` | critical | Node has disk pressure |
| `NodePIDPressure` | warning | Node has PID pressure |

### Resource Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `ContainerCPUHigh` | warning | CPU >80% of limit for 5min |
| `ContainerMemoryHigh` | warning | Memory >85% of limit for 5min |
| `PVCNearCapacity` | warning | PVC >85% capacity |
| `PVCCriticalCapacity` | critical | PVC >95% capacity |

### Node Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `NodeNotReady` | critical | Node not ready for >5min |
| `NodeHighCPU` | warning | Node CPU >85% for 10min |
| `NodeHighMemory` | warning | Node memory >85% for 10min |

### Application Alerts

| Alert | Severity | Condition |
|-------|----------|-----------|
| `PodNotReady` | warning | Pod not ready for >10min |

## 🔧 Configuration

### Workflow Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `alert-payload` | - | Raw AlertManager JSON |
| `gitlab-project` | "" | GitLab project path |
| `notification-channels` | "mattermost" | Comma-separated channels |
| `deduplication-window` | "30" | Minutes to deduplicate |

### Notification Channels

Set in `notification-config` ConfigMap:

```yaml
MATTERMOST_WEBHOOK_URL: "https://mattermost.example.com/hooks/"
SLACK_WEBHOOK_URL: "https://hooks.slack.com/services/..."
GENERIC_WEBHOOK_URL: "https://your-custom-webhook.com/alerts"
DEFAULT_CHANNELS: "mattermost,slack"
```

### Rate Limiting

The sensor includes rate limiting to prevent alert storms:

```yaml
rateLimit:
  requestsPerUnit: 10
  unit: Minute
```

## 🔒 Security

### Network Policies

Deploy network policies to restrict traffic:

```bash
kubectl apply -f 06-network-policies.yaml
```

Policies include:
- Allow AlertManager → EventSource on port 12000
- Allow Sensor → EventBus communication
- Allow workflows → external HTTPS only
- Default deny for workflow pods

### Secrets Management

All sensitive data should be in Secrets:

| Secret | Keys |
|--------|------|
| `mattermost-webhook-secret` | `WEBHOOK_TOKEN` |
| `slack-webhook-secret` | `WEBHOOK_TOKEN` |
| `gitlab-mcp-secret` | `GITLAB_PERSONAL_ACCESS_TOKEN` |
| `generic-webhook-secret` | `AUTH_TOKEN`, `AUTH_HEADER` |

## 📈 Monitoring

### View Dashboard

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-grafana 3000:80
# Open http://localhost:3000
# Search for "Prometheus Alert Triage Dashboard"
# Default credentials: admin/prom-operator
```

### Dashboard Panels

- **Alert Overview**: Active, Critical, Warning, Pending counts
- **Triage Metrics**: Workflow count, success rate
- **Alert Timeline**: Alerts over time, duration
- **Pod Health**: Issues by reason, restarts, OOM events
- **Resources**: CPU/Memory usage vs limits

### Custom Metrics

Workflow metrics can be exported to Prometheus:

```promql
# Workflow success rate
sum(argo_workflows_count{namespace="argo-events",status="Succeeded"})
/ sum(argo_workflows_count{namespace="argo-events"})

# Average workflow duration
argo_workflows_operation_duration_seconds_sum
/ argo_workflows_operation_duration_seconds_count
```

## 🔍 Troubleshooting

### Check EventSource

```bash
kubectl get eventsource alertmanager -n argo-events
kubectl logs -n argo-events -l eventsource-name=alertmanager
```

### Check Sensor

```bash
kubectl get sensor alertmanager-triage-sensor -n argo-events
kubectl logs -n argo-events -l sensor-name=alertmanager-triage-sensor
```

### Check Workflows

```bash
kubectl get workflows -n argo-events -l event-type=prometheus-alert
kubectl logs -n argo-events -l event-type=prometheus-alert
```

### Test Webhook Manually

```bash
# From inside cluster
kubectl run test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -X POST http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/alerts \
  -H "Content-Type: application/json" \
  -d '{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"Test","severity":"warning"}}]}'
```

### AlertManager Configuration

```bash
# Check AlertManager config
kubectl get secret -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d

# Port-forward AlertManager UI
kubectl port-forward -n monitoring svc/alertmanager-monitoring-kube-prometheus-alertmanager 9093:9093
```

## 🗑️ Cleanup

```bash
# Remove all pipeline components
kubectl delete -f 05-sensor.yaml
kubectl delete -f 04-workflow-template.yaml
kubectl delete -f 03-eventsource-alertmanager.yaml
kubectl delete -f 02-custom-alerting-rules.yaml
kubectl delete configmap notification-config -n argo-events --ignore-not-found

# Revert AlertManager config (optional)
helm upgrade monitoring-kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set alertmanager.config.receivers=null
```

## 📚 Additional Resources

- [Argo Events Documentation](https://argoproj.github.io/argo-events/)
- [Prometheus AlertManager](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [Argo Workflows](https://argoproj.github.io/argo-workflows/)
- [Prometheus Operator](https://prometheus-operator.dev/)

## 🤝 Contributing

This is an enhanced version of the original Prometheus alerting triage pipeline. Improvements welcome!

## 📜 License

MIT License - Same as original project
