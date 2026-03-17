# Troubleshooting — Critical Tier Workflow

Commands for debugging the `k8s-triage-critical` workflow when things aren't working as expected.

---

## 1. Check What's Running

```bash
# List recent workflows (newest first)
argo list -n argo-events --sort-by=.metadata.creationTimestamp | head

# Watch workflows being created in real time
argo list -n argo-events --watch

# Detailed step status for latest workflow
argo get -n argo-events @latest

# Or for a specific workflow
argo get -n argo-events <workflow-name>
```

---

## 2. Check parse-otlp Output

This is the first thing to check when fan-out isn't working. Shows exactly what events were extracted and what agents they were routed to.

```bash
# What did parse-otlp produce? (events array + count)
argo get -n argo-events @latest -o json | jq '
  .status.nodes[] | select(.displayName == "parse-otlp") |
  {phase: .phase, event_count: .outputs.parameters[1].value, events: (.outputs.parameters[0].value | fromjson)}
'

# Just the raw events array
argo get -n argo-events @latest -o json | jq '
  .status.nodes[] | select(.displayName == "parse-otlp") |
  .outputs.parameters[0].value | fromjson
'

# Just event count
argo get -n argo-events @latest -o json | jq '
  .status.nodes[] | select(.displayName == "parse-otlp") |
  .outputs.parameters[] | select(.name == "event-count") | .value
'
```

### What to look for

- **Events array is `[]` (empty)**: The OTLP payload had no Warning events with critical reasons. Check the payload structure (see section 5).
- **Events array has items but `{{item.cluster}}` not resolving**: The output isn't valid JSON. Check parse-otlp logs for jq errors.
- **Event count matches expectations**: If you sent 3 critical events, you should see 3 in the array.

---

## 3. Check Pod Logs

With `podGC.strategy: OnWorkflowCompletion`, pods persist until the workflow finishes. Use `kubectl logs` while the workflow is running or just after.

```bash
# Find pods for a specific workflow
kubectl get pods -n argo-events -l workflows.argoproj.io/workflow=<workflow-name>

# Logs for all pods in latest workflow
WORKFLOW=$(argo list -n argo-events -o name | head -1)
kubectl logs -n argo-events -l workflows.argoproj.io/workflow=$WORKFLOW -c main --prefix

# Logs for a specific step (by pod name from argo get output)
kubectl logs -n argo-events <pod-name> -c main

# If pods are already gone, try argo logs (captures from controller)
argo logs -n argo-events @latest
argo logs -n argo-events <workflow-name>
```

---

## 4. Check Each Step

### validate-kagent

```bash
# Did KAgent health check pass?
argo get -n argo-events @latest -o json | jq '
  .status.nodes[] | select(.displayName == "validate-kagent") | {phase, message}
'
```

If this fails, KAgent controller is unreachable. Check:
```bash
# Is the ConfigMap set?
kubectl get configmap kagent-config -n argo-events -o yaml

# Can you reach KAgent from the cluster?
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -s http://kagent-a2a.kagent.svc.cluster.local/api/agents
```

### investigate-and-report

```bash
# Check a specific process-event pod for KAgent/GitLab/Mattermost results
# Get the pod name from argo get output, then:
kubectl logs -n argo-events <process-event-pod> -c main
```

What to look for in the logs:
```
# KAgent working:
Calling KAgent: sre-triage-agent via A2A...
KAgent HTTP: 200, Duration: 55s

# KAgent failing:
KAgent call failed (HTTP 400)
Response body: {"error": "..."}

# GitLab working:
Creating GitLab issue...
GitLab HTTP: 201
Issue #42: https://gitlab.com/...

# GitLab skipped:
GitLab not configured, skipping issue creation

# Mattermost working:
Mattermost: HTTP 200

# Mattermost failing:
Mattermost: HTTP 400
Mattermost error response: ...
Payload size: 1234 bytes
```

---

## 5. Inspect the Raw OTLP Payload

If parse-otlp is producing unexpected results, check what the sensor actually passed to the workflow.

```bash
# Get the otlp-payload parameter value (the raw input)
argo get -n argo-events @latest -o json | jq -r '
  .spec.arguments.parameters[] | select(.name == "otlp-payload") | .value
' | jq .

# Check if it's valid JSON
argo get -n argo-events @latest -o json | jq -r '
  .spec.arguments.parameters[] | select(.name == "otlp-payload") | .value
' | jq empty && echo "Valid JSON" || echo "INVALID JSON"

# Count logRecords in the payload
argo get -n argo-events @latest -o json | jq -r '
  .spec.arguments.parameters[] | select(.name == "otlp-payload") | .value
' | jq '[.resourceLogs[]?.scopeLogs[]?.logRecords[]?] | length'

# Show all events with their type and reason (before filtering)
argo get -n argo-events @latest -o json | jq -r '
  .spec.arguments.parameters[] | select(.name == "otlp-payload") | .value
' | jq '
  [.resourceLogs[]? |
   .scopeLogs[]?.logRecords[]? |
   (.attributes // [] | [.[]? | {(.key): .value.stringValue}] | add // {}) as $a |
   (.body.stringValue // "" | if . != "" then (fromjson? // {}) else {} end) as $ev |
   {
     type: ($a.event_type // $ev.type // "?"),
     reason: ($a.event_reason // $ev.reason // "?"),
     namespace: ($a.obj_namespace // $ev.involvedObject.namespace // "?"),
     name: ($ev.involvedObject.name // "?")
   }
  ]
'
```

### Expected OTLP structure from Alloy

```
resourceLogs[].scopeLogs[].logRecords[]
  ├── body.stringValue = raw K8s event JSON (as string)
  └── attributes[] = Loki labels:
        event_type, event_reason, obj_kind, obj_namespace,
        cluster, environment, region, source
```

If attributes are in `resource.attributes` instead of `logRecord.attributes`, the jq parser handles both via fallback chain.

---

## 6. Check Sensor and EventSource

```bash
# Is the EventSource running and connected to Event Hub?
kubectl get eventsource -n argo-events
kubectl logs -n argo-events -l eventsource-name=<eventsource-name> --tail=20

# Is the Sensor running and triggering workflows?
kubectl get sensor -n argo-events
kubectl logs -n argo-events -l sensor-name=<sensor-name> --tail=20

# Check EventBus
kubectl get eventbus -n argo-events
```

---

## 7. Check ConfigMaps and Secrets

```bash
# KAgent connection
kubectl get configmap kagent-config -n argo-events -o yaml

# Agent routing table
kubectl get configmap agent-routing -n argo-events -o yaml

# Mattermost webhook
kubectl get configmap mattermost-webhook-config -n argo-events -o yaml

# GitLab token (check key name matches GITLAB_TOKEN)
kubectl get secret gitlab-token -n argo-events -o jsonpath='{.data}' | jq 'keys'

# Decode GitLab token to verify it's set (careful — prints the token)
# kubectl get secret gitlab-token -n argo-events -o jsonpath='{.data.GITLAB_TOKEN}' | base64 -d
```

---

## 8. Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `parse-otlp` fails | jq can't parse OTLP payload | Check raw payload (section 5) — may not be valid JSON |
| 0 events extracted | No Warning events with critical reasons | Check payload has `type: "Warning"` and a critical reason |
| `{{item.cluster}}` not resolving | parse-otlp output not valid JSON array | Check parse-otlp logs for jq errors |
| process-event not created | Empty events array `[]` | parse-otlp filtered everything out — check reasons match critical list |
| KAgent HTTP 400 | Bad A2A request format | Check `kind: "text"` in parts, check agent name exists |
| KAgent timeout | Agent unreachable or slow | Check KAGENT_URL, verify service: `kubectl get svc -n kagent` |
| GitLab skipped | Token or project ID missing | Check secret key is `GITLAB_TOKEN`, check `gitlab-project-id` param |
| GitLab 401 | Bad token or wrong project | Verify token scope and project access |
| Mattermost 400 | Payload issue | Check error response in logs (now logged), check payload size |
| Pods disappear before checking logs | podGC cleaning up | Currently set to `OnWorkflowCompletion` — check quickly after workflow ends |
| Sensor not triggering | EventSource not connected | Check EventSource logs for Kafka consumer errors |

---

## 9. Cleanup

```bash
# Delete test workflows
argo delete -n argo-events --selector workflows.argoproj.io/workflow-template=k8s-triage-critical

# Delete all completed workflows
argo delete -n argo-events --completed

# Delete a specific workflow
argo delete -n argo-events <workflow-name>
```
