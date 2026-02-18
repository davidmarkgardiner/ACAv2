# KAgent Multi-Cluster — Mgmt Cluster → Worker Clusters

> KAgent runs on the AKS management cluster and investigates/remediates issues on worker clusters.
> Two approaches: **Centralized** (single AKS-MCP with UAMI) or **Distributed** (AKS-MCP per cluster, no UAMI).

---

## Decision: Centralized vs Distributed

| | Option A: Centralized | Option B: Distributed (recommended) |
|---|---|---|
| **AKS-MCP** | Single instance on mgmt cluster | One instance per worker cluster |
| **Auth** | UAMI + `az aks get-credentials` per call | In-cluster ServiceAccount (no UAMI) |
| **Credential mgmt** | Agent fetches creds before each investigation | None — in-cluster SA always valid |
| **Networking** | All local (mgmt cluster only) | Cross-cluster (Istio VirtualService / Internal LB) |
| **Blast radius** | UAMI can reach all clusters | Each MCP only sees its own cluster |
| **Agent count** | 1 triage + 1 remediation agent | 1 triage + 1 remediation per cluster |
| **Complexity** | UAMI setup, credential refresh, `--context` in every command | Istio ingress per cluster, more agent CRDs |
| **Scalability** | Single point of failure | Scales horizontally, isolated failures |
| **Best for** | Quick PoC / few clusters | Production / many clusters |

---

# Option A: Centralized AKS-MCP (UAMI)

```
┌──────────────────────────────────────────────────────────────┐
│                   AKS MANAGEMENT CLUSTER                       │
│                                                                │
│  ┌────────────────────────────────────────┐                   │
│  │  AKS-MCP (single instance)             │                   │
│  │  - Workload Identity (UAMI)            │                   │
│  │  - Fetches creds on-demand per call    │                   │
│  │  - call_kubectl --context <cluster>    │                   │
│  └──────────────┬─────────────────────────┘                   │
│                  │ MCP tools                                    │
│  ┌──────────────┴─────────────────────────┐                   │
│  │  sre-triage-agent (single)             │                   │
│  │  - AKS-MCP as primary tool source      │                   │
│  │  - Prompt includes target cluster      │                   │
│  └──────────────┬─────────────────────────┘                   │
│                  │ A2A                                          │
│  ┌──────────────┴─────────────────────────┐                   │
│  │  Argo Workflow                          │                   │
│  │  - Passes cluster + resource_group     │                   │
│  └────────────────────────────────────────┘                   │
└──────────┬──────────────┬──────────────┬──────────────────────┘
           │ UAMI auth     │              │
           ▼              ▼              ▼
    aks-prod-we     aks-stg-we     aks-dev-we
```

## A1. UAMI Setup

### Create the UAMI

```bash
UAMI_NAME="aks-mcp-identity"
RG="rg-mgmt-cluster"
LOCATION="westeurope"

az identity create \
  --name $UAMI_NAME \
  --resource-group $RG \
  --location $LOCATION

CLIENT_ID=$(az identity show --name $UAMI_NAME --resource-group $RG --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name $UAMI_NAME --resource-group $RG --query principalId -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

### Assign RBAC on Each Worker Cluster

```bash
WORKER_CLUSTERS=(
  "aks-prod-westeurope:rg-aks-prod-westeurope:prod-sub-id"
  "aks-staging-westeurope:rg-aks-staging-westeurope:stg-sub-id"
  "aks-dev-westeurope:rg-aks-dev-westeurope:dev-sub-id"
)

for entry in "${WORKER_CLUSTERS[@]}"; do
  IFS=':' read -r CLUSTER RG SUB <<< "$entry"
  CLUSTER_ID=$(az aks show --name $CLUSTER --resource-group $RG --subscription $SUB --query id -o tsv)

  # Read-only (triage)
  az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope $CLUSTER_ID

  # Read-write (remediation) — only if needed
  az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Kubernetes Service Cluster Admin Role" \
    --scope $CLUSTER_ID
done
```

### Create Federated Credential

```bash
AKS_OIDC_ISSUER=$(az aks show \
  --name mgmt-cluster \
  --resource-group rg-mgmt-cluster \
  --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create \
  --name aks-mcp-federated \
  --identity-name $UAMI_NAME \
  --resource-group $RG \
  --issuer $AKS_OIDC_ISSUER \
  --subject "system:serviceaccount:aks-mcp:aks-mcp-sa" \
  --audiences "api://AzureADTokenExchange"
```

## A2. AKS-MCP Deployment (Mgmt Cluster)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aks-mcp-sa
  namespace: aks-mcp
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/client-id: "<CLIENT_ID>"
    azure.workload.identity/tenant-id: "<TENANT_ID>"
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
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: aks-mcp-sa
      containers:
        - name: aks-mcp
          image: ghcr.io/azure/aks-mcp:v0.0.12
          args:
            - --transport=streamable-http
            - --access-level=admin
          ports:
            - containerPort: 8000
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
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

Register as RemoteMCPServer:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-central
  namespace: kagent
spec:
  url: http://aks-mcp.aks-mcp.svc:8000/mcp
  transport: streamableHTTP
```

## A3. Agent CRD (Centralized)

Single agent, uses `--context` to target different clusters:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: sre-triage-agent
  namespace: kagent
spec:
  description: SRE Triage Agent - investigates issues on worker clusters via centralized AKS-MCP
  type: Declarative
  declarative:
    systemMessage: |
      You are an SRE Triage Agent on the AKS management cluster.
      You investigate issues on REMOTE worker clusters.

      ## Multi-Cluster Access
      - STEP 1: Fetch credentials for the target cluster:
        run_az_cli_command("az aks get-credentials --resource-group <RG> --name <CLUSTER> --overwrite-existing")
      - STEP 2: Use call_kubectl with --context <cluster-name> for all commands
      - STEP 3: Use call_helm with --kube-context <cluster-name> for helm commands
      - The investigation request tells you the cluster name and resource group

      ## Rules
      - Always fetch credentials before your first kubectl/helm command
      - Always include --context in every kubectl command
      - Always use the EXACT namespace from the investigation request
      - Be concise. Bullet points over paragraphs.
      # ... rest of existing rules and runbooks ...

    modelConfig: azure-openai-gpt4o
    tools:
      - type: McpServer
        mcpServer:
          name: aks-mcp-central
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            - call_kubectl
            - call_helm
            - run_az_cli_command
            - list_detectors
            - get_detector
      # kagent-tool-server for mgmt cluster self-diagnostics (optional)
      - type: McpServer
        mcpServer:
          name: kagent-tool-server
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            - k8s_get_resources
            - k8s_describe_resource
            - k8s_get_pod_logs
            - k8s_get_events
            - helm_list_releases
            - helm_get_release
```

## A4. Workflow Prompt (Centralized)

```
Investigate this Kubernetes issue on a REMOTE worker cluster:

Target Cluster: {{workflow.parameters.cluster}}
Resource Group: {{workflow.parameters.resource_group}}
Namespace: {{workflow.parameters.namespace}}
Resource: {{workflow.parameters.resource_kind}}/{{workflow.parameters.resource_name}}
Event: {{workflow.parameters.event_type}}
Severity: {{workflow.parameters.severity}}
Error: {{workflow.parameters.error_message}}

Query: {{workflow.parameters.query}}

CRITICAL:
1. First fetch credentials: run_az_cli_command("az aks get-credentials --resource-group {{workflow.parameters.resource_group}} --name {{workflow.parameters.cluster}} --overwrite-existing")
2. Then use call_kubectl with --context {{workflow.parameters.cluster}} for ALL commands
3. Use the EXACT namespace "{{workflow.parameters.namespace}}" — copy it exactly
```

## A5. Checklist (Centralized)

```
UAMI:
  [ ] UAMI created in Azure
  [ ] RBAC assigned on all worker clusters
  [ ] Federated credential linked to aks-mcp-sa
  [ ] ServiceAccount annotated with client-id and tenant-id

AKS-MCP:
  [ ] Deployed on mgmt cluster with Workload Identity
  [ ] Registered as RemoteMCPServer in kagent namespace
  [ ] Test: run_az_cli_command("az aks get-credentials ...") succeeds
  [ ] Test: call_kubectl("kubectl --context <cluster> get nodes") works

Agent + Workflow:
  [ ] sre-triage-agent has AKS-MCP as primary tool source
  [ ] Workflow passes cluster + resource_group parameters
  [ ] Prompt includes credential fetch + --context instructions
  [ ] End-to-end test: alert on worker cluster → triage → GitLab issue
```

---

# Option B: Distributed AKS-MCP (Recommended)

```
┌──────────────────────────────────────────────────────────────┐
│                   AKS MANAGEMENT CLUSTER                       │
│                                                                │
│  KAgent controller + agents                                    │
│                                                                │
│  sre-triage-prod-we ─────► RemoteMCPServer: aks-mcp-prod-we  │
│  sre-triage-stg-we ──────► RemoteMCPServer: aks-mcp-stg-we   │
│  sre-triage-dev-we ──────► RemoteMCPServer: aks-mcp-dev-we   │
│                                                                │
│  Argo Workflow: routes alert → correct agent by cluster name  │
└──────────┬──────────────┬──────────────┬──────────────────────┘
           │ Istio mesh    │              │
           │ / Internal LB │              │
           ▼              ▼              ▼
    ┌────────────┐ ┌────────────┐ ┌────────────┐
    │aks-prod-we │ │aks-stg-we  │ │aks-dev-we  │
    │            │ │            │ │            │
    │ AKS-MCP   │ │ AKS-MCP   │ │ AKS-MCP   │
    │ in-cluster │ │ in-cluster │ │ in-cluster │
    │ SA (no     │ │ SA (no     │ │ SA (no     │
    │  UAMI)     │ │  UAMI)     │ │  UAMI)     │
    │            │ │            │ │            │
    │ Istio      │ │ Istio      │ │ Istio      │
    │ ingress GW │ │ ingress GW │ │ ingress GW │
    └────────────┘ └────────────┘ └────────────┘
```

### Why this is better

1. **No UAMI** — AKS-MCP uses in-cluster SA, always authenticated, never expires
2. **Better security** — each MCP instance only has access to its own cluster
3. **Isolated failures** — if one AKS-MCP goes down, other clusters unaffected
4. **Simpler agent prompts** — no `--context` flag, no credential fetching step, agent just calls `call_kubectl("kubectl get pods -n X")`
5. **Scales naturally** — add a new cluster = deploy AKS-MCP + register RemoteMCPServer + create agent CRD

## B1. AKS-MCP Deployment (Per Worker Cluster)

Deploy this on **each worker cluster**:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: aks-mcp
  labels:
    istio-injection: enabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aks-mcp-sa
  namespace: aks-mcp
---
# RBAC: read-only for triage
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aks-mcp-readonly
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "policy", "rbac.authorization.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "describe"]
  - apiGroups: [""]
    resources: ["pods/log", "pods/exec"]
    verbs: ["get", "create"]
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
    spec:
      serviceAccountName: aks-mcp-sa
      containers:
        - name: aks-mcp
          image: ghcr.io/azure/aks-mcp:v0.0.12
          args:
            - --transport=streamable-http
            - --access-level=readonly       # triage only; use "readwrite" for remediation
          ports:
            - containerPort: 8000
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
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
    - name: http-mcp
      port: 8000
      targetPort: 8000
```

## B2. Expose via Istio Ingress Gateway + VirtualService

On **each worker cluster**, expose AKS-MCP through the Istio ingress gateway so the mgmt cluster can reach it:

```yaml
# Gateway — use existing shared gateway or create per-service
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: aks-mcp-gateway
  namespace: aks-mcp
spec:
  selector:
    istio: ingressgateway              # or your gateway label
  servers:
    - port:
        number: 443
        name: https-mcp
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: aks-mcp-tls    # cert-manager Certificate secret
      hosts:
        - "aks-mcp.prod-we.internal.company.com"    # unique per cluster
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  hosts:
    - "aks-mcp.prod-we.internal.company.com"
  gateways:
    - aks-mcp-gateway
  http:
    - match:
        - uri:
            prefix: /mcp
      route:
        - destination:
            host: aks-mcp.aks-mcp.svc.cluster.local
            port:
              number: 8000
      timeout: 300s                    # agent investigations can take minutes
      retries:
        attempts: 2
        retryOn: 5xx,reset,connect-failure
---
# Optional: mTLS between clusters via Istio multi-cluster mesh
# If clusters are in the same Istio trust domain, mTLS is automatic
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: aks-mcp-mtls
  namespace: aks-mcp
spec:
  selector:
    matchLabels:
      app: aks-mcp
  mtls:
    mode: STRICT
```

### Alternative: Internal LoadBalancer (no Istio)

If Istio isn't available on worker clusters, use an Azure Internal LB:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: aks-mcp-external
  namespace: aks-mcp
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    # Optional: pin to a specific subnet
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks-services"
spec:
  type: LoadBalancer
  selector:
    app: aks-mcp
  ports:
    - name: http-mcp
      port: 8000
      targetPort: 8000
```

Then use the internal LB IP in the RemoteMCPServer URL.

### DNS Setup

Create Azure Private DNS records (or use your internal DNS):

```bash
# For each worker cluster's AKS-MCP
# Option 1: Istio ingress IP
INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context aks-prod-we)

# Option 2: Internal LB IP
LB_IP=$(kubectl get svc aks-mcp-external -n aks-mcp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context aks-prod-we)

# Add DNS record
az network private-dns record-set a add-record \
  --zone-name internal.company.com \
  --resource-group rg-dns \
  --record-set-name aks-mcp.prod-we \
  --ipv4-address $INGRESS_IP
```

## B3. Register RemoteMCPServers (Mgmt Cluster)

On the **mgmt cluster**, register each worker cluster's AKS-MCP:

```yaml
# One RemoteMCPServer per worker cluster
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-prod-we
  namespace: kagent
spec:
  url: https://aks-mcp.prod-we.internal.company.com/mcp
  transport: streamableHTTP
---
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-stg-we
  namespace: kagent
spec:
  url: https://aks-mcp.stg-we.internal.company.com/mcp
  transport: streamableHTTP
---
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-dev-we
  namespace: kagent
spec:
  url: https://aks-mcp.dev-we.internal.company.com/mcp
  transport: streamableHTTP
```

## B4. Agent CRDs (Per Cluster)

One triage agent per cluster, each wired to its cluster's AKS-MCP.
No `--context` needed — the agent's AKS-MCP is already on the target cluster.

```yaml
# Template — create one per cluster, changing name + MCP server reference
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: sre-triage-prod-we              # unique per cluster
  namespace: kagent
  labels:
    platform.com/type: triage
    platform.com/cluster: aks-prod-we
spec:
  description: SRE Triage Agent for aks-prod-westeurope
  type: Declarative
  declarative:
    systemMessage: |
      You are an SRE Triage Agent for the aks-prod-westeurope cluster.

      ## Your Cluster
      - Cluster: aks-prod-westeurope
      - This is a production cluster with ~200 namespaces
      - Your tools (call_kubectl, call_helm) are connected directly to this cluster
      - You do NOT need --context flags — you are already on the right cluster

      ## Rules
      - Always use the EXACT namespace from the investigation request
      - Be concise. Bullet points over paragraphs.
      - When recommending resource creation, include ready-to-use YAML
      - Start with pod/deployment status and events (fastest signal)
      - If you find the root cause, state it clearly and recommend a specific fix

      ## Investigation Order
      1. Check pod/deployment status and events
      2. Pull logs from unhealthy pods
      3. Check node health and resource pressure
      4. Check recent events in the namespace
      5. Check helm release status if helm-managed
      6. Test service connectivity for dependency issues

      ## Output Format
      **Issue:** One-line summary
      **Evidence:** 2-5 bullet points with specific data
      **Root Cause:** Assessment with confidence (confirmed/likely/possible)
      **Recommended Fix:** Specific action
      **Escalation:** Only if needed

    modelConfig: azure-openai-gpt4o
    tools:
      - type: McpServer
        mcpServer:
          name: aks-mcp-prod-we          # this cluster's AKS-MCP
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            - call_kubectl
            - call_helm
            - run_az_cli_command
            - list_detectors
            - get_detector
  a2aConfig:
    skills:
      - id: triage-prod-we
        name: Triage aks-prod-westeurope
        description: Investigate issues on aks-prod-westeurope cluster
        tags: [triage, production, westeurope]
```

Create remediation agents the same way, with `--access-level=readwrite` on the AKS-MCP and write tools added.

### Generating Agent CRDs from a Template

For many clusters, use a script:

```bash
#!/bin/bash
# generate-agents.sh — create agent CRDs for all clusters

CLUSTERS=(
  "aks-prod-we:aks-prod-westeurope:production:200"
  "aks-stg-we:aks-staging-westeurope:staging:50"
  "aks-dev-we:aks-dev-westeurope:development:30"
)

for entry in "${CLUSTERS[@]}"; do
  IFS=':' read -r SHORT FULL ENV NS_COUNT <<< "$entry"

  cat > "sre-triage-${SHORT}.yaml" << EOF
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: sre-triage-${SHORT}
  namespace: kagent
  labels:
    platform.com/type: triage
    platform.com/cluster: ${FULL}
    platform.com/environment: ${ENV}
spec:
  description: SRE Triage Agent for ${FULL}
  type: Declarative
  declarative:
    systemMessage: |
      You are an SRE Triage Agent for the ${FULL} cluster.
      Environment: ${ENV} (~${NS_COUNT} namespaces)
      Your tools are connected directly to this cluster — no --context flags needed.
      Always use the EXACT namespace from the investigation request.
      Be concise. When recommending resource creation, include ready-to-use YAML.

      ## Output Format
      **Issue:** One-line summary
      **Evidence:** 2-5 bullet points
      **Root Cause:** confirmed/likely/possible
      **Recommended Fix:** Specific action
    modelConfig: azure-openai-gpt4o
    tools:
      - type: McpServer
        mcpServer:
          name: aks-mcp-${SHORT}
          kind: RemoteMCPServer
          apiGroup: kagent.dev
          toolNames:
            - call_kubectl
            - call_helm
            - run_az_cli_command
            - list_detectors
            - get_detector
  a2aConfig:
    skills:
      - id: triage-${SHORT}
        name: Triage ${FULL}
        description: Investigate issues on ${FULL}
        tags: [triage, ${ENV}]
EOF

  echo "Generated sre-triage-${SHORT}.yaml"
done
```

## B5. Workflow Routing (Distributed)

The workflow selects the correct agent based on the cluster parameter:

```yaml
# Updated call-kagent step in kagent-sre-workflow.yaml
#
# Map cluster name → agent name
# Convention: sre-triage-{cluster-short-name}

# In the script:
CLUSTER="{{workflow.parameters.cluster}}"

# Derive agent name from cluster
# Convention: aks-prod-westeurope → sre-triage-prod-we
# Or use a lookup ConfigMap
case "$CLUSTER" in
  aks-prod-westeurope)   AGENT_NAME="sre-triage-prod-we" ;;
  aks-staging-westeurope) AGENT_NAME="sre-triage-stg-we" ;;
  aks-dev-westeurope)    AGENT_NAME="sre-triage-dev-we" ;;
  *)
    echo "ERROR: Unknown cluster $CLUSTER — no agent registered"
    exit 1
    ;;
esac

# Or with remediation:
if [ "$REMEDIATE" = "true" ]; then
  AGENT_NAME=$(echo "$AGENT_NAME" | sed 's/triage/remediation/')
fi
```

The prompt is simpler — no `--context` or credential instructions needed:

```
Investigate this Kubernetes issue:

Namespace: {{workflow.parameters.namespace}}
Resource: {{workflow.parameters.resource_kind}}/{{workflow.parameters.resource_name}}
Event: {{workflow.parameters.event_type}}
Severity: {{workflow.parameters.severity}}
Error: {{workflow.parameters.error_message}}

Query: {{workflow.parameters.query}}

CRITICAL: Use the EXACT namespace "{{workflow.parameters.namespace}}" — copy it exactly.
Use your tools to gather evidence. Report findings as Issue/Evidence/Root Cause/Fix.
```

## B6. End-to-End Flow (Distributed)

```
1. Alert fires on aks-prod-westeurope (OOMKilled in payments-prod)
   │
2. AlertManager webhook → Argo Events EventSource (on mgmt cluster)
   │
3. Argo Events Sensor extracts:
   │  - cluster: aks-prod-westeurope
   │  - namespace: payments-prod
   │  - event_type: OOMKilled
   │  - resource_name: payment-api-xxx
   │
4. Sensor triggers: kagent-sre-workflow
   │  - cluster → agent lookup: sre-triage-prod-we
   │
5. Workflow calls sre-triage-prod-we via A2A
   │  - Agent has AKS-MCP on aks-prod-we as its tool source
   │  - Agent calls: call_kubectl("kubectl describe pod payment-api-xxx -n payments-prod")
   │  - Agent calls: call_kubectl("kubectl logs payment-api-xxx -n payments-prod --tail=200")
   │  - No --context needed — AKS-MCP is already on the right cluster
   │  - Agent produces structured analysis
   │
6. Workflow creates GitLab issue
   │
7. Workflow notifies Slack/Teams
```

## B7. Checklist (Distributed)

```
Per Worker Cluster:
  [ ] AKS-MCP deployed with in-cluster SA + RBAC
  [ ] Istio VirtualService (or Internal LB) exposing AKS-MCP
  [ ] DNS record pointing to ingress IP
  [ ] Test: curl https://aks-mcp.<cluster>.internal.company.com/mcp (returns MCP response)

On Mgmt Cluster:
  [ ] RemoteMCPServer CRD registered for each worker cluster
  [ ] Agent CRD created for each cluster (sre-triage-<short>, sre-remediation-<short>)
  [ ] Agents reference correct RemoteMCPServer
  [ ] Workflow routing logic maps cluster name → agent name
  [ ] Test: A2A call to each agent succeeds

Networking:
  [ ] VNET peering between mgmt and worker clusters (or shared VNET)
  [ ] Private DNS zone resolves aks-mcp.*.internal.company.com
  [ ] Istio mTLS or TLS between mgmt → worker (if using Istio)
  [ ] Firewall rules allow mgmt cluster → worker cluster port 8000/443

End-to-End:
  [ ] Submit test workflow for each worker cluster
  [ ] Verify agent uses correct cluster's AKS-MCP
  [ ] Verify GitLab issue created with correct cluster name
  [ ] Verify Slack/Teams notification received
```

---

## Adding a New Cluster (Distributed)

When onboarding a new worker cluster:

```bash
# 1. Deploy AKS-MCP on the new cluster
kubectl apply -f aks-mcp-deployment.yaml --context new-cluster

# 2. Expose via Istio or Internal LB
kubectl apply -f aks-mcp-virtualservice.yaml --context new-cluster

# 3. Add DNS record
az network private-dns record-set a add-record ...

# 4. Register RemoteMCPServer on mgmt cluster
kubectl apply -f - --context mgmt-cluster <<EOF
apiVersion: kagent.dev/v1alpha2
kind: RemoteMCPServer
metadata:
  name: aks-mcp-new-cluster
  namespace: kagent
spec:
  url: https://aks-mcp.new-cluster.internal.company.com/mcp
  transport: streamableHTTP
EOF

# 5. Create agent CRD
./generate-agents.sh  # or apply manually

# 6. Update workflow routing (add case for new cluster)

# 7. Test
argo submit -n argo --from=workflowtemplate/kagent-sre-workflow \
  -p cluster="new-cluster" \
  -p namespace="default" \
  -p query="List all pods" \
  -p event_type="HealthCheck" \
  --watch
```

---

## Related Docs

| Document | Description |
|----------|-------------|
| `KAGENT-LIFT-AND-SHIFT.md` | Single-cluster deployment guide |
| `BYOA-AGENT-PLATFORM-PROPOSAL.md` | BYOA routing and onboarding vision |
| `COMPARISON-TEST-SCENARIOS.md` | Holmes vs KAgent test results (KAgent 5-0) |
| `holmesgpt-multi-cluster.yaml` | Holmes multi-cluster reference (centralized pattern) |
| `WORKLOAD-IDENTITY-SETUP.md` | Detailed workload identity setup guide |
