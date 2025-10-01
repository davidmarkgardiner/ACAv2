# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the implementation of an **Azure Container Apps as a Service** platform. The system enables development teams to provision, manage, and operate Azure Container Apps through event-driven workflows using Argo Events, Argo Workflows, and Bicep Infrastructure as Code.

**Current State:** Repository currently contains a Next.js Firebase template that will be transformed into the ACA platform.

**Target Architecture:**
- **Payload-driven provisioning** via REST API, Web UI, CLI, or Git
- **Event processing** using Argo Events (webhook EventSource, Sensors)
- **Workflow execution** using Argo Workflows (create, update, delete, scale operations)
- **Infrastructure deployment** via Azure CLI executing Bicep templates
- **Kubernetes cluster** for Argo components (kind-argo-workflow)

## Essential Commands

### Development Server
```bash
npm run dev          # Start Next.js development server (port 3000)
npm run build        # Build for production
npm run start        # Start production server
npm run lint         # Run ESLint
```

### Kubernetes & Argo
```bash
# Current Kubernetes context
kubectl config current-context    # kind-argo-workflow

# Argo namespaces
kubectl get ns | grep argo        # argo, argo-events, argo-rollouts

# View Argo Workflows
kubectl get workflows -n argo

# View Argo EventSources and Sensors
kubectl get eventsources -n argo-events
kubectl get sensors -n argo-events
```

### Azure CLI Commands
```bash
# Container Apps (from docs/az-conteinrapp-cli.md)
az containerapp create --help
az containerapp update --help
az containerapp delete --help
az containerapp show --help

# Deploy Bicep templates
az deployment group create \
  --resource-group <rg-name> \
  --template-file <bicep-file> \
  --parameters <params>
```

### Testing
```bash
npx playwright test                    # Run all Playwright tests
npx playwright test --ui              # Run tests in UI mode
npx playwright test <test-file>       # Run specific test
```

## Architecture Overview

### Current State (Firebase Template)
```
src/
├── app/
│   ├── layout.tsx              # Root layout with AuthProvider
│   └── page.tsx                # Home page
├── components/
│   ├── FirestoreDemo.tsx       # Demo component (to be removed)
│   ├── LoginForm.tsx           # Auth form (to be repurposed)
│   └── UserProfile.tsx         # User profile (to be adapted)
├── context/
│   └── AuthContext.tsx         # Auth context (needs Azure AD integration)
└── lib/
    └── firebase.ts             # Firebase config (to be replaced)
```

### Target State (ACA Platform)

**Core Components to Build:**

1. **Frontend Layer (Next.js)**
   - Payload builder form for Container App configuration
   - Dashboard for viewing deployed apps
   - Deployment history and status tracking
   - Replace Firebase Auth with Azure AD OAuth2

2. **API Layer**
   - REST endpoints: `/api/v1/container-apps` (POST, GET, PATCH, DELETE)
   - Payload validation against JSON schema
   - Event publishing to Argo Events webhook
   - Authentication via Azure AD tokens

3. **Bicep Templates** (to be created)
   ```
   bicep/
   ├── modules/
   │   ├── environment.bicep        # Container App Environment
   │   ├── container-app.bicep      # Main Container App
   │   ├── networking.bicep         # VNet integration
   │   ├── monitoring.bicep         # Log Analytics
   │   └── security.bicep           # Key Vault, Managed Identity
   └── templates/
       ├── basic-web-app.bicep      # Common patterns
       └── api-service.bicep
   ```

4. **Argo Workflows** (to be created)
   ```
   argo/workflows/
   ├── containerapp-create.yaml     # CREATE operation
   ├── containerapp-update.yaml     # UPDATE operation
   ├── containerapp-delete.yaml     # DELETE operation
   └── containerapp-scale.yaml      # SCALE operation
   ```

5. **Argo Events Configuration** (to be created)
   ```
   argo/events/
   ├── eventsource-webhook.yaml     # HTTP webhook endpoint
   └── sensor-containerapp.yaml     # Routes events to workflows
   ```

## Key Implementation Details

### Payload Schema (from PRD)

Container Apps are provisioned using standardized JSON payloads:

```json
{
  "operation": "create|update|delete|scale",
  "metadata": {
    "requestId": "uuid",
    "requestedBy": "user@company.com",
    "team": "team-name",
    "environment": "dev|staging|prod"
  },
  "containerApp": {
    "name": "my-app",
    "resourceGroup": "rg-team-name-env",
    "image": {
      "registry": "myregistry.azurecr.io",
      "repository": "my-app",
      "tag": "v1.0.0"
    },
    "resources": {
      "cpu": 0.25,
      "memory": "0.5Gi"
    },
    "scaling": {
      "minReplicas": 0,
      "maxReplicas": 10,
      "rules": [...]
    },
    "ingress": {
      "external": true,
      "targetPort": 80
    }
  }
}
```

### Workflow Execution Pattern

1. **User submits payload** → API validates and publishes event
2. **Argo EventSource** receives webhook → triggers Sensor
3. **Argo Sensor** routes to appropriate Workflow based on operation type
4. **Argo Workflow** executes steps:
   - Validate payload and permissions
   - Authenticate to Azure (Service Principal)
   - Deploy Bicep templates via `az deployment group create`
   - Verify deployment health
   - Send notifications (Slack/Teams)

### Bicep Module Pattern

Each Bicep module should:
- Accept parameters from the payload
- Use resource naming conventions: `{prefix}-{team}-{env}-{name}`
- Output FQDNs and resource IDs
- Tag resources for cost tracking

Example Container App module structure (docs/prd.md:822-904):
```bicep
param appName string
param environmentId string
param containerImage string
param cpu string = '0.25'
param memory string = '0.5Gi'
param minReplicas int = 0
param maxReplicas int = 10

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  // ... resource definition
}

output fqdn string = containerApp.properties.configuration.ingress.fqdn
```

## Development Workflow

### Phase 1: MVP (Weeks 1-4)
Current focus: Core create/delete operations

**Priority Tasks:**
1. Create Bicep module for Container App Environment (docs/prd.md:452-468)
2. Create Bicep module for Container App (docs/prd.md:820-904)
3. Build Argo Workflow for CREATE operation (docs/prd.md:699-813)
4. Set up Argo EventSource webhook (docs/prd.md:227-245)
5. Build REST API for payload submission (docs/prd.md:596-611)
6. Implement payload validation

### Testing Strategy

- **Unit tests:** Payload validation logic, Bicep parameter generation
- **Integration tests:** End-to-end deployment scenarios with Argo
- **Playwright tests:** UI form submission, dashboard rendering

### Authentication Strategy

**Current:** Firebase Auth (src/lib/firebase.ts:1-26)
**Target:** Azure AD OAuth2

Migration steps:
1. Replace Firebase config with Azure AD app registration
2. Update AuthContext to use MSAL.js
3. Implement token-based API authentication
4. Configure Service Principal for Argo Workflows

## Configuration Files

### Environment Variables (.env.local)

**Current (Firebase):**
```env
NEXT_PUBLIC_FIREBASE_API_KEY=...
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=...
```

**Target (Azure):**
```env
NEXT_PUBLIC_AZURE_AD_CLIENT_ID=...
NEXT_PUBLIC_AZURE_AD_TENANT_ID=...
AZURE_CLIENT_ID=...           # For Argo Workflows
AZURE_CLIENT_SECRET=...       # For Argo Workflows
AZURE_TENANT_ID=...
```

### Kubernetes Configuration

Active context: `kind-argo-workflow` (docs/config.md:9-10)

Namespaces:
- `argo` - Argo Workflows controller
- `argo-events` - EventSources and Sensors
- `argo-rollouts` - Progressive delivery (future use)

## Important Implementation Notes

### Argo Workflows Container Image

Use `mcr.microsoft.com/azure-cli:latest` for workflow steps that execute Azure CLI commands (docs/prd.md:738-780).

### Workflow Authentication

Store Azure credentials in Kubernetes secrets:
```yaml
env:
- name: AZURE_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: azure-credentials
      key: client-id
```

### Bicep Deployment Pattern

```bash
# Parse payload to extract values
APP_NAME=$(echo $PAYLOAD | jq -r '.containerApp.name')
RESOURCE_GROUP=$(echo $PAYLOAD | jq -r '.containerApp.resourceGroup')

# Authenticate
az login --service-principal -u $AZURE_CLIENT_ID -p $AZURE_CLIENT_SECRET --tenant $AZURE_TENANT_ID

# Deploy
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file /bicep/container-app.bicep \
  --parameters appName=$APP_NAME containerImage=$IMAGE
```

### Error Handling

All workflows should:
- Implement exponential backoff retries
- Log errors to Azure Log Analytics
- Send failure notifications via webhook
- Support rollback on critical failures (docs/prd.md:270-275)

## Non-Functional Requirements

From docs/prd.md:320-363:

- **Performance:** Deployment completion < 5 minutes, API response < 200ms
- **Reliability:** 99.9% platform availability, automatic retry on transient failures
- **Security:** RBAC with Azure AD, secrets in Key Vault only, TLS 1.3, network isolation
- **Scalability:** Support 500+ Container Apps, multi-region capability

## Task Master Integration

This project uses Task Master for task tracking. See .taskmaster/CLAUDE.md for full workflow.

**Quick commands:**
```bash
task-master next                    # Get next task to work on
task-master show <id>              # View task details
task-master set-status --id=<id> --status=done
```

## Common Issues & Solutions

### Argo Workflows not triggering
- Check EventSource webhook is exposed: `kubectl get svc -n argo-events`
- Verify Sensor is running: `kubectl get sensors -n argo-events`
- Check webhook payload format matches sensor filters

### Bicep deployment failures
- Validate template syntax: `az bicep build --file template.bicep`
- Check Azure RBAC permissions for Service Principal
- Review deployment logs: `az deployment group show -g <rg> -n <deployment>`

### Authentication errors
- Verify Service Principal credentials are current
- Check Key Vault access policies for Container App managed identity
- Ensure Azure AD app has correct API permissions

## Reference Documentation

- **PRD:** docs/prd.md (full requirements)
- **Azure CLI:** docs/az-conteinrapp-cli.md (Container Apps commands)
- **Config:** docs/config.md (Kubernetes context info)
- **Argo Workflows:** https://argoproj.github.io/workflows/
- **Azure Container Apps:** https://learn.microsoft.com/azure/container-apps/
- **Bicep:** https://learn.microsoft.com/azure/azure-resource-manager/bicep/

## Git Workflow

This repo uses `main-clean` as the primary branch.

```bash
git status                          # Currently on main-clean
git add .
git commit -m "feat: <description>"
git push origin main-clean
```

---

**Document Control**
- Version: 1.0
- Last Updated: 2025-10-01
- Next Review: As major components are implemented
