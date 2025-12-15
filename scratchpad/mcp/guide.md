 AKS-MCP Deployment Guide

  Prerequisites

  # 1. Set your cluster variables
  export RESOURCE_GROUP="your-resource-group"
  export CLUSTER_NAME="your-cluster-name"
  export LOCATION="westeurope"
  export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  export DOMAIN="aks-mcp.yourdomain.com"  # Your DNS name

  # 2. Verify Workload Identity is enabled
  az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME \
    --query "oidcIssuerProfile.enabled" -o tsv

  # 3. Get OIDC issuer
  export OIDC_ISSUER=$(az aks show -g $RESOURCE_GROUP -n $CLUSTER_NAME \
    --query "oidcIssuerProfile.issuerUrl" -o tsv)

  Step 1: Create Managed Identity

  # Create identity
  az identity create \
    --name uami-aks-mcp \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION

  # Get Client ID (you'll need this for the ServiceAccount)
  export CLIENT_ID=$(az identity show \
    --name uami-aks-mcp \
    --resource-group $RESOURCE_GROUP \
    --query clientId -o tsv)

  export PRINCIPAL_ID=$(az identity show \
    --name uami-aks-mcp \
    --resource-group $RESOURCE_GROUP \
    --query principalId -o tsv)

  echo "CLIENT_ID: $CLIENT_ID"

  Step 2: Assign Azure Roles

  # Grant Contributor role (required for full functionality)
  az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" \
    --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP

  Step 3: Create Federated Credential

  az identity federated-credential create \
    --name fc-aks-mcp \
    --identity-name uami-aks-mcp \
    --resource-group $RESOURCE_GROUP \
    --issuer $OIDC_ISSUER \
    --subject system:serviceaccount:aks-mcp:aks-mcp \
    --audiences api://AzureADTokenExchange

  Step 4: Deploy AKS-MCP

  Save this as aks-mcp-complete.yaml and replace ${CLIENT_ID} with your actual Client ID:

  # aks-mcp-complete.yaml
  # Replace ${CLIENT_ID} with your Managed Identity Client ID
  ---
  apiVersion: v1
  kind: Namespace
  metadata:
    name: aks-mcp
    labels:
      istio-injection: enabled
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
      # REPLACE THIS with your Managed Identity Client ID
      azure.workload.identity/client-id: "${CLIENT_ID}"
    labels:
      azure.workload.identity/use: "true"

  ---
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
    ACCESS_LEVEL: "readonly"
    TRANSPORT: "streamable-http"
    HOST: "0.0.0.0"
    PORT: "8000"
    TIMEOUT: "600"
    LOG_LEVEL: "info"
    ADDITIONAL_TOOLS: ""
    ALLOW_NAMESPACES: ""

  ---
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: aks-mcp
    namespace: aks-mcp
    labels:
      app: aks-mcp
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
          azure.workload.identity/use: "true"
        annotations:
          prometheus.io/scrape: "true"
          prometheus.io/port: "8000"
          prometheus.io/path: "/metrics"
      spec:
        serviceAccountName: aks-mcp
        securityContext:
          runAsNonRoot: true
          runAsUser: 65532
          runAsGroup: 65532
          fsGroup: 65532
          seccompProfile:
            type: RuntimeDefault
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchLabels:
                      app: aks-mcp
                  topologyKey: kubernetes.io/hostname
        topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
            whenUnsatisfiable: ScheduleAnyway
            labelSelector:
              matchLabels:
                app: aks-mcp
        containers:
          - name: aks-mcp
            # IMPORTANT: Use v0.0.12+ - earlier versions fail on workload identity
            image: ghcr.io/azure/aks-mcp:v0.0.12
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
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                cpu: 500m
                memory: 512Mi
            # TCP probes - MCP endpoint requires POST, not GET
            livenessProbe:
              tcpSocket:
                port: 8000
              initialDelaySeconds: 10
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            readinessProbe:
              tcpSocket:
                port: 8000
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 3
              failureThreshold: 3
            # v0.0.12 runs as 'mcp' user - these paths are critical
            volumeMounts:
              - name: tmp
                mountPath: /tmp
              - name: azure-cli-cache
                mountPath: /home/mcp/.azure
              - name: kube-cache
                mountPath: /home/mcp/.kube
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
      - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: aks-istio-ingress
            podSelector:
              matchLabels:
                istio: aks-istio-ingressgateway-external
        ports:
          - protocol: TCP
            port: 8000
      - from:
          - podSelector: {}
        ports:
          - protocol: TCP
            port: 8000
    egress:
      - to:
          - namespaceSelector: {}
            podSelector:
              matchLabels:
                k8s-app: kube-dns
        ports:
          - protocol: UDP
            port: 53
      - to:
          - ipBlock:
              cidr: 0.0.0.0/0
        ports:
          - protocol: TCP
            port: 443
          - protocol: TCP
            port: 6443

  Step 5: Deploy Istio Gateway & VirtualService

  Save this as aks-mcp-istio.yaml and replace ${DOMAIN} with your domain:

  # aks-mcp-istio.yaml
  # Replace ${DOMAIN} with your actual domain (e.g., aks-mcp.yourcompany.com)
  ---
  # Gateway - in aks-istio-ingress namespace to access TLS secret
  apiVersion: networking.istio.io/v1
  kind: Gateway
  metadata:
    name: aks-mcp-gateway
    namespace: aks-istio-ingress
  spec:
    selector:
      # For external (public) gateway:
      istio: aks-istio-ingressgateway-external
      # For internal (private) gateway, use:
      # istio: aks-istio-ingressgateway-internal
    servers:
      - port:
          number: 443
          name: https
          protocol: HTTPS
        tls:
          mode: SIMPLE
          credentialName: aks-mcp-tls
        hosts:
          - "${DOMAIN}"
      - port:
          number: 80
          name: http
          protocol: HTTP
        hosts:
          - "${DOMAIN}"

  ---
  # VirtualService - routes traffic to aks-mcp service
  apiVersion: networking.istio.io/v1
  kind: VirtualService
  metadata:
    name: aks-mcp
    namespace: aks-mcp
  spec:
    hosts:
      - "${DOMAIN}"
    gateways:
      - aks-istio-ingress/aks-mcp-gateway
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
          perTryTimeout: 60s
          retryOn: connect-failure,refused-stream,unavailable

  ---
  # Certificate (if using cert-manager with Let's Encrypt)
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: aks-mcp-cert
    namespace: aks-istio-ingress
  spec:
    secretName: aks-mcp-tls
    issuerRef:
      name: letsencrypt-prod
      kind: ClusterIssuer
    dnsNames:
      - "${DOMAIN}"

  Step 6: Apply Everything

  # Replace variables in manifests
  sed -i "s/\${CLIENT_ID}/$CLIENT_ID/g" aks-mcp-complete.yaml
  sed -i "s/\${DOMAIN}/$DOMAIN/g" aks-mcp-istio.yaml

  # Apply core deployment
  kubectl apply -f aks-mcp-complete.yaml

  # Wait for pods to be ready
  kubectl wait --for=condition=Ready pod -l app=aks-mcp -n aks-mcp --timeout=120s

  # Apply Istio resources
  kubectl apply -f aks-mcp-istio.yaml

  # Verify deployment
  kubectl get pods -n aks-mcp
  kubectl get gateway -n aks-istio-ingress
  kubectl get virtualservice -n aks-mcp

  Step 7: Test Connection

  # Get gateway IP
  export GATEWAY_IP=$(kubectl get svc -n aks-istio-ingress \
    aks-istio-ingressgateway-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  echo "Gateway IP: $GATEWAY_IP"

  # Test HTTP (before TLS is ready)
  curl -X POST http://$GATEWAY_IP/mcp \
    -H "Host: $DOMAIN" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "1.0"}}, "id": 1}'

  # Test HTTPS (after certificate is issued)
  curl -X POST https://$DOMAIN/mcp \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "1.0"}}, "id": 1}'

  Quick Reference: Internal vs External Gateway

  | Scenario           | Gateway Selector                         | Use Case                                  |
  |--------------------|------------------------------------------|-------------------------------------------|
  | External (public)  | istio: aks-istio-ingressgateway-external | Public internet access, Let's Encrypt     |
  | Internal (private) | istio: aks-istio-ingressgateway-internal | Corporate network only, self-signed certs |

  For internal-only access, change the Gateway selector and use self-signed TLS:

  # Create self-signed cert for internal use
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/aks-mcp.key \
    -out /tmp/aks-mcp.crt \
    -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN"

  kubectl create secret tls aks-mcp-tls \
    --cert=/tmp/aks-mcp.crt \
    --key=/tmp/aks-mcp.key \
    -n aks-istio-ingress

  MCP Client Configuration

  Once deployed, configure your MCP client:

  VS Code / Copilot (.vscode/mcp.json):
  {
    "servers": {
      "aks-mcp": {
        "type": "http",
        "url": "https://aks-mcp.yourdomain.com/mcp"
      }
    }
  }

  Claude Code (.mcp.json):
  {
    "mcpServers": {
      "aks-mcp": {
        "type": "http",
        "url": "https://aks-mcp.yourdomain.com/mcp"
      }
    }
  }