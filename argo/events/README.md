# Argo Events Configuration

This directory contains Argo Events configuration for the ACA-as-a-Service platform, enabling event-driven workflow triggering.

## Components

### EventSource: `eventsource-webhook.yaml`
Exposes an HTTP webhook endpoint to receive Container App operation requests.

- **Namespace**: `argo-events`
- **Service Port**: 12000
- **Endpoint**: `/container-apps`
- **Method**: POST

The webhook accepts JSON payloads containing Container App configurations and routes them to appropriate workflows based on the operation type.

### Sensor: `sensor-containerapp.yaml`
Listens for events from the webhook EventSource and triggers Argo Workflows based on the operation type.

**Supported Operations:**
- `create` → Triggers `containerapp-create` workflow
- `delete` → Triggers `containerapp-delete` workflow
- `update` → Logs event (Phase 2 implementation)
- `scale` → Logs event (Phase 2 implementation)

**Filtering Logic:**
Each trigger has a filter expression that checks `body.operation` to route events correctly.

### RBAC: `rbac.yaml`
Defines ServiceAccounts and RBAC permissions for:
- **aca-workflow-sa**: ServiceAccount for Argo Workflows execution
- **aca-sensor-sa**: ServiceAccount for Argo Events Sensor to create workflows

## Deployment

### Prerequisites
1. Argo Workflows installed in `argo` namespace
2. Argo Events installed in `argo-events` namespace
3. Azure credentials stored as Kubernetes secrets
4. Bicep templates mounted as ConfigMap

### 1. Create Azure Credentials Secret

```bash
kubectl create secret generic azure-credentials \
  --namespace=argo \
  --from-literal=client-id=<YOUR_CLIENT_ID> \
  --from-literal=client-secret=<YOUR_CLIENT_SECRET> \
  --from-literal=tenant-id=<YOUR_TENANT_ID> \
  --from-literal=subscription-id=<YOUR_SUBSCRIPTION_ID>
```

### 2. Create Notification Webhook Secret (Optional)

```bash
kubectl create secret generic notification-config \
  --namespace=argo \
  --from-literal=slack-webhook=<YOUR_SLACK_WEBHOOK_URL>
```

### 3. Create Bicep Templates ConfigMap

```bash
kubectl create configmap bicep-templates \
  --namespace=argo \
  --from-file=../bicep/
```

### 4. Deploy RBAC Resources

```bash
kubectl apply -f rbac.yaml
```

### 5. Deploy Workflow Templates

```bash
kubectl apply -f ../workflows/containerapp-create.yaml
kubectl apply -f ../workflows/containerapp-delete.yaml
```

### 6. Deploy EventSource

```bash
kubectl apply -f eventsource-webhook.yaml
```

Verify EventSource is running:
```bash
kubectl get eventsources -n argo-events
kubectl get pods -n argo-events -l eventsource-name=aca-webhook
```

### 7. Deploy Sensor

```bash
kubectl apply -f sensor-containerapp.yaml
```

Verify Sensor is running:
```bash
kubectl get sensors -n argo-events
kubectl get pods -n argo-events -l sensor-name=aca-operations
```

## Accessing the Webhook

### Port Forward (Development)

```bash
# Find the EventSource pod
kubectl get pods -n argo-events -l eventsource-name=aca-webhook

# Port forward
kubectl port-forward -n argo-events \
  <eventsource-pod-name> 12000:12000
```

Webhook URL: `http://localhost:12000/container-apps`

### Service Exposure (Production)

Create a Service and Ingress:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: aca-webhook-svc
  namespace: argo-events
spec:
  selector:
    eventsource-name: aca-webhook
  ports:
    - protocol: TCP
      port: 80
      targetPort: 12000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aca-webhook-ingress
  namespace: argo-events
spec:
  rules:
    - host: aca-webhook.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: aca-webhook-svc
                port:
                  number: 80
```

## Testing

### Test CREATE Operation

```bash
curl -X POST http://localhost:12000/container-apps \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "create",
    "metadata": {
      "requestId": "test-123",
      "requestedBy": "admin@example.com",
      "team": "platform",
      "environment": "dev"
    },
    "containerApp": {
      "name": "test-app",
      "resourceGroup": "rg-test-dev",
      "location": "eastus",
      "image": {
        "registry": "mcr.microsoft.com",
        "repository": "azuredocs/containerapps-helloworld",
        "tag": "latest"
      },
      "resources": {
        "cpu": 0.25,
        "memory": "0.5Gi"
      },
      "scaling": {
        "minReplicas": 0,
        "maxReplicas": 5
      },
      "ingress": {
        "external": true,
        "targetPort": 80
      }
    }
  }'
```

### Test DELETE Operation

```bash
curl -X POST http://localhost:12000/container-apps \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "delete",
    "metadata": {
      "requestId": "test-456",
      "requestedBy": "admin@example.com",
      "team": "platform"
    },
    "containerApp": {
      "name": "test-app",
      "resourceGroup": "rg-test-dev"
    }
  }'
```

### Verify Workflow Triggered

```bash
# List workflows
kubectl get workflows -n argo

# Get workflow details
kubectl get workflow <workflow-name> -n argo -o yaml

# Watch workflow logs
kubectl logs -n argo -l workflows.argoproj.io/workflow=<workflow-name> -f
```

## Troubleshooting

### EventSource Pod Not Running

```bash
kubectl describe eventsource aca-webhook -n argo-events
kubectl logs -n argo-events -l eventsource-name=aca-webhook
```

### Sensor Not Triggering Workflows

```bash
kubectl describe sensor aca-operations -n argo-events
kubectl logs -n argo-events -l sensor-name=aca-operations
```

Check sensor logs for filter evaluation and trigger execution.

### Workflow Fails with Permission Errors

Verify RBAC is correctly configured:
```bash
kubectl get sa aca-workflow-sa -n argo
kubectl get rolebindings -n argo | grep aca
```

### Azure Authentication Fails

Verify secrets exist and contain correct values:
```bash
kubectl get secret azure-credentials -n argo
kubectl get secret azure-credentials -n argo -o json | jq '.data | map_values(@base64d)'
```

## Integration with REST API

The Next.js API (`/api/v1/container-apps`) will POST payloads to this webhook endpoint:

```typescript
const webhookUrl = process.env.ARGO_WEBHOOK_URL ||
  'http://aca-webhook-svc.argo-events.svc.cluster.local:12000/container-apps';

const response = await fetch(webhookUrl, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(payload)
});
```

## Security Considerations

1. **Authentication**: Add webhook authentication (Bearer tokens, mTLS)
2. **Network Policies**: Restrict webhook access to API pods only
3. **Secret Management**: Rotate Azure credentials regularly
4. **RBAC**: Follow principle of least privilege
5. **Audit Logging**: Enable Kubernetes audit logs for compliance

## Future Enhancements

- [ ] Add UPDATE and SCALE workflow implementations
- [ ] Implement webhook authentication
- [ ] Add rate limiting
- [ ] Configure monitoring and alerting
- [ ] Add dead letter queue for failed events
- [ ] Implement event replay mechanism
