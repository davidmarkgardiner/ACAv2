curl -X POST http://localhost:3002/api/v1/container-apps \
  -H "Content-Type: application/json" \
  -d '{
    "operation": "create",
    "metadata": {
      "requestId": "550e8400-e29b-41d4-a716-446655440000",
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
