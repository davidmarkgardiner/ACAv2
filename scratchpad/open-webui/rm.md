# Open WebUI with Azure Workload Identity (UAMI)

Deploy Open WebUI on AKS with passwordless authentication to Azure OpenAI using User Assigned Managed Identity (UAMI) and Workload Identity Federation.

## What's Included

```
openwebui-deployment/
├── README.md
├── azure-cli/
│   └── setup-workload-identity.sh   # Creates UAMI + Federated Credential + Role
└── helm/
    └── values.yaml                   # Helm values for Open WebUI chart
```

## Prerequisites

1. **AKS Cluster** with OIDC and Workload Identity enabled:
   ```bash
   # Check current state
   az aks show -g <rg> -n <aks> --query "{oidc:oidcIssuerProfile.issuerUrl, wi:securityProfile.workloadIdentity.enabled}"
   
   # Enable if needed
   az aks update -g <rg> -n <aks> --enable-oidc-issuer --enable-workload-identity
   ```

2. **Azure OpenAI Service** with deployed models (e.g., gpt-4o)

3. **Tools**: `az`, `kubectl`, `helm`

---

## Azure OpenAI URL Format

**Important**: Azure OpenAI requires the deployment name in the URL, not just the endpoint.

```
https://<RESOURCE_NAME>.openai.azure.com/openai/deployments/<DEPLOYMENT_NAME>/chat/completions?api-version=2024-10-21
```

Example for a resource named `myaoai` with a deployment named `gpt-4o`:
```
https://myaoai.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21
```

For **multiple deployments**, configure in `values.yaml`:

```yaml
openaiBaseApiUrls:
  - "https://myaoai.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21"
  - "https://myaoai.openai.azure.com/openai/deployments/gpt-4o-mini/chat/completions?api-version=2024-10-21"

# Match with keys (placeholder value for Entra ID auth)
openaiApiKeys:
  - "entra-id-auth"
  - "entra-id-auth"
```

See `helm/values-example.yaml` for a complete working example.

---

## Deployment Steps

### Step 1: Create Azure Resources

Edit `azure-cli/setup-workload-identity.sh` with your values, then run:

```bash
chmod +x azure-cli/setup-workload-identity.sh
./azure-cli/setup-workload-identity.sh
```

**Save the UAMI Client ID from the output.**

### Step 2: Deploy with Helm

```bash
# Add repo
helm repo add open-webui https://helm.openwebui.com/
helm repo update

# Edit values.yaml - replace <YOUR_UAMI_CLIENT_ID> with the ID from Step 1

# Deploy
helm upgrade --install openwebui open-webui/open-webui \
  -f helm/values.yaml \
  -n openwebui \
  --create-namespace
```

### Step 3: Verify Workload Identity

```bash
# Check pod is running
kubectl -n openwebui get pods

# Verify Azure env vars are injected (this confirms workload identity is working)
kubectl -n openwebui exec deploy/open-webui -- env | grep AZURE

# Should see:
# AZURE_CLIENT_ID=<your-uami-client-id>
# AZURE_TENANT_ID=<your-tenant-id>
# AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
```

### Step 4: Configure Azure OpenAI in UI

```bash
# Port forward
kubectl -n openwebui port-forward svc/open-webui 8080:80
```

1. Open http://localhost:8080
2. Create admin account
3. Go to **Admin Panel** → **Settings** → **Connections**
4. Click **+ Add Connection**
5. Set:
   - **Provider**: Azure OpenAI
   - **Authentication**: **Entra ID** ← This uses workload identity!
   - **Endpoint**: `https://your-openai.openai.azure.com/`
   - **API Version**: `2024-10-21`
   - **Deployment**: Your deployment name (e.g., `gpt-4o`)
6. Save and test

---

## Troubleshooting

| Issue | Check |
|-------|-------|
| AZURE_* env vars missing | Pod needs label `azure.workload.identity/use: "true"` |
| "No matching federated identity" | Subject must be `system:serviceaccount:openwebui:open-webui` |
| 401 from Azure OpenAI | UAMI needs `Cognitive Services OpenAI User` role |

```bash
# Debug commands
kubectl -n openwebui get sa open-webui -o yaml  # Check annotation
kubectl -n openwebui get pod -o yaml | grep -A2 "labels:"  # Check label
kubectl -n openwebui logs deploy/open-webui  # Check logs
```

---

---

## Custom CA Certificate

If your Azure OpenAI endpoint uses a private endpoint or corporate proxy with a custom CA:

```bash
# Create ConfigMap from your CA certificate
kubectl create configmap custom-ca \
  --from-file=ca.crt=/path/to/your/ca.crt \
  -n openwebui

# Or for a CA bundle (multiple CAs)
cat corp-root-ca.crt corp-intermediate-ca.crt > ca-bundle.crt
kubectl create configmap custom-ca \
  --from-file=ca.crt=ca-bundle.crt \
  -n openwebui
```

The `values.yaml` already includes the volume mount configuration. The CA will be mounted at `/etc/ssl/certs/custom-ca.crt`.

If you need to append to the system CA bundle instead:

```yaml
extraEnvVars:
  - name: REQUESTS_CA_BUNDLE
    value: "/etc/ssl/certs/ca-certificates.crt"

extraInitContainers:
  - name: append-ca
    image: busybox:latest
    command:
      - sh
      - -c
      - |
        cat /custom-ca/ca.crt >> /etc/ssl/certs/ca-certificates.crt
    volumeMounts:
      - name: custom-ca
        mountPath: /custom-ca
        readOnly: true
      - name: ca-certs
        mountPath: /etc/ssl/certs

volumes:
  - name: ca-certs
    emptyDir: {}
```

---

## Istio Configuration

An `istio.yaml` file is included with Gateway, VirtualService, and DestinationRule.

```bash
# Label namespace for sidecar injection
kubectl label namespace openwebui istio-injection=enabled

# Create TLS secret (if using HTTPS)
kubectl create secret tls openwebui-tls \
  --cert=path/to/cert.pem \
  --key=path/to/key.pem \
  -n openwebui

# Edit istio.yaml - replace openwebui.example.com with your hostname

# Apply
kubectl apply -f helm/istio.yaml
```

For HTTP-only (dev/testing), use this simplified VirtualService:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: openwebui
  namespace: openwebui
spec:
  hosts:
    - "openwebui.example.com"
  gateways:
    - istio-system/your-shared-gateway  # Or create your own
  http:
    - route:
        - destination:
            host: open-webui
            port:
              number: 80
      timeout: 300s
```

---

## References

- [Open WebUI Workload Identity Docs](https://docs.openwebui.com/tutorials/integrations/azure-openai/workload-identity-auth/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/)

---

https://github.com/open-webui/open-webui/compare/main...carhensi:open-webui:feature/azure-openai-support