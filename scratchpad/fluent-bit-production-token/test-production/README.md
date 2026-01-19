# Production Pipeline Test Environment

Local testing environment for the multi-cluster triage pipeline.

```
Webhook → Sensor → Holmes AI → GitLab Issue → Mattermost
```

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

## Docs

- [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) - Full deployment instructions
- [TESTING-STATUS.md](TESTING-STATUS.md) - Test results and status
