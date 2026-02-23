# Securing kagent UI Access at Work (AKS + Istio + Entra ID)

## Problem

kagent has **no native authentication**. The current codebase uses an `UnsecureAuthenticator` that:

- Accepts any `user_id` from query parameters or headers
- Defaults to `admin@kagent.dev` if nothing is provided
- Has a `NoopAuthorizer` that allows all operations for all users
- The UI hardcodes `admin@kagent.dev` with a TODO comment

A design proposal exists ([EP-476](https://github.com/kagent-dev/kagent/issues/476)) for native OIDC support, but it is **not yet implemented**. Until it lands, authentication must be handled externally.

## Solution Overview

Use **Istio + Entra ID** to gate access before requests ever reach kagent. Two complementary approaches, depending on needs:

| Approach | What It Does | Best For |
|----------|-------------|----------|
| **Istio AuthorizationPolicy** | Blocks unauthorized requests at the sidecar | Service-to-service lockdown, namespace isolation |
| **OAuth2 Proxy** | Handles OIDC login flow, injects JWT | Human users accessing the UI via browser |

For the kagent UI (browser-based), you need **both**: OAuth2 Proxy handles the login redirect, and Istio policies enforce access rules at the mesh level.

## Architecture

```
Browser (SRE team member)
  |
  v
Istio Ingress Gateway
  |
  v (VirtualService: kagent.yourwork.com)
OAuth2 Proxy (sidecar or separate pod)
  |  - Redirects to Entra ID login if no session
  |  - Validates token, sets Authorization header
  v
Istio Sidecar (on kagent pod)
  |  - RequestAuthentication: validates JWT from Entra ID
  |  - AuthorizationPolicy: checks group claim
  v
kagent UI (:8080)
  |
  v
kagent Controller (API)
```

## Step 1: Entra ID App Registration

Create an App Registration in Azure Entra ID for kagent.

### Azure Portal / CLI

```bash
# Create the app registration
az ad app create \
  --display-name "kagent-ui" \
  --web-redirect-uris "https://kagent.yourwork.com/oauth2/callback" \
  --sign-in-audience AzureADMyOrg

# Note the Application (client) ID from the output
# Note your Tenant ID from Azure portal

# Add a client secret
az ad app credential reset \
  --id <APPLICATION_ID> \
  --display-name "kagent-oauth2-proxy"
```

### Enable Group Claims

In the App Registration manifest (Azure Portal > App Registrations > kagent-ui > Manifest):

```json
{
  "groupMembershipClaims": "SecurityGroup"
}
```

Or via Token Configuration > Add groups claim > Security groups.

### Create a Security Group

```bash
# Create the security group
az ad group create \
  --display-name "SRE-kagent-Users" \
  --mail-nickname "sre-kagent-users"

# Add members
az ad group member add \
  --group "SRE-kagent-Users" \
  --member-id <USER_OBJECT_ID>
```

Note the **Object ID** of this group - you'll use it in the AuthorizationPolicy.

## Step 2: Deploy OAuth2 Proxy

OAuth2 Proxy sits in front of the kagent UI and handles the browser login flow.

### Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: oauth2-proxy-secrets
  namespace: kagent
type: Opaque
stringData:
  client-id: "<APPLICATION_CLIENT_ID>"
  client-secret: "<CLIENT_SECRET>"
  cookie-secret: "<RANDOM_32_BYTE_BASE64>"  # python -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
```

### OAuth2 Proxy Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: kagent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oauth2-proxy
  template:
    metadata:
      labels:
        app: oauth2-proxy
        sidecar.istio.io/inject: "true"
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
          args:
            - --provider=oidc
            - --oidc-issuer-url=https://login.microsoftonline.com/<TENANT_ID>/v2.0
            - --client-id=$(CLIENT_ID)
            - --client-secret=$(CLIENT_SECRET)
            - --cookie-secret=$(COOKIE_SECRET)
            - --cookie-secure=true
            - --cookie-samesite=lax
            - --upstream=http://kagent-ui.kagent.svc:8080
            - --http-address=0.0.0.0:4180
            - --redirect-url=https://kagent.yourwork.com/oauth2/callback
            - --email-domain=yourwork.com
            - --scope=openid profile email
            - --pass-authorization-header=true
            - --pass-access-token=true
            - --set-authorization-header=true
            # Restrict to specific Entra ID group
            - --allowed-group=<SRE_KAGENT_USERS_GROUP_ID>
            - --oidc-groups-claim=groups
          env:
            - name: CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secrets
                  key: client-id
            - name: CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secrets
                  key: client-secret
            - name: COOKIE_SECRET
              valueFrom:
                secretKeyRef:
                  name: oauth2-proxy-secrets
                  key: cookie-secret
          ports:
            - containerPort: 4180
              name: http
          readinessProbe:
            httpGet:
              path: /ping
              port: 4180
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /ping
              port: 4180
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
  namespace: kagent
spec:
  selector:
    app: oauth2-proxy
  ports:
    - port: 4180
      targetPort: 4180
      name: http
```

## Step 3: Istio VirtualService

Route traffic through OAuth2 Proxy instead of directly to the kagent UI:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: kagent-ui
  namespace: kagent
spec:
  hosts:
    - kagent.yourwork.com
  gateways:
    - istio-system/main-gateway  # your existing Istio Gateway
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: oauth2-proxy.kagent.svc.cluster.local
            port:
              number: 4180
```

## Step 4: Istio RequestAuthentication

Defence in depth - validate the JWT at the mesh level too, not just in OAuth2 Proxy:

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: kagent-entra-jwt
  namespace: kagent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kagent  # match kagent controller/UI pod labels
  jwtRules:
    - issuer: "https://login.microsoftonline.com/<TENANT_ID>/v2.0"
      jwksUri: "https://login.microsoftonline.com/<TENANT_ID>/discovery/v2.0/keys"
      audiences:
        - "<APPLICATION_CLIENT_ID>"
      forwardOriginalToken: true
      outputClaimToHeaders:
        - header: x-user-email
          claim: email
        - header: x-user-groups
          claim: groups
```

## Step 5: Istio AuthorizationPolicy

Lock down who can access kagent, even if they somehow bypass OAuth2 Proxy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: kagent-sre-only
  namespace: kagent
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kagent
  action: ALLOW
  rules:
    # Allow OAuth2 Proxy to reach kagent (it's in the same namespace)
    - from:
        - source:
            principals: ["cluster.local/ns/kagent/sa/oauth2-proxy"]
      when:
        # Only if the request carries a valid JWT with the SRE group
        - key: request.auth.claims[groups]
          values: ["<SRE_KAGENT_USERS_GROUP_ID>"]
    # Allow internal agent-to-agent traffic (no JWT needed)
    - from:
        - source:
            namespaces: ["kagent"]
            principals: ["cluster.local/ns/kagent/sa/kagent"]
---
# Also lock down AKS-MCP so only kagent agents can reach it
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: aks-mcp-kagent-only
  namespace: aks-mcp
spec:
  selector:
    matchLabels:
      app: aks-mcp
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["kagent"]
```

## Step 6: Role-Based Access (Optional)

If you want to separate who can view (triage) vs who can trigger remediation, create two Entra ID groups and split policies:

```yaml
# SRE-Viewers: can use kagent UI and triage agent
# SRE-Admins: can also trigger remediation agent

apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: remediation-admins-only
  namespace: kagent
spec:
  selector:
    matchLabels:
      app: sre-remediation-agent
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["kagent"]
      when:
        - key: request.auth.claims[groups]
          values: ["<SRE_ADMINS_GROUP_ID>"]
```

## Summary

| Layer | Resource | Purpose |
|-------|----------|---------|
| Entra ID | App Registration + Security Group | Define who is allowed |
| OAuth2 Proxy | Deployment in kagent namespace | Browser login flow, session management |
| Istio VirtualService | Route to OAuth2 Proxy | Traffic routing |
| Istio RequestAuthentication | JWT validation | Verify Entra ID tokens at mesh level |
| Istio AuthorizationPolicy | Group-based allow rules | Enforce access: SRE group only |
| Istio AuthorizationPolicy | Namespace-based allow for AKS-MCP | Only kagent namespace can reach AKS-MCP |

## What Happens When EP-476 Lands

Once kagent implements native OIDC ([EP-476](https://github.com/kagent-dev/kagent/issues/476)):

- OAuth2 Proxy can be removed (kagent handles login directly)
- Istio RequestAuthentication + AuthorizationPolicy should stay (defence in depth)
- kagent will map OIDC group claims to internal RBAC roles
- The `NoopAuthorizer` gets replaced with a real authorizer

Until then, this setup gives you production-grade access control with zero changes to kagent itself.
