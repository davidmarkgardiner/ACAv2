# K8s Event Triage — Working Configuration

**Tested:** 2026-03-12 on `aks-event-triage-dev` (AKS, K8s 1.32.11, UK South)
**Status:** End-to-end proven — Alloy -> Event Hub -> Argo Events -> Workflow

## Messaging Strategy

Azure Event Hub (Kafka-enabled) is the **tactical solution** for the event bus layer. It was selected for speed of delivery — it's a managed service with native AKS integration and zero operational overhead.

**Strategically**, the intent is to move to a dedicated Kafka deployment (e.g. Confluent, Strimzi, or Azure Event Hubs Premium with full Kafka API parity). This gives us:
- Full Kafka consumer group semantics (offsets, rebalancing, compaction)
- Topic-level retention policies and replay
- Schema Registry for event contracts
- Multi-consumer fan-out without Event Hub partition limits

The pipeline is designed for this swap — Alloy's `otelcol.exporter.kafka` and the Argo Events Kafka EventSource both speak standard Kafka protocol. Migrating means changing broker URLs, auth credentials, and TLS config. No pipeline logic changes required.

## Architecture

```
K8s Warning Events (default namespace)
    |
    v
[Grafana Alloy v1.12.2]  (monitoring namespace)
    | loki.source.kubernetes_events -> otelcol.exporter.kafka
    | OTLP JSON encoding, SASL_SSL auth
    v
[Azure Event Hub: k8s-events topic]  (evhns-event-triage-dev, Standard tier, Kafka enabled)
    |
    v
[Argo Events: Kafka EventSource]  (argo-events namespace)
    | Consumes via Kafka protocol, consumer group v4
    v
[Argo Events: JetStream EventBus]  (NATS 2.10.10)
    |
    v
[Argo Events: Sensor]  (rate limited 5/min)
    |
    v
[Argo Workflow: k8s-event-triage]  (parse event, log it)
    |
    +-- In production: add LLM triage + GitLab issue creation steps
```

## Prerequisites

- AKS cluster (Standard_B4ms or similar, 2+ nodes)
- Azure Event Hub Standard or Premium tier (Basic does NOT support Kafka)
- Argo Events v1.9.x installed (`kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml`)
- Argo Workflows v3.5+ installed

## Deployment Steps

### Step 1: Create Namespaces

```bash
kubectl apply -f 01-namespaces.yaml
```

### Step 2: Install Argo Events + Argo Workflows

```bash
# Argo Events (pin to v1.9.10 — do NOT use 'stable' floating tag)
kubectl apply -n argo-events -f https://raw.githubusercontent.com/argoproj/argo-events/v1.9.10/manifests/install.yaml

# Argo Workflows
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.6.4/install.yaml

# Wait for controllers
kubectl wait --for=condition=available --timeout=120s deployment/controller-manager -n argo-events
kubectl wait --for=condition=available --timeout=120s deployment/workflow-controller -n argo
```

### Step 3: Create Secrets

Three secrets are needed. When migrating to a dedicated Kafka broker, update these — no pipeline changes required.

| Secret | Namespace | Keys | Purpose |
|--------|-----------|------|---------|
| `alloy-eventhub` | `monitoring` | `connection-string` | SAS/Kafka connection string for Alloy producer |
| `eventhub-credentials` | `argo-events` | `username`, `connection-string` | SASL_PLAIN auth for EventSource Kafka consumer. `username` is always the literal `$ConnectionString` for Event Hub SAS auth |
| `eventhub-tls-ca` | `argo-events` | `ca.pem` | TLS CA chain for broker endpoint. Required by Argo Events v1.9.x even for public CAs |

```bash
# Event Hub connection string for Alloy (monitoring namespace)
kubectl create secret generic alloy-eventhub -n monitoring \
  --from-literal=connection-string='Endpoint=sb://<EVENTHUB_NAMESPACE>.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...'

# Event Hub credentials for EventSource (argo-events namespace)
# username is always the literal "$ConnectionString" — this tells Event Hub you're using a SAS token
# connection-string is your SAS connection string (the password)
kubectl create secret generic eventhub-credentials -n argo-events \
  --from-literal=username='$ConnectionString' \
  --from-literal=connection-string='Endpoint=sb://<EVENTHUB_NAMESPACE>.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=...'

# TLS CA certificate — required by Argo Events v1.9.x (tls: {} fails validation)
# Generate once per Event Hub namespace, cert rarely changes:
echo | openssl s_client -connect <EVENTHUB_NAMESPACE>.servicebus.windows.net:9093 \
  -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > /tmp/eventhub-ca-chain.pem

kubectl create secret generic eventhub-tls-ca -n argo-events \
  --from-file=ca.pem=/tmp/eventhub-ca-chain.pem
```

### Step 4: Deploy EventBus

```bash
kubectl apply -f 04-eventbus.yaml

# Wait for JetStream to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=eventbus-default-js -n argo-events --timeout=120s
```

### Step 5: Deploy RBAC

```bash
kubectl apply -f 06-rbac.yaml
```

### Step 6: Deploy WorkflowTemplate

```bash
kubectl apply -f 07-workflow-template.yaml
```

### Step 7: Deploy Alloy

Edit `03-alloy.yaml` and replace ALL placeholders:

| Placeholder | Example Value |
|------------|---------------|
| `REPLACE_CLUSTER_NAME` | `aks-event-triage-dev` |
| `REPLACE_ENVIRONMENT` | `dev` |
| `REPLACE_AZURE_REGION` | `uksouth` |
| `REPLACE_EVENTHUB_NAMESPACE` | `evhns-event-triage-dev` |
| `REPLACE_EVENTHUB_NAME` | `k8s-events` |

```bash
# Apply with sed replacement (or edit manually)
sed -e 's/REPLACE_CLUSTER_NAME/aks-event-triage-dev/g' \
    -e 's/REPLACE_ENVIRONMENT/dev/g' \
    -e 's/REPLACE_AZURE_REGION/uksouth/g' \
    -e 's/REPLACE_EVENTHUB_NAMESPACE/evhns-event-triage-dev/g' \
    -e 's/REPLACE_EVENTHUB_NAME/k8s-events/g' \
    03-alloy.yaml | kubectl apply -f -
```

### Step 8: Deploy EventSource

Edit `05-eventsource.yaml` and replace placeholders:

| Placeholder | Example Value |
|------------|---------------|
| `REPLACE_EVENTHUB_NAMESPACE` | `evhns-event-triage-dev` |
| `REPLACE_EVENTHUB_NAME` | `k8s-events` |
| `REPLACE_CONSUMER_GROUP` | `argo-events-consumer-v4` |

```bash
sed -e 's/REPLACE_EVENTHUB_NAMESPACE/evhns-event-triage-dev/g' \
    -e 's/REPLACE_EVENTHUB_NAME/k8s-events/g' \
    -e 's/REPLACE_CONSUMER_GROUP/argo-events-consumer-v4/g' \
    05-eventsource.yaml | kubectl apply -f -
```

### Step 9: Deploy Sensor

```bash
kubectl apply -f 08-sensor.yaml
```

### Step 10: Verify

```bash
# All pods should be Running
kubectl get pods -n argo-events
kubectl get pods -n monitoring

# EventSource should show "Sarama consumer group up and running"
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=5

# Sensor should show "Subscribing to subject"
kubectl logs -n argo-events -l sensor-name=k8s-event-triage --tail=5
```

### Step 11: Test

```bash
# Create a pod with a bad image to generate Warning events
kubectl run test-warning --image=nginx:does-not-exist --restart=Never -n default

# Wait 30 seconds, then check for workflows
kubectl get workflows -n argo-events

# Should see k8s-triage-xxxxx workflows with STATUS=Succeeded

# Clean up test
kubectl delete pod test-warning -n default
```

## File Inventory

| File | Purpose |
|------|---------|
| `01-namespaces.yaml` | argo, argo-events, monitoring namespaces |
| `02-secrets.yaml` | Secret templates (DO NOT apply directly — use kubectl create) |
| `03-alloy.yaml` | Alloy ConfigMap + Deployment + RBAC + Service |
| `04-eventbus.yaml` | Native NATS EventBus (switched from JetStream — see GOTCHAS #13) |
| `05-eventsource.yaml` | Kafka EventSource (Event Hub consumer) |
| `06-rbac.yaml` | Service accounts and roles |
| `07-workflow-template.yaml` | Simple parse-and-log workflow (PoC) |
| `08-sensor.yaml` | Event -> Workflow routing with rate limiting |
| `09-workflow-template-llm.yaml` | Enhanced DAG workflow: parse-and-log -> LLM triage (Ollama qwen2.5:7b) |
| `10-gitea-issue-step.yaml` | Gitea issue creation step (conditional on LLM triage output) |
| `11-gitea-credentials-secret.yaml` | Gitea credentials secret template + label bootstrap Job |
| `helm-values-argo-events.yaml` | Helm values for private registry image overrides |
| `PRIVATE-REGISTRY.md` | Full guide: import images to ACR, deploy with Helm, verify |
| `TEARDOWN.md` | Full teardown guide — reverse dependency order, stuck resource fixes |
| `PRODUCTION-PLAN.md` | Full production deployment plan (7 phases, scaling, monitoring, rollback) |

## Production Enhancements

The following manifests implement production enhancements. See `PRODUCTION-PLAN.md` for the full deployment plan.

### 1. LLM Triage Step
Add a step after `parse-and-log` that calls an LLM (Ollama/OpenAI) to classify severity and recommend remediation.

### 2. GitLab Issue Creation
Add a conditional step that creates a GitLab/Gitea issue for critical/warning events:
```yaml
- name: create-gitlab-issue
  when: "{{steps.llm-triage.outputs.parameters.create-issue}} == true"
  script:
    image: badouralix/curl-jq:alpine
    command: [sh]
    env:
      - name: GITLAB_URL
        valueFrom:
          secretKeyRef:
            name: gitlab-credentials
            key: url
      - name: GITLAB_TOKEN
        valueFrom:
          secretKeyRef:
            name: gitlab-credentials
            key: token
      - name: GITLAB_PROJECT_ID
        valueFrom:
          secretKeyRef:
            name: gitlab-credentials
            key: project-id
    source: |
      TITLE="[K8S-TRIAGE] {{steps.parse-and-log.outputs.parameters.reason}}: {{steps.parse-and-log.outputs.parameters.name}}"
      BODY="## K8s Event Triage\n\n**Cluster:** {{workflow.parameters.cluster}}\n**Event:** {{steps.parse-and-log.outputs.parameters.reason}}"

      jq -n --arg title "$TITLE" --arg body "$BODY" \
        '{title: $title, description: $body, labels: "triage,k8s-event"}' | \
      curl -s -X POST "$GITLAB_URL/api/v4/projects/$GITLAB_PROJECT_ID/issues" \
        -H "Content-Type: application/json" \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -d @-
```

### 3. Notification (Mattermost/Telegram)
Add a webhook notification step for real-time alerting.

### 4. More Namespaces
Expand the Alloy `namespaces` list in `03-alloy.yaml` to include your application namespaces. Never include `argo`, `argo-events`, `monitoring`, or `kube-system` to prevent feedback loops.

## Troubleshooting

### EventSource can't connect to Event Hub
- Check secret key names: must be `username` and `connection-string` (exact names matter)
- `username` value must be the literal string `$ConnectionString` (not your actual username)
- Verify Event Hub is Standard/Premium tier (Basic doesn't support Kafka)
- If TLS errors occur, you may need a custom CA cert (see GOTCHAS.md #10) but this is rare

### Workflow storm (too many workflows)
- Delete and recreate the Event Hub topic to clear backlog
- Use a fresh consumer group name
- Rate limit in Sensor (currently 5/min)

### EventBus stuck deleting
- Remove the EventSource first, then patch out the finalizer:
  ```bash
  kubectl delete eventsource <name> -n argo-events
  kubectl patch eventbus default -n argo-events --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```

### EventBus pods stuck in ImagePullBackOff (private registry)
- The controller ignores CR-level image overrides for sidecars — see GOTCHAS.md #12
- **Fix:** Use `helm-values-argo-events.yaml` to override images at the Helm level
- See `PRIVATE-REGISTRY.md` for the complete guide

### Alloy not forwarding events
- Check Alloy logs: `kubectl logs -n monitoring deploy/alloy`
- "no involved object for event" errors are harmless (malformed K8s events)
- Verify the namespace list includes your target namespace
