# Deployment Guide — kagent Triage Pipeline

Step-by-step guide to deploy the kagent triage pipeline on a Kubernetes cluster.

This guide uses the **Kind homelab cluster** (`kind-homelab` context) as the reference environment. Adapt context names and domains for your cluster.

---

## Prerequisites

### Required Components

| Component | Version | Namespace | Purpose |
|-----------|---------|-----------|---------|
| kagent | v0.8.0+ | `kagent` | AI agent framework |
| Argo Workflows | v3.5+ | `argo` | Workflow execution |
| Argo Events | v1.9+ | `argo-events` | Event routing |
| NATS EventBus | — | `argo-events` | Message bus |
| Traefik | v3+ | `traefik` | Ingress (optional) |

### Verify Prerequisites

```bash
CONTEXT="kind-homelab"

# 1. Check Argo Workflows controller
kubectl --context $CONTEXT get pods -n argo -l app=workflow-controller
# Expected: Running

# 2. Check Argo Events controller
kubectl --context $CONTEXT get pods -n argo-events -l app=controller-manager
# Expected: Running

# 3. Check EventBus (NATS)
kubectl --context $CONTEXT get eventbus default -n argo-events
# Expected: eventbus.argoproj.io/default

# 4. Check kagent
kubectl --context $CONTEXT get pods -n kagent
# Expected: kagent-controller and kagent-ui pods Running

# 5. Check existing EventSource
kubectl --context $CONTEXT get eventsource k8s-warning-events -n argo-events
# Expected: eventsource.argoproj.io/k8s-warning-events

# 6. Verify kagent API is accessible
kubectl --context $CONTEXT port-forward svc/kagent-controller -n kagent 8083:8083 &
curl -sf http://localhost:8083/api/agents && echo "API OK"
kill %1
```

### Required Secrets

| Secret | Namespace | Key | Purpose |
|--------|-----------|-----|---------|
| `telegram-bot-secret` | `argo-events` | `token` | Telegram bot token for notifications |
| `litellm-key` | `kagent` | `api-key` | LiteLLM API key for LLM access |

```bash
# Create Telegram bot secret (if not exists)
kubectl --context $CONTEXT create secret generic telegram-bot-secret \
  -n argo-events \
  --from-literal=token="YOUR_TELEGRAM_BOT_TOKEN"

# Verify
kubectl --context $CONTEXT get secret telegram-bot-secret -n argo-events
```

---

## Step 1: Create Test Namespace

Create the `test-ns` namespace with a ServiceAccount and RBAC for the kagent agent.

```bash
kubectl --context $CONTEXT apply -f 00-test-namespace.yaml
```

**Verify:**
```bash
kubectl --context $CONTEXT get ns test-ns
# NAME      STATUS   AGE
# test-ns   Active   5s

kubectl --context $CONTEXT get sa test-ns-sa -n test-ns
# NAME        SECRETS   AGE
# test-ns-sa  0         5s

kubectl --context $CONTEXT get role test-ns-reader -n test-ns
# NAME             CREATED AT
# test-ns-reader   2026-...
```

**What this creates:**
- `test-ns` namespace with label `kagent-triage: enabled`
- `test-ns-sa` ServiceAccount
- `test-ns-reader` Role (read access to pods, deployments, events, etc.)
- RoleBinding linking the SA to the Role

---

## Step 2: Deploy kagent Agent

Create the namespace-specific AI agent with a diagnostic system prompt.

```bash
kubectl --context $CONTEXT apply -f 01-test-agent.yaml
```

**Verify:**
```bash
# Check agent was created
kubectl --context $CONTEXT get agent test-ns-agent -n kagent
# NAME            AGE
# test-ns-agent   5s

# Wait for Ready state
kubectl --context $CONTEXT wait agent/test-ns-agent -n kagent \
  --for=condition=Ready --timeout=60s
# agent.kagent.dev/test-ns-agent condition met

# Check agent status detail
kubectl --context $CONTEXT get agent test-ns-agent -n kagent \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# True

# Verify agent appears in API
kubectl --context $CONTEXT port-forward svc/kagent-controller -n kagent 8083:8083 &
curl -s http://localhost:8083/api/agents | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('agents', []):
    print(f\"  {a['name']} (Ready: {a.get('status', {}).get('conditions', [{}])[0].get('status', 'Unknown')})\")
"
kill %1
```

**What this creates:**
- `test-ns-agent` Agent CR in `kagent` namespace
- Namespace-scoped system prompt for diagnosing pod failures, image pulls, OOM, crashloops
- A2A skills for namespace diagnostics and resource analysis
- MCP tools for kubectl-equivalent operations

---

## Step 3: Deploy WorkflowTemplate

Create the Argo WorkflowTemplate that orchestrates the triage pipeline.

```bash
kubectl --context $CONTEXT apply -f 02-workflow-kagent-triage.yaml
```

**Verify:**
```bash
kubectl --context $CONTEXT get workflowtemplate kagent-triage -n argo-events
# NAME            AGE
# kagent-triage   5s

# Check template details
kubectl --context $CONTEXT get workflowtemplate kagent-triage -n argo-events \
  -o jsonpath='{.spec.templates[*].name}'
# main find-agent create-conversation send-telegram
```

**What this creates:**
- `kagent-triage` WorkflowTemplate with 3-step DAG:
  1. `find-agent` — Discovers namespace-specific agent via REST API
  2. `create-conversation` — Sends event details to agent via **A2A protocol** (NOT session API)
  3. `send-telegram` — Posts diagnosis to Telegram channel

> **A2A Protocol**: The workflow uses `POST /api/a2a/kagent/{agent-name}/` with JSON-RPC 2.0.
> Trailing slash is REQUIRED. Message parts must include `"kind": "text"`.
> The session API (`/api/sessions/{id}/events`) is broken on v0.8.0-beta4 — do NOT use it.

**Parameters accepted:**
| Parameter | Description |
|-----------|-------------|
| `event-namespace` | Namespace where the event occurred |
| `event-name` | Name of the K8s event |
| `event-reason` | Event reason (e.g., `ImagePullBackOff`) |
| `event-message` | Human-readable event message |
| `resource-kind` | Kind of affected resource (Pod, Deployment, etc.) |
| `resource-name` | Name of affected resource |
| `telegram-chat-id` | Telegram chat ID (default: `xxx`) |

---

## Step 4: Deploy Sensor

> **⚠️ CASCADE LOOP WARNING**: Sensors MUST include PolicyViolation filter + rate limit.
> Without these, Kyverno events can create an infinite workflow loop. See [SENSOR-SAFEGUARDS.md](./SENSOR-SAFEGUARDS.md).

Create the Argo Sensor that routes `test-ns` warning events to the workflow.

```bash
kubectl --context $CONTEXT apply -f test-ns-sensor.yaml
```

**Sensor safeguards (all sensors include):**
1. `body.reason != PolicyViolation` filter — prevents Kyverno cascade
2. `rateLimit: unit: minute, requestsPerUnit: 5` — max 5 workflows/minute
3. Namespace-specific filter — only watches target namespace

**Verify:**
```bash
# Check sensor created
kubectl --context $CONTEXT get sensors -n argo-events -l app=kagent-triage

# Wait for sensor pod to start
kubectl --context $CONTEXT get pods -n argo-events -l app=kagent-triage

# Check sensor logs for subscription confirmation
kubectl --context $CONTEXT logs -n argo-events -l app=kagent-triage --tail=20
# Should see: "successfully subscribed to eventbus"
```

**What this creates:**
- Namespace-specific sensors in `argo-events` namespace
- Subscribes to `k8s-warning-events` EventSource on the default EventBus (NATS)
- Filters events by namespace AND excludes PolicyViolation reasons
- Triggers `kagent-triage` WorkflowTemplate with mapped event parameters
- Rate-limited: max 5 workflows/minute per sensor

---

## Step 5: Deploy Ingress (Optional)

Expose the kagent UI externally via Traefik IngressRoute.

```bash
kubectl --context $CONTEXT apply -f 04-ingress-kagent-ui.yaml
```

**Verify:**
```bash
kubectl --context $CONTEXT get ingressroute kagent-ui -n kagent
# NAME        AGE
# kagent-ui   5s

# Test access (if DNS is configured)
curl -sf https://kagent.xxx && echo "UI accessible"
```

**Note:** This uses Traefik with Cloudflare cert resolver. For other ingress controllers, see the [Lift-and-Shift Guide](./LIFT-AND-SHIFT-AKS.md).

---

## Step 6: Test the Pipeline

### 6a. Inject Test Errors

```bash
kubectl --context $CONTEXT apply -f 05-test-error-injection.yaml
```

This creates:
| Resource | Type | Error Triggered |
|----------|------|-----------------|
| `bad-image-deployment` | Deployment | `ImagePullBackOff` (invalid tag) |
| `oom-test-pod` | Pod | `OOMKilled` (64Mi limit, 100M allocation) |
| `crashloop-test-pod` | Pod | `CrashLoopBackOff` (exit 1 command) |
| `resource-pressure-deployment` | Deployment | CPU throttling (stress test) |

### 6b. Watch Events

```bash
# Watch K8s warning events in test-ns
kubectl --context $CONTEXT get events -n test-ns --field-selector type=Warning -w
```

Expected output:
```
LAST SEEN   TYPE      REASON              OBJECT                          MESSAGE
5s          Warning   Failed              pod/bad-image-deployment-xxx    Failed to pull image "nginx:nonexistent-tag-xyz123"
3s          Warning   BackOff             pod/crashloop-test-pod          Back-off restarting failed container
2s          Warning   OOMKilling          pod/oom-test-pod                Memory cgroup out of memory
```

### 6c. Watch Workflows

```bash
# Watch for workflow triggers
kubectl --context $CONTEXT get workflows -n argo-events -w
```

Expected output:
```
NAME                        STATUS      AGE
kagent-triage-xxxxx         Running     5s
kagent-triage-yyyyy         Succeeded   30s
```

### 6d. Check Agent Response

```bash
# Port-forward to check conversations
kubectl --context $CONTEXT port-forward svc/kagent-controller -n kagent 8083:8083 &

# List recent conversations
curl -s http://localhost:8083/api/conversations | python3 -c "
import json, sys
data = json.load(sys.stdin)
for conv in data[:5]:
    print(f\"Agent: {conv.get('agent_name', 'unknown')} | Messages: {len(conv.get('messages', []))}\")"

kill %1
```

### 6e. Check Telegram

Verify notifications arrived in the configured Telegram channel (ID: `xxx`).

### 6f. Cleanup Test Resources

```bash
kubectl --context $CONTEXT delete -f 05-test-error-injection.yaml
```

---

## Full Deployment (One Command)

```bash
CONTEXT="kind-homelab"

# Deploy all components
for f in 00-test-namespace.yaml 01-test-agent.yaml 02-workflow-kagent-triage.yaml \
         03-sensor-kagent-triage.yaml 04-ingress-kagent-ui.yaml; do
  echo "Applying $f..."
  kubectl --context $CONTEXT apply -f "$f"
done

# Wait for agent
kubectl --context $CONTEXT wait agent/test-ns-agent -n kagent --for=condition=Ready --timeout=60s

# Wait for sensor pod
kubectl --context $CONTEXT wait pod -n argo-events -l sensor-name=kagent-triage-sensor \
  --for=condition=Ready --timeout=60s

echo "✅ Pipeline deployed and ready"
```

---

## Troubleshooting

### Agent Not Reaching Ready State

```bash
# Check agent events
kubectl --context $CONTEXT describe agent test-ns-agent -n kagent

# Check kagent controller logs
kubectl --context $CONTEXT logs -n kagent -l app.kubernetes.io/component=controller --tail=50

# Verify ModelConfig exists
kubectl --context $CONTEXT get modelconfig default-model-config -n kagent
```

### Sensor Not Triggering Workflows

```bash
# Check sensor pod logs
kubectl --context $CONTEXT logs -n argo-events -l sensor-name=kagent-triage-sensor --tail=30

# Verify EventBus is healthy
kubectl --context $CONTEXT get eventbus default -n argo-events -o yaml | grep -A5 status

# Verify EventSource is active
kubectl --context $CONTEXT get eventsource k8s-warning-events -n argo-events

# Check that events are actually firing
kubectl --context $CONTEXT get events -n test-ns --field-selector type=Warning
```

### Workflow Fails at find-agent Step

```bash
# Check workflow logs
kubectl --context $CONTEXT logs -n argo-events -l workflows.argoproj.io/workflow=<name> -c main

# Verify kagent API is accessible from workflow pod
kubectl --context $CONTEXT run test-api --rm -it --image=python:3.11-slim -n argo-events -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://kagent-controller.kagent:8083/api/agents').read()[:200])"
```

### Telegram Notifications Not Sending

```bash
# Verify secret exists
kubectl --context $CONTEXT get secret telegram-bot-secret -n argo-events

# Check the send-telegram step logs in the workflow
kubectl --context $CONTEXT logs -n argo-events <workflow-pod> -c main

# Test Telegram API directly
TOKEN=$(kubectl --context $CONTEXT get secret telegram-bot-secret -n argo-events \
  -o jsonpath='{.data.token}' | base64 -d)
curl -s "https://api.telegram.org/bot${TOKEN}/getMe" | jq
```

---

## Next Steps

- Add more namespace agents: See [Adding Namespace Agents](./ADDING-NAMESPACE-AGENTS.md)
- Migrate to AKS: See [Lift-and-Shift Guide](./LIFT-AND-SHIFT-AKS.md)
- API details: See [API Reference](./API-REFERENCE.md)
