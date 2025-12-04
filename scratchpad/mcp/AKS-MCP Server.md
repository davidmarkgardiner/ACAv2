## AKS-MCP Server - No LLM Required!

**The AKS-MCP server does NOT use any LLM itself.** It's purely a **tool provider** - it exposes tools that AI assistants can call.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                        YOUR MCP CLIENT                               │
│  (Claude Desktop, VS Code + Copilot, Cursor, Claude Code)           │
│                              │                                       │
│                    Has its own LLM                                   │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               │ HTTP (Streamable HTTP transport)
                               │ POST to /mcp endpoint
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      AKS-MCP SERVER (on AKS)                        │
│                                                                      │
│  • No LLM - just exposes tools                                      │
│  • Authenticates to Azure via Workload Identity                     │
│  • Executes kubectl, az commands                                    │
│  • Returns structured results                                        │
└─────────────────────────────────────────────────────────────────────┘
```

### Communication Flow

1. **You ask Claude/Copilot**: "List my AKS clusters"
2. **The LLM** (running in Claude/Copilot) decides to call the `az_aks_operations` tool
3. **MCP client** sends HTTP POST to `http://aks-mcp.your-cluster:8000/mcp`
4. **AKS-MCP server** executes `az aks list` using Workload Identity
5. **Results** returned as JSON to your MCP client
6. **The LLM** formats the response for you

### Key Points from the Blog

The MCP server uses a User-Assigned Managed Identity with Workload Identity to authenticate to Azure, giving it necessary permissions to manage both Kubernetes and Azure resources.

The transport is configured as `--transport=streamable-http`, which configures the MCP server to use Streamable HTTP as the transport protocol, listening on port 8000.

The MCP endpoint is available at `http://0.0.0.0:8000/mcp`. Send POST requests to /mcp to initialize session and obtain Mcp-Session-Id.

---

## Connecting VS Code to the In-Cluster AKS-MCP

### Option A: Port Forward (Testing)

```bash
kubectl port-forward svc/aks-mcp 8000:8000
```

Then in `.vscode/mcp.json`:
```json
{
  "servers": {
    "aks-mcp": {
      "type": "http",
      "url": "http://localhost:8000/mcp"
    }
  }
}
```

### Option B: Ingress (Production)

Expose via your Istio ingress, then:
```json
{
  "servers": {
    "aks-mcp": {
      "type": "http", 
      "url": "https://aks-mcp.internal.yourcompany.com/mcp"
    }
  }
}
```

---

## Comparison: AKS-MCP vs dot-ai

| Aspect | AKS-MCP | dot-ai |
|--------|---------|--------|
| **LLM Required** | ❌ No - tool provider only | ✅ Yes - needs Anthropic/OpenAI key |
| **AI Logic** | None - your client's LLM decides | Built-in - AI-powered analysis |
| **Remediation** | Manual - returns commands | Smart - confidence thresholds, auto-fix |
| **Patterns/Policies** | ❌ No | ✅ Vector DB for org knowledge |
| **Azure Integration** | ✅ Deep - Workload Identity native | ⚠️ Basic - needs kubeconfig |
| **Use Case** | Azure/AKS operations | Cross-platform K8s + AI reasoning |

---

## For Your Setup

Given you're on AKS with Workload Identity already, the blog's approach is ideal:

1. **No API keys to manage** for the MCP server itself
2. **Workload Identity** handles Azure auth seamlessly
3. **Your existing LLM** (Claude in this chat, Copilot in VS Code) provides the intelligence
4. **Centralised** - all your team can use the same MCP server

---

# AKS-MCP Server - Production Deployment
# Hardened for enterprise AKS with Istio Add-on
# 
# Prerequisites:
# - AKS cluster with Workload Identity enabled
# - Istio AKS Add-on enabled
# - User-Assigned Managed Identity with federated credentials
#
# Usage:
# 1. Update the CLIENT_ID in the ServiceAccount annotation
# 2. Update the VirtualService hosts to match your domain
# 3. Apply: kubectl apply -f aks-mcp-production.yaml

---
apiVersion: v1
kind: Namespace
metadata:
  name: aks-mcp
  labels:
    istio.io/rev: asm-1-20  # Adjust to your Istio revision
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aks-mcp
  namespace: aks-mcp
  annotations:
    # Replace with your Managed Identity Client ID
    azure.workload.identity/client-id: "${MANAGED_IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"

---
# Least-privilege RBAC for Kubernetes access
# Adjust verbs based on your access-level setting
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aks-mcp
rules:
  # Core resources - read access
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - services
      - endpoints
      - configmaps
      - secrets
      - namespaces
      - nodes
      - events
      - persistentvolumeclaims
      - persistentvolumes
      - serviceaccounts
    verbs: ["get", "list", "watch"]
  
  # Apps - read access
  - apiGroups: ["apps"]
    resources:
      - deployments
      - daemonsets
      - statefulsets
      - replicasets
    verbs: ["get", "list", "watch"]
  
  # Batch - read access
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch"]
  
  # Networking - read access
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses
      - networkpolicies
    verbs: ["get", "list", "watch"]
  
  # RBAC - read access
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources:
      - roles
      - rolebindings
      - clusterroles
      - clusterrolebindings
    verbs: ["get", "list", "watch"]
  
  # Autoscaling - read access
  - apiGroups: ["autoscaling"]
    resources:
      - horizontalpodautoscalers
    verbs: ["get", "list", "watch"]
  
  # Policy - read access
  - apiGroups: ["policy"]
    resources:
      - poddisruptionbudgets
    verbs: ["get", "list", "watch"]

  # --- WRITE ACCESS (only if --access-level=readwrite) ---
  # Uncomment the following for readwrite access:
  
  # # Pod operations (delete for restart)
  # - apiGroups: [""]
  #   resources: ["pods"]
  #   verbs: ["delete"]
  
  # # Deployment operations
  # - apiGroups: ["apps"]
  #   resources: ["deployments", "statefulsets", "daemonsets"]
  #   verbs: ["patch", "update"]
  
  # # Deployment scale
  # - apiGroups: ["apps"]
  #   resources: ["deployments/scale", "statefulsets/scale"]
  #   verbs: ["patch", "update"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-mcp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aks-mcp
subjects:
  - kind: ServiceAccount
    name: aks-mcp
    namespace: aks-mcp

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: aks-mcp-config
  namespace: aks-mcp
data:
  # MCP server configuration
  ACCESS_LEVEL: "readonly"  # readonly | readwrite | admin
  TRANSPORT: "streamable-http"
  HOST: "0.0.0.0"
  PORT: "8000"
  TIMEOUT: "600"
  LOG_LEVEL: "info"
  # Additional tools (comma-separated): helm,cilium,hubble
  ADDITIONAL_TOOLS: ""
  # Namespace restrictions (comma-separated, empty = all)
  ALLOW_NAMESPACES: ""

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aks-mcp
  namespace: aks-mcp
  labels:
    app: aks-mcp
    app.kubernetes.io/name: aks-mcp
    app.kubernetes.io/component: mcp-server
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: aks-mcp
  template:
    metadata:
      labels:
        app: aks-mcp
        app.kubernetes.io/name: aks-mcp
        azure.workload.identity/use: "true"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: aks-mcp
      
      # Security context at pod level
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      
      # Anti-affinity for HA
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: aks-mcp
                topologyKey: kubernetes.io/hostname
      
      # Topology spread for zone distribution
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: aks-mcp
      
      containers:
        - name: aks-mcp
          image: ghcr.io/azure/aks-mcp:v0.0.9
          imagePullPolicy: IfNotPresent
          
          args:
            - --access-level=$(ACCESS_LEVEL)
            - --transport=$(TRANSPORT)
            - --host=$(HOST)
            - --port=$(PORT)
            - --timeout=$(TIMEOUT)
            - --log-level=$(LOG_LEVEL)
          
          envFrom:
            - configMapRef:
                name: aks-mcp-config
          
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          
          # Security context at container level
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
          
          # Resource limits
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          
          # Health probes
          livenessProbe:
            httpGet:
              path: /mcp
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3
          
          readinessProbe:
            httpGet:
              path: /mcp
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          
          # Writable directories for the container
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: azure-cli-cache
              mountPath: /home/nonroot/.azure
            - name: kube-cache
              mountPath: /home/nonroot/.kube
      
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 100Mi
        - name: azure-cli-cache
          emptyDir:
            sizeLimit: 100Mi
        - name: kube-cache
          emptyDir:
            sizeLimit: 50Mi
      
      # Termination grace period
      terminationGracePeriodSeconds: 30

---
apiVersion: v1
kind: Service
metadata:
  name: aks-mcp
  namespace: aks-mcp
  labels:
    app: aks-mcp
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8000
      targetPort: http
      protocol: TCP
  selector:
    app: aks-mcp

---
# Istio VirtualService for internal access
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  hosts:
    - aks-mcp.internal.example.com  # Update to your domain
  gateways:
    - istio-system/internal-gateway  # Update to your gateway
  http:
    - match:
        - uri:
            prefix: /mcp
      route:
        - destination:
            host: aks-mcp.aks-mcp.svc.cluster.local
            port:
              number: 8000
      timeout: 600s
      retries:
        attempts: 3
        perTryTimeout: 200s
        retryOn: connect-failure,refused-stream,unavailable,cancelled,resource-exhausted

---
# Istio DestinationRule for traffic policy
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  host: aks-mcp.aks-mcp.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        h2UpgradePolicy: UPGRADE
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
    loadBalancer:
      simple: ROUND_ROBIN
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50

---
# PodDisruptionBudget for availability
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: aks-mcp

---
# NetworkPolicy - restrict ingress to Istio sidecar only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: aks-mcp
  namespace: aks-mcp
spec:
  podSelector:
    matchLabels:
      app: aks-mcp
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from Istio ingress gateway
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              istio: ingressgateway
      ports:
        - protocol: TCP
          port: 8000
    # Allow from same namespace (for probes via sidecar)
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 8000
  egress:
    # Allow DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Allow Azure APIs (management.azure.com, login.microsoftonline.com, etc.)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
    # Allow Kubernetes API
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0  # K8s API can be anywhere
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443

---
# Kyverno ClusterPolicy for additional validation (optional)
# Uncomment if using Kyverno
# apiVersion: kyverno.io/v1
# kind: ClusterPolicy
# metadata:
#   name: aks-mcp-security
# spec:
#   validationFailureAction: Enforce
#   background: true
#   rules:
#     - name: require-security-context
#       match:
#         any:
#           - resources:
#               kinds:
#                 - Pod
#               namespaces:
#                 - aks-mcp
#       validate:
#         message: "Pods in aks-mcp namespace must have security context configured"
#         pattern:
#           spec:
#             securityContext:
#               runAsNonRoot: true
#             containers:
#               - securityContext:
#                   allowPrivilegeEscalation: false
#                   readOnlyRootFilesystem: true