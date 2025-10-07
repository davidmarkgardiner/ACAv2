Build and Deployment Process

  1. Build Docker Image:
  docker build --platform linux/amd64 -t ca2e9de733d8acr.azurecr.io/function-app:latest .
  - Base image: mcr.microsoft.com/azure-functions/python:4-python3.11
  - Copied: function_app.py, requirements.txt, host.json
  - Installed Python dependencies
  - Platform: linux/amd64 (ACA requirement)

  2. Push to ACR:
  az acr login --name ca2e9de733d8acr
  docker push ca2e9de733d8acr.azurecr.io/function-app:latest

  3. Deploy via Bicep:
  az deployment group create \
    --name funcapp-deployment-<timestamp> \
    --resource-group <rg-name> \
    --template-file bicep/templates/function-app-deployment.bicep \
    --parameters \
        namePrefix=funcapp \
        environment=ca-dev \
        location=westeurope \
        containerImage=ca2e9de733d8acr.azurecr.io/function-app:latest

  4. Testing (from PERFORMANCE-REPORT.md):

  Warm requests:
  curl -w "%{time_total}\n" https://funcapp-ca-dev.happygrass-179b2dee.westeurope.azurecontainerapps.io/api/hello?name=Test
  # Repeated 3 times: 117ms, 113ms, 125ms (avg 118ms)

  Cold start test:
  - Monitored replicas: az containerapp revision show
  - Waited for scale-to-zero (5 minutes)
  - Sent request after 0 replicas reached
  - Measured total time: 17.2 seconds

  Scale-to-zero monitoring:
  # Checked every 30 seconds
  az containerapp show --name funcapp-ca-dev --resource-group <rg> --query properties.runningStatus