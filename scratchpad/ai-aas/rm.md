# UAMI vs SPN Authentication for AKS Workloads

Great question, Dave — and yes, switching to a **User-Assigned Managed Identity (UAMI)** via Workload Identity Federation would likely eliminate your JWT wrapper problem entirely. Here me explain why.

## The Core Difference

**With an SPN (your current setup):**
The flow is essentially OAuth2 client credentials. Your app needs to actively construct a token request — presenting the client ID + client secret to Azure AD's token endpoint, receiving a JWT back, then passing that JWT as a Bearer token to the AI-as-a-Service backend. HolmesGPT doesn't do this natively, hence your wrapper.

**With a UAMI + Workload Identity Federation:**
The authentication is handled *transparently by the infrastructure* — your app code (HolmesGPT) never touches a JWT directly.

## How the UAMI Handshake Actually Works

Since you already have the service account federated with the cluster, you're most of the way there. Here's the actual flow:

1. **Pod starts up** — the Azure Workload Identity webhook mutates the pod, injecting three things:
   - `AZURE_CLIENT_ID` — pointing to your UAMI
   - `AZURE_TENANT_ID`
   - `AZURE_FEDERATED_TOKEN_FILE` — a projected volume at `/var/run/secrets/azure/tokens/azure-identity-token`

2. **That projected token** is a Kubernetes service account token (not an Azure JWT) — it's signed by the cluster's OIDC issuer and is short-lived (typically 1 hour, auto-rotated).

3. **When your app needs to call the AI service**, the Azure SDK (or any OIDC-aware client using `DefaultAzureCredential` / `ManagedIdentityCredential`) reads that K8s SA token from the file, then exchanges it with Azure AD using the **federated credential trust**. The exchange is: "Here's a token from the trusted OIDC issuer (your AKS cluster), for this specific service account, in this namespace — give me an Azure AD access token scoped to the resource I need."

4. **Azure AD validates** the K8s token against the OIDC discovery document published by your AKS cluster, checks the federated credential mapping (issuer + subject must match), and returns a proper Azure AD JWT.

5. **That Azure AD JWT** is then used as the Bearer token to your AI-as-a-Service backend.

The critical difference: steps 3-5 happen **inside the Azure SDK automatically**. No client secret, no manual token construction.

## The Catch for HolmesGPT

Here's where it gets nuanced. The question is: **how does HolmesGPT call the AI backend?**

- If it uses the **Azure OpenAI SDK** or any SDK that supports `DefaultAzureCredential`, then yes — UAMI solves this completely. The SDK handles the token exchange transparently.

- If it makes **raw HTTP calls** to the model endpoint and expects you to configure a static API key or Bearer token, then UAMI alone won't help — because something still needs to do the token exchange and inject the resulting JWT into the HTTP Authorization header.

In that case, you'd still need a sidecar or init container that fetches the Azure AD token using the projected SA token and exposes it to HolmesGPT — but this is *significantly simpler* than your current SPN wrapper because there's no secret to manage, rotate, or store.

## What I'd Recommend

Check what HolmesGPT uses under the hood for HTTP calls to the model. If it supports the OpenAI-compatible API pattern:

```yaml
# Your HolmesGPT pod would just need these labels/annotations
# for workload identity, and the ServiceAccount binding:
apiVersion: v1
kind: ServiceAccount
metadata:
  name: holmesgpt-sa
  namespace: your-namespace
  annotations:
    azure.workload.identity/client-id: "<your-uami-client-id>"
  labels:
    azure.workload.identity/use: "true"
```

Then ensure the UAMI has a federated credential configured with:
- **Issuer**: your AKS cluster's OIDC issuer URL
- **Subject**: `system:serviceaccount:<namespace>:<holmesgpt-sa>`

If HolmesGPT doesn't natively support Azure SDK auth, a lightweight **token proxy sidecar** (even a simple Python/Go container that calls `ManagedIdentityCredential().get_token()` and refreshes it into a shared volume or local endpoint) would be cleaner than managing SPN secrets.

Want me to help you sketch out the sidecar approach, or shall we dig into what HolmesGPT's actual HTTP client supports?