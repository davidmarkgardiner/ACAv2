# Azure Function App - Artifact Deployment to Container Apps

## Overview

This Function App is deployed to Azure Container Apps using a **ZIP artifact** file. This deployment method is ideal for Python-based Azure Functions as it preserves the application structure and doesn't require containerization.

## Artifact Format: ZIP

**Why ZIP?**
- ✅ Standard format for Python Azure Functions
- ✅ Officially supported by Azure Container Apps
- ✅ Preserves directory structure and manifest files
- ✅ No compilation required (unlike JAR/WAR)
- ✅ Smaller file size compared to TAR.GZ

**Alternative formats considered:**
- ❌ **JAR**: Java-specific, requires JDK/Maven
- ❌ **WAR**: Java web application format
- ❌ **TAR.GZ**: Less standard for Azure Functions

## Quick Start

### 1. Build the Artifact

```bash
cd function-app
./build-artifact.sh
```

This creates `function-app.zip` containing:
- `function_app.py` - Main application code
- `host.json` - Azure Functions host configuration
- `requirements.txt` - Python dependencies

### 2. Deploy to Azure Container Apps

```bash
./deploy-artifact.sh
```

**Optional: Set environment variables before deployment:**

```bash
export RESOURCE_GROUP="rg-my-functionapp"
export LOCATION="canadacentral"
export ENVIRONMENT="env-my-functionapp"
export APP_NAME="my-functionapp-api"
export SUBSCRIPTION="your-subscription-id"

./deploy-artifact.sh
```

### 3. Verify Deployment

After successful deployment, test the endpoints:

```bash
# Health check
curl https://<your-app-fqdn>/api/health

# Hello endpoint
curl https://<your-app-fqdn>/api/hello?name=World
```

## Manual Deployment

If you prefer to run the Azure CLI commands directly:

```bash
# Build artifact first
./build-artifact.sh

# Deploy with az containerapp up
az containerapp up \
  --name my-functionapp-api \
  --resource-group rg-my-functionapp \
  --location canadacentral \
  --environment env-my-functionapp \
  --artifact ./function-app.zip \
  --ingress external \
  --target-port 80 \
  --subscription <your-subscription-id>
```

## What Gets Created

The `az containerapp up` command automatically creates:

1. **Resource Group** (if doesn't exist)
2. **Container Registry** - Stores the container image built from the artifact
3. **Container Apps Environment** - Provides the runtime environment
4. **Log Analytics Workspace** - For monitoring and logging
5. **Container App** - Your deployed Function App

## Application Structure

```
function-app.zip
├── function_app.py      # Main app with HTTP triggers
├── host.json           # Functions host configuration
└── requirements.txt    # Python dependencies
```

### Endpoints

- **GET /api/health** - Health check endpoint (returns JSON status)
- **GET /api/hello** - Hello world endpoint (accepts `name` parameter)

## Configuration

### Environment Variables

Default values (can be overridden):

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOURCE_GROUP` | `rg-functionapp-aca` | Azure resource group name |
| `LOCATION` | `canadacentral` | Azure region |
| `ENVIRONMENT` | `env-functionapp-aca` | Container Apps environment name |
| `APP_NAME` | `functionapp-api` | Container App name |
| `SUBSCRIPTION` | _(current)_ | Azure subscription ID |

### Target Port

The Function App listens on port **80** by default when deployed to Container Apps. This is specified via the `--target-port 80` flag.

## Troubleshooting

### Build Issues

**Error: Required file not found**
- Ensure you're running the build script from the `function-app` directory
- Verify all required files exist: `function_app.py`, `host.json`, `requirements.txt`

### Deployment Issues

**Error: Artifact file not found**
```bash
# Run build script first
./build-artifact.sh
```

**Error: Subscription not set**
```bash
# List subscriptions
az account list --output table

# Set default subscription
az account set --subscription <subscription-id>

# Or export for deployment
export SUBSCRIPTION="<subscription-id>"
```

**Error: Missing Container Apps extension**
```bash
# Install/upgrade Container Apps extension with preview features
az extension add --name containerapp --upgrade --allow-preview true
```

**Error: Namespace not registered**
```bash
# Register required namespaces
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

### Runtime Issues

**Function not responding**
```bash
# Check Container App logs
az containerapp logs show \
  --name <app-name> \
  --resource-group <resource-group> \
  --follow

# Check Container App status
az containerapp show \
  --name <app-name> \
  --resource-group <resource-group>
```

**404 errors on endpoints**
- Ensure you're accessing `/api/<function-name>` (e.g., `/api/health`, `/api/hello`)
- Verify ingress is set to `external`
- Check FQDN is correct

## Advanced: Bicep Deployment

For production deployments, consider using Bicep templates instead of `az containerapp up`. See the `/bicep` directory for modular templates.

Example Bicep deployment:
```bash
az deployment group create \
  --resource-group <resource-group> \
  --template-file bicep/modules/container-app.bicep \
  --parameters \
    appName=functionapp-api \
    environmentId=<env-resource-id> \
    artifactPath=./function-app.zip
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Deploy Function App to ACA

on:
  push:
    branches: [main]
    paths:
      - 'function-app/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Build artifact
        run: |
          cd function-app
          ./build-artifact.sh

      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Deploy to Container Apps
        run: |
          cd function-app
          export RESOURCE_GROUP="${{ secrets.RESOURCE_GROUP }}"
          export SUBSCRIPTION="${{ secrets.SUBSCRIPTION_ID }}"
          ./deploy-artifact.sh
```

## Performance Considerations

- **Cold Start**: Container Apps scale to zero. First request after idle may take 2-5 seconds
- **Scaling**: Configure min/max replicas based on load
- **Dependencies**: Keep `requirements.txt` minimal to reduce image build time

## Security Best Practices

1. **Authentication**: Consider changing `http_auth_level` from `ANONYMOUS` to `FUNCTION` or use Azure AD
2. **Secrets**: Store secrets in Azure Key Vault, reference via Container App secrets
3. **Network**: Use internal ingress for backend services
4. **HTTPS**: Container Apps provide automatic HTTPS certificates

## Monitoring

```bash
# View real-time logs
az containerapp logs show \
  --name <app-name> \
  --resource-group <resource-group> \
  --follow

# View metrics
az monitor metrics list \
  --resource <container-app-resource-id> \
  --metric-names Requests

# Query Log Analytics
az monitor log-analytics query \
  --workspace <workspace-id> \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == '<app-name>' | limit 50"
```

## Cost Optimization

- Enable **scale to zero** for dev/test environments
- Use **consumption-based pricing** (default)
- Set appropriate **min/max replicas**
- Monitor **request patterns** to optimize scaling rules

## References

- [Azure Container Apps - Deploy Artifact Documentation](https://learn.microsoft.com/en-us/azure/container-apps/deploy-artifact)
- [Azure Functions Python Developer Guide](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-python)
- [Container Apps Scaling Documentation](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
- Project PRD: `/docs/prd.md`

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review Container App logs
3. Refer to official Azure documentation
4. Open an issue in the project repository
