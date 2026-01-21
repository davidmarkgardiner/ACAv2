# Production Pipeline Test Environment

Local testing environment for the multi-cluster triage pipeline.

## Status: ✅ WORKING (2026-01-20)

| Component | Status | Notes |
|-----------|--------|-------|
| Webhook Testing | ✅ Working | Full pipeline verified |
| EventHub Testing | ✅ Working | **Requires Argo Events v1.9.5** |
| Holmes AI | ✅ Working | Model: `claude-sonnet-4-20250514` |
| GitLab Integration | ✅ Working | Issues created with AI analysis |
| Mattermost Notifications | ✅ Working | Summary + recommendations |

### ⚠️ CRITICAL: Argo Events Version

**You MUST use Argo Events v1.9.5** (Helm chart 2.4.14). Versions 1.9.6-1.9.9 have a bug that causes EventHub EventSource to crash.

```bash
# Check version
kubectl get deployment -n argo-events -o wide | grep argo-events
# Should show: quay.io/argoproj/argo-events:v1.9.5

# Downgrade if needed
helm upgrade argo-events argo/argo-events --namespace argo-events --version 2.4.14 --reuse-values
```

See [ARGO-EVENTS-EVENTHUB-BUG.md](ARGO-EVENTS-EVENTHUB-BUG.md) for details.

---

## Test Methods

| Method | Use Case | File |
|--------|----------|------|
| **Webhook** | Local testing, quick iteration | `03-webhook-eventsource.yaml` |
| **EventHub** | Production simulation, gradual rollout | `05-eventhub-eventsource.yaml` |

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Webhook        │───►│  Argo Sensor    │───►│  Argo Workflow  │───►│  GitLab Issue   │
│  OR EventHub    │    │  (filtered)     │    │  (Holmes AI)    │    │  + Mattermost   │
└─────────────────┘    └─────────────────┘    └─────────────────┘    └─────────────────┘
```

---

## Option 1: Webhook Testing (Quick)

## Quick Test

```bash
# 1. Deploy everything
kubectl apply -f 00-rbac.yaml
kubectl apply -f 02-workflow-template.yaml
kubectl apply -f 03-webhook-eventsource.yaml
kubectl apply -f 04-sensor-production-test.yaml

# 2. Create secrets (edit with your values)
kubectl create secret generic gitlab-mcp-secret -n argo-events \
  --from-literal=GITLAB_PERSONAL_ACCESS_TOKEN="glpat-xxx"

kubectl create secret generic holmes-secrets -n holmesgpt \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-api03-xxx"

# 3. Deploy Holmes
kubectl apply -f 06-holmes-local-deployment.yaml

# 4. Configure Mattermost (optional)
kubectl create configmap rocketchat-webhook-config -n argo-events \
  --from-literal=WEBHOOK_URL="http://mattermost.mattermost.svc:8065/hooks/xxx"

# 5. Test
kubectl port-forward -n argo-events svc/webhook-prod-test-svc 12000:12000 &
curl -X POST http://localhost:12000/k8s-event \
  -H "Content-Type: application/json" \
  -d @test-payload-eventhub.json

# 6. Watch
kubectl get workflows -n argo-events -w
```

## Files

| File | Purpose |
|------|---------|
| `00-rbac.yaml` | RBAC, ServiceAccount, EventBus |
| `01-secrets.yaml` | Secret templates |
| `02-workflow-template.yaml` | Holmes → GitLab → Mattermost workflow |
| `03-webhook-eventsource.yaml` | Test webhook (port 12000) |
| `04-sensor-production-test.yaml` | Sensor with Base64 decoding |
| `05-holmes-rbac.yaml` | Holmes ClusterRole |
| `06-holmes-local-deployment.yaml` | Complete Holmes deployment |
| `test-payload-eventhub.json` | Event Hub format test payload |
| `DEPLOYMENT-GUIDE.md` | Full deployment instructions |

## What Gets Created

After a successful test:
- **GitLab Issue** with AI analysis and recommendations
- **Mattermost Message** with summary and kubectl commands

---

## Option 2: EventHub Testing (Production Simulation)

See [EVENTHUB-TESTING.md](EVENTHUB-TESTING.md) for complete guide.

### Quick EventHub Test

```bash
# 1. Verify Argo Events version (MUST be v1.9.5!)
kubectl get deployment -n argo-events -o wide | grep argo-events

# 2. Create EventHub secret
kubectl create secret generic eventhub-listener-secret \
  --namespace argo-events \
  --from-literal=sharedAccessKeyName="RootManageSharedAccessKey" \
  --from-literal=sharedAccessKey="YOUR_KEY_HERE"

# 3. Deploy EventSource (edit FQDN first!)
kubectl apply -f 05-eventhub-eventsource.yaml

# 4. Deploy sensor (RECOMMENDED: simple sensor)
kubectl apply -f 08-eventhub-sensor-simple.yaml  # ✅ WORKING - no filters

# Alternative sensors (expression filters have issues with EventHub payload):
# kubectl apply -f 07-eventhub-sensor-namespace-whitelist.yaml  # ⚠️ Filter issues
# kubectl apply -f 06-eventhub-sensor-filtered.yaml             # ⚠️ Filter issues

# 5. Send test event
./send-eventhub-test.sh CrashLoopBackOff --namespace monitoring

# 6. Watch
kubectl get workflows -n argo-events -w
```

### ⚠️ Filtering Recommendation

Expression-based sensor filters don't work well with EventHub payload format. **Recommend filtering at Fluent Bit level** instead:
- Lower EventHub costs (fewer messages)
- More reliable filtering behavior
- See [EVENTHUB-TESTING.md](EVENTHUB-TESTING.md#recommended-fluent-bit-filtering) for config

### Gradual Rollout Strategy

| Phase | Sensor | Namespaces | Event Types |
|-------|--------|------------|-------------|
| 1 | Namespace whitelist | monitoring, holmesgpt | Critical only |
| 2 | Namespace whitelist | + app namespaces | Critical only |
| 3 | System blacklist | All except system | Critical only |
| 4 | System blacklist | All except system | + Health events |

---

## Files

| File | Purpose | Status |
|------|---------|--------|
| `00-rbac.yaml` | RBAC, ServiceAccount, EventBus | ✅ |
| `01-secrets.yaml` | Secret templates | ✅ |
| `02-workflow-template.yaml` | Holmes → GitLab → Mattermost workflow | ✅ |
| `03-webhook-eventsource.yaml` | Test webhook (port 12000) | ✅ |
| `04-sensor-production-test.yaml` | Webhook sensor with Base64 decoding | ✅ |
| `05-eventhub-eventsource.yaml` | **EventHub EventSource** | ✅ |
| `06-eventhub-sensor-filtered.yaml` | EventHub sensor (system NS blacklist) | ⚠️ Filter issues |
| `07-eventhub-sensor-namespace-whitelist.yaml` | EventHub sensor (NS whitelist) | ⚠️ Filter issues |
| `08-eventhub-sensor-simple.yaml` | **EventHub sensor (no filters) - RECOMMENDED** | ✅ |
| `05-holmes-rbac.yaml` | Holmes ClusterRole | ✅ |
| `06-holmes-local-deployment.yaml` | Complete Holmes deployment | ✅ |
| `send-eventhub-test.sh` | Send test events to EventHub (Python) | ✅ |
| `send-eventhub-curl.sh` | Send test events to EventHub (curl) | ✅ |
| `test-payload-eventhub.json` | Event Hub format test payload | ✅ |

## What Gets Created

After a successful test:
- **GitLab Issue** with AI analysis and recommendations
- **Mattermost Message** with summary and kubectl commands

## Docs

- [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) - Full deployment instructions
- [TESTING-STATUS.md](TESTING-STATUS.md) - Test results and status
- [EVENTHUB-TESTING.md](EVENTHUB-TESTING.md) - EventHub integration testing
- [ARGO-EVENTS-EVENTHUB-BUG.md](ARGO-EVENTS-EVENTHUB-BUG.md) - **Critical bug fix documentation (v1.9.5)**

## Azure Resources (Created for Testing)

| Resource | Name | Location |
|----------|------|----------|
| EventHub Namespace | `k8s-events-hub-fb` | uksouth |
| EventHub | `kube-events` | uksouth |
| Resource Group | `k8s-cluster` | uksouth |
| Consumer Group | `$Default` | Basic tier |
| K8s Secret | `eventhub-listener-secret` | argo-events |
