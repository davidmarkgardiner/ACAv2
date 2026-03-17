# Event Hub OTLP Pipeline - K8s Event Triage

Automated K8s event triage pipeline. Alloy on the workload cluster collects K8s events and sends them to Azure Event Hub as OTLP JSON. On the management cluster, Argo Events consumes from Event Hub, Argo Workflows parses the OTLP envelope, and KAgent provides AI-powered analysis via A2A protocol. Alerts go to Mattermost.

## Architecture

```
Workload Cluster                     Azure                        Management Cluster
┌──────────────────┐   Kafka/TLS   ┌────────────────┐  Kafka/TLS  ┌───────────────────────────────┐
│ Alloy            ├──────────────►│ Event Hub      ├────────────►│ EventSource (Kafka consumer)  │
│                  │               │ (Standard)     │             └──────────┬────────────────────┘
│ K8s events       │               │                │                        │ NATS EventBus
│ → loki.process   │               │ Topic:         │             ┌──────────▼────────────────────┐
│ → otelcol.kafka  │               │ k8s-events     │             │ Sensor (rate limited)         │
│   (otlp_json)    │               │                │             └──────────┬────────────────────┘
└──────────────────┘               └────────────────┘                        │ creates Workflow
                                                                  ┌──────────▼────────────────────┐
                                                                  │ Workflow                       │
                                                                  │  ├─ parse-otlp (jq)           │
                                                                  │  │  Extract K8s events from    │
                                                                  │  │  OTLP envelope, filter      │
                                                                  │  │                             │
                                                                  │  └─ analyze-and-alert          │
                                                                  │     (withParam fan-out)        │
                                                                  │     KAgent A2A → Mattermost    │
                                                                  └───────────────────────────────┘
```

### How OTLP works here

Alloy can't write K8s events directly to Kafka. The pipeline is:
`loki.source.kubernetes_events` → `loki.process` (enrich with labels) → `otelcol.receiver.loki` → `otelcol.exporter.kafka` (otlp_json encoding).

This means Event Hub messages are **OTLP log envelopes**, not raw K8s event JSON. The raw K8s event is nested inside `resourceLogs[].scopeLogs[].logRecords[].body.stringValue` as a JSON string. The workflow's `parse-otlp` step (jq) unwraps this.

See `OTLP-PAYLOAD-REFERENCE.md` for the exact JSON structure and field mapping.

### Consumer groups explained

Alloy sends everything to **one** Event Hub topic. On the consumer side, each tier uses a different **Kafka consumer group**.

Within a consumer group, messages are load-balanced (split). **Across** consumer groups, messages are **duplicated** — each group gets every message independently. Filtering happens in the workflow's jq step, which is cheap (64Mi, ~3s).

This means you can have three tiers reading the same topic, each filtering for different events, without them interfering with each other.

```
Event Hub Topic: k8s-events
    │           │           │
consumer-      consumer-    consumer-
critical       warnings     infra
    │           │           │
gets ALL       gets ALL     gets ALL
messages       messages     messages
    │           │           │
filters:       filters:     filters:
CrashLoop,     non-critical infra
OOM, etc.      warnings     namespaces
```

If you don't need tier isolation, a single consumer group with one sensor and one workflow works fine.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Argo Events | Installed with controller in `argo-events` namespace |
| Argo Workflows | Installed (controller + server) |
| EventBus | NATS native in `argo-events` namespace (**commonly missed**) |
| Azure Event Hub | **Standard** or Premium tier (Basic does NOT support Kafka protocol) |
| KAgent | Running in cluster with A2A endpoint accessible (for AI analysis tiers) |
| Mattermost | Incoming webhook configured |

### EventBus

If you don't have one, EventSources and Sensors can't communicate. Deploy:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native: {}
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native: {}
EOF
```

## Repository Structure

### Option A: Simple (single tier)

Start here. One EventSource, one Sensor, one Workflow. No KAgent dependency.

```
eventhub-otlp-pipeline/
├── 01-secrets.yaml              # Event Hub credentials + Mattermost webhook
├── 01-shared-rbac.yaml          # SA permission to create workflows
├── 02-eventsource.yaml          # Kafka consumer from Event Hub
├── 03-sensor.yaml               # Routes events to workflow (includes RBAC)
├── 04-workflow-template.yaml    # parse-otlp → classify → Mattermost
└── OTLP-PAYLOAD-REFERENCE.md    # OTLP JSON structure + field mapping
```

### Option B: Three-tier (phased rollout)

Independent tiers with different SLAs. Each tier has its own consumer group, sensor, and workflow. See `PHASED-ROLLOUT.md` for the full plan.

```
eventhub-otlp-pipeline/
├── 01-secrets.yaml              # Shared: Event Hub creds + Mattermost + TLS CA
├── 01-shared-rbac.yaml          # Shared: SA → workflow creation RBAC
├── 01-kagent-config.yaml        # Shared: KAgent A2A endpoint + agent names
│
├── tier-critical/               # CrashLoopBackOff, OOMKilled, etc.
│   ├── eventsource.yaml         #   consumer group: consumer-critical
│   ├── sensor.yaml              #   rate limit: 5/min
│   └── workflow-template.yaml   #   KAgent A2A analysis + Mattermost (must alert)
│
├── tier-warnings/               # All other Warning events (non-critical)
│   ├── eventsource.yaml         #   consumer group: consumer-warnings
│   ├── sensor.yaml              #   rate limit: 10/min
│   └── workflow-template.yaml   #   KAgent A2A analysis (best effort)
│
├── tier-infra/                  # Core infra namespaces (cert-manager, etc.)
│   ├── eventsource.yaml         #   consumer group: consumer-infra
│   ├── sensor.yaml              #   rate limit: 3/min
│   └── workflow-template.yaml   #   Mattermost only (add KAgent later)
│
├── alloy/                       # Workload cluster Alloy deployment
│   ├── 01-namespace.yaml        #   monitoring namespace
│   ├── 02-secret.yaml           #   Event Hub connection string
│   ├── 03-deployment.yaml       #   Deployment + SA + RBAC + Service
│   ├── alloy-config-phase1.yaml #   Phase 1: app namespaces only
│   └── alloy-config-phase3.yaml #   Phase 3: + infra namespaces
│
├── PHASED-ROLLOUT.md            # Three-tier architecture + phased plan
└── OTLP-PAYLOAD-REFERENCE.md    # OTLP JSON structure + field mapping
```

## Deployment — Option A (Simple)

### 1. Create Azure Event Hub

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

### 2. Extract TLS CA certificate

Argo Events requires an explicit CA cert for TLS. Event Hub uses Microsoft's public CA chain:

```bash
# Extract CA chain from your Event Hub endpoint
echo | openssl s_client \
  -connect evh-YOUR-NAMESPACE.servicebus.windows.net:9093 \
  -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /tmp/eventhub-ca-chain.pem

# Verify it's not empty
wc -l /tmp/eventhub-ca-chain.pem

# Create K8s secret
kubectl create secret generic eventhub-tls-ca \
  -n argo-events \
  --from-file=ca.pem=/tmp/eventhub-ca-chain.pem
```

**Do not skip this.** Using `tls: insecureSkipVerify: true` alone does not work — Argo Events requires either `caCertSecret` or `clientCertSecret`. An empty `caCertSecret.name: ""` causes a crash ("secret-" volume name error).

### 3. Create secrets and config

**Option 1 — Edit and apply `01-secrets.yaml`:**

Replace the `REPLACE_*` placeholders in `01-secrets.yaml`, then:

```bash
kubectl apply -f 01-secrets.yaml
```

**Option 2 — Create imperatively (avoids secrets in files):**

```bash
# Event Hub credentials
# IMPORTANT: Use printf and --from-file to handle special chars in the SAS key (/, +, =)
printf '%s' '$ConnectionString' > /tmp/eh-username.txt
printf '%s' 'Endpoint=sb://evh-YOUR-NAMESPACE.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=YOUR_KEY' > /tmp/eh-connstr.txt

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

### 4. Edit EventSource placeholders

In `02-eventsource.yaml`, replace:

| Placeholder | Example |
|-------------|---------|
| `REPLACE_EVENTHUB_NAMESPACE` | `evh-platform-prod` |
| `REPLACE_EVENTHUB_NAME` | `k8s-events` |
| `REPLACE_CONSUMER_GROUP` | `argo-events-consumer` |

### 5. Deploy

```bash
# RBAC first
kubectl apply -f 01-shared-rbac.yaml

# Then pipeline components
kubectl apply -f 02-eventsource.yaml
kubectl apply -f 03-sensor.yaml
kubectl apply -f 04-workflow-template.yaml
```

### 6. Verify

```bash
# 1. EventBus exists
kubectl get eventbus -n argo-events
# Expected: "default" with running NATS pods

# 2. EventSource pod is running and connected
kubectl get pods -n argo-events -l eventsource-name=eventhub-k8s-events
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=20
# Look for: "successfully connected to eventbus" and Kafka consumer messages

# 3. Sensor pod is running and subscribed
kubectl get pods -n argo-events -l sensor-name=k8s-event-triage
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=20
# Look for: "successfully subscribed to eventbus"

# 4. WorkflowTemplate exists
kubectl get workflowtemplate -n argo-events

# 5. RBAC is correct
kubectl auth can-i create workflows -n argo-events \
  --as=system:serviceaccount:argo-events:argo-events-sa
# Expected: yes
```

## Deployment — Option B (Three-Tier)

### 1. Azure setup (same as Option A, plus consumer groups)

```bash
# Create three consumer groups on the same Event Hub
az eventhubs eventhub consumer-group create \
  --name consumer-critical \
  --eventhub-name k8s-events \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage

az eventhubs eventhub consumer-group create \
  --name consumer-warnings \
  --eventhub-name k8s-events \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage

az eventhubs eventhub consumer-group create \
  --name consumer-infra \
  --eventhub-name k8s-events \
  --namespace-name evh-YOUR-NAMESPACE \
  --resource-group rg-event-triage
```

### 2. Secrets + TLS + Config (same as Option A steps 2-3)

Plus the KAgent config:

```bash
# Edit 01-kagent-config.yaml with your KAgent URL and agent names, then:
kubectl apply -f 01-kagent-config.yaml
```

Or create imperatively:

```bash
kubectl create configmap kagent-config \
  -n argo-events \
  --from-literal=KAGENT_URL='http://kagent-controller-manager.kagent.svc.cluster.local:8082' \
  --from-literal=KAGENT_CRITICAL_AGENT='sre-triage-agent' \
  --from-literal=KAGENT_WARNINGS_AGENT='sre-triage-agent'
```

### 3. Edit EventSource placeholders

Replace `REPLACE_EVENTHUB_NAMESPACE` and `REPLACE_EVENTHUB_NAME` in all three tier EventSource files.

### 4. Deploy phase by phase

**Phase 1 — Critical only:**

```bash
kubectl apply -f 01-shared-rbac.yaml
kubectl apply -f 01-kagent-config.yaml
kubectl apply -f tier-critical/eventsource.yaml
kubectl apply -f tier-critical/sensor.yaml
kubectl apply -f tier-critical/workflow-template.yaml
```

**Phase 2 — Add warnings:**

```bash
kubectl apply -f tier-warnings/eventsource.yaml
kubectl apply -f tier-warnings/sensor.yaml
kubectl apply -f tier-warnings/workflow-template.yaml
```

**Phase 3 — Add infra catch-all:**

```bash
kubectl apply -f tier-infra/eventsource.yaml
kubectl apply -f tier-infra/sensor.yaml
kubectl apply -f tier-infra/workflow-template.yaml
```

### 5. Verify each tier

```bash
# Check all three EventSources are connected
kubectl get pods -n argo-events -l app.kubernetes.io/part-of=k8s-event-triage

# Check each EventSource by name
for es in eventhub-critical eventhub-warnings eventhub-infra; do
  echo "--- $es ---"
  kubectl logs -n argo-events -l eventsource-name=$es --tail=5
done

# Check sensors
for s in k8s-triage-critical k8s-triage-warnings k8s-triage-infra; do
  echo "--- $s ---"
  kubectl logs -n argo-events -l sensor-name=$s --tail=5
done

# Check WorkflowTemplates
kubectl get workflowtemplate -n argo-events
```

## Manual Testing

### Test the workflow directly (bypasses EventSource + Sensor)

Save a sample OTLP payload to a file:

```bash
cat > /tmp/sample-otlp.json << 'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"cluster","value":{"stringValue":"my-cluster"}},{"key":"environment","value":{"stringValue":"production"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"{\"type\":\"Warning\",\"reason\":\"CrashLoopBackOff\",\"message\":\"back-off 5m0s restarting failed container=myapp\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"myapp-6f8b9c-x2k4l\",\"namespace\":\"default\"},\"count\":5,\"lastTimestamp\":\"2026-02-20T10:00:00Z\"}"},"attributes":[{"key":"event_type","value":{"stringValue":"Warning"}},{"key":"event_reason","value":{"stringValue":"CrashLoopBackOff"}},{"key":"obj_kind","value":{"stringValue":"Pod"}},{"key":"obj_namespace","value":{"stringValue":"default"}}]},{"body":{"stringValue":"{\"type\":\"Normal\",\"reason\":\"Pulled\",\"message\":\"Successfully pulled image\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"myapp-6f8b9c-x2k4l\",\"namespace\":\"default\"},\"count\":1,\"lastTimestamp\":\"2026-02-20T09:55:00Z\"}"},"attributes":[{"key":"event_type","value":{"stringValue":"Normal"}},{"key":"event_reason","value":{"stringValue":"Pulled"}},{"key":"obj_kind","value":{"stringValue":"Pod"}},{"key":"obj_namespace","value":{"stringValue":"default"}}]}]}]}]}
EOF
```

Submit via `kubectl apply` (more reliable than `argo submit -p` for large JSON):

```bash
cat > /tmp/test-workflow.yaml << WFEOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-otlp-parse-
  namespace: argo-events
spec:
  workflowTemplateRef:
    name: k8s-event-triage
  arguments:
    parameters:
      - name: otlp-payload
        value: '$(cat /tmp/sample-otlp.json)'
WFEOF

kubectl apply -f /tmp/test-workflow.yaml
argo watch -n argo-events @latest
```

**Expected:** parse-otlp extracts 1 Warning event (CrashLoopBackOff), filters out 1 Normal (Pulled), fan-out creates 1 classify-and-alert pod.

For the three-tier version, change `workflowTemplateRef.name` to `k8s-triage-critical`, `k8s-triage-warnings`, or `k8s-triage-infra`.

### Test EventSource connectivity

```bash
# Check EventSource logs for Kafka consumer connection
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=50

# Look for these messages (good):
#   "Sarama consumer group up and running!"
#   "successfully connected to eventbus"

# Look for these messages (bad):
#   "SASL handshake failed"     → wrong connection string
#   "dial tcp: i/o timeout"     → network/firewall issue
#   "x509: certificate"         → TLS CA cert issue
```

## Troubleshooting

### Events arrive in Event Hub but no workflows trigger

Walk through this chain in order. The first thing that's wrong is your problem:

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 1 | EventBus exists | `kubectl get eventbus -n argo-events` | `default` listed |
| 2 | EventSource pod running | `kubectl get pods -n argo-events -l eventsource-name=<NAME>` | Running |
| 3 | EventSource connected | `kubectl logs ... -l eventsource-name=<NAME> --tail=50` | "connected to eventbus" + Kafka messages |
| 4 | Sensor pod running | `kubectl get pods -n argo-events -l sensor-name=<NAME>` | Running |
| 5 | Sensor subscribed | `kubectl logs ... -l sensor-name=<NAME> --tail=50` | "subscribed to eventbus" |
| 6 | **Names match** | Compare sensor YAML ↔ EventSource YAML | See below |
| 7 | Consumer group exists | `az eventhubs eventhub consumer-group list ...` | Listed |
| 8 | RBAC correct | `kubectl auth can-i create workflows -n argo-events --as=system:serviceaccount:argo-events:argo-events-sa` | `yes` |
| 9 | WorkflowTemplate exists | `kubectl get wft -n argo-events` | Listed |

### The naming chain (most common issue)

The sensor references the EventSource by **exact name**. These three values must form a chain:

```yaml
# EventSource
metadata:
  name: eventhub-k8s-events        # ← (A) EventSource name
spec:
  kafka:
    k8s-events:                     # ← (B) Event key name
      ...

# Sensor
spec:
  dependencies:
    - name: k8s-event
      eventSourceName: eventhub-k8s-events  # ← must match (A)
      eventName: k8s-events                 # ← must match (B)
```

If any of these don't match, the sensor silently ignores events. No error.

For the three-tier setup:

| Tier | EventSource name | Sensor `eventSourceName` | Event key | Sensor `eventName` |
|------|-----------------|-------------------------|-----------|-------------------|
| Critical | `eventhub-critical` | `eventhub-critical` | `k8s-events` | `k8s-events` |
| Warnings | `eventhub-warnings` | `eventhub-warnings` | `k8s-events` | `k8s-events` |
| Infra | `eventhub-infra` | `eventhub-infra` | `k8s-events` | `k8s-events` |

### EventSource crashes with "too many open files"

inotify limits too low on cluster nodes. Need >= 512:

```bash
# Check current value on a node
kubectl run inotify-check --rm -it --image=alpine -- cat /proc/sys/fs/inotify/max_user_instances

# Fix (run on each affected node, non-persistent across reboots)
# Option 1: SSH to node
sysctl -w fs.inotify.max_user_instances=512

# Option 2: Via privileged pod targeting a specific node
kubectl run fix-inotify --rm -it \
  --overrides='{"spec":{"nodeName":"NODE-NAME","hostPID":true,"containers":[{"name":"fix","image":"alpine","command":["nsenter","--target","1","--mount","--uts","--ipc","--net","--","sysctl","-w","fs.inotify.max_user_instances=512"],"securityContext":{"privileged":true}}]}}' \
  --image=alpine

# Persistent fix: add to /etc/sysctl.d/99-inotify.conf on each node:
# fs.inotify.max_user_instances=512
```

### EventSource fails with "secret-" volume name error

Empty `caCertSecret.name: ""` causes the controller to generate an invalid RFC 1123 volume name. You must point to a real secret — see Step 2 of deployment.

### EventSource fails with "invalid tls config"

Argo Events requires either `caCertSecret` or `clientCertSecret`+`clientKeySecret` when TLS is enabled. You cannot use `insecureSkipVerify` alone without providing a cert secret.

### SASL handshake failed / authentication error

- The `username` secret value must be exactly `$ConnectionString` (literal string, including the dollar sign)
- The `connection-string` secret value is the full Event Hub connection string
- SAS keys contain `/`, `+`, `=` — use `printf` + `--from-file` instead of `--from-literal` to avoid shell escaping issues

### Workflow runs but parse-otlp outputs empty array

The OTLP structure from your Alloy may differ from expected. Check:

1. Capture a real message: Azure Portal → Event Hub → Process Data → peek at messages
2. Compare against `OTLP-PAYLOAD-REFERENCE.md`
3. Check if the Alloy enrichment labels match what the jq filter expects (`event_type`, `event_reason`, `obj_kind`, `obj_namespace`)

### Manual workflow submit says "empty params"

Don't use `argo submit -p` with large JSON — shell escaping breaks it. Use the `kubectl apply -f` method shown in the Manual Testing section above.

## Alloy (Workload Cluster)

The `alloy/` directory contains everything needed to deploy Alloy on the workload cluster:

```bash
# On the workload cluster
kubectl apply -f alloy/01-namespace.yaml
kubectl apply -f alloy/02-secret.yaml          # Edit connection string first
kubectl apply -f alloy/alloy-config-phase1.yaml # Or phase3 for infra namespaces
kubectl apply -f alloy/03-deployment.yaml
```

Edit `alloy/02-secret.yaml` with your Event Hub connection string, and update the namespace list in the Alloy config to match your target namespaces.

## KAgent A2A Integration

The critical and warnings tiers call KAgent via the A2A protocol for AI-powered analysis. The workflow doesn't know about VLLM models or endpoints — it just calls KAgent, and KAgent routes to the correct VLLM backend based on which agent is configured.

Configuration is in `01-kagent-config.yaml`:

```yaml
data:
  KAGENT_URL: "http://kagent-controller-manager.kagent.svc.cluster.local:8082"
  KAGENT_CRITICAL_AGENT: "sre-triage-agent"    # backed by cloud VLLM
  KAGENT_WARNINGS_AGENT: "sre-triage-agent"    # backed by hosted VLLM
```

Key A2A details:
- Protocol: JSON-RPC 2.0, method `message/send` (NOT `tasks/send`)
- URL pattern: `POST ${KAGENT_URL}/api/a2a/kagent/${AGENT_NAME}/` — **trailing slash is required**
- Response: analysis text in `result.artifacts[0].parts[0].text`
- Namespace anchoring: prompt includes `CRITICAL: use exact namespace "X"` to prevent model hallucination

To use different VLLM backends per tier, deploy separate KAgent agents and update the agent names in the ConfigMap.

## Tested Configuration

| Component | Version / Config |
|-----------|------------------|
| Argo Events | v1.9.6 |
| Argo Workflows | v3.6.4 |
| Event Hub | Standard tier, Kafka protocol |
| Kafka protocol version | 2.1.0 |
| SASL mechanism | PLAIN |
| EventBus | NATS native (default) |
| Alloy | v1.12.2 |
| Workflow images | `badouralix/curl-jq:alpine` (all steps) |
| E2E tested on | proxmox-k8s (K8s v1.31.14, 3 nodes) |
