# Namespace Onboarding with Argo Workflows

Automated Kubernetes namespace provisioning using Argo Workflows and Argo Events. This system provides a self-service platform for teams to request and provision namespaces with proper resource quotas, network policies, and labeling.

## Architecture Overview

```
┌─────────────────┐         ┌──────────────────────┐         ┌─────────────────────┐
│                 │  POST   │                      │         │                     │
│  Web UI / API   ├────────►│  Argo Events         ├────────►│  Argo Workflows     │
│  Client         │         │  Webhook EventSource │         │  WorkflowTemplate   │
└─────────────────┘         └──────────────────────┘         └──────────┬──────────┘
                                                                        │
                            ┌───────────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────────────────────────────────┐
              │                    Workflow DAG                          │
              │                                                          │
              │  ┌──────────────┐                                        │
              │  │ parse-payload│                                        │
              │  └──────┬───────┘                                        │
              │         │                                                │
              │         ▼                                                │
              │  ┌──────────────────┐                                    │
              │  │ create-namespace │                                    │
              │  └────────┬─────────┘                                    │
              │           │                                              │
              │     ┌─────┴─────┐                                        │
              │     ▼           ▼                                        │
              │  ┌────────────────┐  ┌─────────────────────┐             │
              │  │ create-quota   │  │ create-network-policy│             │
              │  └───────┬────────┘  └──────────┬──────────┘             │
              │          │                      │                        │
              │          └──────────┬───────────┘                        │
              │                     ▼                                    │
              │            ┌─────────────────────┐                       │
              │            │ store-configuration │                       │
              │            └─────────────────────┘                       │
              └─────────────────────────────────────────────────────────┘
```

## Components

### Directory Structure

```
application-stack/core/
├── argo-events/
│   ├── 01-namespace.yaml              # argo-events namespace
│   ├── 02-eventbus.yaml               # NATS-based EventBus
│   ├── 03-auth-secrets.yaml           # Webhook auth token + TLS certs
│   ├── 04-eventsource.yaml            # Webhook endpoints
│   ├── 05-sensor.yaml                 # Event-to-workflow trigger
│   ├── 06-enhanced-workflow-template.yaml  # Event-driven template variant
│   ├── 07-rbac.yaml                   # Argo Events RBAC
│   ├── 08-monitoring.yaml             # Prometheus metrics
│   └── 09-integration-tests.sh        # Test suite
├── argo-workflows/
│   ├── rbac.yaml                      # Workflow service account & permissions
│   ├── namespace-onboarding-template.yaml  # Main WorkflowTemplate
│   └── complete-namespace-workflow.yaml    # Standalone workflow variant
└── scripts/
    ├── apply-configurations.sh        # Deploy all resources
    └── deploy-and-test.sh             # Deploy + run tests
```

### Key Resources

| Resource | Name | Namespace | Purpose |
|----------|------|-----------|---------|
| WorkflowTemplate | `namespace-onboarding-template` | `argo` | Main provisioning logic |
| EventSource | `namespace-onboarding-webhook` | `argo-events` | Webhook endpoints |
| Sensor | `namespace-onboarding-sensor` | `argo-events` | Triggers workflows |
| ServiceAccount | `argo-namespace-provisioner` | `argo` | Workflow execution identity |
| ClusterRole | `namespace-provisioner` | - | Permissions for provisioning |

## API Specification

### Webhook Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/onboard` | POST | Bearer token | Submit namespace onboarding request |
| `/health` | GET | None | Health check |
| `/status` | GET | None | Status monitoring |

**Port:** 12000

### Request Payload

```json
{
  "NamespaceName": "my-app-dev",
  "Swc": "AA11111",
  "Environment": "DEV",
  "ResourceQuotaCPU": 2,
  "ResourceQuotaMemoryGB": 2,
  "ResourceQuotaStorageGB": 10,
  "AllowAccessFromNS": "ingress-nginx",
  "BillingReference": "COST-CENTER-123",
  "ManagedAksClusterName": "minikube"
}
```

### Field Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `NamespaceName` | string | Yes | - | Namespace name (DNS-1123 label format) |
| `Swc` | string | Yes | - | Software component ID (alphanumeric) |
| `Environment` | enum | Yes | - | `DEV`, `STAGING`, or `PROD` |
| `ResourceQuotaCPU` | number | No | `2` | CPU cores limit |
| `ResourceQuotaMemoryGB` | number | No | `2` | Memory limit in GB |
| `ResourceQuotaStorageGB` | number | No | `0` | Storage limit in GB |
| `AllowAccessFromNS` | string | No | - | Namespace allowed to access (NetworkPolicy) |
| `BillingReference` | string | No | - | Cost allocation reference |
| `ManagedAksClusterName` | string | No | `minikube` | Target cluster name |

## Deployment

### Prerequisites

- Kubernetes cluster (minikube, AKS, etc.)
- Argo Workflows installed
- Argo Events installed
- kubectl configured

### Deploy All Resources

```bash
# Run the deployment script
./application-stack/core/scripts/apply-configurations.sh

# Or deploy and run tests
./application-stack/core/scripts/deploy-and-test.sh
```

### Manual Deployment Order

```bash
# 1. Argo Events namespace and EventBus
kubectl apply -f application-stack/core/argo-events/01-namespace.yaml
kubectl apply -f application-stack/core/argo-events/02-eventbus.yaml

# 2. Authentication secrets
kubectl apply -f application-stack/core/argo-events/03-auth-secrets.yaml

# 3. EventSource and Sensor
kubectl apply -f application-stack/core/argo-events/04-eventsource.yaml
kubectl apply -f application-stack/core/argo-events/05-sensor.yaml

# 4. RBAC
kubectl apply -f application-stack/core/argo-events/07-rbac.yaml
kubectl apply -f application-stack/core/argo-workflows/rbac.yaml

# 5. WorkflowTemplate
kubectl apply -f application-stack/core/argo-workflows/namespace-onboarding-template.yaml
```

### Verify Deployment

```bash
# Check Argo Events resources
kubectl get eventsources,sensors -n argo-events

# Check WorkflowTemplate
kubectl get workflowtemplates -n argo

# Check pods are running
kubectl get pods -n argo-events
kubectl get pods -n argo
```

## Usage

### Option 1: Event-Driven via Webhook

```bash
# Port forward to webhook service
kubectl port-forward svc/namespace-onboarding-webhook-eventsource-svc \
  12000:12000 -n argo-events

# Submit onboarding request
curl -X POST http://localhost:12000/onboard \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer namespace-onboarding-webhook-token" \
  -d '{
    "NamespaceName": "my-new-namespace",
    "Swc": "APP001",
    "Environment": "DEV",
    "ResourceQuotaCPU": 2,
    "ResourceQuotaMemoryGB": 4,
    "ResourceQuotaStorageGB": 10,
    "ManagedAksClusterName": "minikube"
  }'
```

### Option 2: Direct REST API to Argo Server

```bash
# Port forward to Argo Server
kubectl port-forward svc/argo-server 2746:2746 -n argo

# Submit workflow via REST API
curl -X POST http://localhost:2746/api/v1/workflows/argo/submit \
  -H "Content-Type: application/json" \
  -d '{
    "namespace": "argo",
    "resourceKind": "WorkflowTemplate",
    "resourceName": "namespace-onboarding-template",
    "submitOptions": {
      "parameters": [
        "payload={\"NamespaceName\":\"my-namespace\",\"Swc\":\"APP001\",\"Environment\":\"DEV\",\"ResourceQuotaCPU\":2,\"ResourceQuotaMemoryGB\":2,\"ResourceQuotaStorageGB\":0,\"ManagedAksClusterName\":\"minikube\"}",
        "targetCluster=minikube"
      ]
    }
  }'
```

### Option 3: Argo CLI

```bash
# Submit using argo CLI
argo submit --from workflowtemplate/namespace-onboarding-template \
  -p payload='{"NamespaceName":"my-namespace","Swc":"APP001","Environment":"DEV","ResourceQuotaCPU":2,"ResourceQuotaMemoryGB":2,"ResourceQuotaStorageGB":0,"ManagedAksClusterName":"minikube"}' \
  -p targetCluster=minikube \
  -n argo
```

## What Gets Created

When a namespace is onboarded, the workflow creates:

### 1. Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <NamespaceName>
  labels:
    onboarding: "true"
    managed-by: "argo-workflows"
    cluster: <ManagedAksClusterName>
    swc: <Swc>
    environment: <Environment>
  annotations:
    billing-reference: <BillingReference>
    creation-timestamp: <ISO8601 timestamp>
```

### 2. ResourceQuota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: <NamespaceName>
spec:
  hard:
    requests.cpu: "<ResourceQuotaCPU>"
    requests.memory: <ResourceQuotaMemoryGB>Gi
    requests.storage: <ResourceQuotaStorageGB>Gi
    limits.cpu: "<ResourceQuotaCPU>"
    limits.memory: <ResourceQuotaMemoryGB>Gi
    persistentvolumeclaims: "10"
```

### 3. NetworkPolicies

**Default deny-all policy:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: <NamespaceName>
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

**Allow from specific namespace (if `AllowAccessFromNS` specified):**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-namespace
  namespace: <NamespaceName>
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: <AllowAccessFromNS>
```

### 4. Configuration ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <NamespaceName>-onboarding-config
  namespace: <NamespaceName>
  labels:
    onboarding: "true"
    managed-by: "argo-workflows"
data:
  config.json: |
    <original JSON payload>
```

## Testing

### Run Integration Tests

```bash
./application-stack/core/argo-events/09-integration-tests.sh
```

### Test Cases Covered

1. Health check endpoint (GET `/health`)
2. Status endpoint (GET `/status`)
3. Unauthorized request rejection (401)
4. Authorized onboarding request (200)
5. Invalid environment value handling
6. Missing required fields handling
7. Invalid payload structure handling
8. Workflow creation verification
9. EventSource logs inspection
10. Sensor logs inspection

### Manual Verification

```bash
# Check workflow status
argo list -n argo

# Get workflow details
argo get <workflow-name> -n argo

# Check created namespace
kubectl get namespace <NamespaceName> --show-labels

# Check resource quota
kubectl get resourcequota -n <NamespaceName>

# Check network policies
kubectl get networkpolicies -n <NamespaceName>
```

## RBAC Permissions

The `argo-namespace-provisioner` ServiceAccount has ClusterRole permissions for:

| API Group | Resources | Verbs |
|-----------|-----------|-------|
| `""` (core) | namespaces, configmaps, secrets, pods, services, serviceaccounts, persistentvolumeclaims, events, limitranges, resourcequotas | create, get, list, watch, update, patch, delete |
| `apps` | deployments, statefulsets, daemonsets, replicasets | create, get, list, watch, update, patch, delete |
| `batch` | jobs, cronjobs | create, get, list, watch, update, patch, delete |
| `networking.k8s.io` | networkpolicies, ingresses | create, get, list, watch, update, patch, delete |
| `rbac.authorization.k8s.io` | roles, rolebindings | create, get, list, watch, update, patch, delete |
| `argoproj.io` | workflowtaskresults, rollouts, analysisruns, analysistemplates, experiments | create, get, list, watch, update, patch, delete |

## Monitoring

Prometheus metrics are available via ServiceMonitor:

```bash
# Check metrics services
kubectl get svc -n argo-events | grep metrics

# Port forward to metrics endpoint
kubectl port-forward svc/eventsource-metrics-service 9090:9090 -n argo-events
```

## Troubleshooting

### Common Issues

**EventSource pod not starting:**
```bash
kubectl describe eventsource namespace-onboarding-webhook -n argo-events
kubectl logs -l owner-name=namespace-onboarding-webhook -n argo-events
```

**Sensor not triggering workflows:**
```bash
kubectl describe sensor namespace-onboarding-sensor -n argo-events
kubectl logs -l sensor-name=namespace-onboarding-sensor -n argo-events
```

**Workflow failing:**
```bash
argo logs <workflow-name> -n argo
kubectl describe workflow <workflow-name> -n argo
```

**Permission denied errors:**
```bash
# Check ServiceAccount binding
kubectl get clusterrolebinding argo-namespace-provisioner-binding -o yaml

# Verify ServiceAccount exists
kubectl get sa argo-namespace-provisioner -n argo
```

### Idempotent Operations

The workflow is idempotent:
- If namespace exists, labels and annotations are updated
- ResourceQuota and NetworkPolicies use `kubectl apply` (create or update)
- ConfigMap is created or updated with latest payload

## Extending the Workflow

### Adding New Steps

Edit `namespace-onboarding-template.yaml` to add new DAG tasks:

```yaml
- name: create-custom-resource
  template: create-custom-resource
  dependencies: [create-namespace]
  arguments:
    parameters:
      - name: namespace
        value: "{{tasks.parse-payload.outputs.parameters.namespace}}"
```

### Adding New Payload Fields

1. Update the `parse-json-payload` template to extract new fields
2. Add new output parameters
3. Pass parameters to relevant templates

## Security Considerations

- Webhook endpoint requires Bearer token authentication
- TLS certificates for encrypted transport (self-signed for local dev)
- Network isolation via default deny-all NetworkPolicy
- RBAC scoped to minimum required permissions
- Sensitive data stored in Kubernetes Secrets

## GitOps Integration

The `store-configuration` step can be extended to:
1. Clone a GitOps repository
2. Create/update namespace manifests
3. Commit and push changes
4. Trigger ArgoCD sync for declarative management

This enables disaster recovery by re-applying stored configurations.
