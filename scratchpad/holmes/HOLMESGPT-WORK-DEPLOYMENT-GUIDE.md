# HolmesGPT Production Deployment Guide (AKS)

**Purpose**: Step-by-step guide to deploy HolmesGPT AI-powered Kubernetes troubleshooting platform on Azure Kubernetes Service (AKS) with Azure OpenAI, AKS-MCP, and chatbot interface.

**Last Updated**: 2025-12-23
**Target Platform**: Azure Kubernetes Service (AKS)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1: LLM Gateway Setup (LiteLLM + Azure OpenAI)](#3-phase-1-llm-gateway-setup-litellm)
4. [Phase 2: AKS-MCP Server Deployment](#4-phase-2-aks-mcp-server-deployment)
5. [Phase 3: Holmes Deployment](#5-phase-3-holmes-deployment)
6. [Phase 4: Chatbot UI](#6-phase-4-chatbot-ui)
7. [Phase 5: Integration & Testing](#7-phase-5-integration--testing)
8. [Phase 6: Optimization](#8-phase-6-optimization)
9. [Troubleshooting](#9-troubleshooting)
10. [Appendix: Configuration Templates](#10-appendix-configuration-templates)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           USER INTERFACE                                 │
│  ┌──────────────────┐                                                   │
│  │   Chatbot UI     │  ← Simple web UI for asking questions             │
│  │  (nginx + HTML)  │                                                   │
│  └────────┬─────────┘                                                   │
│           │ HTTP POST                                                    │
└───────────┼─────────────────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         HOLMES AI ENGINE                                 │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    HolmesGPT                                      │  │
│  │  - Receives investigation requests                                │  │
│  │  - Orchestrates LLM + MCP tool calls                             │  │
│  │  - Synthesizes findings & recommendations                        │  │
│  └────────┬──────────────────────────────────────────┬──────────────┘  │
│           │                                           │                  │
│           ▼                                           ▼                  │
│  ┌──────────────────┐                     ┌────────────────────────┐   │
│  │   LiteLLM        │                     │   MCP Server(s)        │   │
│  │   Gateway        │                     │   - AKS-MCP Server     │   │
│  │                  │                     │   - kubectl, helm, az  │   │
│  └────────┬─────────┘                     └────────────────────────┘   │
│           │                                                             │
└───────────┼─────────────────────────────────────────────────────────────┘
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         LLM PROVIDERS                                    │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     Azure OpenAI Service                        │    │
│  │                     (gpt-4o-mini / gpt-4o)                      │    │
│  │                  Authenticated via Workload Identity            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **User asks question** via Chatbot UI → "Why is my pod crashing?"
2. **Holmes receives request** and determines investigation strategy
3. **Holmes calls LLM** (via LiteLLM) to analyze and plan
4. **LLM decides to use tools** → calls MCP server (kubectl get, describe, logs)
5. **MCP executes commands** and returns results to Holmes
6. **Holmes synthesizes findings** and returns root cause + fix recommendation
7. **Chatbot displays results** to user

---

## 2. Prerequisites

### Existing Infrastructure (if available)

If you already have the AI Ops Chatbot stack deployed, you can reuse:

| Component | Namespace | Can Reuse? | Notes |
|-----------|-----------|------------|-------|
| **AKS-MCP** | `aks-mcp` | Yes | Holmes connects directly to existing AKS-MCP |
| **LiteLLM** | `litellm` | Yes | Holmes uses LiteLLM as AI gateway |
| **Azure OpenAI** | N/A | Yes | Same model (gpt-4o-mini) works for Holmes |
| **Istio Gateway** | `aks-istio-ingress` | Yes | Add VirtualService for Holmes |

**Reference Docs:**
- `docs/AKS-MCP-README.md` - AKS-MCP installation and tools reference
- `docs/AI-OPS-CHATBOT-HANDOVER.md` - Existing chatbot stack details

### Infrastructure Requirements

| Component | Requirement | Notes |
|-----------|-------------|-------|
| AKS Cluster | 1.27+ | Workload Identity enabled |
| Azure OpenAI | Deployed model | gpt-4o-mini or gpt-4o recommended |
| Managed Identity | UAMI | For Workload Identity federation |
| Namespace Access | Create namespaces | holmes, litellm, aks-mcp, chatbot |
| Ingress Controller | Istio (recommended) | For external access with VirtualServices |
| DNS | Azure DNS or external | Optional for external access |

### Required Tools (local machine)

```bash
# Kubernetes CLI
kubectl version --client

# Helm (v3.10+)
helm version

# Azure CLI
az --version

# Logged in to Azure
az account show
```

### Create Namespaces

```bash
kubectl create namespace holmes
kubectl create namespace litellm
kubectl create namespace aks-mcp
kubectl create namespace chatbot
```

### Verify Workload Identity is Enabled

```bash
# Check AKS has OIDC issuer
az aks show --name YOUR_AKS --resource-group YOUR_RG \
  --query "oidcIssuerProfile.issuerUrl" -o tsv

# Should return: https://oidc.prod-aks.azure.com/GUID/
```

---

## Quick Deploy (If AI Ops Chatbot Stack Exists)

If you already have AKS-MCP and LiteLLM deployed from the AI Ops Chatbot stack, skip to Phase 3:

```bash
# Verify existing components
kubectl get pods -n aks-mcp    # Should show aks-mcp running
kubectl get pods -n litellm    # Should show litellm running

# Deploy Holmes only (Phase 3)
kubectl create namespace holmes
helm repo add holmesgpt https://holmesgpt.github.io/holmesgpt-helm-charts
helm repo update
helm install holmes holmesgpt/holmesgpt -n holmes -f holmes-values.yaml

# Deploy Chatbot UI (Phase 4)
kubectl create namespace chatbot
kubectl apply -f chatbot/

# Verify
kubectl get pods -n holmes
```

If components don't exist, continue with full deployment below.

---

## 3. Phase 1: LLM Gateway Setup (LiteLLM + Azure OpenAI)

LiteLLM acts as a unified gateway that connects Holmes to Azure OpenAI. It handles authentication via Workload Identity (no API keys needed in pods).

**Step 1: Create Managed Identity**

```bash
# Create user-assigned managed identity
az identity create \
    --name uami-litellm \
    --resource-group YOUR_RG \
    --location YOUR_LOCATION

# Get client ID
CLIENT_ID=$(az identity show --name uami-litellm --resource-group YOUR_RG --query clientId -o tsv)

# Assign Cognitive Services OpenAI User role
az role assignment create \
    --assignee $CLIENT_ID \
    --role "Cognitive Services OpenAI User" \
    --scope /subscriptions/YOUR_SUB/resourceGroups/YOUR_RG/providers/Microsoft.CognitiveServices/accounts/YOUR_AOAI
```

**Step 2: Create Federated Credential**

```bash
AKS_OIDC_ISSUER=$(az aks show --name YOUR_AKS --resource-group YOUR_RG --query "oidcIssuerProfile.issuerUrl" -o tsv)

az identity federated-credential create \
    --name litellm-federation \
    --identity-name uami-litellm \
    --resource-group YOUR_RG \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:litellm:litellm-sa
```

**Step 3: Deploy LiteLLM for Azure**

```yaml
# litellm-azure-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: litellm
data:
  config.yaml: |
    model_list:
      - model_name: gpt-4o-mini
        litellm_params:
          model: azure/gpt-4o-mini
          api_base: https://YOUR_AOAI.openai.azure.com
          api_version: "2024-10-21"
          azure_ad_token: os.environ/AZURE_FEDERATED_TOKEN_FILE

    litellm_settings:
      drop_params: true
      set_verbose: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litellm-sa
  namespace: litellm
  annotations:
    azure.workload.identity/client-id: "YOUR_CLIENT_ID"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
        azure.workload.identity/use: "true"  # Enable workload identity
    spec:
      serviceAccountName: litellm-sa
      containers:
      - name: litellm
        image: ghcr.io/berriai/litellm:main-latest
        ports:
        - containerPort: 4000
        env:
        - name: LITELLM_CONFIG_PATH
          value: /config/config.yaml
        volumeMounts:
        - name: config
          mountPath: /config
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            memory: 1Gi
      volumes:
      - name: config
        configMap:
          name: litellm-config
```

### Verify LiteLLM Deployment

```bash
# Check pod is running
kubectl get pods -n litellm

# Check logs
kubectl logs -n litellm deploy/litellm --tail=50

# Test health endpoint
kubectl exec -n litellm deploy/litellm -- curl -s http://localhost:4000/health

# Test model endpoint (from within cluster)
kubectl run test-litellm --image=curlimages/curl --rm -i --restart=Never -- \
  curl -X POST http://litellm.litellm.svc.cluster.local:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}'
```

---

## 4. Phase 2: AKS-MCP Server Deployment

AKS-MCP provides tools that Holmes can use during investigations (kubectl, helm, az CLI). It uses Workload Identity for Azure API access.

### AKS-MCP Authentication Methods

AKS-MCP supports multiple authentication methods (tried in order):

| Method | Environment Variables | Use Case |
|--------|----------------------|----------|
| **Workload Identity** | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` | Recommended for AKS |
| Service Principal | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` | CI/CD pipelines |
| User-Assigned MI | `AZURE_CLIENT_ID` only | Azure VMs |
| System-Assigned MI | `AZURE_MANAGED_IDENTITY=system` | Azure VMs |
| Existing Login | None | Local development |

**Note:** The federated token file path must be exactly `/var/run/secrets/azure/tokens/azure-identity-token`.

### Step 1: Create Managed Identity for AKS-MCP

Required for `az` commands (az aks show, az network, az advisor, etc.):

```bash
# Create identity for AKS-MCP
az identity create \
    --name uami-aks-mcp \
    --resource-group YOUR_RG \
    --location YOUR_LOCATION

# Get client ID
AKS_MCP_CLIENT_ID=$(az identity show --name uami-aks-mcp --resource-group YOUR_RG --query clientId -o tsv)

# Assign Reader role on resource group (for az aks show, etc.)
az role assignment create \
    --assignee $AKS_MCP_CLIENT_ID \
    --role "Reader" \
    --scope /subscriptions/YOUR_SUB/resourceGroups/YOUR_RG

# Create federated credential
AKS_OIDC_ISSUER=$(az aks show --name YOUR_AKS --resource-group YOUR_RG --query "oidcIssuerProfile.issuerUrl" -o tsv)

az identity federated-credential create \
    --name aks-mcp-federation \
    --identity-name uami-aks-mcp \
    --resource-group YOUR_RG \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:aks-mcp:aks-mcp-sa
```

### Step 2: Deploy AKS-MCP

**Official Image**: `ghcr.io/azure/aks-mcp:latest` (Microsoft Azure official)

**Access Levels**:
| Level | Permissions |
|-------|-------------|
| `readonly` | get, describe, logs, list operations only |
| `readwrite` | readonly + create, delete, apply, patch |
| `admin` | readwrite + get-credentials, drain, cordon |

**Available Tools** (unified mode - default):
- `call_az` - Execute any Azure CLI command
- `call_kubectl` - Execute any kubectl command
- `helm` - Helm package manager operations
- `az_network_resources` - VNets, Subnets, NSGs, Route Tables
- `az_monitoring` - Metrics, Resource Health, Diagnostics
- `az_advisor_recommendation` - Azure Advisor recommendations

```yaml
# aks-mcp-deployment.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aks-mcp-sa
  namespace: aks-mcp
  annotations:
    azure.workload.identity/client-id: "YOUR_AKS_MCP_CLIENT_ID"  # Required for az CLI commands
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aks-mcp-readonly
rules:
  # Pods and logs
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  # Events
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  # Core resources
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets", "namespaces", "nodes", "persistentvolumeclaims"]
    verbs: ["get", "list"]
  # Workloads
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list"]
  # Networking
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses", "networkpolicies"]
    verbs: ["get", "list"]
  # Istio (if used)
  - apiGroups: ["networking.istio.io"]
    resources: ["virtualservices", "destinationrules", "gateways"]
    verbs: ["get", "list"]
  # CRDs
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-mcp-readonly-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aks-mcp-readonly
subjects:
  - kind: ServiceAccount
    name: aks-mcp-sa
    namespace: aks-mcp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aks-mcp
  template:
    metadata:
      labels:
        app: aks-mcp
        azure.workload.identity/use: "true"  # Enable workload identity
    spec:
      serviceAccountName: aks-mcp-sa
      containers:
      - name: aks-mcp
        image: ghcr.io/azure/aks-mcp:latest
        ports:
        - containerPort: 8000
          name: http
        args:
          - "--transport"
          - "streamable-http"
          - "--port"
          - "8000"
          - "--access-level"
          - "readonly"  # Change to readwrite/admin for auto-healing
        env:
        # Workload Identity injects these automatically:
        # - AZURE_CLIENT_ID
        # - AZURE_TENANT_ID
        # - AZURE_FEDERATED_TOKEN_FILE
        - name: AZURE_SUBSCRIPTION_ID
          value: "YOUR_SUBSCRIPTION_ID"  # Optional: set default subscription
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  selector:
    app: aks-mcp
  ports:
  - port: 8000
    targetPort: 8000
```

### Step 3: Apply Deployment

```bash
kubectl apply -f aks-mcp-deployment.yaml
```

### Verify AKS-MCP Server

```bash
# Check pod is running
kubectl get pods -n aks-mcp

# Check logs
kubectl logs -n aks-mcp deploy/aks-mcp --tail=50

# Test health
kubectl exec -n aks-mcp deploy/aks-mcp -- curl -s http://localhost:8000/health

# Test MCP endpoint
kubectl run test-mcp --image=curlimages/curl --rm -i --restart=Never -- \
  curl -X POST http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp \
  -H "Content-Type: application/json" \
  -d '{"method":"tools/list","params":{}}'
```

---

## 5. Phase 3: Holmes Deployment

Holmes is the AI investigation engine that connects LiteLLM (for reasoning) with MCP servers (for tool execution).

### Step 1: Add Helm Repository

```bash
helm repo add holmesgpt https://holmesgpt.github.io/holmesgpt-helm-charts
helm repo update
```

### Step 2: Create Holmes Values File

```yaml
# holmes-values.yaml
# HolmesGPT Helm Values - Production Configuration

## Basic Configuration
image: holmes
registry: us-central1-docker.pkg.dev/genuine-flight-317411/devel
replicas: 1

logLevel: INFO

# CRITICAL: Prevent Kubernetes service env var conflicts
enableServiceLinks: false

## LLM Configuration via LiteLLM
modelList:
  - model_name: gpt-4o-mini
    litellm_params:
      model: gpt-4o-mini
      api_base: http://litellm.litellm.svc.cluster.local:4000

## MCP Server Integration
# IMPORTANT: Disable built-in toolsets to force MCP usage
toolsets:
  internet:
    enabled: false
  kubernetes/core:
    enabled: false  # MUST disable - forces use of MCP
  kubernetes/logs:
    enabled: false  # MUST disable - forces use of MCP
  prometheus/metrics:
    enabled: false
  robusta:
    enabled: false

mcp_servers:
  aks-mcp:
    description: "Azure Kubernetes Service MCP server for cluster operations"
    config:
      mode: streamable-http  # Use streamable-http (NOT sse)
      url: http://aks-mcp.aks-mcp.svc.cluster.local:8000/mcp
    llm_instructions: |
      AKS-MCP server provides comprehensive Azure Kubernetes troubleshooting tools.

      **Unified Tools (default mode):**
      - call_kubectl: Execute any kubectl command (e.g., "get pods -n kube-system -o wide")
      - call_az: Execute any Azure CLI command (e.g., "az aks show -g myRG -n myCluster")
      - helm: Helm package manager operations

      **Specialized Tools:**
      - az_network_resources: Get VNets, Subnets, NSGs, Route Tables, Load Balancers
      - az_monitoring: Metrics, Resource Health, App Insights, Diagnostics, Control Plane Logs
      - az_advisor_recommendation: Azure Advisor recommendations for Cost, Security, Performance

      **Example Tool Calls:**
      - call_kubectl with args: "get pods -A --field-selector=status.phase!=Running"
      - call_kubectl with args: "logs deployment/myapp -n default --tail=100"
      - call_kubectl with args: "describe pod mypod-xxx -n default"
      - call_kubectl with args: "get events -n default --sort-by='.lastTimestamp'"
      - call_az with cli_command: "az aks show -g myRG -n myCluster -o json"
      - az_network_resources with resource_type: "nsg"

      **Investigation Best Practices:**
      1. Start with call_kubectl "get pods" to identify failing pods
      2. Use call_kubectl "describe pod" for detailed status and events
      3. Use call_kubectl "logs" to check container output
      4. Use call_kubectl "get events" for recent cluster activities
      5. For network issues, use az_network_resources to check NSGs and Route Tables
      6. Use az_monitoring for Azure-level metrics and diagnostics

## Environment Variables
# REQUIRED: Holmes needs these even when using LiteLLM
additionalEnvVars:
  - name: OPENAI_API_KEY
    value: "sk-litellm-proxy"  # Placeholder - Holmes requires this
  - name: OPENAI_API_BASE
    value: "http://litellm.litellm.svc.cluster.local:4000"
  - name: MODEL
    value: "gpt-4o-mini"
  - name: LITELLM_BASE_URL
    value: "http://litellm.litellm.svc.cluster.local:4000"
  - name: ENABLE_TELEMETRY
    value: "false"
  - name: LOG_LEVEL
    value: "INFO"

## Resources
resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    memory: 2Gi

## Service Account
createServiceAccount: true
customServiceAccountName: "holmes-service-account"

customClusterRoleRules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]

## Service Configuration
service:
  type: ClusterIP
  port: 80  # Service port (targets container port 5050)

## Health Probes
# IMPORTANT: Use TCP probes (Holmes doesn't expose /health endpoint reliably)
livenessProbe:
  tcpSocket:
    port: 5050
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 1
  failureThreshold: 3

readinessProbe:
  tcpSocket:
    port: 5050
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 1
  failureThreshold: 3

## Telemetry
enableTelemetry: false
```

### Step 3: Deploy Holmes

```bash
helm install holmes holmesgpt/holmesgpt \
  -n holmes \
  -f holmes-values.yaml
```

### Step 4: Verify Holmes Deployment

```bash
# Check pod is running
kubectl get pods -n holmes

# Check logs for MCP initialization
kubectl logs -n holmes deployment/holmes-holmes --tail=100 | grep -E "✅|❌|Toolset"

# Expected output:
# ✅ Toolset core_investigation
# ✅ Toolset aks-mcp

# Test MCP server reachability from Holmes
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -s http://aks-mcp.aks-mcp.svc.cluster.local:8000/health

# Test Holmes API
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Test Investigation",
    "description": "List all pods in kube-system namespace",
    "subject": {"name": "test", "namespace": "kube-system"},
    "context": {}
  }'
```

---

## 6. Phase 4: Chatbot UI

Simple nginx-based web UI for interacting with Holmes.

### Step 1: Create Chatbot UI HTML

```yaml
# chatbot-html-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chatbot-html
  namespace: chatbot
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>K8s Cluster Chat - Holmes AI</title>
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
                color: #fff;
                min-height: 100vh;
                display: flex;
                flex-direction: column;
            }
            header {
                background: rgba(0,0,0,0.3);
                padding: 20px;
                text-align: center;
                border-bottom: 1px solid rgba(255,255,255,0.1);
            }
            header h1 { font-size: 1.5rem; }
            header p { color: rgba(255,255,255,0.6); font-size: 0.9rem; margin-top: 5px; }
            main {
                flex: 1;
                max-width: 900px;
                margin: 0 auto;
                padding: 20px;
                width: 100%;
            }
            #chat-container {
                background: rgba(255,255,255,0.05);
                border-radius: 12px;
                padding: 20px;
                min-height: 400px;
                max-height: 60vh;
                overflow-y: auto;
                margin-bottom: 20px;
            }
            .message {
                margin-bottom: 15px;
                padding: 15px;
                border-radius: 8px;
            }
            .user-message {
                background: #0066ff;
                margin-left: 20%;
            }
            .assistant-message {
                background: rgba(255,255,255,0.1);
                margin-right: 20%;
            }
            .message-label {
                font-size: 0.75rem;
                opacity: 0.7;
                margin-bottom: 5px;
            }
            .message-content {
                white-space: pre-wrap;
                word-wrap: break-word;
            }
            #input-container {
                display: flex;
                gap: 10px;
            }
            #question-input {
                flex: 1;
                padding: 15px;
                border: none;
                border-radius: 8px;
                background: rgba(255,255,255,0.1);
                color: #fff;
                font-size: 1rem;
            }
            #question-input::placeholder { color: rgba(255,255,255,0.5); }
            #send-btn {
                padding: 15px 30px;
                background: #0066ff;
                border: none;
                border-radius: 8px;
                color: #fff;
                font-size: 1rem;
                cursor: pointer;
                transition: background 0.2s;
            }
            #send-btn:hover { background: #0055dd; }
            #send-btn:disabled { background: #555; cursor: not-allowed; }
            .loading {
                display: inline-block;
                width: 20px;
                height: 20px;
                border: 2px solid rgba(255,255,255,0.3);
                border-top-color: #fff;
                border-radius: 50%;
                animation: spin 1s linear infinite;
            }
            @keyframes spin { to { transform: rotate(360deg); } }
            .error { color: #ff6b6b; }
            .examples {
                margin-top: 20px;
                padding: 15px;
                background: rgba(255,255,255,0.05);
                border-radius: 8px;
            }
            .examples h3 { font-size: 0.9rem; margin-bottom: 10px; }
            .example-btn {
                background: rgba(255,255,255,0.1);
                border: 1px solid rgba(255,255,255,0.2);
                padding: 8px 12px;
                margin: 5px;
                border-radius: 5px;
                color: #fff;
                cursor: pointer;
                font-size: 0.85rem;
            }
            .example-btn:hover { background: rgba(255,255,255,0.2); }
        </style>
    </head>
    <body>
        <header>
            <h1>K8s Cluster Chat</h1>
            <p>Powered by Holmes AI + MCP</p>
        </header>
        <main>
            <div id="chat-container">
                <div class="message assistant-message">
                    <div class="message-label">Holmes AI</div>
                    <div class="message-content">Hello! I can help you investigate Kubernetes cluster issues. Ask me about pods, deployments, services, or any cluster problems.</div>
                </div>
            </div>
            <div id="input-container">
                <input type="text" id="question-input" placeholder="Ask about your cluster (e.g., 'Why is my pod crashing?')" />
                <button id="send-btn">Send</button>
            </div>
            <div class="examples">
                <h3>Example questions:</h3>
                <button class="example-btn" onclick="askExample(this)">What pods are failing?</button>
                <button class="example-btn" onclick="askExample(this)">List pods in kube-system</button>
                <button class="example-btn" onclick="askExample(this)">Check deployment health</button>
                <button class="example-btn" onclick="askExample(this)">Why is my pod in CrashLoopBackOff?</button>
            </div>
        </main>
        <script>
            const chatContainer = document.getElementById('chat-container');
            const input = document.getElementById('question-input');
            const sendBtn = document.getElementById('send-btn');

            function addMessage(content, isUser) {
                const div = document.createElement('div');
                div.className = `message ${isUser ? 'user-message' : 'assistant-message'}`;
                div.innerHTML = `
                    <div class="message-label">${isUser ? 'You' : 'Holmes AI'}</div>
                    <div class="message-content">${content}</div>
                `;
                chatContainer.appendChild(div);
                chatContainer.scrollTop = chatContainer.scrollHeight;
            }

            async function sendMessage() {
                const question = input.value.trim();
                if (!question) return;

                addMessage(question, true);
                input.value = '';
                sendBtn.disabled = true;

                const loadingDiv = document.createElement('div');
                loadingDiv.className = 'message assistant-message';
                loadingDiv.innerHTML = '<div class="loading"></div> Investigating...';
                chatContainer.appendChild(loadingDiv);
                chatContainer.scrollTop = chatContainer.scrollHeight;

                try {
                    const response = await fetch('/api/investigate', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                            source: 'chatbot',
                            title: 'User Question',
                            description: question,
                            subject: { name: 'cluster', namespace: 'default' },
                            context: {}
                        })
                    });

                    chatContainer.removeChild(loadingDiv);

                    if (!response.ok) throw new Error(`HTTP ${response.status}`);

                    const data = await response.json();
                    const analysis = data.analysis || data.result || JSON.stringify(data, null, 2);
                    addMessage(analysis, false);
                } catch (error) {
                    chatContainer.removeChild(loadingDiv);
                    addMessage(`<span class="error">Error: ${error.message}</span>`, false);
                } finally {
                    sendBtn.disabled = false;
                }
            }

            function askExample(btn) {
                input.value = btn.textContent;
                sendMessage();
            }

            sendBtn.addEventListener('click', sendMessage);
            input.addEventListener('keypress', (e) => { if (e.key === 'Enter') sendMessage(); });
        </script>
    </body>
    </html>
```

### Step 2: Create nginx ConfigMap

```yaml
# chatbot-nginx-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: chatbot
data:
  default.conf: |
    server {
        listen 80;
        server_name _;

        # Serve static files
        location / {
            root /usr/share/nginx/html;
            index index.html;
        }

        # Proxy to Holmes API
        location /api/ {
            proxy_pass http://holmes-holmes.holmes.svc.cluster.local:80/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 300s;  # Holmes investigations can take time
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
        }

        # Health check
        location /health {
            return 200 'OK';
            add_header Content-Type text/plain;
        }
    }
```

### Step 3: Deploy Chatbot

```yaml
# chatbot-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatbot
  namespace: chatbot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chatbot
  template:
    metadata:
      labels:
        app: chatbot
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: html
        configMap:
          name: chatbot-html
      - name: nginx-config
        configMap:
          name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: chatbot
  namespace: chatbot
spec:
  selector:
    app: chatbot
  ports:
  - port: 80
    targetPort: 80
```

### Step 4: Expose Chatbot (Ingress)

```yaml
# chatbot-ingress.yaml (for nginx ingress)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatbot
  namespace: chatbot
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - host: chatbot.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: chatbot
            port:
              number: 80
```

Or for Istio:

```yaml
# chatbot-virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: chatbot
  namespace: chatbot
spec:
  hosts:
  - chatbot.your-domain.com
  gateways:
  - istio-system/your-gateway  # Adjust to your gateway
  http:
  - route:
    - destination:
        host: chatbot.chatbot.svc.cluster.local
        port:
          number: 80
```

### Step 5: Deploy and Test

```bash
# Apply all chatbot manifests
kubectl apply -f chatbot-html-configmap.yaml
kubectl apply -f chatbot-nginx-config.yaml
kubectl apply -f chatbot-deployment.yaml
kubectl apply -f chatbot-ingress.yaml

# Port forward for local testing
kubectl port-forward -n chatbot svc/chatbot 8080:80

# Open browser
open http://localhost:8080
```

---

## 7. Phase 5: Integration & Testing

### End-to-End Test Flow

```bash
# 1. Verify all pods are running
kubectl get pods -n litellm
kubectl get pods -n aks-mcp
kubectl get pods -n holmes
kubectl get pods -n chatbot

# 2. Test LiteLLM → LLM Provider
kubectl exec -n litellm deploy/litellm -- curl -s http://localhost:4000/health

# 3. Test Holmes → LiteLLM
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -s http://litellm.litellm.svc.cluster.local:4000/health

# 4. Test Holmes → MCP
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -s http://aks-mcp.aks-mcp.svc.cluster.local:8000/health

# 5. Test complete investigation
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -X POST http://localhost:5050/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Integration Test",
    "description": "List all pods in default namespace and identify any issues",
    "subject": {"name": "integration-test", "namespace": "default"},
    "context": {}
  }'

# 6. Test Chatbot → Holmes
kubectl exec -n chatbot deploy/chatbot -- \
  curl -X POST http://localhost/api/investigate \
  -H "Content-Type: application/json" \
  -d '{
    "source": "test",
    "title": "Chatbot Test",
    "description": "What is the cluster status?",
    "subject": {"name": "test", "namespace": "default"},
    "context": {}
  }'
```

### Common Test Scenarios

| Scenario | Expected Behavior |
|----------|-------------------|
| "List pods in kube-system" | Holmes calls kubectl_get, returns pod list |
| "Why is pod X crashing?" | Holmes calls describe, logs, events, returns root cause |
| "Check deployment health" | Holmes analyzes deployment status, replicas, conditions |
| "Network connectivity issue" | Holmes checks services, endpoints, network policies |

---

## 8. Phase 6: Optimization

### 1. Performance Tuning

**LiteLLM Caching**
```yaml
# In litellm config
litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: redis.default.svc.cluster.local
    port: 6379
```

**Holmes Concurrency**
```yaml
# In Holmes values
replicas: 3
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPU: "70"
```

### 2. Custom Runbooks

Create organization-specific troubleshooting guides:

```yaml
# runbooks-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: holmes-runbooks
  namespace: holmes
data:
  catalog.json: |
    {
      "catalog": [
        {
          "id": "database-connection",
          "update_date": "2025-12-23",
          "description": "Database connection issues, RDS/Aurora connectivity",
          "link": "runbooks/database-connection.md"
        },
        {
          "id": "memory-issues",
          "update_date": "2025-12-23",
          "description": "OOMKilled, memory leaks, high memory usage",
          "link": "runbooks/memory-issues.md"
        }
      ]
    }

  runbooks/database-connection.md: |
    # Database Connection Troubleshooting

    ## Investigation Steps
    1. Check pod environment variables for connection strings
    2. Verify database endpoint is reachable (network policies, security groups)
    3. Check connection pool status
    4. Review pod logs for connection errors

    ## Common Fixes
    - Update security group to allow ingress from cluster
    - Increase connection pool size
    - Check database credentials in secrets

  runbooks/memory-issues.md: |
    # Memory Issues Troubleshooting

    ## Investigation Steps
    1. Check pod memory limits vs requests
    2. Review container memory usage metrics
    3. Look for memory leak patterns in logs
    4. Check JVM heap settings (if Java)

    ## Common Fixes
    - Increase memory limits
    - Add heap dump on OOM
    - Tune garbage collection settings
```

Update Holmes values to use runbooks:
```yaml
# In holmes-values.yaml
custom_runbook_catalogs:
  - "/runbooks/catalog.json"

additionalVolumes:
  - name: custom-runbooks
    configMap:
      name: holmes-runbooks

additionalVolumeMounts:
  - name: custom-runbooks
    mountPath: /runbooks
```

### 3. Monitoring & Observability

**Prometheus Metrics**
```yaml
# In Holmes values
enableMetrics: true
```

**Grafana Dashboard** (see stack-observability skill for pre-built dashboards)

**Key Metrics to Monitor**:
- `holmes_investigations_total` - Investigation count
- `holmes_investigation_duration_seconds` - Latency
- `holmes_mcp_calls_total` - MCP tool usage
- `holmes_errors_total` - Error rate

### 4. Auto-Healing Integration

Connect Holmes to Argo Events for automated incident response:

```yaml
# argo-sensor-holmes.yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: pod-failure-holmes
  namespace: argo-events
spec:
  dependencies:
    - name: pod-failure
      eventSourceName: k8s-events
      eventName: pod-failure
  triggers:
    - template:
        name: investigate-with-holmes
        http:
          url: http://holmes-holmes.holmes.svc.cluster.local:80/api/investigate
          method: POST
          payload:
            - src:
                dependencyName: pod-failure
                dataKey: body
              dest: description
          headers:
            Content-Type: application/json
```

---

## 9. Troubleshooting

### Issue 1: Holmes CrashLoopBackOff - "invalid literal for int()"

**Symptom**: Holmes pod crashes immediately
**Cause**: Kubernetes service env vars conflict with Holmes code
**Fix**: Add `enableServiceLinks: false` to Holmes values

### Issue 2: Holmes can't reach LiteLLM

**Symptom**: "Connection refused" errors
**Debug**:
```bash
# From Holmes pod
kubectl exec -n holmes deploy/holmes-holmes -- \
  curl -v http://litellm.litellm.svc.cluster.local:4000/health
```
**Fix**: Check LiteLLM service/deployment, network policies

### Issue 3: MCP server not loading

**Symptom**: Holmes logs show `❌ Toolset k8s-mcp: Failed to load`
**Cause**: Wrong MCP mode or URL
**Fix**: Use `mode: streamable-http` and correct endpoint path

### Issue 4: LLM authentication failing

**Symptom**: 401/403 from LiteLLM
**Debug**:
```bash
kubectl logs -n litellm deploy/litellm --tail=100 | grep -i error
```
**Fix**: Verify IRSA/workload identity configuration, check API keys

### Issue 5: Chatbot 502 errors

**Symptom**: Chatbot UI shows connection errors
**Cause**: nginx proxy pointing to wrong Holmes service
**Fix**: Update nginx config to use `holmes-holmes.holmes.svc.cluster.local:80`

---

## 10. Appendix: Configuration Templates

### Full Deployment Script

```bash
#!/bin/bash
set -e

echo "Deploying HolmesGPT Stack for AKS..."

# Create namespaces
for ns in holmes litellm aks-mcp chatbot; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
done

# Deploy LiteLLM with Workload Identity
echo "Deploying LiteLLM..."
kubectl apply -f litellm/

# Deploy AKS-MCP
echo "Deploying AKS-MCP..."
kubectl apply -f aks-mcp/

# Wait for LiteLLM
echo "Waiting for LiteLLM..."
kubectl rollout status deployment/litellm -n litellm --timeout=120s

# Wait for AKS-MCP
echo "Waiting for AKS-MCP server..."
kubectl rollout status deployment/aks-mcp -n aks-mcp --timeout=120s

# Deploy Holmes
echo "Deploying Holmes..."
helm upgrade --install holmes holmesgpt/holmesgpt \
  -n holmes \
  -f holmes-values.yaml \
  --wait

# Deploy Chatbot
echo "Deploying Chatbot UI..."
kubectl apply -f chatbot/

echo "Deployment complete!"
echo ""
echo "Test commands:"
echo "  kubectl port-forward -n chatbot svc/chatbot 8080:80"
echo "  open http://localhost:8080"
```

### Quick Health Check Script

```bash
#!/bin/bash

echo "=== HolmesGPT Stack Health Check ==="

# Check LiteLLM
echo -n "LiteLLM: "
kubectl exec -n litellm deploy/litellm -- curl -sf http://localhost:4000/health > /dev/null && echo "OK" || echo "FAIL"

# Check AKS-MCP
echo -n "AKS-MCP: "
kubectl exec -n aks-mcp deploy/aks-mcp -- curl -sf http://localhost:8000/health > /dev/null && echo "OK" || echo "FAIL"

# Check Holmes
echo -n "Holmes: "
kubectl exec -n holmes deploy/holmes-holmes -- curl -sf http://localhost:5050/api/investigate \
  -X POST -H "Content-Type: application/json" \
  -d '{"source":"health","title":"Health Check","description":"ping","subject":{"name":"test","namespace":"default"},"context":{}}' > /dev/null && echo "OK" || echo "FAIL"

# Check Chatbot
echo -n "Chatbot: "
kubectl exec -n chatbot deploy/chatbot -- curl -sf http://localhost:80/health > /dev/null && echo "OK" || echo "FAIL"

echo ""
echo "=== Pod Status ==="
kubectl get pods -n litellm -n aks-mcp -n holmes -n chatbot
```

---

## Summary Checklist

- [ ] **Prerequisites**: AKS with Workload Identity enabled
- [ ] **Prerequisites**: Azure OpenAI deployed with gpt-4o-mini model
- [ ] **Phase 1**: LiteLLM deployed and connected to Azure OpenAI via Workload Identity
- [ ] **Phase 2**: AKS-MCP deployed with cluster read access (RBAC)
- [ ] **Phase 3**: Holmes deployed with MCP integration verified
- [ ] **Phase 4**: Chatbot UI deployed and accessible
- [ ] **Phase 5**: End-to-end test passes (ask a question, get cluster data back)
- [ ] **Phase 6**: Custom runbooks added (optional)
- [ ] **Phase 6**: Monitoring configured (optional)
- [ ] **Phase 6**: Auto-healing with Argo Events integration (optional)

---

**Questions?** Check the skill documentation at `.claude/skills/holmesgpt-deployer/` or the troubleshooting section above.
