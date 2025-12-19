Ah, that's a common enterprise scenario - your Azure OpenAI is configured with a custom audience/resource URI rather than the default `https://cognitiveservices.azure.com/.default`. Let me find the best way to handle this.I found it. LiteLLM supports a custom `azure_scope` parameter that defaults to `https://cognitiveservices.azure.com/.default` but can be overridden. This is exactly what you need for your custom audience.

## Solution: Use `azure_scope` in LiteLLM

You can configure the custom scope in your LiteLLM config:

```yaml
model_list:
  - model_name: gpt-4
    litellm_params:
      model: azure/gpt-4
      api_base: https://your-resource.openai.azure.com/
      api_version: "2024-02-01"
      azure_scope: "api://your-custom-audience/.default"  # 👈 Your custom audience

litellm_settings:
  enable_azure_ad_token_refresh: true
```

## Complete Kubernetes Deployment with Custom Scope

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: open-webui
data:
  config.yaml: |
    model_list:
      - model_name: gpt-4
        litellm_params:
          model: azure/gpt-4
          api_base: https://your-resource.openai.azure.com/
          api_version: "2024-02-01"
          azure_scope: os.environ/AZURE_SCOPE  # Custom audience from env var
      - model_name: gpt-35-turbo
        litellm_params:
          model: azure/gpt-35-turbo
          api_base: https://your-resource.openai.azure.com/
          api_version: "2024-02-01"
          azure_scope: os.environ/AZURE_SCOPE
    
    litellm_settings:
      enable_azure_ad_token_refresh: true
    
    general_settings:
      master_key: os.environ/LITELLM_MASTER_KEY
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: litellm-sa
  namespace: open-webui
  annotations:
    azure.workload.identity/client-id: "<YOUR-UAMI-CLIENT-ID>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: open-webui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: litellm-sa
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:main-stable
          ports:
            - containerPort: 4000
          args:
            - "--config"
            - "/app/config.yaml"
          env:
            # Your custom audience/scope
            - name: AZURE_SCOPE
              value: "api://your-custom-audience/.default"
            # Optional: Specify the UAMI client ID explicitly
            - name: AZURE_CLIENT_ID
              value: "<YOUR-UAMI-CLIENT-ID>"
            # LiteLLM master key
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: master-key
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
      volumes:
        - name: config
          configMap:
            name: litellm-config
---
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: open-webui
type: Opaque
stringData:
  master-key: "sk-your-litellm-master-key"
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-service
  namespace: open-webui
spec:
  selector:
    app: litellm
  ports:
    - port: 4000
      targetPort: 4000
  type: ClusterIP
```

## Alternative: Sidecar Token Fetcher (If LiteLLM Doesn't Work)

If LiteLLM's built-in `azure_scope` doesn't work with your specific enterprise setup, you can create a sidecar that fetches the token and injects it:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: open-webui
spec:
  template:
    metadata:
      labels:
        app: litellm
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: litellm-sa
      containers:
        # Token refresher sidecar
        - name: token-refresher
          image: mcr.microsoft.com/azure-cli:latest
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                TOKEN=$(az account get-access-token \
                  --resource "api://your-custom-audience" \
                  --query accessToken -o tsv)
                echo "$TOKEN" > /shared/azure-token
                sleep 300  # Refresh every 5 minutes
              done
          volumeMounts:
            - name: token-volume
              mountPath: /shared
        
        # LiteLLM container
        - name: litellm
          image: ghcr.io/berriai/litellm:main-stable
          ports:
            - containerPort: 4000
          args:
            - "--config"
            - "/app/config.yaml"
          env:
            - name: AZURE_AD_TOKEN_FILE
              value: "/shared/azure-token"
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
            - name: token-volume
              mountPath: /shared
      
      volumes:
        - name: config
          configMap:
            name: litellm-config
        - name: token-volume
          emptyDir: {}
```

Then in your LiteLLM config, use the token from file:

```yaml
model_list:
  - model_name: gpt-4
    litellm_params:
      model: azure/gpt-4
      api_base: https://your-resource.openai.azure.com/
      api_version: "2024-02-01"
      azure_ad_token: "oidc/env_path/AZURE_AD_TOKEN_FILE"  # Read token from file path in env var
```

## Quick Summary

| Approach | Complexity | Best For |
|----------|------------|----------|
| `azure_scope` parameter | ⭐ Simple | Standard enterprise setups with custom audience |
| Sidecar token fetcher | Medium | When built-in auth doesn't work |
| Custom init container | Medium | One-time token fetch (short-lived pods) |

Try the `azure_scope` approach first - it's the cleanest solution. What's the exact audience URI you're using? (e.g., `api://some-guid` or `api://some-app-name`)