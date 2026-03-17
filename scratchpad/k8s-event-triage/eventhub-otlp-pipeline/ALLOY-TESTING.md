# Alloy Testing Guide - Verify Events Reach Event Hub

Step-by-step test to verify Alloy picks up K8s events and sends them to Event Hub.

## Quick Checklist

Before testing, verify these common gotchas:

| # | Check | How | Likely your issue? |
|---|-------|-----|-------------------|
| 1 | **Namespace in Alloy config** | See Step 1 | **YES — most common miss** |
| 2 | Alloy pod is running | `kubectl get pods -n monitoring -l app=alloy` | |
| 3 | Alloy is healthy | `kubectl logs -n monitoring -l app=alloy --tail=20` | |
| 4 | RBAC allows event watching | See Step 2 | |
| 5 | Event Hub connection works | See Step 4 | |
| 6 | Dedup filter isn't dropping | See Step 5 | |

---

## Step 1: Check which namespaces Alloy is watching

This is the most common issue. The Alloy config has an explicit namespace list — if your namespace isn't in it, Alloy ignores all events from it.

```bash
# View the live config
kubectl get configmap alloy-config -n monitoring -o jsonpath='{.data.config\.alloy}' | head -40
```

Look for the `namespaces` array in `loki.source.kubernetes_events`:

```
loki.source.kubernetes_events "cluster_events" {
  namespaces = [
    "REPLACE_APP_NAMESPACE_1",    ← is "dgdemo" in this list?
    "REPLACE_APP_NAMESPACE_2",
  ]
```

**If `dgdemo` is not listed, that's your problem.** Fix it:

```bash
# Edit the configmap to add dgdemo
kubectl edit configmap alloy-config -n monitoring
# Add "dgdemo" to the namespaces array

# Restart Alloy to pick up the config change
kubectl rollout restart deployment/alloy -n monitoring
kubectl rollout status deployment/alloy -n monitoring
```

---

## Step 2: Verify Alloy is running and has RBAC

```bash
# Pod running?
kubectl get pods -n monitoring -l app=alloy

# Healthy?
kubectl logs -n monitoring -l app=alloy --tail=30

# RBAC — can Alloy watch events?
kubectl auth can-i watch events --as=system:serviceaccount:monitoring:alloy
# Expected: yes

kubectl auth can-i list events --as=system:serviceaccount:monitoring:alloy
# Expected: yes
```

If RBAC returns `no`, the ClusterRole/ClusterRoleBinding is missing. Apply `alloy/03-deployment.yaml` which includes them.

---

## Step 3: Check Alloy's debug UI

Alloy exposes a web UI with pipeline metrics. Port-forward and check:

```bash
kubectl port-forward -n monitoring svc/alloy 12345:12345
```

Then open in browser:
- **http://localhost:12345/graph** — pipeline graph showing all components and their status
- **http://localhost:12345/-/healthy** — health check (should return 200)
- **http://localhost:12345/-/ready** — readiness check

In the graph view, look for:
- `loki.source.kubernetes_events` — should show events being emitted
- `loki.process.enrich` — should show events passing through (check the drop counter)
- `otelcol.exporter.kafka` — should show events being sent (check for errors)

---

## Step 4: Generate a test event and watch Alloy logs

Open **two terminals**.

**Terminal 1 — Watch Alloy logs:**

```bash
kubectl logs -n monitoring -l app=alloy -f
```

**Terminal 2 — Create a test event:**

```bash
# Make sure the namespace exists
kubectl get ns dgdemo

# Create a pod that will generate a Warning event (ImagePullBackOff)
kubectl run test-bad-image \
  --image=this-image-does-not-exist:v999 \
  -n dgdemo

# Wait 10-30 seconds for K8s to generate Warning events
# Then check:
kubectl get events -n dgdemo --sort-by='.lastTimestamp'
```

You should see events like:
```
Warning   ErrImagePull       ...
Warning   ImagePullBackOff   ...
```

**Back in Terminal 1 (Alloy logs):** look for log lines mentioning the event. If you see nothing, either:
- `dgdemo` is not in the namespace list (Step 1)
- Alloy's log level isn't showing event processing (try setting to `debug` — see below)

**Clean up the test pod:**

```bash
kubectl delete pod test-bad-image -n dgdemo
```

---

## Step 5: Check the dedup filter

The Alloy config drops events where `count >= 2` (dedup). This means:

- **First occurrence** of an event (count=1) → forwarded
- **Subsequent occurrences** (count=2, 3, ...) → dropped

If you're generating events that are repeats of something that already fired, they'll be dropped. The test pod in Step 4 creates fresh events, so this shouldn't be an issue there.

To temporarily **disable the dedup filter** for testing, remove or comment out the `stage.drop` block in the Alloy config:

```bash
kubectl edit configmap alloy-config -n monitoring
```

Comment out:
```
// stage.drop {
//   source              = "event_count"
//   expression          = "^[2-9]|^[1-9][0-9]+"
//   drop_counter_reason = "duplicate_event"
// }
```

Then restart: `kubectl rollout restart deployment/alloy -n monitoring`

Remember to re-enable it after testing.

---

## Step 6: Enable debug logging

If you're not seeing anything useful in Alloy's info-level logs:

```bash
kubectl edit configmap alloy-config -n monitoring
```

Change:
```
logging {
  level  = "debug"    ← was "info"
  format = "logfmt"
}
```

Restart: `kubectl rollout restart deployment/alloy -n monitoring`

Then watch logs again. Debug level will show:
- K8s event watch connections
- Each event being processed through the pipeline stages
- Kafka producer messages being sent (or errors)

**Turn this back to `info` after testing** — debug is very verbose.

---

## Step 7: Verify events reach Event Hub

### Option A: Azure Portal

1. Go to your Event Hub namespace in the Azure Portal
2. Click on the Event Hub (topic) name (e.g., `k8s-events`)
3. Under **Monitoring**, check **Metrics**:
   - **Incoming Messages** — should show a count > 0
   - **Incoming Bytes** — should show data flowing
4. Under **Process Data** → **Explore** → you can peek at actual messages

### Option B: Azure CLI

```bash
# Check Event Hub metrics (last hour)
az monitor metrics list \
  --resource "/subscriptions/YOUR_SUB/resourceGroups/YOUR_RG/providers/Microsoft.EventHub/namespaces/YOUR_NAMESPACE/eventhubs/k8s-events" \
  --metric "IncomingMessages" \
  --interval PT1H \
  --output table
```

### Option C: Read directly with a consumer (temporary test)

```bash
# Quick Python consumer (run from any pod or locally with azure-eventhub package)
pip install azure-eventhub

python3 << 'PYEOF'
from azure.eventhub import EventHubConsumerClient
import json

CONNECTION_STR = "Endpoint=sb://YOUR-NAMESPACE.servicebus.windows.net/;SharedAccessKeyName=...;SharedAccessKey=..."
EVENTHUB_NAME = "k8s-events"

def on_event(partition_context, event):
    body = event.body_as_json()
    print(json.dumps(body, indent=2)[:500])
    partition_context.update_checkpoint()

client = EventHubConsumerClient.from_connection_string(
    CONNECTION_STR, consumer_group="$Default", eventhub_name=EVENTHUB_NAME
)

print("Listening for events (Ctrl+C to stop)...")
with client:
    client.receive(on_event=on_event, starting_position="-1")
PYEOF
```

---

## Step 8: End-to-end test script

Run this all in one go after Alloy is configured with `dgdemo` in the namespace list:

```bash
#!/bin/bash
set -e

NAMESPACE="dgdemo"
ALLOY_NS="monitoring"

echo "=== 1. Checking Alloy is running ==="
kubectl get pods -n $ALLOY_NS -l app=alloy
echo ""

echo "=== 2. Checking namespace '$NAMESPACE' is in Alloy config ==="
if kubectl get configmap alloy-config -n $ALLOY_NS -o jsonpath='{.data.config\.alloy}' | grep -q "$NAMESPACE"; then
  echo "OK: '$NAMESPACE' found in Alloy config"
else
  echo "PROBLEM: '$NAMESPACE' NOT found in Alloy config namespace list"
  echo "Fix: kubectl edit configmap alloy-config -n $ALLOY_NS"
  exit 1
fi
echo ""

echo "=== 3. Creating test pod with bad image ==="
kubectl run alloy-test-event \
  --image=does-not-exist-alloy-test:v999 \
  -n $NAMESPACE 2>/dev/null || true
echo "Waiting 30s for K8s to generate Warning events..."
sleep 30
echo ""

echo "=== 4. Checking K8s events were generated ==="
kubectl get events -n $NAMESPACE --field-selector involvedObject.name=alloy-test-event --sort-by='.lastTimestamp'
echo ""

echo "=== 5. Checking Alloy logs for event processing ==="
echo "Last 20 lines of Alloy logs:"
kubectl logs -n $ALLOY_NS -l app=alloy --tail=20
echo ""

echo "=== 6. Cleanup ==="
kubectl delete pod alloy-test-event -n $NAMESPACE --ignore-not-found
echo ""

echo "=== Done ==="
echo "If no events appeared in Alloy logs:"
echo "  1. Check namespace is in config (step 2)"
echo "  2. Enable debug logging and re-test"
echo "  3. Check Alloy debug UI: kubectl port-forward -n $ALLOY_NS svc/alloy 12345:12345"
```

---

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| No events in Alloy logs | Namespace not in config | Add namespace to `loki.source.kubernetes_events.namespaces` |
| Events picked up but not sent | Kafka connection error | Check `EVENTHUB_CONNECTION_STRING` env var, check Alloy logs for SASL/TLS errors |
| Events sent but count=0 in Event Hub | Wrong broker URL or topic name | Verify `brokers` and `topic` in Alloy config match your Event Hub |
| Only first event arrives, repeats dropped | Dedup filter (`stage.drop`) | Expected behaviour — only count=1 events are forwarded |
| Alloy pod crashlooping | Bad config syntax | Check `kubectl describe pod` and `kubectl logs` for config parse errors |
| RBAC denied | Missing ClusterRole | Apply the ClusterRole + ClusterRoleBinding from `alloy/03-deployment.yaml` |
