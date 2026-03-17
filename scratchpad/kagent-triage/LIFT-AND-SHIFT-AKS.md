# Lift-and-Shift Guide — Kind Homelab to Azure AKS

This guide documents every change needed to move the kagent triage pipeline from the Kind homelab cluster to Azure Kubernetes Service (AKS).

## What's Portable (No Changes Needed)

These components work identically on AKS:

| Component | Why It's Portable |
|-----------|-------------------|
| Agent CRs (`*-agent.yaml`) | Standard kagent CRD — cluster-agnostic |
| WorkflowTemplate (`kagent-triage`) | Pure Python scripts calling in-cluster APIs |
| Agent system prompts | Domain knowledge, not cluster-specific |
| MCP tool configuration | Uses in-cluster service DNS |
| RBAC (Roles/RoleBindings) | Standard K8s RBAC |

## What Changes

| Component | Homelab (Kind) | AKS Target | Effort |
|-----------|----------------|------------|--------|
| EventSource | In-cluster K8s event watcher | Azure Event Hub consumer | Medium |
| Secrets | K8s Secrets (manual) | Azure Key Vault + ESO/Workload Identity | Medium |
| Ingress | Traefik IngressRoute + Cloudflare | AGIC or NGINX Ingress + Azure DNS | Low |
| ModelConfig | LiteLLM → Kimi API | Azure OpenAI or direct provider | Low |
| Telegram chat ID | Homelab channel | Work/prod channel | Trivial |
| kubectl context | `kind-homelab` | AKS cluster context | Trivial |

---

## 1. EventSource: K8s Watcher → Azure Event Hub

### Current (Kind Homelab)

The `k8s-warning-events` EventSource watches Kubernetes events directly from the cluster API:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: k8s-warning-events
  namespace: argo-events
spec:
  resource:
    k8s-events:
      namespace: ""  # Cluster-wide
      group: ""
      version: v1
      resource: events
      eventTypes:
        - ADD
      filter:
        afterEventTime: "2024-01-01T00:00:00Z"
      fieldSelector: type=Warning
```

### AKS Target

In the AKS architecture, **workload clusters** ship events to **Event Hub** via **Grafana Alloy**, and the **management cluster** consumes them via Argo Events.

#### Architecture

```
Workload Cluster (AKS)         Management Cluster (AKS)
┌──────────────────┐           ┌──────────────────────┐
│ K8s Warning      │           │ Argo EventSource     │
│ Events           │           │ (Azure Event Hub)    │
│      │           │           │      │               │
│      ▼           │           │      ▼               │
│ Grafana Alloy    │ ──────▶   │ Argo Sensor          │
│ (Kafka protocol) │ Event Hub │ (namespace filter)   │
│                  │           │      │               │
└──────────────────┘           │      ▼               │
                               │ kagent Agent         │
                               └──────────────────────┘
```

#### Workload Cluster: Alloy Configuration

Deploy Grafana Alloy on each workload cluster to forward events to Event Hub:

```yaml
# alloy-values.yaml (Helm)
alloy:
  config: |
    // Discover K8s events
    loki.source.kubernetes_events "events" {
      namespaces = []  // All namespaces
      log_format = "json"
      forward_to = [loki.process.filter_warnings.receiver]
    }

    // Filter for warnings only
    loki.process "filter_warnings" {
      stage.json {
        expressions = {
          type = "type",
          reason = "reason",
          namespace = "involvedObject.namespace",
          kind = "involvedObject.kind",
          name = "involvedObject.name",
          message = "message",
        }
      }
      stage.match {
        selector = '{type="Warning"}'
        action = "keep"
      }
      forward_to = [kafka.write.eventhub.receiver]
    }

    // Send to Azure Event Hub (Kafka protocol)
    kafka.write "eventhub" {
      brokers = ["{{EVENTHUB_NAMESPACE}}.servicebus.windows.net:9093"]
      topic   = "{{EVENTHUB_NAME}}"
      tls {
        enabled = true
      }
      authentication {
        mechanism = "PLAIN"
        username  = "$ConnectionString"
        password  = env("EVENTHUB_CONNECTION_STRING")
      }
    }
```

#### Management Cluster: EventSource

Replace the in-cluster K8s watcher with an Azure Event Hub EventSource:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: azure-eventhub-events
  namespace: argo-events
spec:
  eventBusName: default
  azureEventsHub:
    k8s-events:
      hubName: "{{EVENTHUB_NAME}}"
      fqdn: "{{EVENTHUB_NAMESPACE}}.servicebus.windows.net"
      sharedAccessKeyName:
        name: eventhub-credentials
        key: sharedAccessKeyName
      sharedAccessKey:
        name: eventhub-credentials
        key: sharedAccessKey
```

#### Update Sensor Reference

In each Sensor, change the EventSource name:

```yaml
# Before (Kind)
dependencies:
  - name: k8s-events
    eventSourceName: k8s-warning-events
    eventName: k8s-events

# After (AKS)
dependencies:
  - name: k8s-events
    eventSourceName: azure-eventhub-events
    eventName: k8s-events
```

**Note:** The data path for filtering may change depending on the Event Hub payload format. Verify the JSON structure with:
```bash
# Check event payload format
kubectl logs -n argo-events -l eventsource-name=azure-eventhub-events --tail=5
```

#### Key Placeholders

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{EVENTHUB_NAMESPACE}}` | Event Hub namespace FQDN prefix | `myorg-k8s-events` |
| `{{EVENTHUB_NAME}}` | Event Hub name (topic) | `k8s-warning-events` |
| `{{CLUSTER_NAME}}` | Source cluster identifier | `aks-prod-uksouth` |
| `{{ENVIRONMENT}}` | Environment label | `production` |

---

## 2. Secrets Management

### Current (Kind Homelab)

Secrets are plain Kubernetes Secrets created manually:

```bash
kubectl create secret generic telegram-bot-secret -n argo-events --from-literal=token="..."
kubectl create secret generic litellm-key -n kagent --from-literal=api-key="..."
```

### AKS Target: Azure Key Vault + External Secrets Operator

#### Option A: External Secrets Operator (ESO) — Recommended

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: telegram-bot-secret
  namespace: argo-events
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: telegram-bot-secret
  data:
    - secretKey: token
      remoteRef:
        key: telegram-bot-token

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: litellm-key
  namespace: kagent
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: litellm-key
  data:
    - secretKey: api-key
      remoteRef:
        key: litellm-api-key

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: eventhub-credentials
  namespace: argo-events
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: ClusterSecretStore
  target:
    name: eventhub-credentials
  data:
    - secretKey: sharedAccessKeyName
      remoteRef:
        key: eventhub-shared-access-key-name
    - secretKey: sharedAccessKey
      remoteRef:
        key: eventhub-shared-access-key
```

#### ClusterSecretStore (Azure Key Vault)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: azure-keyvault
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: "https://{{KEY_VAULT_NAME}}.vault.azure.net"
      serviceAccountRef:
        name: external-secrets-sa
        namespace: external-secrets
```

#### Option B: Azure Workload Identity (Direct)

For the WorkflowTemplate's Telegram step, use Workload Identity:

```yaml
# ServiceAccount with Azure identity
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-events-sa
  namespace: argo-events
  annotations:
    azure.workload.identity/client-id: "{{MANAGED_IDENTITY_CLIENT_ID}}"
  labels:
    azure.workload.identity/use: "true"
```

---

## 3. Ingress: Traefik → AGIC/NGINX

### Current (Kind Homelab)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: kagent-ui
  namespace: kagent
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`kagent.xxx`)
      kind: Rule
      services:
        - name: kagent-ui
          port: 8080
  tls:
    certResolver: cloudflare
```

### AKS Target: Application Gateway Ingress Controller (AGIC)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kagent-ui
  namespace: kagent
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/ssl-redirect: "true"
    appgw.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  tls:
    - hosts:
        - kagent.{{DOMAIN}}
      secretName: kagent-tls
  rules:
    - host: kagent.{{DOMAIN}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kagent-ui
                port:
                  number: 8080
```

### AKS Target: NGINX Ingress (Alternative)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kagent-ui
  namespace: kagent
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - kagent.{{DOMAIN}}
      secretName: kagent-tls
  rules:
    - host: kagent.{{DOMAIN}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kagent-ui
                port:
                  number: 8080
```

### DNS

| Homelab | AKS |
|---------|-----|
| Cloudflare DNS (manual) | Azure DNS Zone (automated) |
| `*.xxx` | `*.{{DOMAIN}}` |
| Cloudflare Tunnel (for public) | App Gateway public IP / Internal LB |

---

## 4. ModelConfig: LLM Provider

### Current (Kind Homelab)

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: OpenAI
  model: kimi-for-coding
  apiKeySecret: litellm-key
  apiKeySecretKey: api-key
  openAI:
    baseUrl: http://litellm-proxy.kagent:4000/v1
```

### AKS Target: Azure OpenAI

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: AzureOpenAI
  model: gpt-4o
  apiKeySecret: azure-openai-key
  apiKeySecretKey: api-key
  azureOpenAI:
    endpoint: https://{{AOAI_RESOURCE}}.openai.azure.com
    deploymentName: gpt-4o
    apiVersion: "2024-06-01"
```

### AKS Target: Direct OpenAI

```yaml
apiVersion: kagent.dev/v1alpha2
kind: ModelConfig
metadata:
  name: default-model-config
  namespace: kagent
spec:
  provider: OpenAI
  model: gpt-4o
  apiKeySecret: openai-key
  apiKeySecretKey: api-key
```

---

## 5. Other Changes

### Telegram Chat ID

Update the default Telegram chat ID in the WorkflowTemplate:

```yaml
# In 02-workflow-kagent-triage.yaml
parameters:
  - name: telegram-chat-id
    value: "{{TELEGRAM_CHAT_ID}}"  # Replace with production channel
```

### Resource Scaling

For production AKS, increase agent resources:

```yaml
# In agent CRs
deployment:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi
```

### Namespace Labels

Add environment labels to namespaces for multi-cluster identification:

```yaml
metadata:
  labels:
    kagent-triage: enabled
    environment: production
    cluster: "{{CLUSTER_NAME}}"
```

### ServiceAccount for Workflows

```yaml
# Ensure the workflow SA exists in AKS
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-events-sa
  namespace: argo-events
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-events-workflow-runner
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows", "workflowtemplates"]
    verbs: ["create", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-events-workflow-runner
subjects:
  - kind: ServiceAccount
    name: argo-events-sa
    namespace: argo-events
roleRef:
  kind: ClusterRole
  name: argo-events-workflow-runner
  apiGroup: rbac.authorization.k8s.io
```

---

## Migration Checklist

### Pre-Migration

- [ ] AKS cluster provisioned with Argo Workflows + Argo Events
- [ ] kagent Helm chart installed on AKS (`v0.8.0+`)
- [ ] EventBus (NATS or Jetstream) deployed in `argo-events` namespace
- [ ] Azure Event Hub created and accessible
- [ ] Azure Key Vault provisioned with required secrets
- [ ] External Secrets Operator installed (or Workload Identity configured)
- [ ] DNS zone configured for kagent UI domain
- [ ] Ingress controller (AGIC or NGINX) installed

### Migration Steps

1. [ ] Deploy ExternalSecrets for `telegram-bot-secret`, `litellm-key`, `eventhub-credentials`
2. [ ] Deploy Azure Event Hub EventSource (`azure-eventhub-events`)
3. [ ] Deploy Alloy on workload cluster(s) to forward events
4. [ ] Deploy ModelConfig (Azure OpenAI or preferred provider)
5. [ ] Deploy namespace + RBAC (`00-test-namespace.yaml` — no changes needed)
6. [ ] Deploy Agent CRs (`01-test-agent.yaml` — no changes needed)
7. [ ] Deploy WorkflowTemplate (`02-workflow-kagent-triage.yaml` — update Telegram chat ID)
8. [ ] Deploy Sensor(s) — update `eventSourceName` to `azure-eventhub-events`
9. [ ] Deploy Ingress (replace Traefik IngressRoute with AGIC/NGINX Ingress)
10. [ ] Test E2E with error injection

### Post-Migration Verification

```bash
# Verify all agents are Ready
kubectl get agents -n kagent

# Verify sensor pod is Running and subscribed
kubectl get pods -n argo-events -l sensor-name=kagent-triage-sensor

# Verify Event Hub events are flowing
kubectl logs -n argo-events -l eventsource-name=azure-eventhub-events --tail=10

# Inject test error and verify workflow triggers
kubectl apply -f 05-test-error-injection.yaml
kubectl get workflows -n argo-events -w
```

---

## Summary of File Changes

| File | Change Required |
|------|----------------|
| `00-test-namespace.yaml` | ✅ No change |
| `01-test-agent.yaml` | ✅ No change (update ModelConfig name if different) |
| `02-workflow-kagent-triage.yaml` | ⚠️ Update Telegram chat ID |
| `03-sensor-kagent-triage.yaml` | ⚠️ Update `eventSourceName` |
| `04-ingress-kagent-ui.yaml` | ❌ Replace with AGIC/NGINX Ingress |
| `05-test-error-injection.yaml` | ✅ No change |
| **New:** EventSource | ➕ Azure Event Hub EventSource |
| **New:** ExternalSecrets | ➕ ESO manifests for Key Vault |
| **New:** ModelConfig | ➕ Azure OpenAI ModelConfig |
| **New:** Alloy config | ➕ On workload cluster(s) |
