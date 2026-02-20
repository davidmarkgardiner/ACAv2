# Event Hub OTLP Pipeline - K8s Event Triage

End-to-end pipeline that consumes K8s events from Azure Event Hub (sent by Alloy in OTLP JSON format), parses the OTLP envelope, classifies event severity, and sends Mattermost notifications.

## Architecture

```
Workload Cluster                        Azure                    Management Cluster
┌──────────────┐    Kafka/TLS    ┌──────────────┐    Kafka/TLS    ┌──────────────────────────────┐
│ Alloy        ├────────────────►│ Event Hub    ├────────────────►│ EventSource (Kafka consumer) │
│ (OTLP JSON)  │                 │ (Standard)   │                 └──────────┬───────────────────┘
└──────────────┘                 └──────────────┘                            │ NATS EventBus
                                                                  ┌──────────▼───────────────────┐
                                                                  │ Sensor (rate limit 5/min)     │
                                                                  └──────────┬───────────────────┘
                                                                             │ creates Workflow
                                                                  ┌──────────▼───────────────────┐
                                                                  │ Workflow                      │
                                                                  │  ├─ parse-otlp (Python)      │
                                                                  │  │  Extract K8s events from   │
                                                                  │  │  OTLP envelope, filter     │
                                                                  │  │  Warning only              │
                                                                  │  └─ classify-and-alert        │
                                                                  │     (withParam fan-out)       │
                                                                  │     Severity + Mattermost     │
                                                                  └──────────────────────────────┘
```

## Prerequisites

- Argo Events installed (controller + EventBus in `argo-events` namespace)
- Argo Workflows installed
- Azure Event Hub **Standard** tier (Basic does NOT support Kafka protocol)
- Service account `argo-events-sa` with workflow creation RBAC

## Files

| File | Description |
|---|---|
| `01-secrets.yaml` | Secret + ConfigMap templates (fill in your values) |
| `02-eventsource.yaml` | Kafka EventSource consuming from Event Hub |
| `03-sensor.yaml` | Sensor with rate limiting, passes full OTLP body |
| `04-workflow-template.yaml` | OTLP parser + severity classifier + Mattermost alert |
| `OTLP-PAYLOAD-REFERENCE.md` | OTLP JSON structure reference and field mapping |

## Deployment Steps

### 1. Create Azure Event Hub (if not already done)

```bash
# Create resource group
az group create --name rg-event-triage --location uksouth

# Create Event Hub namespace (MUST be Standard or Premium for Kafka)
az eventhubs namespace create \
  --name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage \
  --location uksouth \
  --sku Standard \
  --enable-kafka true

# Create Event Hub (topic)
az eventhubs eventhub create \
  --name k8s-events \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage \
  --partition-count 2 \
  --cleanup-policy Delete \
  --retention-time 24

# Create consumer group
az eventhubs eventhub consumer-group create \
  --name argo-events-consumer \
  --eventhub-name k8s-events \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage

# Get connection string
az eventhubs namespace authorization-rule keys list \
  --name RootManageSharedAccessKey \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage \
  --query primaryConnectionString -o tsv
```

### 2. Extract TLS CA Certificate

Argo Events requires an explicit CA cert secret for TLS connections. Event Hub uses Microsoft's public CA chain.

```bash
# Extract CA chain from Event Hub endpoint
echo | openssl s_client \
  -connect evh-YOUR-NAMESPACE.servicebus.windows.net:9093 \
  -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /tmp/eventhub-ca-chain.pem

# Create K8s secret
kubectl create secret generic eventhub-tls-ca \
  -n argo-events \
  --from-file=ca.pem=/tmp/eventhub-ca-chain.pem
```

### 3. Create Secrets and ConfigMap

Edit `01-secrets.yaml` with your real values, then:

```bash
kubectl apply -f 01-secrets.yaml
```

Or create them imperatively:

```bash
# Event Hub credentials
printf '%s' '$ConnectionString' > /tmp/eh-username.txt
printf '%s' 'Endpoint=sb://evh-YOUR-NAMESPACE.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...' > /tmp/eh-connstr.txt

kubectl create secret generic eventhub-credentials \
  -n argo-events \
  --from-file=username=/tmp/eh-username.txt \
  --from-file=connection-string=/tmp/eh-connstr.txt

rm /tmp/eh-username.txt /tmp/eh-connstr.txt

# Mattermost webhook
kubectl create configmap mattermost-webhook-config \
  -n argo-events \
  --from-literal=WEBHOOK_URL='https://mattermost.your-domain.com/hooks/YOUR-WEBHOOK-ID'
```

### 4. Deploy Pipeline

```bash
kubectl apply -f 02-eventsource.yaml
kubectl apply -f 03-sensor.yaml
kubectl apply -f 04-workflow-template.yaml
```

### 5. Verify

```bash
# Check EventSource is connected
kubectl logs -n argo-events -l owner-name=eventhub-k8s-events --tail=5
# Should see: "Sarama consumer group up and running!"

# Check Sensor is running
kubectl get pods -n argo-events -l owner-name=k8s-event-triage

# Test with a manual workflow submission (see OTLP-PAYLOAD-REFERENCE.md for sample payload)
argo submit -n argo-events \
  --from workflowtemplate/k8s-event-triage \
  -p "otlp-payload=$(cat sample-otlp.json)" \
  --watch
```

## Troubleshooting

### EventSource pod crashes with "too many open files"

Increase inotify limits on cluster nodes:

```bash
# Check current value
cat /proc/sys/fs/inotify/max_user_instances

# Fix (needs root on each node, non-persistent across reboots)
sysctl -w fs.inotify.max_user_instances=512

# For persistent fix, add to /etc/sysctl.d/99-inotify.conf:
# fs.inotify.max_user_instances=512
```

### EventSource fails with "secret-" volume name error

The `tls.caCertSecret` must reference a real secret. Empty `name: ""` causes the controller to generate an invalid volume name. See Step 2 above.

### EventSource fails with "Invalid spec" / "invalid tls config"

Argo Events requires either `caCertSecret` or `clientCertSecret`+`clientKeySecret` when TLS is configured. You cannot use `insecureSkipVerify: false` alone without a cert secret.

### Events not triggering workflows

1. Check EventSource logs for Kafka consumer errors
2. Check Sensor logs: `kubectl logs -n argo-events -l owner-name=k8s-event-triage`
3. Verify EventBus is healthy: `kubectl get eventbus -n argo-events`
4. Check rate limiting — sensor allows max 5 workflows per minute

### Workflow parse-otlp step fails

The OTLP structure may differ from expected. Capture a real message from Event Hub:
- Azure Portal → Event Hub → Process Data → peek at messages
- Compare against `OTLP-PAYLOAD-REFERENCE.md`

## Tested Configuration

| Component | Version / Config |
|---|---|
| Argo Events | v1.9.6 |
| Argo Workflows | v3.6.4 |
| Event Hub | Standard tier, Kafka protocol |
| Kafka protocol version | 2.1.0 |
| SASL mechanism | PLAIN |
| EventBus | NATS native (default) |
| Tested on | proxmox-k8s (K8s v1.31.14, 3 nodes) |
