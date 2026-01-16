# Inspecting Azure Event Hub Events Without Portal Access

This guide covers CLI and programmatic methods to view, inspect, and debug events in Azure Event Hub when you don't have Azure Portal access.

> **Note**: This guide is for the **Fluent Bit** production implementation.
> These inspection methods work regardless of which sender is used (Fluent Bit, kubernetes-event-exporter, etc.).

## Prerequisites

```bash
# Required tools
az --version          # Azure CLI
pip install azure-eventhub  # Python SDK (optional)

# Set environment variables
export RESOURCE_GROUP="your-rg"
export EVENTHUB_NAMESPACE="k8s-events-hub"
export EVENTHUB_NAME="kube-events"
export CONSUMER_GROUP="argo-events"  # or "$Default"
```

---

## Method 1: Azure CLI Metrics (Quick Health Check)

Check if events are flowing through Event Hub:

```bash
# Get incoming/outgoing message counts (last hour)
az monitor metrics list \
  --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.EventHub/namespaces/${EVENTHUB_NAMESPACE}/eventhubs/${EVENTHUB_NAME}" \
  --metric "IncomingMessages,OutgoingMessages" \
  --interval PT1M \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --output table

# Get message count and size
az monitor metrics list \
  --resource "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.EventHub/namespaces/${EVENTHUB_NAMESPACE}/eventhubs/${EVENTHUB_NAME}" \
  --metric "IncomingBytes,OutgoingBytes,IncomingMessages,OutgoingMessages" \
  --interval PT5M \
  --aggregation Total \
  --output table
```

---

## Method 2: Python Script to Read Events

### Install Dependencies

```bash
pip install azure-eventhub azure-identity
```

### Read Events Script

Create `read-eventhub-events.py`:

```python
#!/usr/bin/env python3
"""
Read events from Azure Event Hub using Workload Identity or Connection String.
"""
import os
import json
import argparse
from datetime import datetime, timedelta, timezone

def read_with_connection_string(connection_string, eventhub_name, consumer_group, max_events, timeout):
    """Read events using connection string authentication."""
    from azure.eventhub import EventHubConsumerClient

    events_received = []

    def on_event(partition_context, event):
        if event:
            event_data = {
                "partition_id": partition_context.partition_id,
                "sequence_number": event.sequence_number,
                "offset": event.offset,
                "enqueued_time": str(event.enqueued_time),
                "body": event.body_as_str()
            }
            events_received.append(event_data)
            print(f"\n{'='*60}")
            print(f"Partition: {partition_context.partition_id}")
            print(f"Sequence: {event.sequence_number}")
            print(f"Time: {event.enqueued_time}")
            print(f"Body:\n{json.dumps(json.loads(event.body_as_str()), indent=2)}")

            if len(events_received) >= max_events:
                raise KeyboardInterrupt("Max events reached")

    client = EventHubConsumerClient.from_connection_string(
        conn_str=connection_string,
        consumer_group=consumer_group,
        eventhub_name=eventhub_name
    )

    print(f"Listening for events on {eventhub_name} (consumer group: {consumer_group})...")
    print(f"Will stop after {max_events} events or {timeout} seconds")
    print("Press Ctrl+C to stop early\n")

    try:
        with client:
            client.receive(
                on_event=on_event,
                starting_position="-1",  # Start from end (latest)
                max_wait_time=timeout
            )
    except KeyboardInterrupt:
        pass

    return events_received


def read_with_workload_identity(fqdn, eventhub_name, consumer_group, max_events, timeout):
    """Read events using Workload Identity (DefaultAzureCredential)."""
    from azure.eventhub import EventHubConsumerClient
    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()
    events_received = []

    def on_event(partition_context, event):
        if event:
            event_data = {
                "partition_id": partition_context.partition_id,
                "sequence_number": event.sequence_number,
                "offset": event.offset,
                "enqueued_time": str(event.enqueued_time),
                "body": event.body_as_str()
            }
            events_received.append(event_data)
            print(f"\n{'='*60}")
            print(f"Partition: {partition_context.partition_id}")
            print(f"Sequence: {event.sequence_number}")
            print(f"Time: {event.enqueued_time}")

            # Try to parse as JSON and pretty print
            try:
                body = json.loads(event.body_as_str())
                print(f"Body:\n{json.dumps(body, indent=2)}")
            except json.JSONDecodeError:
                print(f"Body (raw): {event.body_as_str()}")

            if len(events_received) >= max_events:
                raise KeyboardInterrupt("Max events reached")

    client = EventHubConsumerClient(
        fully_qualified_namespace=fqdn,
        eventhub_name=eventhub_name,
        consumer_group=consumer_group,
        credential=credential
    )

    print(f"Listening for events on {fqdn}/{eventhub_name}")
    print(f"Consumer group: {consumer_group}")
    print(f"Will stop after {max_events} events or {timeout} seconds")
    print("Press Ctrl+C to stop early\n")

    try:
        with client:
            client.receive(
                on_event=on_event,
                starting_position="-1",
                max_wait_time=timeout
            )
    except KeyboardInterrupt:
        pass

    return events_received


def read_from_beginning(connection_string, eventhub_name, consumer_group, max_events):
    """Read events from the beginning of the retention period."""
    from azure.eventhub import EventHubConsumerClient

    events_received = []

    def on_event(partition_context, event):
        if event:
            print(f"\n{'='*60}")
            print(f"Partition: {partition_context.partition_id}")
            print(f"Sequence: {event.sequence_number}")
            print(f"Enqueued: {event.enqueued_time}")

            try:
                body = json.loads(event.body_as_str())
                print(f"Body:\n{json.dumps(body, indent=2)}")
            except json.JSONDecodeError:
                print(f"Body (raw): {event.body_as_str()}")

            events_received.append(event)
            if len(events_received) >= max_events:
                raise KeyboardInterrupt("Max events reached")

    client = EventHubConsumerClient.from_connection_string(
        conn_str=connection_string,
        consumer_group=consumer_group,
        eventhub_name=eventhub_name
    )

    print(f"Reading historical events from beginning...")
    print(f"Will read up to {max_events} events\n")

    try:
        with client:
            client.receive(
                on_event=on_event,
                starting_position="@latest",  # Use "-1" for from beginning
                max_wait_time=30
            )
    except KeyboardInterrupt:
        pass

    print(f"\nTotal events read: {len(events_received)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read events from Azure Event Hub")
    parser.add_argument("--connection-string", "-c", help="Event Hub connection string")
    parser.add_argument("--fqdn", "-f", help="Event Hub FQDN (for Workload Identity)")
    parser.add_argument("--eventhub", "-e", default="kube-events", help="Event Hub name")
    parser.add_argument("--consumer-group", "-g", default="$Default", help="Consumer group")
    parser.add_argument("--max-events", "-m", type=int, default=10, help="Max events to read")
    parser.add_argument("--timeout", "-t", type=int, default=30, help="Timeout in seconds")
    parser.add_argument("--from-beginning", action="store_true", help="Read from beginning")

    args = parser.parse_args()

    if args.connection_string:
        if args.from_beginning:
            read_from_beginning(args.connection_string, args.eventhub, args.consumer_group, args.max_events)
        else:
            read_with_connection_string(args.connection_string, args.eventhub, args.consumer_group, args.max_events, args.timeout)
    elif args.fqdn:
        read_with_workload_identity(args.fqdn, args.eventhub, args.consumer_group, args.max_events, args.timeout)
    else:
        print("Error: Provide either --connection-string or --fqdn")
        parser.print_help()
```

### Usage Examples

```bash
# Using connection string
export EVENTHUB_CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)

python read-eventhub-events.py \
  --connection-string "$EVENTHUB_CONNECTION_STRING" \
  --eventhub "kube-events" \
  --consumer-group "\$Default" \
  --max-events 5 \
  --timeout 60

# Using Workload Identity (when running in AKS pod)
python read-eventhub-events.py \
  --fqdn "${EVENTHUB_NAMESPACE}.servicebus.windows.net" \
  --eventhub "kube-events" \
  --max-events 10
```

---

## Method 3: Run Event Reader as Kubernetes Job

Deploy a temporary pod to read events from within the cluster:

```yaml
# eventhub-reader-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: eventhub-reader
  namespace: argo-events
spec:
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: eventsource-eventhub-sa  # Use existing SA with permissions
      restartPolicy: Never
      containers:
      - name: reader
        image: python:3.11-slim
        env:
        - name: EVENTHUB_FQDN
          value: "k8s-events-hub.servicebus.windows.net"
        - name: EVENTHUB_NAME
          value: "kube-events"
        - name: CONSUMER_GROUP
          value: "$Default"
        command:
        - /bin/bash
        - -c
        - |
          pip install -q azure-eventhub azure-identity
          python3 << 'EOF'
          import os
          import json
          from azure.eventhub import EventHubConsumerClient
          from azure.identity import DefaultAzureCredential

          fqdn = os.environ["EVENTHUB_FQDN"]
          hub = os.environ["EVENTHUB_NAME"]
          cg = os.environ["CONSUMER_GROUP"]

          credential = DefaultAzureCredential()
          client = EventHubConsumerClient(
              fully_qualified_namespace=fqdn,
              eventhub_name=hub,
              consumer_group=cg,
              credential=credential
          )

          count = 0
          def on_event(ctx, event):
              global count
              if event:
                  count += 1
                  print(f"\n{'='*60}")
                  print(f"Event #{count} | Partition: {ctx.partition_id}")
                  print(f"Sequence: {event.sequence_number} | Time: {event.enqueued_time}")
                  try:
                      body = json.loads(event.body_as_str())
                      print(json.dumps(body, indent=2))
                  except:
                      print(event.body_as_str())
                  if count >= 10:
                      raise KeyboardInterrupt()

          print(f"Reading from {fqdn}/{hub}...")
          try:
              with client:
                  client.receive(on_event=on_event, starting_position="-1", max_wait_time=30)
          except KeyboardInterrupt:
              pass
          print(f"\nTotal events: {count}")
          EOF
```

```bash
# Deploy and watch
kubectl apply -f eventhub-reader-job.yaml
kubectl logs -n argo-events job/eventhub-reader -f

# Cleanup
kubectl delete job eventhub-reader -n argo-events
```

---

## Method 4: Inspect Events via Argo Events Logs

If events are flowing, you can see them in the EventSource and Sensor logs:

```bash
# EventSource logs show raw events received
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=100 | grep -A 20 "received"

# Sensor logs show events being processed
kubectl logs -n argo-events -l sensor-name=eventhub-production-alerts --tail=100

# Get the actual event data from sensor (look for "body" field)
kubectl logs -n argo-events -l sensor-name=eventhub-production-alerts --tail=200 | grep -E '"body"|"reason"|"cluster"'
```

---

## Method 5: Azure CLI - Get Connection String

```bash
# Get primary connection string (requires namespace-level access)
az eventhubs namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv

# Get Event Hub specific connection string (if configured)
az eventhubs eventhub authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name <rule-name> \
  --query primaryConnectionString -o tsv

# List available authorization rules
az eventhubs namespace authorization-rule list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --output table
```

---

## Method 6: Quick Bash One-Liner with Docker

```bash
# Run Python event reader in Docker (no local Python needed)
docker run --rm -it \
  -e CONN_STR="$EVENTHUB_CONNECTION_STRING" \
  python:3.11-slim bash -c '
    pip install -q azure-eventhub && python3 << EOF
import os, json
from azure.eventhub import EventHubConsumerClient

def on_event(ctx, event):
    if event:
        print(f"Partition {ctx.partition_id}: {event.body_as_str()[:200]}...")

client = EventHubConsumerClient.from_connection_string(
    os.environ["CONN_STR"],
    consumer_group="\$Default",
    eventhub_name="kube-events"
)
print("Waiting for events (30s timeout)...")
with client:
    client.receive(on_event=on_event, starting_position="-1", max_wait_time=30)
EOF'
```

---

## Method 7: Event Hub Partition Info

```bash
# Get partition information
az eventhubs eventhub show \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --name $EVENTHUB_NAME \
  --query "{partitions:partitionCount,retention:messageRetentionInDays,status:status}"

# List consumer groups
az eventhubs eventhub consumer-group list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --output table
```

---

## Decoding Base64 Event Payloads

Azure Event Hub wraps messages. To decode:

```bash
# If you capture a base64 body from logs:
echo 'eyJjbHVzdGVyIjoiYWtzLXByb2QiLCJyZWFzb24iOiJCYWNrT2ZmIn0=' | base64 -d | jq .

# From sensor logs, extract and decode:
kubectl logs -n argo-events -l sensor-name=eventhub-production-alerts --tail=50 \
  | grep '"body"' \
  | sed 's/.*"body":"\([^"]*\)".*/\1/' \
  | head -1 \
  | base64 -d | jq .
```

---

## Troubleshooting

### No Events Showing

```bash
# 1. Check if events are being sent (metrics)
az monitor metrics list \
  --resource "/subscriptions/$(az account show -o tsv --query id)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.EventHub/namespaces/${EVENTHUB_NAMESPACE}/eventhubs/${EVENTHUB_NAME}" \
  --metric "IncomingMessages" \
  --interval PT1M --output table

# 2a. Check Fluent Bit is running and sending (CURRENT)
kubectl get pods -n monitoring -l app=fluent-bit
kubectl logs -n monitoring -l app=fluent-bit --tail=50
kubectl logs -n monitoring -l app=fluent-bit --tail=100 | grep -iE "kafka|error|warn|broker"

# 2b. Check event exporter is running (LEGACY - if still using kubernetes-event-exporter)
kubectl logs -n monitoring -l app=event-exporter --tail=50

# 3. Verify consumer group exists
az eventhubs eventhub consumer-group show \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $EVENTHUB_NAMESPACE \
  --eventhub-name $EVENTHUB_NAME \
  --name "argo-events"

# 4. Check External Secret is syncing (Fluent Bit setup)
kubectl get externalsecret -n monitoring
kubectl describe externalsecret eventhub-sas-secret -n monitoring
```

### Authentication Errors

```bash
# Check Workload Identity is configured
kubectl get sa -n argo-events eventsource-eventhub-sa -o yaml | grep -A5 annotations

# Verify managed identity has correct role
az role assignment list \
  --assignee <managed-identity-client-id> \
  --scope "/subscriptions/<sub>/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.EventHub/namespaces/${EVENTHUB_NAMESPACE}" \
  --output table
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Check message count | `az monitor metrics list --metric IncomingMessages ...` |
| Get connection string | `az eventhubs namespace authorization-rule keys list ...` |
| Read events (Python) | `python read-eventhub-events.py -c "$CONN_STR" -m 10` |
| Read events (K8s Job) | `kubectl apply -f eventhub-reader-job.yaml` |
| View in sensor logs | `kubectl logs -l sensor-name=... \| grep body` |
| Decode base64 payload | `echo '<payload>' \| base64 -d \| jq .` |
| List consumer groups | `az eventhubs eventhub consumer-group list ...` |
| **Fluent Bit logs** | `kubectl logs -n monitoring -l app=fluent-bit` |
| **Fluent Bit Kafka status** | `kubectl logs -n monitoring -l app=fluent-bit \| grep kafka` |
| **External Secret status** | `kubectl get externalsecret -n monitoring` |
