# Troubleshooting: Workflows Not Being Triggered

Use this guide when EventSource and Sensor are deployed but no workflows are being created.

## Quick Diagnosis Checklist

Run these commands in order to identify where the pipeline is broken:

```bash
# Set namespace
NS=argo-events

# 1. Check all components are running
echo "=== 1. COMPONENT STATUS ==="
kubectl get eventbus,eventsource,sensor -n $NS

# 2. Check pods are healthy
echo -e "\n=== 2. POD STATUS ==="
kubectl get pods -n $NS

# 3. Check for recent workflows
echo -e "\n=== 3. RECENT WORKFLOWS ==="
kubectl get workflows -n $NS --sort-by=.metadata.creationTimestamp | tail -10

# 4. Check EventBus status
echo -e "\n=== 4. EVENTBUS STATUS ==="
kubectl get eventbus default -n $NS -o jsonpath='{.status.conditions[*].type}{"\n"}'
```

---

## Step-by-Step Debugging

### 1. Check EventBus (CRITICAL - Often Missed!)

**The EventBus is required for EventSource → Sensor communication.**

```bash
# Check EventBus exists and is healthy
kubectl get eventbus -n argo-events

# Should show: default   Running
# If missing, apply:
kubectl apply -f 02a-mgmt-cluster-rbac.yaml

# Check EventBus pods
kubectl get pods -n argo-events -l controller=eventbus-controller
kubectl get pods -n argo-events -l eventbus-name=default

# Check EventBus logs
kubectl logs -n argo-events -l eventbus-name=default --tail=50
```

**Common issue:** EventBus not deployed = Sensor never receives events.

---

### 2. Check EventSource

```bash
# Status
kubectl get eventsource -n argo-events
kubectl describe eventsource eventhub-k8s-events -n argo-events

# Check conditions
kubectl get eventsource eventhub-k8s-events -n argo-events -o jsonpath='{.status.conditions[*]}' | jq .

# EventSource pod logs (shows if connecting to Event Hub)
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=100

# Look for:
# - "connected to event hub" = good
# - "failed to connect" = auth issue
# - "received event" = events are flowing
```

**Check the secret exists:**
```bash
kubectl get secret eventhub-listener-secret -n argo-events
kubectl get secret eventhub-listener-secret -n argo-events -o jsonpath='{.data}' | jq .

# Verify secret has correct keys
kubectl get secret eventhub-listener-secret -n argo-events -o jsonpath='{.data.sharedAccessKeyName}' | base64 -d
kubectl get secret eventhub-listener-secret -n argo-events -o jsonpath='{.data.sharedAccessKey}' | base64 -d | head -c 20
```

---

### 3. Check Sensor

```bash
# Status
kubectl get sensor -n argo-events
kubectl describe sensor fluent-bit-gitlab-issues -n argo-events

# Check conditions
kubectl get sensor fluent-bit-gitlab-issues -n argo-events -o jsonpath='{.status.conditions[*]}' | jq .

# Sensor pod logs (shows if receiving events and triggering)
kubectl logs -n argo-events -l sensor-name=fluent-bit-gitlab-issues --tail=100

# Look for:
# - "received event" = sensor is getting events
# - "triggering workflow" = about to create workflow
# - "failed to trigger" = RBAC or template issue
# - "error" = check the error message
```

---

### 4. Check RBAC / ServiceAccount

```bash
# Check ServiceAccount exists
kubectl get sa argo-events-sa -n argo-events

# Check RoleBinding
kubectl get rolebinding -n argo-events | grep argo-events

# Check if SA can create workflows
kubectl auth can-i create workflows --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# Should return: yes

# Check if SA can use WorkflowTemplates
kubectl auth can-i get workflowtemplates --as=system:serviceaccount:argo-events:argo-events-sa -n argo-events
# Should return: yes
```

**If "no" - apply RBAC:**
```bash
kubectl apply -f 02a-mgmt-cluster-rbac.yaml
```

---

### 5. Check WorkflowTemplate Exists

```bash
# The sensor references this template
kubectl get workflowtemplate multi-cluster-triage -n argo-events

# If missing:
kubectl apply -f ../workflow-multi-cluster-triage.yaml
```

---

### 6. Check Events Are Actually Arriving

**Generate a test event on the source cluster:**
```bash
# On SOURCE cluster (where Fluent Bit runs)
kubectl run test-trigger --image=invalid:nonexistent --restart=Never
sleep 5
kubectl delete pod test-trigger --ignore-not-found
```

**Check Fluent Bit picked it up:**
```bash
# On SOURCE cluster
kubectl logs -n monitoring -l app=fluent-bit --tail=30 | grep -i "test-trigger\|warning\|backoff"
```

**Check Event Hub metrics (without portal):**
```bash
az monitor metrics list \
  --resource "/subscriptions/$(az account show -o tsv --query id)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.EventHub/namespaces/$EVENTHUB_NAMESPACE/eventhubs/$EVENTHUB_NAME" \
  --metric "IncomingMessages" \
  --interval PT1M --output table
```

---

### 7. Check EventSource is Receiving from Event Hub

```bash
# Look for messages received
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=100 | grep -iE "message|received|event|dispatch"

# Check for errors
kubectl logs -n argo-events -l eventsource-name=eventhub-k8s-events --tail=100 | grep -iE "error|fail|timeout|auth"
```

---

### 8. Check Sensor is Receiving from EventSource

```bash
# Look for dependency resolution
kubectl logs -n argo-events -l sensor-name=fluent-bit-gitlab-issues --tail=100 | grep -iE "dependency|trigger|workflow|received"

# Check for template errors (common issue!)
kubectl logs -n argo-events -l sensor-name=fluent-bit-gitlab-issues --tail=100 | grep -iE "error|template|b64dec|mustFromJson"
```

**Common template errors:**
- `b64dec` fails = Event Hub payload format different than expected
- `mustFromJson` fails = JSON parsing error in payload
- `dig` returns empty = Field path incorrect

---

## Common Issues and Fixes

### Issue 1: EventBus Not Running
```
Symptom: Sensor shows "Conditions: []" or pods not running
Fix: kubectl apply -f 02a-mgmt-cluster-rbac.yaml (includes EventBus)
```

### Issue 2: Secret Missing or Wrong Format
```
Symptom: EventSource logs show "authentication failed"
Fix:
  kubectl delete secret eventhub-listener-secret -n argo-events
  kubectl create secret generic eventhub-listener-secret \
    --namespace argo-events \
    --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \
    --from-literal=sharedAccessKey="<your-key>"
```

### Issue 3: RBAC Missing
```
Symptom: Sensor logs show "forbidden" or "cannot create workflows"
Fix: kubectl apply -f 02a-mgmt-cluster-rbac.yaml
```

### Issue 4: WorkflowTemplate Missing
```
Symptom: Sensor logs show "workflowtemplate not found"
Fix: kubectl apply -f ../workflow-multi-cluster-triage.yaml
```

### Issue 5: Consumer Group Doesn't Exist
```
Symptom: EventSource logs show "consumer group not found"
Fix:
  az eventhubs eventhub consumer-group create \
    --resource-group $RESOURCE_GROUP \
    --namespace-name $EVENTHUB_NAMESPACE \
    --eventhub-name $EVENTHUB_NAME \
    --name argo-events
```

### Issue 6: Event Hub FQDN Wrong
```
Symptom: EventSource logs show "connection refused" or "host not found"
Fix: Update fqdn in 03-eventsource-workload-identity.yaml
  fqdn: "YOUR-NAMESPACE.servicebus.windows.net"  # NOT the full connection string!
```

### Issue 7: Base64 Decoding Fails
```
Symptom: Sensor logs show "illegal base64" or template errors
Cause: Event Hub payload format different than expected
Debug:
  # Deploy debug sensor to see raw payload
  kubectl apply -f 04-sensor-production.yaml  # Includes debug sensor
  kubectl logs -n argo-events -l sensor-name=fluent-bit-debug --tail=20
```

---

## Full Status Check Script

```bash
#!/bin/bash
NS=argo-events

echo "============================================"
echo "ARGO EVENTS PIPELINE STATUS CHECK"
echo "============================================"

echo -e "\n--- EventBus ---"
kubectl get eventbus -n $NS 2>/dev/null || echo "NO EVENTBUS FOUND!"

echo -e "\n--- EventSource ---"
kubectl get eventsource -n $NS
kubectl get eventsource eventhub-k8s-events -n $NS -o jsonpath='Status: {.status.conditions[0].type}' 2>/dev/null
echo ""

echo -e "\n--- Sensor ---"
kubectl get sensor -n $NS
kubectl get sensor fluent-bit-gitlab-issues -n $NS -o jsonpath='Status: {.status.conditions[0].type}' 2>/dev/null
echo ""

echo -e "\n--- WorkflowTemplate ---"
kubectl get workflowtemplate multi-cluster-triage -n $NS 2>/dev/null || echo "MISSING!"

echo -e "\n--- Secret ---"
kubectl get secret eventhub-listener-secret -n $NS 2>/dev/null || echo "MISSING!"

echo -e "\n--- ServiceAccount ---"
kubectl get sa argo-events-sa -n $NS 2>/dev/null || echo "MISSING!"

echo -e "\n--- RBAC Check ---"
echo -n "Can create workflows: "
kubectl auth can-i create workflows --as=system:serviceaccount:$NS:argo-events-sa -n $NS

echo -e "\n--- Pods ---"
kubectl get pods -n $NS

echo -e "\n--- Recent Workflows (last 5) ---"
kubectl get workflows -n $NS --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -6

echo -e "\n--- Recent Errors (EventSource) ---"
kubectl logs -n $NS -l eventsource-name=eventhub-k8s-events --tail=20 2>/dev/null | grep -i error | tail -5

echo -e "\n--- Recent Errors (Sensor) ---"
kubectl logs -n $NS -l sensor-name=fluent-bit-gitlab-issues --tail=20 2>/dev/null | grep -i error | tail -5
```

---

## Deployment Order

Apply resources in this order:

```bash
# 1. RBAC and EventBus (MUST be first!)
kubectl apply -f 02a-mgmt-cluster-rbac.yaml

# 2. Secret for Event Hub
kubectl apply -f 03a-mgmt-cluster-external-secret.yaml
# OR manually:
kubectl create secret generic eventhub-listener-secret \
  --namespace argo-events \
  --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \
  --from-literal=sharedAccessKey="<your-key>"

# 3. WorkflowTemplate
kubectl apply -f ../workflow-multi-cluster-triage.yaml

# 4. EventSource
kubectl apply -f 03-eventsource-workload-identity.yaml

# 5. Sensor
kubectl apply -f 04-sensor-production.yaml

# 6. Verify
kubectl get eventbus,eventsource,sensor,workflowtemplate -n argo-events
```
